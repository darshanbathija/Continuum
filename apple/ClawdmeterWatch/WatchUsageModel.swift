import Foundation
import Combine
import OSLog
import WatchKit
import ClawdmeterShared

/// watchOS view-model. Same shape as iOS's `UsageModel` but smaller:
///   - No "force poll on app foreground" via UIApplication notifications
///     (we use `WKExtension.applicationDidBecomeActiveNotification` instead).
///   - No background polling for now — we rely on the user opening the app
///     or on widget complications timeline-refreshing.
///
/// Token sourcing (revised after V1):
///   1. WatchConnectivity from the iPhone (preferred — works on simulator,
///      no iCloud dependency).
///   2. iCloud-Keychain shared access group (legacy fallback for cases
///      where the iPhone app isn't running but iCloud Keychain happens to
///      have populated the entry).
///
/// Usage fallback: if we never receive a token but the iPhone is forwarding
/// its own polled `UsageData` via WatchConnectivity, we render that
/// snapshot directly. The user sees fresh-ish numbers either way.
@MainActor
public final class WatchUsageModel: ObservableObject {

    /// Local keychain — no iCloud sync, no access group. Tokens delivered
    /// via WatchConnectivity land here.
    public let tokenProvider: PastedAnthropicTokenProvider
    /// iCloud-synced shared keychain — read-only fallback for the case
    /// where the bridge hasn't delivered yet but iCloud Keychain happens
    /// to have the entry.
    private let sharedTokenProvider: PastedAnthropicTokenProvider
    private let logger = Logger(subsystem: "com.clawdmeter.watch", category: "WatchUsageModel")

    @Published public private(set) var usage: UsageData?
    @Published public private(set) var lastError: AISourceError?
    @Published public private(set) var needsReauth: Bool = false
    /// `true` when the iPhone has forwarded its polled usage data via
    /// WatchConnectivity. Surfaces in the UI as a small "via iPhone" hint
    /// so the user knows where the number is coming from.
    @Published public private(set) var receivingFromPhone: Bool = false

    /// Per-provider usage snapshots delivered through the new
    /// `usageByProvider` WCSession channel. v5 iPhones never populate this
    /// — Watch falls back to the legacy `usage` field (Claude only). v6+
    /// iPhones drive the Codex + Gemini meters via this dict.
    @Published public private(set) var usageByProvider: [String: UsageData] = [:]
    /// Provider opt-in envelope mirrored from the iPhone/Mac. Nil means legacy
    /// all-provider behavior for older phone/Mac builds.
    @Published public private(set) var enabledProviderIDs: [String]? = UsageStore.readEnabledProviderIDs()

