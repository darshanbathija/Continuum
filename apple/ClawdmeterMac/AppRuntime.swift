import Foundation
import Combine
import ClawdmeterShared
import OSLog

private let runtimeLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AppRuntime")

/// App-level owner for all provider models. Lives for the app's lifetime as
/// a `@StateObject` in `ClawdmeterMacApp`.
///
/// Why: codex's diagnosis — `MenuBarExtra` label `.task` modifiers on macOS
/// Tahoe are unreliable for starting app-owned work, and `MenuBarExtra` scenes
/// don't invalidate from per-child @ObservedObject changes consistently. By
/// owning both models here and forwarding their `objectWillChange` to this
/// runtime, every per-model `@Published` change re-invalidates the parent
/// scene, which reliably re-snapshots the menu bar label.
extension Notification.Name {
    // v0.27.0: Design tab + Open Design integration stripped out. Old
    // clawdmeterDidOpenInDesign / clawdmeterDesignBridgeUnavailable
    // notification names removed; no remaining publishers or listeners.
}

@MainActor
final class AppRuntime: ObservableObject {

    let claudeModel: AppModel
    let codexModel: AppModel
    let geminiModel: AppModel
    let usageHistoryStore: UsageHistoryStore

    // Sessions feature (Phase 1 + 2 + supervisor):
    let repoIndex: RepoIndex
    let agentSessionRegistry: AgentSessionRegistry
    let tmuxClient: TmuxControlClient
    let tmuxSupervisor: TmuxSupervisor
    let agentControlServer: AgentControlServer
    let notificationDispatcher: NotificationDispatcher
    let sessionsModel: SessionsModel
    let sessionScheduler: SessionScheduler

    // v0.24.0: in-app update checker. Polls GitHub Releases once a day,
    // surfaces a chip in the titlebar when a newer version ships. The
    // chip opens a popover with release notes + "Download in Browser"
    // CTA. Sparkle one-click install is parked in TODOS.md as phase 2.
    let updateCoordinator: UpdateCoordinator

    // v0.27.0: openFolderInDesign(baseDir:) removed along with the Design tab.

    private var cancellables = Set<AnyCancellable>()
    private var usageQueryService: UsageQueryService?
    private var sessionsRefreshTask: Task<Void, Never>?

    /// In-process daemon client for Mac SwiftUI surfaces (D2 / PR #24a).
    /// Set after `agentControlServer.start()` binds ports — same code path
    /// as the iOS app's `AgentControlClient`, so Mac Code IDE actions and
    /// the chat pipeline (PR #25) share the iOS code path.
    ///
    /// Nil only when the server failed to bind any port in
    /// `AgentControlServer.portFallbackRange`. Mac Code IDE actions
    /// degrade gracefully — buttons disable themselves rather than crash.
    /// AppDelegate surfaces the bind failure as an alert.
    var loopbackClient: AgentControlClient?

