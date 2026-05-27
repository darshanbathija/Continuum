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

    // Sessions feature (Phase 1 + 2 + supervisor):
    let repoIndex: RepoIndex
    let agentSessionRegistry: AgentSessionRegistry
    let workspaceStore: WorkspaceStore
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
        // v0.24.0: in-app update checker. Instantiate first — no
        // dependencies on other subsystems, and its background timer
        // schedules its first check 8s out so logs don't interleave
        // with the rest of AppRuntime's init.
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
        if UserDefaults.standard.bool(forKey: "clawdmeter.claude.autoImportFromClaudeCode") {
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
            // `.opencode` and `.unknown` don't have a per-kind AppModel
            // (OpenCode runs as a long-lived `opencode serve` daemon,
            // unknown is forward-compat sentinel only); they resolve
            // through the registry but never have a model entry.
        ]

        // Don't forward objectWillChange — it was saturating main thread with
        // SwiftUI invalidations and starving the per-poller main-queue hops
        // for the slower provider. Let each MenuBarGaugeView observe its own
        // model directly.

        // Start all pollers immediately. AppModel.start() is idempotent.
        claudeModel.start()
        codexModel.start()
        geminiModel.start()
        cursorModel.start()

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
        // Workspace store first — RepoIndex's 4th source (A1-A) reads its
        // snapshot to surface freshly-added repos that have no JSONL history.
        self.workspaceStore = WorkspaceStore()
        let workspaceStoreRef = self.workspaceStore
        self.repoIndex = RepoIndex(
            workspaceSnapshotProvider: { @Sendable in
                await MainActor.run { workspaceStoreRef.workspaces }
            }
        )
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
            notifications: self.notificationDispatcher,
            workspaceStore: self.workspaceStore
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
            supervisor: self.tmuxSupervisor,
            workspaceStore: self.workspaceStore
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
            //   - tmuxSupervisor.start() — tmux session enumeration + spawn
            //     warmup; doesn't block window paint, no mobile dep
            //   - sessionsModel.startPeriodicRefresh() — kicks the 60s
            //     timer + does an initial repo index walk
            //   - sessionScheduler.start() — schedules deferred session work
            //
            // These three move into a Task that runs after AppRuntime.init
            // returns. Cold-start latency drops by the cost of the tmux
            // session enumeration + repo index walk (~50-200ms on a
            // populated machine).
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
            let relayEnabled = UserDefaults.standard.object(forKey: "clawdmeter.relay.enabled") as? Bool ?? false
            if relayEnabled, let loopback = self.loopbackClient {
                let dispatcher = RelayRequestDispatcher(loopbackClient: loopback)
                self.relayDispatcher = dispatcher
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
                self.tmuxSupervisor.start()
                self.sessionsRefreshTask = self.sessionsModel.startPeriodicRefresh()
                self.sessionScheduler.start()
                runtimeLogger.info("A7 deferred subsystems started (tmux supervisor + sessions refresh + scheduler)")
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
            frameHandler: { [weak dispatcher] inbound in
                await dispatcher?.dispatch(inbound)
            }
        )
        relayClient = client
        client.start()
        runtimeLogger.info(
            "Relay client started (sid=\(bundle.sid.prefix(8), privacy: .public)…, host=\(bundle.relayUrl, privacy: .public))"
        )
    }

    private func bootstrapProviderRuntimes() {
        Task(priority: .utility) { @MainActor in
            OpencodeProcessManager.shared.prepareRuntimeHost()
        }
        Task(priority: .utility) { @MainActor in
            if CodexSDKManager.shared.sdkModeActive {
                // Sidecar probe is deferred to first SDK session start
                // (see CodexSubscriptionRelay.start lazy-probe block).
                // Launch-time probe was removed in PR #136 because it
                // wakes Codex.app and triggers macOS's protected app-data
                // prompt even when the user only opened Clawdmeter.
                runtimeLogger.info("Codex SDK mode is enabled; sidecar probe deferred to first SDK session start")
            }
            if AntigravitySidecarManager.shared.sdkModeActive {
                _ = await AntigravitySidecarManager.shared.enableSDKMode()
            }
            await ChatProviderProbe.shared.invalidate()
        }
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
        case .opencode, .unknown:
            // Caller should not reach this — guarded by `providerConfig`
            // returning nil for these kinds.
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
        case .opencode, .unknown: return nil
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
}
