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
    public let autoReviver: AutoReviver
    private let logger = Logger(subsystem: "com.clawdmeter.ios", category: "UsageModel")

    @Published public private(set) var usage: UsageData?
    @Published public private(set) var lastError: AISourceError?
    @Published public private(set) var needsReauth: Bool = false
    @Published public private(set) var isPolling: Bool = false
    @Published public private(set) var now: Date = Date()

    /// Codex snapshot mirrored from the Mac via iCloud Key-Value store
    /// AND/OR via the paired daemon's `/usage` endpoint. `nil` if the
    /// user hasn't run the Mac app or iCloud sync hasn't propagated yet.
    @Published public private(set) var codexSnapshot: UsageStore.Snapshot?

    /// Gemini snapshot mirrored from the paired Mac daemon's `/usage`
    /// dict (wire v6+). Gemini doesn't have a local poll path on iOS —
    /// the Gemini CLI's OAuth token lives at `~/.gemini/oauth_creds.json`
    /// on the Mac and the daemon is the only authority for the
    /// cloudcode-pa quota. `nil` until the daemon serves its first
    /// `/usage` response carrying a `gemini` entry.
    @Published public private(set) var geminiSnapshot: UsageStore.Snapshot?

    /// Cursor snapshot mirrored from the paired Mac daemon's `/usage`
    /// dict. Cursor usage is polled on the Mac from the Cursor Agent
    /// account and mirrored to iOS widgets/watch through the same
    /// provider-keyed path as Gemini.
    @Published public private(set) var cursorSnapshot: UsageStore.Snapshot?

    /// OpenCode usage mirrored from the paired Mac daemon.
    @Published public private(set) var opencodeSnapshot: UsageStore.Snapshot?

    /// Grok usage mirrored from the paired Mac daemon.
    @Published public private(set) var grokSnapshot: UsageStore.Snapshot?

    /// Aggregated token-analytics snapshot mirrored from the Mac via iCloud
    /// KV. `nil` until the Mac has run with the iCloud entitlement live.
    /// Drives the iOS Analytics tab. Plan A19.
    @Published public private(set) var analyticsSnapshot: UsageHistorySnapshot?
    /// Latest provider opt-in envelope from the paired Mac daemon. Nil means
    /// legacy all-provider behavior for older Mac builds.
    @Published public private(set) var enabledProviderIDs: [String]?
    /// Multi-account (wire v28): secondary accounts' live usage from the
    /// paired Mac's /usage envelope. Empty pre-v28 / single-account.
    @Published public private(set) var secondaryAccounts: [UsageEnvelope.SecondaryInstanceUsage] = []

    private var poller: UsagePoller?
    private var clockTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Background timer that pulls live Codex usage + analytics from the
    /// paired Mac daemon (over Tailscale via `AgentControlClient`). Set
    /// up by `wire(daemonClient:)` once the iOS app has finished pairing.
    /// Drops the iCloud-KV-sync dependency for users without a paid
    /// Apple Developer entitlement.
    private var daemonRefreshTimer: Timer?
    private weak var daemonClient: AgentControlClient?

    deinit {
        // Audit P1 fix: invalidate the run-loop-retained refresh timer
        // so a replaced UsageModel (sign-in switch, app reset) doesn't
        // keep firing `refreshFromDaemon` against a zombie instance.
        daemonRefreshTimer?.invalidate()
        daemonRefreshTimer = nil
    }

    public init() {
        // Use the shared, iCloud-synced Keychain entry. The Mac app mirrors
        // Claude Code's token here on launch, so on a fresh iPhone install
        // with iCloud Keychain on (the default), this is already populated.
        // Falls through to manual paste if the user hasn't run the Mac app
        // or doesn't have iCloud Keychain.
        let provider = PastedAnthropicTokenProvider.shared()
        self.tokenProvider = provider
        self.autoReviver = AutoReviver(tokenProvider: provider)
        // Auto-clear bogus stored tokens (e.g. garbage left over from a
        // failed paste before we hardened the extraction code). Real Claude
        // Code OAuth tokens always start with `sk-ant-oat01-` and are
        // ~108 chars; if what we read is wildly off, drop it so the UI
        // returns the user to a clean state.
        if let stored = tokenProvider.currentAccessToken,
           !Self.looksLikeValidToken(stored) {
            logger.warning("Discarding malformed stored token (len=\(stored.count, privacy: .public))")
            tokenProvider.clear()
        }
        let initialToken = tokenProvider.currentAccessToken
        logger.info("UsageModel init: hasToken=\(initialToken != nil, privacy: .public) len=\(initialToken?.count ?? 0, privacy: .public)")
        configurePollerIfTokenPresent()
        observeAppLifecycle()
        startClock()
        enabledProviderIDs = UsageStore.readEnabledProviderIDs()
        observeCloudMirror()
        // Push whatever token we have to the paired Apple Watch so it can
        // poll on its own. iCloud Keychain doesn't reliably reach watchOS
        // (especially on simulators) so WatchConnectivity is the safety net.
        WatchTokenBridge.shared.pushToken(tokenProvider.currentAccessToken)
        WatchTokenBridge.shared.pushEnabledProviderIDs(enabledProviderIDs)
    }

    /// Pull whatever Codex snapshot iCloud currently has, then subscribe
    /// for live updates pushed from the Mac. iCloud KV's
    /// `didChangeExternallyNotification` fires when a remote write lands.
    private func observeCloudMirror() {
        analyticsSnapshot = UsageCloudMirror.shared.readAnalyticsSnapshot()
        if let analyticsSnapshot {
            applyEnabledProviderIDs(analyticsSnapshot.enabledProviderIDs)
        }
        codexSnapshot = isProviderEnabled("codex")
            ? UsageCloudMirror.shared.readSnapshot(providerID: "codex")
            : nil
        UsageCloudMirror.shared.didUpdate
            .sink { [weak self] providerID in
                guard let self else { return }
                if providerID == "codex" {
                    let snap = UsageCloudMirror.shared.readSnapshot(providerID: "codex")
                    Task { @MainActor in
                        guard self.isProviderEnabled("codex") else {
                            self.codexSnapshot = nil
                            UsageStore.reloadWidgets(providerID: "codex")
                            return
                        }
                        self.codexSnapshot = snap
                        if let snap {
                            UsageStore.write(snap.usage, providerID: "codex", displayName: snap.displayName)
                            UsageStore.reloadWidgets(providerID: "codex")
                        }
                    }
                } else if providerID == "analytics" {
                    let snap = UsageCloudMirror.shared.readAnalyticsSnapshot()
                    Task { @MainActor in
                        // Plan A19: monotonic ordering. Only accept newer
                        // snapshots so out-of-order iCloud delivery can't
                        // clobber a fresh value with a stale one.
                        if let snap, snap.computedAt > (self.analyticsSnapshot?.computedAt ?? .distantPast) {
                            self.analyticsSnapshot = snap
                            self.applyEnabledProviderIDs(snap.enabledProviderIDs)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Subscribe to a paired Mac daemon for live Codex usage + analytics
    /// so the iPhone doesn't depend on iCloud. Idempotent — calling
    /// twice replaces the previous client/timer. Polls every 30s while
    /// the app is foregrounded; iCloud KV stays available as a fallback
    /// for users on a paid developer account.
    public func wire(daemonClient: AgentControlClient) {
        self.daemonClient = daemonClient
        daemonRefreshTimer?.invalidate()
        // Immediate fetch — don't wait 30s on first launch.
        Task { @MainActor in await self.refreshFromDaemon() }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshFromDaemon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        daemonRefreshTimer = timer
    }

    /// Manual pull used by iOS Analytics. Keeps daemon/iCloud precedence in
    /// one model instead of letting views fetch and merge snapshots themselves.
    public func refreshMirroredData() async {
        await refreshFromDaemon()
    }

    /// One-shot fetch — drop the daemon's `/usage` + `/analytics` data
    /// onto the published properties. The Live tab's CodexSection and
    /// the Analytics tab already render from these publishers, so the
    /// switch to daemon-sourced data is invisible to the views.
    @MainActor
    private func refreshFromDaemon() async {
        guard let client = daemonClient else { return }
        // Only attempt when the client is actually paired — otherwise we
        // just burn cellular every 30s for 404s.
        guard client.host != nil, client.token != nil else { return }

        async let usagePayload = client.fetchUsage()
        async let analyticsPayload = client.fetchAnalytics()

        if let usage = await usagePayload {
            applyEnabledProviderIDs(usage.enabledProviderIDs)
            secondaryAccounts = usage.secondaryInstanceUsage()
            // Codex: prefer the v6 dict + per-provider fallback shape;
            // legacy `usage.codex` field is still populated by the server
            // and the `usageData(for:)` helper handles fallback per X1.
            if let codex = usage.usageData(for: "codex") {
                codexSnapshot = UsageStore.Snapshot(
                    providerID: "codex",
                    displayName: "Codex",
                    usage: codex,
                    writtenAt: usage.lastChecked
                )
                UsageStore.write(codex, providerID: "codex", displayName: "Codex")
                UsageStore.reloadWidgets(providerID: "codex")
                // Forward to the paired Apple Watch's per-provider channel.
                WatchTokenBridge.shared.pushUsage(providerID: "codex", codex)
            }
            // Gemini: only available on wire v6+. v5 Macs return no
            // `gemini` entry in the dict and `usageData(for:)` returns nil.
            if let gemini = usage.usageData(for: "gemini") {
                geminiSnapshot = UsageStore.Snapshot(
                    providerID: "gemini",
                    displayName: "Gemini",
                    usage: gemini,
                    writtenAt: usage.lastChecked
                )
                UsageStore.write(gemini, providerID: "gemini", displayName: "Gemini")
                UsageStore.reloadWidgets(providerID: "gemini")
                WatchTokenBridge.shared.pushUsage(providerID: "gemini", gemini)
                // D5: drive the Gemini quota Live Activity. Status .unknown
                // means cached-fallback (D7) — stale flag tells the widget
                // to render a small caution dot in the Dynamic Island.
                GeminiQuotaLiveActivityCoordinator.shared.refresh(
                    usage: gemini,
                    stale: gemini.status == .unknown
                )
            }
            if let cursor = usage.usageData(for: "cursor") {
                cursorSnapshot = UsageStore.Snapshot(
                    providerID: "cursor",
                    displayName: "Cursor",
                    usage: cursor,
                    writtenAt: usage.lastChecked
                )
                UsageStore.write(cursor, providerID: "cursor", displayName: "Cursor")
                UsageStore.reloadWidgets(providerID: "cursor")
                WatchTokenBridge.shared.pushUsage(providerID: "cursor", cursor)
            }
            if let opencode = usage.usageData(for: "opencode") {
                opencodeSnapshot = UsageStore.Snapshot(
                    providerID: "opencode",
                    displayName: "OpenCode",
                    usage: opencode,
                    writtenAt: usage.lastChecked
                )
                UsageStore.write(opencode, providerID: "opencode", displayName: "OpenCode")
                UsageStore.reloadWidgets(providerID: "opencode")
                WatchTokenBridge.shared.pushUsage(providerID: "opencode", opencode)
            }
            if let grok = usage.usageData(for: "grok") {
                grokSnapshot = UsageStore.Snapshot(
                    providerID: "grok",
                    displayName: "Grok",
                    usage: grok,
                    writtenAt: usage.lastChecked
                )
                UsageStore.write(grok, providerID: "grok", displayName: "Grok")
                UsageStore.reloadWidgets(providerID: "grok")
                WatchTokenBridge.shared.pushUsage(providerID: "grok", grok)
            }
        }
        if let snap = await analyticsPayload {
            // Plan A19 monotonic guard: only accept newer snapshots.
            if snap.computedAt > (analyticsSnapshot?.computedAt ?? .distantPast) {
                analyticsSnapshot = snap
                applyEnabledProviderIDs(snap.enabledProviderIDs)
            }
        }
    }

    public func setAutoReviveEnabled(_ enabled: Bool) {
        _ = enabled
        autoReviver.isEnabled = false
    }

    public func reviveNow() {
        autoReviver.isEnabled = false
    }

    private func startClock() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                if let usage = self.usage {
                    await self.autoReviver.tick(usage: usage, now: self.now)
                }
            }
        }
    }

    /// Sanity-check on what we're about to save / what we just read. Tokens
    /// look like `sk-ant-oat01-<102 random chars>` ≈ 108 chars total, with
    /// some wiggle room for future Anthropic format changes.
    private static func looksLikeValidToken(_ token: String) -> Bool {
        token.hasPrefix("sk-ant-") && token.count <= 200 && !token.contains("\n")
    }

    /// Set/replace the Anthropic token. Accepts a bare `sk-ant-oat01-…`
    /// token, the full JSON blob Claude Code stores
    /// (`{"claudeAiOauth":{"accessToken":"…","…"}}`), or an empty string to
    /// clear. Returns `true` if accepted, `false` if extraction couldn't
    /// find something that looks like a Claude OAuth token — the UI
    /// surfaces the error rather than pretending the paste worked.
    @discardableResult
    public func setToken(_ raw: String) -> Bool {
        let extracted = Self.extractAccessToken(from: raw)
        let fp = extracted.count > 18
            ? "\(extracted.prefix(14))…\(extracted.suffix(4))"
            : "(short:\(extracted.count))"
        logger.info("setToken: raw len=\(raw.count, privacy: .public) extracted len=\(extracted.count, privacy: .public) fp=\(fp, privacy: .public)")
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            tokenProvider.clear()
            poller?.stop()
            poller = nil
            usage = nil
            lastError = nil
            needsReauth = false
            isPolling = false
            WatchTokenBridge.shared.pushToken(nil)
            return true
        }
        guard Self.looksLikeValidToken(trimmed) else {
            logger.warning("setToken: extracted value doesn't look like a Claude OAuth token (len=\(trimmed.count, privacy: .public)); refusing to save")
            return false
        }
        let ok = tokenProvider.setToken(trimmed)
        logger.info("setToken: write ok=\(ok, privacy: .public) hasToken=\(self.tokenProvider.hasToken, privacy: .public)")
        guard ok else { return false }
        configurePollerIfTokenPresent()
        forcePoll()
        // Push the newly-saved token to the paired watch immediately.
        WatchTokenBridge.shared.pushToken(trimmed)
        return true
    }

    /// One-shot poll, ignoring cadence. Used by pull-to-refresh and after
    /// the user pastes a new token.
    public func forcePoll() {
        guard let poller else { return }
        Task { _ = await poller.forcePoll() }
    }

    /// Pull a bare `sk-ant-…` token out of whatever the user pasted. Handles
    /// the three shapes we see in the wild:
    ///   1. Bare token: `"sk-ant-oat01-…"`
    ///   2. Claude Code's Keychain JSON: `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-…", …}}`
    ///   3. A bigger object with the same shape nested somewhere.
    /// Falls through to the trimmed input if nothing matches, so a fresh
    /// token-format from Anthropic won't immediately break the flow.
    private static func extractAccessToken(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sk-ant-") { return trimmed }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let token = findAccessToken(in: obj) {
            return token
        }
        return trimmed
    }

    private static func findAccessToken(in obj: Any) -> String? {
        if let s = obj as? String, s.hasPrefix("sk-ant-") { return s }
        if let dict = obj as? [String: Any] {
            if let s = dict["accessToken"] as? String, s.hasPrefix("sk-ant-") {
                return s
            }
            for value in dict.values {
                if let nested = findAccessToken(in: value) { return nested }
            }
        }
        if let arr = obj as? [Any] {
            for value in arr {
                if let nested = findAccessToken(in: value) { return nested }
            }
        }
        return nil
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
            guard isProviderEnabled("claude") else {
                usage = nil
                UsageStore.reloadWidgets(providerID: "claude")
                return
            }
            usage = u
            lastError = nil
            needsReauth = false
            // Mirror to App Group for the widget extension to pick up.
            UsageStore.write(u, providerID: "claude", displayName: "Claude")
            UsageStore.reloadWidgets(providerID: "claude")
            // Forward to the paired Apple Watch so the watch app shows
            // fresh data even if its own poller is starved for a token.
            WatchTokenBridge.shared.pushUsage(u)
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

    private func applyEnabledProviderIDs(_ ids: [String]?) {
        enabledProviderIDs = ids
        UsageStore.writeEnabledProviderIDs(ids)
        UsageStore.reloadWidgets()
        WatchTokenBridge.shared.pushEnabledProviderIDs(ids)

        guard let enabledRoots = enabledProviderRoots(ids) else { return }
        if !enabledRoots.contains("claude") { usage = nil }
        if !enabledRoots.contains("codex") { codexSnapshot = nil }
        if !enabledRoots.contains("gemini") { geminiSnapshot = nil }
        if !enabledRoots.contains("cursor") { cursorSnapshot = nil }
    }

    private func isProviderEnabled(_ providerID: String) -> Bool {
        guard let enabledRoots = enabledProviderRoots(enabledProviderIDs ?? UsageStore.readEnabledProviderIDs()) else {
            return true
        }
        return enabledRoots.contains(ProviderRegistry.rootProviderID(for: providerID))
    }

    private func enabledProviderRoots(_ ids: [String]?) -> Set<String>? {
        guard let ids else { return nil }
        return Set(ids.map { ProviderRegistry.rootProviderID(for: $0) })
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
