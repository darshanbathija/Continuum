import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if canImport(Combine)
import Combine
#endif

/// Orchestrates a single `AISource` on a polling loop. Owns:
/// - Cadence (foreground 60s vs background per platform)
/// - Bounded refresh on auth failures (E7)
/// - Rate-limit backoff (Retry-After header)
/// - Epoch-aware merge with last-known `UsageData` (E3 + E14)
/// - Fan-out to publishers via an async stream (WCSession bridge / CloudKit mirror /
///   WidgetCenter reload all subscribe to this stream).
///
/// Lives in `ClawdmeterShared` so iPhone, Mac, and (via WCSession-pushed snapshots)
/// the watch all run the same orchestrator.
public final class UsagePoller: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var foregroundInterval: TimeInterval = 60
        public var backgroundInterval: TimeInterval = 300
        public var maxBackoffSeconds: TimeInterval = 600
        /// Terminal auth failures (provider CLI not logged in / read denied) get
        /// a LONG backoff so the poll loop stops re-reading the provider's
        /// cross-app dir (~/.codex, ~/.gemini, …) every tick — that recurring
        /// read is what re-fires the macOS "access data from other apps" prompt.
        /// Reserved for terminal auth states ONLY; transient errors
        /// (network/rate-limit) keep `maxBackoffSeconds`. Reset to 0 on the
        /// explicit foreground path (`forcePoll`).
        public var authFailureBackoffSeconds: TimeInterval = 21_600 // 6h
        /// Random 0...N seconds added to every inter-poll delay. Multiple
        /// accounts of the same provider (multi-account: a primary + secondary
        /// Claude) share one aggressively per-IP-rate-limited endpoint
        /// (`/api/oauth/usage`). Without jitter their loops, both anchored near
        /// app launch on the same fixed interval, poll in lockstep forever —
        /// the one that fires microseconds later always 429s and its gauge
        /// never populates. Jitter desyncs them within a cycle or two so each
        /// account gets a clean window. 0 disables (deterministic for tests).
        public var intervalJitterSeconds: TimeInterval = 8
        /// Time-Sensitive `WarningGate` for predictor (V1.5 surface).
        public var predictorEnabled: Bool = true

        public init() {}
    }

    public enum Event: Sendable {
        case usage(UsageData)
        case error(AISourceError)
        case unauthenticatedNeedsReauth
        case predictorWarning(BurnRatePredictor.WarningGate.Level)
    }

    private let source: any AISource
    private let predictor: BurnRatePredictor
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "UsagePoller")
    private let configuration: Configuration

    /// Async stream consumed by app/widget/bridge layers.
    ///
    /// V1 used `AsyncStream<Event>` here but observed that downstream consumers
    /// sometimes never received events under macOS Tahoe's MenuBarExtra
    /// lifecycle (the listen task entered `for await` and never woke). The
    /// direct-callback path below is the canonical fallback and matches the
    /// pattern used by `WCSession`/`NSURLSession` delegates: simpler, no actor
    /// hopping needed, no stream lifetime questions.
    public typealias EventHandler = @Sendable (Event) -> Void
    public var onEvent: EventHandler?

    /// Combine subject for SwiftUI-friendly subscription. Each event is
    /// published on the main thread (PublishSubject + receive(on:)).
    public let eventPublisher = PassthroughSubject<Event, Never>()

    /// Legacy stream — retained for tests; new code should use `eventPublisher` or `onEvent`.
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private var lastUsage: UsageData?
    private var currentBackoffSeconds: TimeInterval = 0
    /// Timestamp of the last successful poll, used by the quiet-machine gate:
    /// if the source's data dir hasn't changed since this instant, the next
    /// background tick republishes the cached usage instead of re-reading the
    /// cross-app dir (avoiding the macOS "data from other apps" prompt).
    private var lastSourceMtimeProbeDate: Date?
    private var fiveMinGate: BurnRatePredictor.WarningGate
    private var task: Task<Void, Never>?

    public init(
        source: any AISource,
        predictor: BurnRatePredictor = BurnRatePredictor(),
        configuration: Configuration = Configuration()
    ) {
        self.source = source
        self.predictor = predictor
        self.configuration = configuration
        self.fiveMinGate = BurnRatePredictor.WarningGate(level: .fiveMin)
        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { c in continuation = c }
        self.continuation = continuation
    }

    /// Publish event synchronously. Handler is non-async — it's responsible
    /// for hopping to its own actor (e.g., AppModel uses DispatchQueue.main).
    /// Combine subject also fires for SwiftUI subscribers via .receive(on:).
    private func publish(_ event: Event) {
        continuation.yield(event)
        onEvent?(event)
        eventPublisher.send(event)
    }

    /// Current best-known `UsageData` (post-merge). Useful for instant render on app launch.
    public var currentUsage: UsageData? { lastUsage }

    /// Start polling. Repeated calls are no-ops.
    public func start(initialDelaySeconds: TimeInterval = 0) {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            if initialDelaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(initialDelaySeconds * 1_000_000_000))
            }
            while !Task.isCancelled {
                await self.tick()
                // Base cadence (or active backoff), plus jitter so concurrent
                // same-provider pollers don't collide on the shared rate-limited
                // endpoint every cycle (see `intervalJitterSeconds`).
                let base = max(self.configuration.foregroundInterval, self.currentBackoffSeconds)
                let jitterCap = max(0, self.configuration.intervalJitterSeconds)
                let jitter = jitterCap > 0 ? Double.random(in: 0...jitterCap) : 0
                try? await Task.sleep(nanoseconds: UInt64((base + jitter) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Single poll cycle. Public so apps can also `forcePoll()` on foreground.
    @discardableResult
    public func forcePoll() async -> Event {
        // Explicit foreground / user action (popover open, reviveNow, refresh):
        // clear any long auth backoff and bypass the quiet-machine gate so we
        // re-attempt the cross-app read right now (re-surfacing the OS prompt
        // here is acceptable — the user just asked for fresh data).
        currentBackoffSeconds = 0
        return await tick(force: true)
    }

    @discardableResult
    private func tick(force: Bool = false) async -> Event {
        // Quiet-machine gate: on a background tick (not forced), if we already
        // have a cached value, aren't in backoff, and the source's data dir is
        // unchanged since the last successful poll, republish the cached usage
        // WITHOUT re-reading the cross-app dir. A no-op `dataChangedSince`
        // default keeps every other source on the always-poll path.
        if !force,
           let prev = lastUsage,
           currentBackoffSeconds == 0,
           !source.dataChangedSince(lastSourceMtimeProbeDate) {
            let event = Event.usage(prev)
            publish(event)
            return event
        }
        do {
            let fresh = try await source.poll()
            currentBackoffSeconds = 0
            lastSourceMtimeProbeDate = Date()

            // Plan E3 + E14: merge using (epoch, updatedAt) tuple ordering.
            if let prev = lastUsage, !prev.shouldReplace(with: fresh) {
                logger.debug("Skipping stale poll result (epoch=\(fresh.sessionEpoch), updatedAt=\(fresh.updatedAt))")
                let event = Event.usage(prev)
                publish(event)
                return event
            }

            lastUsage = fresh

            if configuration.predictorEnabled {
                predictor.update(with: fresh)
                let proj = predictor.project()
                if fiveMinGate.evaluate(minutesRemaining: proj.minutesRemaining) {
                    let warn = Event.predictorWarning(.fiveMin)
                    publish(warn)
                }
            }

            let event = Event.usage(fresh)
            publish(event)
            logger.info("Poll OK: session=\(fresh.sessionPct)% weekly=\(fresh.weeklyPct)% status=\(fresh.status.rawValue)")
            return event
        } catch let error as AISourceError {
            return await handle(error: error)
        } catch {
            return await handle(error: .networkFailure(underlying: error))
        }
    }

    @discardableResult
    private func handle(error: AISourceError) async -> Event {
        switch error {
        case .unauthenticated:
            // Per E7: bounded refresh attempts.
            do {
                _ = try await source.refreshCredentialsIfNeeded()
                logger.info("Token refreshed; next tick will retry.")
            } catch AISourceError.authExpired {
                logger.error("OAuth refresh exhausted (E7 bound). User must re-auth.")
                // Terminal auth state: stop the loop re-reading the provider's
                // cross-app dir every tick (which re-fires the macOS "data from
                // other apps" prompt) until the user logs back in / foregrounds
                // the app (forcePoll resets this to 0).
                currentBackoffSeconds = configuration.authFailureBackoffSeconds
                let event = Event.unauthenticatedNeedsReauth
                publish(event)
                return event
            } catch {
                logger.error("Unexpected refresh error: \(String(describing: error))")
            }
            // Exponential backoff before retry.
            currentBackoffSeconds = min(max(currentBackoffSeconds * 2, 30), configuration.maxBackoffSeconds)
            let event = Event.error(error)
            publish(event)
            return event

        case .rateLimited(let retryAfter):
            let suggested = retryAfter ?? 60
            currentBackoffSeconds = min(suggested, configuration.maxBackoffSeconds)
            logger.notice("Rate limited; sleeping \(self.currentBackoffSeconds)s before next tick.")
            let event = Event.error(error)
            publish(event)
            return event

        case .authExpired:
            logger.error("Auth expired (caller must surface re-auth UNNotification per plan).")
            // Terminal auth state — long backoff (see authFailureBackoffSeconds)
            // so we stop the every-tick cross-app re-read that re-triggers the
            // macOS TCC prompt. forcePoll() clears it on the next foreground.
            currentBackoffSeconds = configuration.authFailureBackoffSeconds
            let event = Event.unauthenticatedNeedsReauth
            publish(event)
            return event

        case .networkFailure, .malformedResponse, .dataSourceContractViolation:
            // Exponential backoff capped at config max.
            currentBackoffSeconds = min(max(currentBackoffSeconds * 2, 5), configuration.maxBackoffSeconds)
            logger.error("Poll error: \(String(describing: error)); next tick in \(self.currentBackoffSeconds)s")
            let event = Event.error(error)
            publish(event)
            return event
        }
    }
}