    init() {
        // v0.24.0: in-app update checker. Instantiate first — no
        // dependencies on other subsystems, and its background timer
        // schedules its first check 8s out so logs don't interleave
        // with the rest of AppRuntime's init.
        self.updateCoordinator = UpdateCoordinator()

        let claudeTokenProvider = KeychainTokenProvider()
        // Mirror Claude Code's local OAuth token into our shared, iCloud-synced
        // Keychain entry so the iPhone and Watch apps can read the same token
        // with zero manual setup. Best-effort — no token, no mirror.
        if let token = claudeTokenProvider.currentAccessToken {
            PastedAnthropicTokenProvider.shared().setToken(token)
            runtimeLogger.info("Mirrored Claude token (\(token.count, privacy: .public) chars) into iCloud Keychain")
        }
        self.claudeModel = AppModel(
            config: .claude,
            source: AnthropicSource(tokenProvider: claudeTokenProvider),
            tokenProvider: claudeTokenProvider
        )

        let codexTokenProvider = CodexTokenProvider()
        self.codexModel = AppModel(
            config: .codex,
            source: CodexSource(tokenProvider: codexTokenProvider),
            tokenProvider: codexTokenProvider
        )

        // Gemini: OAuth token from `~/.gemini/oauth_creds.json` (Gemini CLI
        // manages this) → poll Antigravity's cloudcode-pa quota endpoint.
        // Same TOS posture as CodexSource against chatgpt.com/backend-api;
        // documented in CLAUDE.md.
        let geminiTokenProvider = GeminiTokenProvider()
        // v0.26.6: wire the Tier-1 LS-local quota probe so the Antigravity
        // tile lights up when Antigravity 2 desktop app is running, without
        // requiring the user to have first run `gemini auth login` to seed
        // ~/.gemini/oauth_creds.json (which Tier 2 needs). The probe returns
        // nil silently when LSP isn't reachable, letting Tier 2 take over.
        self.geminiModel = AppModel(
            config: .gemini,
            source: AntigravitySource(
                tokenProvider: geminiTokenProvider,
                lsQuotaProbe: { @Sendable in await AntigravityLSQuotaProbe.probe() }
            ),
            tokenProvider: geminiTokenProvider
        )

        // Don't forward objectWillChange — it was saturating main thread with
        // SwiftUI invalidations and starving the per-poller main-queue hops
        // for the slower provider. Let each MenuBarGaugeView observe its own
        // model directly.

        // Start all pollers immediately. AppModel.start() is idempotent.
        claudeModel.start()
        codexModel.start()
        geminiModel.start()

        // Analytics history: walks the on-disk JSONL caches, computes
        // calendar-day-aligned totals, mirrors the snapshot into iCloud KV
        // for the iOS analytics tab. Plan A8 + A19.
        self.usageHistoryStore = UsageHistoryStore()
        self.usageHistoryStore.$snapshot
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { snapshot in
                UsageCloudMirror.shared.writeAnalyticsSnapshot(snapshot)
            }
            .store(in: &cancellables)

        // Sessions feature: assemble the daemon + repo index + UI model
        // BEFORE any `self`-capturing call so all stored properties are
        // initialized before Swift lets us use `self`.
        // Per E2: AgentControlServer is @MainActor, RepoIndex is an actor,
        // NotificationDispatcher is an actor. SessionsModel bridges to UI.
        // Per the feature flag plan (T18): gate the daemon start on
        // `UserDefaults.clawdmeter.sessions.enabled`. Default on in v1.
        self.repoIndex = RepoIndex()
        self.agentSessionRegistry = AgentSessionRegistry()
        self.tmuxClient = TmuxControlClient()
        self.tmuxSupervisor = TmuxSupervisor(
            tmux: self.tmuxClient,
            registry: self.agentSessionRegistry
        )
        self.notificationDispatcher = NotificationDispatcher()
        // v0.27.0: openDesignDaemon (the bundled Open Design Node sidecar)
        // removed along with the Design tab.
        self.agentControlServer = AgentControlServer(
            repoIndex: self.repoIndex,
            registry: self.agentSessionRegistry,
            tmux: self.tmuxClient,
            notifications: self.notificationDispatcher
        )
        // Hand the daemon refs to the live-usage publishers + analytics
        // store so the iPhone's `/usage` and `/analytics` endpoints can
        // serve fresh data over Tailscale. Drops the iCloud-KV-sync
        // requirement for analytics — users without a paid Apple
        // Developer entitlement now get the same data via pairing.
        self.agentControlServer.attachUsageSources(
            claude: self.claudeModel,
            codex: self.codexModel,
            gemini: self.geminiModel,
            history: self.usageHistoryStore
        )
        self.sessionsModel = SessionsModel(
            repoIndex: self.repoIndex,
            registry: self.agentSessionRegistry,
            supervisor: self.tmuxSupervisor
        )
        self.sessionScheduler = SessionScheduler(
            registry: self.agentSessionRegistry,
            tmuxClient: self.tmuxClient
        )

        // Vend the Mach service the widget extension queries. Created here
        // (after all stored properties are initialized) so the service can
        // hand back live in-memory snapshots from its first connection.
        self.usageQueryService = UsageQueryService(runtime: self)

        // D4 (v0.17, wire v12): wire the iOS-side auto-revive RPC into
        // the matching AppModel. The server's handler dispatches on
        // AgentKind; we fan out to the per-provider model here. Capture
        // weak so the daemon's long-lived closure doesn't pin AppRuntime
        // beyond its natural lifetime.
        self.agentControlServer.setAutoReviveCallback = { [weak self] kind, enabled in
            guard let self else { return }
            switch kind {
            case .claude: self.claudeModel.setAutoReviveEnabled(enabled)
            case .codex:  self.codexModel.setAutoReviveEnabled(enabled)
            case .gemini: self.geminiModel.setAutoReviveEnabled(enabled)
            case .opencode:
                // PR #29: OpenCode doesn't run a 5h-window quota poller,
                // so the auto-revive concept doesn't apply. The iOS
                // surface hides the toggle for opencode (the toggle UI
                // gates on AppModel availability). If a stale client
                // still posts here, silently ignore — no AutoReviver
                // to drive.
                break
            case .cursor:
                // Cursor usage limits are owned by the user's Cursor account;
                // no Clawdmeter auto-revive poller exists for this provider.
                break
            case .unknown:
                // X3: forward-compat unknown — never user-toggleable.
                // The handler returns 400 before reaching here.
                break
            }
        }

        let sessionsEnabled = UserDefaults.standard.object(forKey: "clawdmeter.sessions.enabled") as? Bool ?? true
        if sessionsEnabled {
            self.tmuxSupervisor.start()
            // v0.27.0: agentControlServer.attachDesignBridge(...) call removed
            // along with the Design tab + Open Design daemon.
            self.agentControlServer.start()
            // PR #24a A1: synchronous loopback bootstrap. `start()` above
            // is sync and assigns `boundPort`/`boundWsPort` before
            // returning, so the client always sees populated ports. Nil
            // return only happens when bind exhausted the port range —
            // surfaces as `loopbackClient == nil`; Mac IDE actions
            // disable themselves and AppDelegate raises an alert.
            self.loopbackClient = MacLoopbackClient.make(from: self.agentControlServer)
            if self.loopbackClient == nil {
                runtimeLogger.error("MacLoopbackClient construction failed — Mac IDE actions will be disabled this session")
            }
            self.sessionsRefreshTask = self.sessionsModel.startPeriodicRefresh()
            self.sessionScheduler.start()
            // v0.27.0: openDesignDaemon.ensureRunning() removed along with
            // the Design tab.
            // v0.22.11: auto-archive chat sessions idle > 5 minutes.
            // User reported the chat view defaulting to whatever was
            // last active even hours later — having stale active
            // sessions makes the sidebar feel cluttered. Code-tab
            // sessions are unaffected (they're long-running by nature
            // and the user explicitly archives them via the IDE).
            // Sweep every 60 s; idempotent (archive is a no-op for
            // already-archived sessions).
            let chatIdleTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let cutoff = Date().addingTimeInterval(-5 * 60)
                    for s in self.agentSessionRegistry.sessions
                        where s.kind == .chat && s.archivedAt == nil && s.lastEventAt < cutoff
                    {
                        self.agentSessionRegistry.archive(id: s.id)
                    }
                }
            }
            RunLoop.main.add(chatIdleTimer, forMode: .common)
            // Phase 10: APNS Live Activity push trigger.
            // Subscribe to registry deltas; whenever a session status,
            // planText, or active-set changes, hand a fresh wire-shape
            // content state to MacAPNSPusher. The pusher no-ops when no
            // APNS credentials are configured or no tokens are
            // registered, so this is safe to wire unconditionally.
            self.agentSessionRegistry.$sessions
                .removeDuplicates { [weak self] old, new in
                    self?.liveActivityFingerprint(old) == self?.liveActivityFingerprint(new)
                }
                .sink { [weak self] sessions in
                    self?.pushLiveActivityUpdate(sessions: sessions)
                }
                .store(in: &cancellables)
            runtimeLogger.info("Sessions daemon started on port \(self.agentControlServer.boundPort ?? 0)")
        } else {
            runtimeLogger.info("Sessions feature disabled via UserDefaults — daemon not started")
        }

        runtimeLogger.info("AppRuntime.init COMPLETE instance=\(ObjectIdentifier(self).hashValue)")
    }

    /// Compute a fingerprint over only the fields that affect the
    /// aggregate Live Activity content state. Without this, every
    /// registry mutation (lastEventSeq bumps for chat messages, token
    /// totals, etc.) would trigger an APNS push.
    private func liveActivityFingerprint(_ sessions: [AgentSession]) -> String {
        let active = sessions
            .filter { $0.archivedAt == nil && $0.status != .done }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return active
            .map { "\($0.id.uuidString):\($0.status.rawValue):\($0.planText == nil ? "0" : "1")" }
            .joined(separator: "|")
    }

    private func pushLiveActivityUpdate(sessions: [AgentSession]) {
        let active = sessions.filter { $0.archivedAt == nil && $0.status != .done }
        let mostRecent = active.max(by: { $0.lastEventAt < $1.lastEventAt }) ?? active.first
        let payload: APNSContentStatePayload
        if let mostRecent {
            let city = CityPool.cityName(for: mostRecent.id)
            let needsAttention = active.contains { $0.planText != nil && $0.status == .planning }
            payload = APNSContentStatePayload(
                event: "update",
                content: WireSessionLiveActivityContentState(
                    activeSessionCount: active.count,
                    latestCity: city,
                    latestAgentKind: mostRecent.agent,
                    latestState: mostRecent.status.rawValue,
                    needsAttention: needsAttention
                )
            )
        } else {
            // Empty active set — end the activity. APNS treats event=end
            // as a signal to dismiss; iOS-side LiveActivityCoordinator
            // also handles the in-process end path.
            payload = APNSContentStatePayload(
                event: "end",
                content: WireSessionLiveActivityContentState(
                    activeSessionCount: 0,
                    latestCity: "",
                    latestAgentKind: .claude,
                    latestState: "done",
                    needsAttention: false
                )
            )
        }
        Task { await MacAPNSPusher.shared.push(contentState: payload) }
    }

    deinit {
        // sessionsRefreshTask is @MainActor-isolated; cancellation needs
        // to hop. Best-effort.
        let task = sessionsRefreshTask
        Task { @MainActor in
            task?.cancel()
            // PR #30: clean shutdown of the OpenCode singleton. The
            // process manager + SSE adapter aren't owned here, but
            // their lifecycle tracks the app's so we tear them down
            // when AppRuntime goes away.
            OpencodeProcessManager.shared.stop()
            OpencodeSSEAdapter.shared.stop()
        }
        runtimeLogger.warning("AppRuntime.deinit")
    }
}
