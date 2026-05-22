import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
                let nextDelay = max(self.configuration.foregroundInterval, self.currentBackoffSeconds)
                try? await Task.sleep(nanoseconds: UInt64(nextDelay * 1_000_000_000))
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
        await tick()
    }

    @discardableResult
    private func tick() async -> Event {
        do {
            let fresh = try await source.poll()
            currentBackoffSeconds = 0

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
