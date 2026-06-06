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
    /// v0.28.0: Cursor as a first-class provider. Reads cursor-agent's
    /// keychain JWT and polls api2.cursor.sh's GetCurrentPeriodUsage.
    let cursorModel: AppModel
    /// Grok as a first-class provider. Reads the Grok CLI's `/usage show`
    /// credits meter for live usage limits; token analytics remain history-ledger
    /// based.
    let grokModel: AppModel
    let usageHistoryStore: UsageHistoryStore

    /// F3-wire (Codex eng-review #10): one `AppModel` per registered
    /// `ProviderInstanceId`, keyed by `wireId`. The four per-kind
    /// properties above are back-compat shortcuts that resolve to the
    /// primary instance for each kind — every call site that knows only
    /// `AgentKind` still works without modification.
    ///
    /// Instance-aware call sites (multi-account UI, daemon spawn paths,
    /// `/usage` envelope assembly) read through `appModel(for:)` to
    /// pick the right per-instance model.
    ///
    /// **Population:** seeded with the primaries at init via
    /// `providerInstanceRegistry.allInstances()`. Custom instances added
    /// later (via Settings → Providers → Add Account) call
    /// `addInstance(_:)` which spawns a fresh `AppModel` and stores it
    /// here.
    let providerInstanceRegistry: ProviderInstanceRegistry
    private var modelsByInstanceWireId: [String: AppModel] = [:]

    // Sessions feature:
    let repoIndex: RepoIndex
    let agentSessionRegistry: AgentSessionRegistry
    let workspaceStore: WorkspaceStore
    let repoEnvStore: RepoEnvStore
    let repoEnvRuntimeResolver: RepoEnvRuntimeResolver
    let vendorProvisioningService: VendorProvisioningService
    let agentControlServer: AgentControlServer
    let notificationDispatcher: NotificationDispatcher
    let sessionsModel: SessionsModel
    let sessionScheduler: SessionScheduler

    // v0.24.0: in-app update checker. Polls GitHub Releases once a day,
    // surfaces a chip in the titlebar when a newer version ships. The
    // chip opens a popover with release notes + "Download in Browser"
    // CTA. Sparkle one-click install is parked in TODOS.md as phase 2.
    let updateCoordinator: UpdateCoordinator

    // E7: relay-session-token pairing UX. Owns the X25519 keypair +
    // bundle the Mac shows in a QR; iPhone scans it to derive the
    // shared symmetric key. See RelayPairingService for state machine.
    let relayPairingService: RelayPairingService

    // E3 (respin): outbound relay WebSocket client. Opens when paired
    // (E7 bundle available) and the user has explicitly flipped the
    // `clawdmeter.relay.enabled` UserDefaults flag. The relay is
    // ADDITIVE — `AgentControlServer` still listens on Tailscale; the
    // relay just adds a second transport that activates when paired.
    //
    // Per the design doc §1 "relay-degraded fallback": when the relay
    // is unreachable for >60s the client transitions to `.degraded`
    // and AgentControlServer's outbound-notification path can prefer
    // Tailscale. Inbound HTTP requests still arrive on whichever
    // transport the iPhone used.
    private(set) var relayClient: MacRelayClient?
    private var relayDispatcher: RelayRequestDispatcher?
    /// Track B (B0): forwards `op == "mux"` relay frames to loopback WS streams
    /// so the 4 WSChannels work over the relay. Inert until iOS sends mux frames.
    private var relaySubscriptionBridge: RelaySubscriptionBridge?
    /// Track B (B1.7): reassembles chunked inbound `.request` payloads. One
    /// instance is safe for concurrent requests — it keys partials by the
    /// per-request messageId.
    private let relayMuxRequestReassembler = RelayChunkReassembler()
    private var relayPairingObserver: AnyCancellable?

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
        // Sparkle-backed updater. Instantiate first so app menu,
        // titlebar, Code, and Settings all share one state model.
        self.updateCoordinator = UpdateCoordinator()

        // E7: relay-pairing service. Phase starts `.unpaired`; the user
        // taps "Pair iPhone" in Settings to mint a fresh bundle.
        self.relayPairingService = RelayPairingService()

        // Claude polling reads from Continuum's own Keychain entry. The
        // first-party token is loaded in one of two ways:
        //
        // 1. Explicit: the user clicks "Authenticate from Claude Code" in
        //    Settings, which copies Claude Code's third-party Keychain entry
        //    into Continuum's own. Always available.
        //
        // 2. Auto-import at launch (opt-in via the
        //    `clawdmeter.claude.autoImportFromClaudeCode` UserDefault). When
        //    enabled, this mirrors Claude Code's Keychain item on every
        //    launch so the iPhone / Watch see the latest refreshed token
        //    without manual action. Default OFF — #133 disabled the silent
        //    auto-mirror after macOS treated the background read as
        //    third-party Keychain access and prompted for the laptop
        //    password. The Settings toggle flips ON automatically the
        //    first time the user successfully clicks Authenticate, so
        //    one-time auth carries through subsequent launches.
        let claudeTokenProvider = PastedAnthropicTokenProvider.shared()
        self.claudeModel = AppModel(
            config: .claude,
            source: AnthropicSource(tokenProvider: claudeTokenProvider),
            tokenProvider: claudeTokenProvider
        )
        // v0.29.32: also require Claude to be enabled — the auto-import reads
        // Claude Code's third-party keychain entry, which must not happen until
        // the user opts Claude in.
        if ProviderEnablement.isEnabled("claude"),
           UserDefaults.standard.bool(forKey: "clawdmeter.claude.autoImportFromClaudeCode") {
            Task.detached(priority: .utility) {
                if let token = KeychainTokenProvider().currentAccessToken {
                    let didMirror = PastedAnthropicTokenProvider.shared().setToken(token)
                    if didMirror {
                        runtimeLogger.info("Auto-imported Claude token (\(token.count, privacy: .public) chars) into shared Keychain at launch")
                    } else {
                        runtimeLogger.info("Auto-import skipped at launch: shared Keychain write unavailable")
                    }
                } else {
                    runtimeLogger.info("Auto-import enabled but no Claude Code token found in third-party Keychain")
                }
            }
        }

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

        // v0.28.0: Cursor via cursor-agent's keychain JWT (read by
        // CursorTokenProvider) → POST gRPC-Web to api2.cursor.sh's
        // DashboardService/GetCurrentPeriodUsage. Returns billing-period
        // % used + reset epoch. Falls through to .unauthenticated when
        // cursor-agent isn't logged in (no keychain entry yet).
        let cursorTokenProvider = CursorTokenProvider()
        self.cursorModel = AppModel(
            config: .cursor,
            source: CursorSource(tokenProvider: cursorTokenProvider),
            tokenProvider: cursorTokenProvider
        )

        let grokTokenProvider = GrokTokenProvider()
        self.grokModel = AppModel(
            config: .grok,
            source: GrokUsageSource(),
            tokenProvider: grokTokenProvider
        )

        // F3-wire (Codex eng-review #10): seed the provider-instance
        // registry with the primary for every kind and map each kind's
        // primary wireId to the AppModel we just constructed. Custom
        // instances added later (via Settings → Providers → Add
        // Account → assigns a `homePathOverride` + optional
        // `keychainAccessGroupOverride`) plug into the same map via
        // `addInstance(_:)`.
        self.providerInstanceRegistry = ProviderInstanceRegistry()
        self.modelsByInstanceWireId = [
            ProviderInstanceId.primary(kind: .claude).wireId: self.claudeModel,
            ProviderInstanceId.primary(kind: .codex).wireId:  self.codexModel,
            ProviderInstanceId.primary(kind: .gemini).wireId: self.geminiModel,
            ProviderInstanceId.primary(kind: .cursor).wireId: self.cursorModel,
            ProviderInstanceId.primary(kind: .grok).wireId: self.grokModel,
            // `.opencode` and `.unknown` don't have a per-kind AppModel
            // (OpenCode runs as a long-lived `opencode serve` daemon,
            // unknown is forward-compat sentinel only); they resolve
            // through the registry but never have a model entry.
        ]

        // Don't forward objectWillChange — it was saturating main thread with
        // SwiftUI invalidations and starving the per-poller main-queue hops
        // for the slower provider. Let each MenuBarGaugeView observe its own
        // model directly.

        // v0.29.32: providers are opt-in. A poller's first poll lazily reads
        // its provider's keychain, so only start the ones the user has enabled
        // (Settings → Providers / first-run welcome sheet). This is what stops
        // the launch-time keychain prompts. AppModel.start() is idempotent;
        // toggling a provider on later calls start() live (enableProvider).
        if ProviderEnablement.isEnabled("claude") { claudeModel.start() }
        if ProviderEnablement.isEnabled("codex") { codexModel.start() }
        if ProviderEnablement.isEnabled("gemini") { geminiModel.start() }
        // Cursor: the opt-in flag is the gate now (it supersedes the legacy
        // cursorStartupPollingEnabled deferral — enabling Cursor means the user
        // accepts its cursor-agent keychain prompt).
        if ProviderEnablement.isEnabled("cursor") {
            cursorModel.start()
        } else {
            runtimeLogger.info("Cursor poller deferred (provider disabled); keychain untouched until enabled")
        }
        if ProviderEnablement.isEnabled("grok"), !Self.isRunningUnderXCTest {
            grokModel.start()
        } else if ProviderEnablement.isEnabled("grok") {
            runtimeLogger.info("Grok poller deferred under XCTest; CLI untouched during unit-test app bootstrap")
        } else {
            runtimeLogger.info("Grok poller deferred (provider disabled); CLI untouched until enabled")
        }

        // Analytics history: walks the on-disk JSONL caches, computes
        // calendar-day-aligned totals, mirrors the snapshot into iCloud KV
        // for the iOS analytics tab. Plan A8 + A19.
        self.usageHistoryStore = UsageHistoryStore()
        // C2 — was `usageHistoryStore.$snapshot` pre-C2 when the
        // store was `@Published`. With the store now `@Observable`,
        // the daemon-side Combine bridge is `snapshotPublisher` (a
        // `PassthroughSubject` pushed alongside each `snapshot =`
        // write in `refresh(force:)`).
        self.usageHistoryStore.snapshotPublisher
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
        let uiTestingAppSupport = Self.uiTestingAppSupportOverride()
        let sessionsStoreURL = uiTestingAppSupport?.appendingPathComponent("sessions.json")
            ?? AgentSessionRegistry.defaultStoreURL()
        let workspacesStoreURL = uiTestingAppSupport?.appendingPathComponent("workspaces.json")
            ?? WorkspaceStore.defaultStoreURL()
        let repoEnvStoreURL = uiTestingAppSupport?.appendingPathComponent("repo-env-variables.json")
            ?? RepoEnvStore.defaultStoreURL()

        self.workspaceStore = WorkspaceStore(
            storeURL: workspacesStoreURL,
            sessionsURL: sessionsStoreURL
        )
        let workspaceStoreRef = self.workspaceStore
        self.repoIndex = RepoIndex(
            workspaceSnapshotProvider: { @Sendable in
                await MainActor.run { workspaceStoreRef.workspaces }
            }
        )
        self.agentSessionRegistry = AgentSessionRegistry(storeURL: sessionsStoreURL)
        self.repoEnvStore = RepoEnvStore(storeURL: repoEnvStoreURL)
        self.repoEnvRuntimeResolver = RepoEnvRuntimeResolver(
            workspaceStore: self.workspaceStore,
            envStore: self.repoEnvStore
        )
        self.vendorProvisioningService = VendorProvisioningService(
            workspaceStore: self.workspaceStore,
            envStore: self.repoEnvStore,
            repoEnvResolver: self.repoEnvRuntimeResolver
        )
        self.notificationDispatcher = NotificationDispatcher()
        // v0.27.0: openDesignDaemon (the bundled Open Design Node sidecar)
        // removed along with the Design tab.
        self.agentControlServer = AgentControlServer(
            repoIndex: self.repoIndex,
            registry: self.agentSessionRegistry,
            notifications: self.notificationDispatcher,
            workspaceStore: self.workspaceStore,
            repoEnvResolver: self.repoEnvRuntimeResolver,
            vendorProvisioningService: self.vendorProvisioningService
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
            cursor: self.cursorModel,
            grok: self.grokModel,
            history: self.usageHistoryStore
        )
        self.sessionsModel = SessionsModel(
            repoIndex: self.repoIndex,
            registry: self.agentSessionRegistry,
            workspaceStore: self.workspaceStore,
            repoEnvResolver: self.repoEnvRuntimeResolver
        )
        let schedulerServer = self.agentControlServer
        self.sessionScheduler = SessionScheduler(
            registry: self.agentSessionRegistry,
            deliverer: { [weak schedulerServer] session, followUp in
                await schedulerServer?.deliverScheduledFollowUp(session: session, followUp: followUp)
                    ?? .unavailable(reason: "daemon_unavailable")
            }
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
            case .grok:
                // ACP agent with no 5h-window quota poller — auto-revive N/A.
                break
            case .unknown:
                // X3: forward-compat unknown — never user-toggleable.
                // The handler returns 400 before reaching here.
                break
            }
        }

        let sessionsEnabled = UserDefaults.standard.object(forKey: "clawdmeter.sessions.enabled") as? Bool ?? true
        if sessionsEnabled {
            // A7 (Phase 2 + codex D14#4): AgentControlServer.start() stays
            // SYNCHRONOUS on the init path. The mobile wedge depends on
            // its port being bound + server.json written before any
            // paired iPhone can reconnect on app launch. The 5 A7
            // acceptance tests (paired-client reconnect ≤1s, Watch/widget
            // refresh ≤2s, re-pair ≤5s, server.json written first,
            // cold-start improvement) all hinge on AgentControlServer
            // being live at first paint.
            //
            // What DOES defer (non-critical to mobile + first-paint):
            //   - sessionsModel.startPeriodicRefresh() — kicks the 60s
            //     timer + does an initial repo index walk
            //   - sessionScheduler.start() — schedules deferred session work
            //
            // These move into a Task that runs after AppRuntime.init returns.
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

            // E3 (respin): wire the relay-pairing observer behind the
            // `clawdmeter.relay.enabled` UserDefaults gate. Default off
            // so dev/staging builds can flip it without a rebuild and
            // production stays on Tailscale until the relay is shipped
            // end-to-end. When enabled AND a pairing bundle exists,
            // spawn the relay client; otherwise stay idle (Tailscale-only).
            //
            // The relay client routes inbound encrypted frames into the
            // localhost AgentControlServer via `RelayRequestDispatcher`,
            // so paired Mac handlers fire over either Tailscale or the
            // relay transparently.
            // B5 cutover (2026-06-05): default ON to match iOS's relayDefault.
            // The Mac relay client stays idle until a relay pairing bundle
            // exists, so defaulting on costs nothing when unpaired but means a
            // relay-paired iPhone always has its Mac peer present. An explicit
            // `false` (set by a future Settings toggle / MDM) still wins.
            let relayEnabled = UserDefaults.standard.object(forKey: "clawdmeter.relay.enabled") as? Bool ?? true
            if relayEnabled, let loopback = self.loopbackClient {
                let dispatcher = RelayRequestDispatcher(loopbackClient: loopback)
                self.relayDispatcher = dispatcher
                // Track B (B0): the loopback-WS bridge for subscription-over-relay.
                // sendOutbound reaches the relay client (assigned later, before any
                // mux frame can arrive); wsURL/token read the live daemon ports.
                self.relaySubscriptionBridge = RelaySubscriptionBridge(
                    wsURL: { [weak self] in
                        guard let port = self?.agentControlServer.boundWsPort else { return nil }
                        return URL(string: "ws://127.0.0.1:\(port)/")
                    },
                    loopbackToken: { [weak self] in self?.agentControlServer.localLoopbackToken },
                    connFactory: { url, envelope in
                        try await URLSessionLoopbackWSConn(url: url, subscribeEnvelope: envelope)
                    },
                    sendOutbound: { [weak self] frame in
                        guard let payload = try? frame.encoded() else { return }
                        try? await self?.relayClient?.send(op: RelayMux.op, payload: payload)
                    }
                )
                let recorder = RelayPairingServiceHandshakeRecorder(service: self.relayPairingService)
                self.relayPairingObserver = self.relayPairingService.$bundle
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] bundle in
                        Task { @MainActor in
                            self?.handleRelayPairingChange(
                                bundle: bundle,
                                dispatcher: dispatcher,
                                recorder: recorder
                            )
                        }
                    }
                runtimeLogger.info("Relay enabled via UserDefaults (clawdmeter.relay.enabled=YES); observing pairing bundle")
            } else {
                if !relayEnabled {
                    runtimeLogger.info("Relay disabled (clawdmeter.relay.enabled UserDefaults flag is false); Tailscale-only")
                } else {
                    runtimeLogger.warning("Relay enabled but loopback client unavailable; cannot spawn relay client")
                }
            }

            // A7: defer non-critical subsystems. Strong-capture self in
            // the Task since AppRuntime is an app-lifetime singleton; a
            // weak capture risks the work being dropped if init returns
            // before the Task scheduler kicks in.
            Task { @MainActor [self] in
                self.sessionsRefreshTask = self.sessionsModel.startPeriodicRefresh()
                self.sessionScheduler.start()
                runtimeLogger.info("A7 deferred subsystems started (sessions refresh + scheduler)")
            }
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
                        // F2-wire: write-ahead failures on the idle
                        // archive sweep are best-effort logged. We
                        // don't want a SQLite hiccup to break the
                        // 60-second sweeper.
                        do {
                            try await self.agentSessionRegistry.archive(id: s.id)
                        } catch {
                            // No registry logger in this scope —
                            // print is non-ideal but the sweep is
                            // best-effort by design.
                            print("chatIdle archive failed: \(error.localizedDescription)")
                        }
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

        bootstrapProviderRuntimes()
        runtimeLogger.info("AppRuntime.init COMPLETE instance=\(ObjectIdentifier(self).hashValue)")
    }

    // MARK: - E3: relay client lifecycle

    /// Handle a change in `RelayPairingService.bundle` — either nil
    /// (user reset / forget) or a freshly-minted bundle. When non-nil,
    /// we spawn / replace the `MacRelayClient` with one configured
    /// from the bundle + the in-process keypair.
    ///
    /// The real X25519 shared K is derived LATER, when the iPhone
    /// connects + sends its handshake envelope. `MacRelayClient` calls
    /// into `RelayPairingService.recordPeerHandshake(_:)` via the
    /// supplied `recorder`; that's where K materializes and gets
    /// persisted. Until then the client is in `.awaitingPeer` — the
    /// socket is open but no ciphertext flows.
    @MainActor
    private func handleRelayPairingChange(
        bundle: RelayPairingBundle?,
        dispatcher: RelayRequestDispatcher,
        recorder: any MacRelayPairingHandshakeRecorder
    ) {
        // Tear down any existing client; we always rebuild on bundle
        // change (the bundle's `sid` / `macTok` baked into the URL
        // change too, so reusing the old socket would dial the wrong
        // session).
        relayClient?.stop()
        relayClient = nil
        // Track B (B0): drop any live loopback streams — they were bound to the
        // old relay session's opIds; iOS re-subscribes fresh on the new socket.
        relaySubscriptionBridge?.shutdownAll()

        guard let bundle else {
            runtimeLogger.info("Relay pairing cleared; client torn down")
            return
        }
        guard let keypair = relayPairingService.keypairForTesting else {
            runtimeLogger.warning("Relay pairing observed bundle without a keypair; cannot spawn client")
            return
        }
        let ourPubBytes = keypair.publicKey.rawRepresentation
        let config = MacRelayClientConfig.fromMacBundle(
            bundle: bundle,
            ourPublicKeyBytes: ourPubBytes
        )
        let client = MacRelayClient(
            config: config,
            pairingService: recorder,
            frameHandler: { [weak dispatcher, weak self] inbound in
                // Track B (B0): multiplex frames go to the subscription bridge;
                // everything else stays on the legacy request/response tunnel.
                if inbound.op == RelayMux.op {
                    guard let frame = RelayMuxFrame.decode(inbound.data) else { return nil }
                    if frame.kind == .request {
                        // B1.7: multiplexed request → loopback HTTP → .response.
                        await self?.handleMuxRequest(frame, dispatcher: dispatcher)
                    } else {
                        await self?.relaySubscriptionBridge?.handle(frame)
                    }
                    return nil   // mux replies arrive as their own outbound frames
                }
                return await dispatcher?.dispatch(inbound)
            }
        )
        // Track B (P1-7): on a fresh iOS (re)handshake, repair active
        // loopback streams immediately. iOS still resubscribes on its own
        // reconnect path, but Mac-side reconnects should not wait for that.
        client.onPeerReconnect = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.relaySubscriptionBridge?.reopenLiveSubscriptions()
            }
        }
        relayClient = client
        client.start()
        runtimeLogger.info(
            "Relay client started (sid=\(bundle.sid.prefix(8), privacy: .public)…, host=\(bundle.relayUrl, privacy: .public))"
        )
    }

    /// Track B (B1.7): service a multiplexed request frame from iOS — reassemble
    /// its (possibly chunked) payload, run it through the SAME loopback HTTP
    /// dispatcher the legacy tunnel uses, and ship the result back as a (chunked)
    /// `.response` frame correlated by opId.
    private func handleMuxRequest(_ frame: RelayMuxFrame, dispatcher: RelayRequestDispatcher?) async {
        guard let dispatcher else { return }
        let assembled: Data
        do {
            guard let full = try relayMuxRequestReassembler.accept(frame) else { return }  // more chunks pending
            assembled = full
        } catch {
            await sendMuxResponseError(opId: frame.opId, "malformed request chunks")
            return
        }
        guard let req = RelayMuxRequest.decode(assembled) else {
            await sendMuxResponseError(opId: frame.opId, "malformed request")
            return
        }
        // Reuse the tested HTTP dispatcher (op = "<METHOD>.<path>").
        let inbound = MacRelayInboundMessage(
            seq: 0, op: "\(req.method).\(req.path)", data: req.body ?? Data(), receivedAt: Date()
        )
        let envelope = await dispatcher.dispatch(inbound)   // {status, body, error?}
        var status = 502
        var body = Data()
        if let envelope,
           let dict = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any] {
            status = dict["status"] as? Int ?? 502
            if let encoded = dict["bodyBase64"] as? String,
               let decoded = Data(base64Encoded: encoded),
               (dict["bodyLength"] as? Int).map({ $0 == decoded.count }) ?? true {
                body = decoded
            } else if let s = dict["body"] as? String {
                body = Data(s.utf8)
            }
        }
        await sendMuxResponse(opId: frame.opId, status: status, body: body)
    }

    private func sendMuxResponse(opId: String, status: Int, body: Data) async {
        guard let payload = try? RelayMuxResponse(status: status, body: body).encoded() else { return }
        let frames = RelayChunker.split(opId: opId, kind: .response, payload: payload, messageId: UUID().uuidString)
        for f in frames {
            guard let enc = try? f.encoded() else { continue }
            try? await relayClient?.send(op: RelayMux.op, payload: enc)
        }
    }

    private func sendMuxResponseError(opId: String, _ message: String) async {
        let payload = try? JSONSerialization.data(withJSONObject: ["error": message])
        guard let enc = try? RelayMuxFrame(opId: opId, kind: .error, payload: payload).encoded() else { return }
        try? await relayClient?.send(op: RelayMux.op, payload: enc)
    }

    private func bootstrapProviderRuntimes() {
        // Keep pricing current without a rebuild: refresh the LiteLLM snapshot
        // at most once per 24h, then re-aggregate analytics so a newly-released
        // model (e.g. a fresh Opus) stops showing $0 within this session.
        Task.detached(priority: .utility) { [weak self] in
            let refreshed = await PricingUpdater.shared.refreshIfStale()
            if refreshed {
                await MainActor.run { self?.usageHistoryStore.forceRefresh() }
            }
        }
        // v0.29.31: warm the Cursor + OpenRouter model probes on launch so the
        // model pickers show the full live lists immediately, and force a fresh
        // re-probe at most once per 24h so a long-running instance picks up
        // newly-released models without a relaunch. (The probes also self-refresh
        // on a 60s TTL whenever a picker opens — this keeps the cache warm and
        // gives the "auto-check for new models daily" guarantee. First-party
        // Claude/OpenAI/Gemini stay hand-curated in ModelCatalog.bundled.)
        // v0.29.32: the Cursor probe shells `cursor-agent --list-models`, which
        // reads the Cursor keychain — only warm it when Cursor is enabled, else
        // it re-introduces the launch-time Cursor keychain prompt. OpenRouter is
        // network-only (no keychain/TCC), so warm it whenever OpenCode is on.
        let cursorOn = ProviderEnablement.isEnabled("cursor")
        let openrouterOn = ProviderEnablement.isEnabled("opencode")
        if cursorOn || openrouterOn {
            Task.detached(priority: .utility) {
                let key = "clawdmeter.models.lastProbeRefresh"
                let now = Date()
                let last = UserDefaults.standard.object(forKey: key) as? Date
                let stale = last == nil || now.timeIntervalSince(last!) >= 24 * 60 * 60
                if stale { UserDefaults.standard.set(now, forKey: key) }
                if cursorOn {
                    if stale { await CursorModelProbe.shared.invalidate() }
                    _ = await CursorModelProbe.shared.currentModels()
                }
                if openrouterOn {
                    if stale { await OpenRouterModelProbe.shared.invalidate() }
                    _ = await OpenRouterModelProbe.shared.currentModels()
                }
            }
        }
        Task(priority: .utility) { @MainActor in
            OpencodeProcessManager.shared.prepareRuntimeHost()
        }
        Task(priority: .utility) { @MainActor in
            await ChatProviderProbe.shared.invalidate()
        }
    }

    private static var cursorStartupPollingEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["CLAWDMETER_CURSOR_STARTUP_POLLING"] {
            return raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
        }
        return UserDefaults.standard.object(forKey: "clawdmeter.cursor.startupPolling.enabled") as? Bool ?? false
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - F3-wire instance-aware accessors (Codex eng-review #10)

    /// Resolve the `AppModel` for the given configured `ProviderInstanceId`.
    /// Returns `nil` when the instance hasn't been added yet (caller
    /// surfaces a clean error / falls back to the primary as appropriate).
    ///
    /// **Back-compat:** the primary instance for each kind always
    /// resolves to the existing per-kind `AppModel` (claudeModel,
    /// codexModel, …). Custom instances added via `addInstance(_:)`
    /// each get a fresh `AppModel` keyed by their `wireId`.
    func appModel(for instance: ProviderInstanceId) -> AppModel? {
        modelsByInstanceWireId[instance.wireId]
    }

    /// Back-compat convenience: resolve by `AgentKind`, returning the
    /// primary instance's model. Equivalent to
    /// `appModel(for: .primary(kind: kind))`.
    func appModel(for kind: AgentKind) -> AppModel? {
        modelsByInstanceWireId[ProviderInstanceId.primary(kind: kind).wireId]
    }

    /// v0.29.32: live provider opt-in. Flips the persisted enabled flag and
    /// starts/stops the matching poller without a relaunch (the AppModel
    /// already exists from init — it just wasn't started). Also writes the
    /// `menuBarShown` pref so AppDelegate's UserDefaults observer shows/hides
    /// the matching gauge in lockstep (no empty gauge for a disabled provider).
    @MainActor
    func setProviderEnabled(_ id: String, _ enabled: Bool) {
        ProviderEnablement.setEnabled(id, enabled)
        if let kind = AgentKind(rawValue: id), let model = appModel(for: kind) {
            if enabled { model.start() } else { model.stop() }
        }
        UserDefaults.standard.set(enabled, forKey: "clawdmeter.\(id).menuBarShown")
        Task {
            await ChatProviderProbe.shared.invalidate()
            if id == "cursor" {
                await CursorModelProbe.shared.invalidate()
            } else if id == "opencode" {
                await OpenRouterModelProbe.shared.invalidate()
            }
        }
        runtimeLogger.info("Provider \(id, privacy: .public) \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    /// All `AppModel` instances the runtime currently owns, indexed by
    /// `ProviderInstanceId.wireId`. Used by the daemon's `/usage`
    /// envelope assembler to populate the v20 per-instance dict.
    var allAppModelsByWireId: [String: AppModel] {
        modelsByInstanceWireId
    }

    /// Register a freshly configured non-primary instance and spawn its
    /// dedicated `AppModel`. Called from Settings → Providers → Add
    /// Account when the user finishes the new-instance flow.
    ///
    /// The new `AppModel` uses a token provider scoped to the
    /// instance's `keychainAccessGroupOverride` so its credentials
    /// can't bleed into sibling instances (see
    /// `PastedAnthropicTokenProvider.forInstance(_:)`).
    ///
    /// Returns `true` when the instance was registered + a model
    /// constructed; `false` if the registry rejected the instance
    /// (invalid name / masquerader) or the kind has no supported
    /// per-kind config (currently `.opencode` / `.unknown`).
    @discardableResult
    func addInstance(_ instance: ProviderInstanceId) async -> Bool {
        guard instance.isValidName else { return false }
        guard let config = providerConfig(for: instance.kind) else { return false }
        // Reject re-add of an existing wireId — caller should remove
        // first if they want to swap the underlying model.
        if modelsByInstanceWireId[instance.wireId] != nil { return false }
        guard await providerInstanceRegistry.upsert(instance) != nil else { return false }
        let model = makeInstanceAwareModel(config: config, instance: instance)
        model.start()
        modelsByInstanceWireId[instance.wireId] = model
        let redactedHome = instance.homePathOverride == nil
            ? "nil"
            : ProviderInstanceLogRedaction.homeToken(for: instance)
        runtimeLogger.info(
            "AppRuntime.addInstance wireId=\(instance.wireId, privacy: .public) home=\(redactedHome, privacy: .public)"
        )
        return true
    }

    /// Spawn an `AppModel` for `instance` using the per-kind config and
    /// a token provider scoped to the instance's Keychain partition.
    /// Currently only Claude wires the per-instance token provider
    /// (PastedAnthropicTokenProvider.forInstance) — other kinds still
    /// use the shared provider until each one grows a per-instance
    /// constructor. Tracked in TODOS.md as F3-wire phase 2.
    private func makeInstanceAwareModel(
        config: ProviderConfig,
        instance: ProviderInstanceId
    ) -> AppModel {
        switch instance.kind {
        case .claude:
            let tokenProvider = PastedAnthropicTokenProvider.forInstance(instance)
            return AppModel(
                config: config,
                source: AnthropicSource(tokenProvider: tokenProvider),
                tokenProvider: tokenProvider
            )
        case .codex:
            // Codex auth lives on disk (~/.codex/auth.json) — when
            // HOME is overridden, the provider naturally lands at
            // the override's ~/.codex/auth.json. No access-group
            // wiring needed here today; keychain partitioning kicks
            // in only if/when CodexTokenProvider grows a Keychain
            // path (currently file-based).
            let tokenProvider = CodexTokenProvider()
            return AppModel(
                config: config,
                source: CodexSource(tokenProvider: tokenProvider),
                tokenProvider: tokenProvider
            )
        case .gemini:
            let tokenProvider = GeminiTokenProvider()
            return AppModel(
                config: config,
                source: AntigravitySource(
                    tokenProvider: tokenProvider,
                    lsQuotaProbe: { @Sendable in await AntigravityLSQuotaProbe.probe() }
                ),
                tokenProvider: tokenProvider
            )
        case .cursor:
            let tokenProvider = CursorTokenProvider()
            return AppModel(
                config: config,
                source: CursorSource(tokenProvider: tokenProvider),
                tokenProvider: tokenProvider
            )
        case .opencode, .grok, .unknown:
            // Caller should not reach this — guarded by `providerConfig`
            // returning nil for these kinds. Grok's primary AppModel is
            // supported above, but custom per-instance Grok usage is not wired
            // yet because the CLI credits source has no instance-scoped home
            // override here.
            preconditionFailure(
                "AppRuntime.makeInstanceAwareModel called for unsupported kind \(instance.kind)"
            )
        }
    }

    private func providerConfig(for kind: AgentKind) -> ProviderConfig? {
        switch kind {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        case .cursor: return .cursor
        case .opencode, .grok, .unknown: return nil
        }
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

    private static func uiTestingAppSupportOverride() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLAWDMETER_UI_TESTING"] == "1",
              let rawPath = environment["CLAWDMETER_TEST_APP_SUPPORT_DIR"],
              !rawPath.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: rawPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