    private var poller: UsagePoller?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        // Local-only keychain for tokens the iPhone pushes.
        self.tokenProvider = PastedAnthropicTokenProvider()
        // iCloud-synced shared keychain — legacy fallback.
        self.sharedTokenProvider = PastedAnthropicTokenProvider.shared()
        observeWatchConnectivity()
        seedFromSharedKeychainIfNeeded()
        configurePollerIfTokenPresent()
        observeLifecycle()
    }

    public func forcePoll() {
        guard let poller else { return }
        Task { _ = await poller.forcePoll() }
    }

    public var hasAnyToken: Bool {
        tokenProvider.hasToken || sharedTokenProvider.hasToken
    }

    private func configurePollerIfTokenPresent() {
        let activeProvider: TokenProvider? = {
            if tokenProvider.hasToken { return tokenProvider }
            if sharedTokenProvider.hasToken { return sharedTokenProvider }
            return nil
        }()
        guard let provider = activeProvider else {
            poller?.stop()
            poller = nil
            return
        }
        if poller != nil { return }

        let source = AnthropicSource(tokenProvider: provider)
        let p = UsagePoller(source: source)
        p.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.consume(event) }
        }
        p.start()
        poller = p
        logger.info("Poller started")
    }

    private func consume(_ event: UsagePoller.Event) {
        switch event {
        case .usage(let u):
            guard isProviderEnabled("claude") else {
                usage = nil
                receivingFromPhone = false
                UsageStore.reloadWidgets(providerID: "claude")
                return
            }
            usage = u
            lastError = nil
            needsReauth = false
            receivingFromPhone = false
            UsageStore.write(u, providerID: "claude", displayName: "Claude")
            UsageStore.reloadWidgets(providerID: "claude")
        case .error(let err):
            lastError = err
            logger.error("Poller error: \(String(describing: err))")
        case .unauthenticatedNeedsReauth:
            needsReauth = true
        case .predictorWarning:
            break
        }
    }

    private func observeLifecycle() {
        NotificationCenter.default.publisher(for: WKApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                // Re-check Keychain (iCloud Keychain may have synced) and
                // poll fresh data when the watch face is brought back.
                self?.seedFromSharedKeychainIfNeeded()
                self?.configurePollerIfTokenPresent()
                self?.forcePoll()
            }
            .store(in: &cancellables)
    }

    // MARK: - WatchConnectivity ingress

    private func observeWatchConnectivity() {
        WatchTokenBridge.shared.didReceiveEnabledProviderIDs
            .sink { [weak self] ids in
                guard let self else { return }
                Task { @MainActor in
                    self.applyEnabledProviderIDs(ids)
                }
            }
            .store(in: &cancellables)

        WatchTokenBridge.shared.didReceiveToken
            .sink { [weak self] token in
                guard let self else { return }
                Task { @MainActor in
                    if let token, !token.isEmpty {
                        self.tokenProvider.setToken(token)
                        self.configurePollerIfTokenPresent()
                        self.forcePoll()
                    } else {
                        self.tokenProvider.clear()
                        self.poller?.stop()
                        self.poller = nil
                        self.usage = nil
                    }
                }
            }
            .store(in: &cancellables)

        WatchTokenBridge.shared.didReceiveUsage
            .sink { [weak self] usage in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isProviderEnabled("claude") else {
                        self.usage = nil
                        self.receivingFromPhone = false
                        UsageStore.reloadWidgets(providerID: "claude")
                        return
                    }
                    // Phone-forwarded snapshot trumps our (possibly stale)
                    // local poller result when we don't have our own token.
                    if self.tokenProvider.hasToken == false {
                        self.usage = usage
                        self.receivingFromPhone = true
                    } else {
                        // We have our own token; only adopt the phone's
                        // snapshot if it's newer than ours.
                        if let mine = self.usage {
                            if usage.updatedAt > mine.updatedAt {
                                self.usage = usage
                                self.receivingFromPhone = false
                            }
                        } else {
                            self.usage = usage
                            self.receivingFromPhone = true
                        }
                    }
                    UsageStore.write(usage, providerID: "claude", displayName: "Claude")
                    UsageStore.reloadWidgets(providerID: "claude")
                }
            }
            .store(in: &cancellables)

        // v6+ multi-provider channel. Mirrors each per-provider snapshot
        // into the App Group store so widgets/complications can pick it
        // up. Idempotent with the legacy `didReceiveUsage` Claude path —
        // both fire and the App Group write is the same.
        WatchTokenBridge.shared.didReceiveUsageByProvider
            .sink { [weak self] dict in
                guard let self else { return }
                Task { @MainActor in
                    let filtered = self.filterEnabledUsage(dict)
                    self.usageByProvider = filtered
                    for (id, snap) in filtered {
                        let display = self.displayName(for: id)
                        UsageStore.write(snap, providerID: id, displayName: display)
                        UsageStore.reloadWidgets(providerID: id)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func displayName(for providerID: String) -> String {
        switch providerID {
        case "claude": return "Claude"
        case "codex":  return "Codex"
        case "gemini": return "Gemini"
        default:       return providerID.capitalized
        }
    }

    public var codexUsage: UsageData? { isProviderEnabled("codex") ? usageByProvider["codex"] : nil }
    public var geminiUsage: UsageData? { isProviderEnabled("gemini") ? usageByProvider["gemini"] : nil }

    public func isProviderEnabled(_ providerID: String) -> Bool {
        guard let enabledRoots = enabledProviderRoots(enabledProviderIDs) else { return true }
        return enabledRoots.contains(ProviderRegistry.rootProviderID(for: providerID))
    }

    private func applyEnabledProviderIDs(_ ids: [String]?) {
        enabledProviderIDs = ids
        UsageStore.writeEnabledProviderIDs(ids)
        UsageStore.reloadWidgets()

        guard let enabledRoots = enabledProviderRoots(ids) else { return }
        if !enabledRoots.contains("claude") {
            usage = nil
            receivingFromPhone = false
        }
        usageByProvider = usageByProvider.filter { id, _ in
            enabledRoots.contains(ProviderRegistry.rootProviderID(for: id))
        }
    }

    private func filterEnabledUsage(_ dict: [String: UsageData]) -> [String: UsageData] {
        guard let enabledRoots = enabledProviderRoots(enabledProviderIDs) else { return dict }
        return dict.filter { id, _ in
            enabledRoots.contains(ProviderRegistry.rootProviderID(for: id))
        }
    }

    private func enabledProviderRoots(_ ids: [String]?) -> Set<String>? {
        guard let ids else { return nil }
        return Set(ids.map { ProviderRegistry.rootProviderID(for: $0) })
    }

    /// One-shot copy of the shared-keychain token (if any) into the local
    /// keychain. Saves us a round-trip when iCloud Keychain DOES happen to
    /// have the entry.
    private func seedFromSharedKeychainIfNeeded() {
        guard !tokenProvider.hasToken,
              let shared = sharedTokenProvider.currentAccessToken,
              !shared.isEmpty
        else { return }
        tokenProvider.setToken(shared)
    }
}
