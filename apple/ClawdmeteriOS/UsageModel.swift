import Foundation
import Combine
import OSLog
import UIKit
import ClawdmeterShared

/// iOS-specific view-model that wraps a single `UsagePoller` for Claude.
///
/// Why a fresh implementation rather than reusing the Mac's `AppModel`:
///   - The Mac variant instantiates BLE + AutoReviver + Codex sources that
///     don't apply on iOS (no Codex CLI, no ESP32 device, no daemon to
///     drive). Threading those guards through `AppModel` is bigger surface
///     than a clean iOS version.
///   - We need iOS-specific lifecycle: pause polling on background, resume
///     on foreground, and mirror snapshots to the App Group `UsageStore`
///     so the (future) Lock Screen / StandBy widgets pick them up.
@MainActor
public final class UsageModel: ObservableObject {

    public let tokenProvider: PastedAnthropicTokenProvider
    private let logger = Logger(subsystem: "com.clawdmeter.ios", category: "UsageModel")

    @Published public private(set) var usage: UsageData?
    @Published public private(set) var lastError: AISourceError?
    @Published public private(set) var needsReauth: Bool = false
    @Published public private(set) var isPolling: Bool = false

    private var poller: UsagePoller?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        // Use the shared, iCloud-synced Keychain entry. The Mac app mirrors
        // Claude Code's token here on launch, so on a fresh iPhone install
        // with iCloud Keychain on (the default), this is already populated.
        // Falls through to manual paste if the user hasn't run the Mac app
        // or doesn't have iCloud Keychain.
        self.tokenProvider = PastedAnthropicTokenProvider.shared()
        configurePollerIfTokenPresent()
        observeAppLifecycle()
    }

    /// Set/replace the Anthropic token. Tearing down + rebuilding the poller
    /// is fine — it's cheap and lets us pick up a fresh URLSession.
    public func setToken(_ raw: String) {
        let ok = tokenProvider.setToken(raw)
        logger.info("setToken: ok=\(ok, privacy: .public) hasToken=\(self.tokenProvider.hasToken, privacy: .public)")
        if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configurePollerIfTokenPresent()
            forcePoll()
        } else {
            // Sign-out: tear down poller, drop usage so UI returns to the
            // "paste token" state.
            poller?.stop()
            poller = nil
            usage = nil
            lastError = nil
            needsReauth = false
            isPolling = false
        }
    }

    /// One-shot poll, ignoring cadence. Used by pull-to-refresh and after
    /// the user pastes a new token.
    public func forcePoll() {
        guard let poller else { return }
        Task { _ = await poller.forcePoll() }
    }

    // MARK: - Private

    private func configurePollerIfTokenPresent() {
        guard tokenProvider.hasToken else {
            poller?.stop()
            poller = nil
            isPolling = false
            return
        }
        if poller != nil { return }

        let source = AnthropicSource(tokenProvider: tokenProvider)
        let p = UsagePoller(source: source)
        p.onEvent = { [weak self] event in
            // Hop to main — the poller fires from a cooperative task.
            DispatchQueue.main.async {
                self?.consume(event)
            }
        }
        p.start()
        poller = p
        isPolling = true
        logger.info("Poller started")
    }

    private func consume(_ event: UsagePoller.Event) {
        switch event {
        case .usage(let u):
            usage = u
            lastError = nil
            needsReauth = false
            // Mirror to App Group for the widget extension to pick up.
            UsageStore.write(u, providerID: "claude", displayName: "Claude")
            UsageStore.reloadWidgets(providerID: "claude")
        case .error(let err):
            lastError = err
            logger.error("Poller error: \(String(describing: err))")
        case .unauthenticatedNeedsReauth:
            needsReauth = true
            logger.warning("Re-auth required")
        case .predictorWarning(let level):
            logger.notice("Predictor warning level: \(level.rawValue) min")
        }
    }

    // MARK: - Lifecycle

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.forcePoll() }
            .store(in: &cancellables)
        // We don't stop the poller on background — iOS will pause network
        // anyway, and resuming polling is cheap. We could add BGAppRefreshTask
        // here for ~5min cadence in the background.
    }
}
