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

    private var cancellables = Set<AnyCancellable>()
    private var usageQueryService: UsageQueryService?
    private var sessionsRefreshTask: Task<Void, Never>?

    init() {
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
        self.geminiModel = AppModel(
            config: .gemini,
            source: AntigravitySource(tokenProvider: geminiTokenProvider),
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

        let sessionsEnabled = UserDefaults.standard.object(forKey: "clawdmeter.sessions.enabled") as? Bool ?? true
        if sessionsEnabled {
            self.tmuxSupervisor.start()
            self.agentControlServer.start()
            self.sessionsRefreshTask = self.sessionsModel.startPeriodicRefresh()
            self.sessionScheduler.start()
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
        Task { @MainActor in task?.cancel() }
        runtimeLogger.warning("AppRuntime.deinit")
    }
}
