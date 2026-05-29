import Foundation
import Combine
import ClawdmeterShared
import OSLog

/// Per-provider view-model. The Mac app instantiates one of these per source
/// (Claude + Codex) so each menu bar item has its own independent poller,
/// countdown, and auto-revive loop.
@MainActor
public final class AppModel: ObservableObject {

    public let config: ProviderConfig

    @Published public private(set) var usage: UsageData?
    @Published public private(set) var lastError: AISourceError?
    @Published public private(set) var needsReauth: Bool = false

    /// Wall-clock — intentionally NOT `@Published`. Ticking a clock at 1 Hz on
    /// an ObservableObject observed by a `MenuBarExtra` label caused
    /// `AppDelegate.scenesDidChange` to rebuild the entire main-menu view graph
    /// every second on macOS Tahoe (sampled at 98% main-thread time, observable
    /// as a beachball when hovering the popover). Views that need a live clock
    /// drive their own cadence via `TimelineView`.
    public var now: Date { Date() }

    private let poller: UsagePoller
    public let autoReviver: AutoReviver
    private let logger: Logger
    private var listenTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    // F1d-wire (strangler-fig per D23): per-period sequence cursor for
    // the Cursor adapter. The polling loop calls
    // `CursorAdapterUsageBridge.project(usage:sessionId:sequenceNumber:)`
    // each time it consumes a polled `UsageData`; the sequence number
    // advances by one per poll so the canonical event id
    // (`cursor-{sessionId}-{seq}`) is unique per poll. Downstream
    // consumers that dedup by id (orchestration store F2, push gateway
    // E6) see one event per poll — no double-counting.
    //
    // Reset to 0 whenever the period epoch changes (Cursor extends
    // billing periods automatically; a different epoch means a new
    // period started). Tracked here rather than on the poller because
    // the bridge is invoked at the AppModel consume boundary — that's
    // where the strangler-fig flag check lives.
    //
    // Only used when `config.id == "cursor"` AND
    // `FeatureFlags.useCursorAdapter` is on. Other providers (and
    // Cursor with the flag off) never read this state.
    private var cursorAdapterSequence: UInt64 = 0
    private var cursorAdapterLastSessionId: String?

    public init(
        config: ProviderConfig,
        source: any AISource,
        tokenProvider: TokenProvider,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.poller = UsagePoller(source: source)
        self.autoReviver = AutoReviver(
            tokenProvider: tokenProvider,
            session: urlSession,
            model: config.reviveModel,
            endpoint: config.reviveEndpoint,
            anthropicVersion: config.reviveAuthVersion
        )
        self.logger = Logger(subsystem: "com.clawdmeter.mac", category: "AppModel.\(config.id)")
        logger.info("AppModel.init \(config.id) instance=\(ObjectIdentifier(self).hashValue)")
    }

    deinit {
        // Audit P1 fix: invalidate the run-loop-retained tick timer so a
        // replaced AppModel (e.g. on sign-in switch) doesn't keep firing
        // refresh callbacks through `[weak self]` against a zombie
        // instance.
        clockTimer?.invalidate()
        clockTimer = nil
        logger.warning("AppModel.deinit \(self.config.id)")
    }

