import Foundation
import Combine
import ClawdmeterShared
import OSLog

/// Per-provider view-model that ties UsagePoller + AutoReviver (+ ESP32BLEDriver
/// for Claude) together. The Mac app instantiates one of these per source so
/// each menu bar item has its own independent poller, countdown, and revive
/// loop.
@MainActor
public final class AppModel: ObservableObject {

    public let config: ProviderConfig

    @Published public private(set) var usage: UsageData?
    @Published public private(set) var lastError: AISourceError?
    @Published public private(set) var needsReauth: Bool = false
    @Published public private(set) var hardwareState: BLEState = .idle
    @Published public private(set) var hardwareLinkEnabled: Bool = false

    /// Wall-clock — intentionally NOT `@Published`. Ticking a clock at 1 Hz on
    /// an ObservableObject observed by a `MenuBarExtra` label caused
    /// `AppDelegate.scenesDidChange` to rebuild the entire main-menu view graph
    /// every second on macOS Tahoe (sampled at 98% main-thread time, observable
    /// as a beachball when hovering the popover). Views that need a live clock
    /// drive their own cadence via `TimelineView`.
    public var now: Date { Date() }

    private let poller: UsagePoller
    private let bleDriver: ESP32BLEDriver?
    public let autoReviver: AutoReviver
    private let logger: Logger
    private var listenTask: Task<Void, Never>?
    private var bleTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    public init(
        config: ProviderConfig,
        source: any AISource,
        tokenProvider: TokenProvider,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.poller = UsagePoller(source: source)
        self.bleDriver = config.hasBLEHardware ? ESP32BLEDriver() : nil
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
        logger.warning("AppModel.deinit \(self.config.id)")
    }

    public func start() {
        logger.info("AppModel.start \(self.config.id) (isStarted=\(self.isStarted))")
        guard !isStarted else { return }
        isStarted = true

        // Async callback path. `publish()` in UsagePoller awaits this handler
        // inline; `MainActor.run` hops to main, sets `usage`, and returns
        // before the poller task continues. No GCD dispatch — that path was
        // dropping closures on Tahoe per codex's analysis.
        // Hop to MainActor via Task instead of DispatchQueue.main.async.
        // Observed on macOS Tahoe: GCD's main-queue async from a cooperative
        // task silently drops closures for one poller in a two-poller setup
        // (verified with diagnostics — Codex's dispatch ran, Claude's never
        // did, with no error). Task @MainActor uses Swift Concurrency's
        // executor scheduling which doesn't have this bug.
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
        if let bleDriver {
            bleTask = Task { [weak self] in
                guard let self else { return }
                for await state in bleDriver.stateUpdates {
                    await MainActor.run { self.hardwareState = state }
                }
            }
            if hardwareLinkEnabled {
                bleDriver.start()
                _ = bleDriver.stateMachine.handle(.startScanRequested)
            }
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

    public func toggleHardwareLink(_ enabled: Bool) {
        guard let bleDriver else { return }
        hardwareLinkEnabled = enabled
        if enabled {
            bleDriver.start()
            _ = bleDriver.stateMachine.handle(.startScanRequested)
        } else {
            bleDriver.reset()
        }
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
            usage = u
            lastError = nil
            needsReauth = false
            logger.info("consume \(self.config.id) AFTER SET: usage.session=\(self.usage?.sessionPct ?? -999)")

            // Mirror to the shared App Group cache so widgets (Mac/iOS/watch)
            // pick up the new snapshot on their next refresh.
            logger.info("calling UsageStore.write for \(self.config.id)")
            let didWrite = UsageStore.write(u, providerID: config.id, displayName: config.displayName)
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

            if config.hasBLEHardware, hardwareLinkEnabled, hardwareState == .connected {
                bleDriver?.writeUsage(u)
            }
        case .error(let err):
            lastError = err
            logger.error("Poller error: \(String(describing: err))")
        case .unauthenticatedNeedsReauth:
            needsReauth = true
            logger.warning("Re-auth required (E7 bound).")
        case .predictorWarning(let level):
            logger.notice("Predictor warning level: \(level.rawValue) min")
        }
    }
}