    public func start() {
        logger.info("AppModel.start \(self.config.id) (isStarted=\(self.isStarted))")
        guard !isStarted else { return }
        isStarted = true

        // RunLoop.main.perform — every other main-queue mechanism silently
        // drops closures for Claude's poller on Tahoe (verified for GCD,
        // Task @MainActor, Task.detached @MainActor, OperationQueue.main).
        // RunLoop.main targets the actual NSRunLoop directly.
        let providerLogger = Logger(subsystem: "com.clawdmeter.mac", category: "onEvent.\(self.config.id)")
        poller.onEvent = { [weak self] event in
            providerLogger.info("onEvent INVOKED")
            RunLoop.main.perform { [weak self] in
                providerLogger.info("RunLoop.main RUNNING")
                self?.consume(event)
            }
            // Wake the runloop in case it's idle.
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        poller.start()

        // AutoReviver only needs second-precision triggering near the reset
        // boundary. Don't publish anything — see the `now` doc-comment above
        // for why ticking @Published kills MenuBarExtra performance.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let usage = self.usage {
                    await self.autoReviver.tick(usage: usage, now: Date())
                }
            }
        }
    }

    /// Stop polling — used when a provider is toggled OFF (opt-in providers,
    /// v0.29.32). Quiesces the poller + tick timer so no further keychain
    /// reads or network polls happen. Idempotent; re-`start()` re-arms cleanly
    /// (poller's `guard task == nil` is satisfied after stop nils its task).
    /// The last `usage` snapshot is intentionally left intact.
    public func stop() {
        logger.info("AppModel.stop \(self.config.id) (isStarted=\(self.isStarted))")
        guard isStarted else { return }
        isStarted = false
        poller.stop()
        poller.onEvent = nil
        clockTimer?.invalidate()
        clockTimer = nil
    }

    public func forcePoll() {
        Task { _ = await poller.forcePoll() }
    }

    public func setAutoReviveEnabled(_ enabled: Bool) {
        autoReviver.isEnabled = enabled
    }

    public func reviveNow() {
        Task { @MainActor in
            await autoReviver.fireNow()
            _ = await poller.forcePoll()
        }
    }

    private func consume(_ event: UsagePoller.Event) {
        logger.info("consume \(self.config.id) ENTER: \(String(describing: event))")
        switch event {
        case .usage(let u):
            // F1d-wire shipped in #171 and is now default-ON per
            // F1-finalize: when this is the Cursor consumer, polled
            // UsageData routes through CursorAdapter → canonical
            // .sessionStarted event → projected back into UsageData via
            // CursorAdapterUsageBridge. The
            // `FeatureFlags.useCursorAdapter` env/UserDefaults override
            // remains live as a rollback escape hatch — flip the env to
            // `CLAWDMETER_USE_CURSOR_ADAPTER=0` and the polled UsageData
            // flows through unchanged (the pre-F1 path). Parity enforced
            // by `F1dParityTests`.
            //
            // Dedup contract: the canonical event id is
            // `cursor-{sessionId}-{seq}` where sessionId is derived
            // from the period epoch (stable across polls of the same
            // billing period) and seq increments per poll. Downstream
            // consumers (orchestration store F2, push gateway E6) that
            // subscribe to the canonical event stream see one unique
            // event per poll — no double-counting.
            let routed: UsageData = {
                guard config.id == "cursor", FeatureFlags.useCursorAdapter else {
                    return u
                }
                let sid = CursorAdapterUsageBridge.sessionId(forPeriodEpoch: u.sessionEpoch)
                if sid != cursorAdapterLastSessionId {
                    // New billing period — reset the sequence cursor so
                    // the canonical event id space restarts at 0 for the
                    // new period. Cursor extends periods automatically,
                    // but a fresh epoch means a fresh period.
                    cursorAdapterSequence = 0
                    cursorAdapterLastSessionId = sid
                }
                let seq = cursorAdapterSequence
                cursorAdapterSequence &+= 1
                guard let projected = CursorAdapterUsageBridge.project(
                    usage: u,
                    sessionId: sid,
                    sequenceNumber: seq
                ) else {
                    // Defensive: bridge returned nil (adapter contract
                    // breakage). Fall through to the polled value so
                    // the wire is fail-safe.
                    logger.warning("CursorAdapterUsageBridge returned nil; falling back to polled UsageData")
                    return u
                }
                return projected
            }()

            usage = routed
            lastError = nil
            needsReauth = false
            logger.info("consume \(self.config.id) AFTER SET: usage.session=\(self.usage?.sessionPct ?? -999)")

            // Mirror to the shared App Group cache so widgets (Mac/iOS/watch)
            // pick up the new snapshot on their next refresh.
            let didWrite = UsageStore.write(routed, providerID: config.id, displayName: config.displayName)
            logger.info("UsageStore.write returned \(didWrite) for \(self.config.id)")
            UsageStore.reloadWidgets(providerID: config.id)

            // Mirror Codex snapshots to iCloud KV so the iPhone — which
            // can't read `~/.codex/sessions/` itself — picks them up.
            // Claude is already polled directly on iOS via the shared
            // Keychain token, no mirror needed.
            if config.id == "codex" {
                UsageCloudMirror.shared.writeSnapshot(
                    u,
                    providerID: config.id,
                    displayName: config.displayName
                )
            }
        case .error(let err):
            lastError = err
            logger.error("Poller error: \(String(describing: err))")
        case .unauthenticatedNeedsReauth:
            needsReauth = true
            logger.warning("Re-auth required.")
        case .predictorWarning(let level):
            logger.notice("Predictor warning level: \(level.rawValue) min")
        }
    }
}
