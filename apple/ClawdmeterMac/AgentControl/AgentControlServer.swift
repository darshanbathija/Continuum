import Foundation
import Network
import OSLog
import ClawdmeterShared

let serverLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AgentControlServer")

/// In-process HTTP/1.1 + WebSocket server for the Sessions feature.
///
/// Implementation note (deviation from plan): plan called for SwiftNIO, but
/// Apple's `Network.framework` (`NWListener` + `NWProtocolWebSocket`) gives
/// us HTTP + WS server primitives natively with zero external dependencies.
/// For a personal-use single-user daemon this is the right tradeoff —
/// smaller binary, no new SwiftPM dep, native to macOS 14+. SwiftNIO's
/// extra robustness (10k-connection handling, advanced backpressure) is
/// over-spec for one Mac talking to one iPhone.
///
/// Per E3: binds to fixed default port `21731` with try-next-port-on-conflict
/// fallback. Pairing QR encodes MagicDNS host + this port so iOS pairing
/// survives daemon restarts.
///
/// Per Codex Round 1: binds `0.0.0.0` (all interfaces) and filters on
/// accept rather than binding to the Tailscale `utun` interface IP
/// directly — `utun` flaps on sleep/wake and a fixed-IP bind would break.
/// Accept filter rejects peers whose source isn't loopback / Tailscale
/// CGNAT range (`100.64.0.0/10`). Token auth gates loopback too.
///
/// Per E2: this class is `@MainActor`-isolated for lifecycle (start/stop),
/// but request handling happens on NWConnection's own queues. State
/// shared with handlers (server identity, repo index ref) goes through
/// the actor-isolated `AgentSessionRegistry` and `RepoIndex` actors.
@MainActor
public final class AgentControlServer {

    public static let defaultPort: UInt16 = 21731

    /// Range of fallback ports to try if the default is in use. Per E3:
    /// `21731 → 21732 → 21733 → ...` up to 10 attempts.
    public static let portFallbackRange: ClosedRange<UInt16> = 21731...21741

    private let pairingTokens: PairingTokenStore
    let repoIndex: RepoIndex
    let whois: TailscaleWhois
    let registry: AgentSessionRegistry
    let tmux: TmuxControlClient
    let notifications: NotificationDispatcher
    /// v16 Code V2: persisted per-repo workspace registry. Drives the
    /// `GET /workspaces` + `PATCH /workspaces/:id` endpoints and seeds
    /// new sessions with the repo's last-used model/effort/agent so
    /// iOS new-session flow doesn't need to ship explicit defaults.
    let workspaceStore: WorkspaceStore
    private let repoEnvResolver: RepoEnvRuntimeResolver?
    /// Wire v24: vendor CLI/MCP provisioning. Optional for tests that
    /// instantiate only the session daemon surface.
    let vendorProvisioningService: VendorProvisioningService?
    /// v16 Code V2: bounded LRU receipt cache for iOS write commands.
    /// Wraps the write handlers so a retried request with the same
    /// idempotency key returns the cached response instead of repeating
    /// the side effect (no double-send, no double-merge). Replayed
    /// from `mobile-commands.jsonl` on startup so a daemon restart
    /// still dedups in-flight retries.
    let mobileCommandOutbox: MobileCommandOutbox
    /// v18 Code workbench parity: remote iOS Run/Preview is hosted by the
    /// paired Mac daemon, because iOS cannot execute local repo commands.
    let codeRunProfiles: CodeRunProfileService
    /// Prepared checkpoint restore plans are intentionally short-lived:
    /// iOS must preview a restore before it can confirm it.
    var checkpointRestorePlans: [UUID: CheckpointRestorePlan] = [:]
    /// Phase 0a: long-lived per-session chat-store registry. Replaces the
    /// "reparse JSONL on every /chat-snapshot request" path. Used by the
    /// HTTP handler (snapshotStore) and, in Phase 2, by the WS dispatcher
    /// for `chat-subscribe` long-lived subscriptions (acquire / release).
    let chatStoreRegistry: DaemonChatStoreRegistry
    /// Phase 0b: shared file resolver. Owns the Codex respawn-lineage
    /// tracking — `approve-plan` invalidates the resolver so the next
    /// chat-snapshot request rescans for the new rollout file. The
    /// `chatStoreRegistry` delegates JSONL URL resolution to this.
    private let chatFileResolver: SessionFileResolver
    /// ACP harness: live `AcpHarnessBridge`s keyed by session id. Grok (and,
    /// later, every migrated ACP/SDK provider) is driven through one of these
    /// instead of a tmux pane. Claude/Codex/Cursor stay on their existing
    /// paths; the registry only holds the new harness-driven sessions.
    let harnessRegistry = HarnessSessionRegistry()
    /// Track A: per-session direct PTY hosts for Claude session-drive, gated
    /// by `clawdmeter.claude.ptyHost.enabled` (default OFF → Claude stays on
    /// tmux, byte-identical). tmux stays for terminals + non-Claude providers.
    let claudePtyRegistry = ClaudePtyRegistry.shared
    private var claudePtyExitWired = false
    /// Track A: tears down dormant Claude PTY hosts (flag-gated OFF by default).
    private lazy var idleSessionSweeper = IdleSessionSweeper(
        registry: registry, chatStoreRegistry: chatStoreRegistry
    )
    /// T18 Wire Inspector: per-connection request context so the
    /// outgoing-response recorder can tag entries with the original
    /// method+path. Each NWConnection serves one request before
    /// `connection.cancel()` runs in sendResponse's completion handler,
    /// so the dict never has more than one entry per connection at a
    /// time. Cleared in sendResponse after the response is queued.
    var pendingRequests: [ObjectIdentifier: (method: String, path: String)] = [:]
    /// Wired by AppRuntime after construction so the iPhone can pull live
    /// Claude/Codex usage AND the historical analytics snapshot over
    /// Tailscale instead of needing iCloud KV sync. Nil-tolerant — the
    /// endpoints just return empty payloads when the runtime hasn't
    /// attached yet (cold start, tests).
    weak var claudeModel: AppModel?
    weak var codexModel: AppModel?
    weak var geminiModel: AppModel?
    weak var cursorModel: AppModel?
    weak var grokModel: AppModel?
    weak var usageHistory: UsageHistoryStore?

    private var listener: NWListener?
    var wsListener: NWListener?
    var listenerQueue: DispatchQueue?
    private let listenPortRange: ClosedRange<UInt16>
    private let writesServerMetadata: Bool

    /// The port the HTTP listener actually bound to. Written to `server.json`
    /// for the Settings UI to display in the pairing QR.
    public private(set) var boundPort: UInt16?

    /// The port the WebSocket listener bound to (typically `boundPort + 1`,
    /// may differ on conflict). Encoded into the pairing QR.
    public private(set) var boundWsPort: UInt16?

    /// Per-launch random token for in-process loopback clients (Mac's
    /// `MacLoopbackClient` from PR #24a). Generated fresh on each app
    /// launch, never persisted, never shipped over the wire — only Mac
    /// code inside this process can read it via `localLoopbackToken`.
    /// The auth path (`dispatch` + WS handshake) accepts either this
    /// value OR a valid pairing token, so the iOS pairing flow stays
    /// independent of Mac loopback config.
    public let localLoopbackToken: String = UUID().uuidString

    /// Internal helper that returns true if the given Bearer-token
    /// matches either the loopback token or a registered pairing token.
    /// Hot path on every request — fail fast on the cheap string compare.
    internal func isAuthorized(token: String) -> Bool {
        if token == localLoopbackToken { return true }
        return pairingTokens.validate(token)
    }

    /// Tracks live connections so we can drain on shutdown.
    var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Active WebSocket channels keyed by connection. Both terminal +
    /// event streams conform to `WSChannel`.
    var wsChannels: [ObjectIdentifier: any WSChannel] = [:]

    /// JSONL tail + done-detector + plan-watcher wired per active session.
    var sessionWiring: [UUID: SessionEventWiring] = [:]

    @MainActor
    public var ownedSessionJSONLPaths: Set<String> {
        Set(sessionWiring.values.map { $0.sessionFileURL.path })
    }


    /// v0.8 QA: per-session warmup task for chat-mode CLI sessions. The
    /// handler that handles `POST /sessions/:id/send` awaits the task
    /// before pasting so the first prompt doesn't race the trust-prompt
    /// / update-prompt dismissal. Cleared once the task completes.
    var chatWarmupTasks: [UUID: Task<Void, Never>] = [:]

    /// v0.8 QA: pending permission-prompt continuations awaiting user
    /// response. Keyed by sessionId — only one prompt at a time per
    /// session. The continuation is resumed by handlePermissionRespond
    /// once the user clicks an option in the AskUserQuestion-style card,
    /// at which point the warmup / poll loop proceeds with the chosen
    /// dispatch keys.
    private var pendingPermissionContinuations: [UUID: CheckedContinuation<String, Never>] = [:]
    /// v0.8 QA F4: matches the currently-pending promptId so
    /// handlePermissionRespond can reject stale clicks (paired iOS
    /// surface with a stale prompt, or v0.8.x Claude per-tool flow
    /// where multiple prompts per session is real). Cleared alongside
    /// the continuation.
    private var pendingPermissionPromptIds: [UUID: String] = [:]
    /// Pending prompt → option-id → tmux key sequence map. Server-side
    /// because the wire never carries raw key sequences (security).
    private var permissionOptionDispatch: [UUID: [String: [String]]] = [:]
    /// v0.8 QA F2: sentinel optionId resumed by handleDeleteSession /
    /// stop() so any in-flight warmup task wakes up and returns
    /// cleanly instead of waiting forever for the user.
    private static let cancelledPermissionOptionId = "__cancelled__"

    /// v0.9 — CM5 idempotency: cache of `clientRequestId → groupId` for
    /// POST /chat-sessions/frontier so a network retry doesn't spawn a
    /// second 3-pane group. Bounded; entries expire on iterator-based
    /// sweep when the map crosses 256. Replays return the original
    /// group's per-slot status (one cached snapshot per groupId).
    var frontierGroupIdempotency: [UUID: (groupId: UUID, response: CreateFrontierResponse, createdAt: Date)] = [:]
    /// Per-group monotonic snapshot counter; advances on every child
    /// status change. Used by the frontier-subscribe WS channel (TBD)
    /// and by the response from /retry-slot.
    var frontierUpdateCounters: [UUID: Int] = [:]
    var frontierTurnWinners: [UUID: [String: FrontierTurnWinner]] = [:]

    // v0.8.x: a per-session pane-scanner task for mid-conversation
    // permission prompts (e.g. Claude per-tool approvals) will land
    // here. The startup-time prompt path is wired through
    // chatWarmupTasks above; the scanner is the next increment.
    // Declared lazily when the v0.8.x scanner ships — keeping the
    // var here today would be dead code that misleads readers.

    /// v0.8 QA: same-process accessor so Mac UI's SessionsModel can read
    /// from the daemon's SessionChatStore (the one CodexSDKEventIngestor
    /// writes to) instead of creating its own empty parallel store. iOS
    /// goes through chat-subscribe WS for the same effect; Mac is in the
    /// same process and can read the registry directly.
    @MainActor
    public func chatStore(for session: AgentSession) -> SessionChatStore? {
        chatStoreRegistry.snapshotStore(for: session)
    }

    /// D4 (v0.17, wire v12): callback that fans the iOS-side per-provider
    /// auto-revive toggle out to the matching AppModel.setAutoReviveEnabled.
    /// AppRuntime injects this at startup; the server just dispatches.
    /// Nil means D4 isn't wired (test-time / Previews) and the endpoint
    /// returns 503.
    public var setAutoReviveCallback: (@MainActor (AgentKind, Bool) -> Void)?

    /// v23: workspace onboarding (Add Repo flow) — the same `RepoOnboarding`
    /// the Mac UI uses, reused on the daemon side for iOS-relayed flows.
    /// Lazy because it captures `self.workspaceStore` and `self.repoIndex`
    /// which need init to finish first. Refresh closure fires
    /// `RepoIndex.refresh()` so the iOS workspace switcher sees the new
    /// repo within a tick of the response.
    lazy var repoOnboardingService: RepoOnboarding = {
        let index = self.repoIndex
        return RepoOnboarding(
            workspaceStore: self.workspaceStore,
            repoIndex: index,
            refresh: { await index.refresh() },
            onWorkspaceRegistered: { _ in }
        )
    }()

    /// v23: CGSession liveness probe for `/workspaces/open-local`. Injected
    /// for testability; production uses the live CGSession dictionary.
    var cgSession: CGSessionLiveness = LiveCGSession()

    public init(
        pairingTokens: PairingTokenStore = .shared,
        repoIndex: RepoIndex,
        registry: AgentSessionRegistry,
        tmux: TmuxControlClient,
        notifications: NotificationDispatcher,
        whois: TailscaleWhois = .shared,
        chatStoreRegistry: DaemonChatStoreRegistry? = nil,
        chatFileResolver: SessionFileResolver? = nil,
        workspaceStore: WorkspaceStore? = nil,
        repoEnvResolver: RepoEnvRuntimeResolver? = nil,
        vendorProvisioningService: VendorProvisioningService? = nil,
        mobileCommandOutbox: MobileCommandOutbox? = nil,
        listenPortRange: ClosedRange<UInt16> = 21731...21741,
        writesServerMetadata: Bool = true
    ) {
        self.pairingTokens = pairingTokens
        self.repoIndex = repoIndex
        self.registry = registry
        self.tmux = tmux
        self.notifications = notifications
        self.whois = whois
        self.listenPortRange = listenPortRange
        self.writesServerMetadata = writesServerMetadata
        // v16 Code V2: WorkspaceStore is @MainActor like the rest of the
        // registries — default-construct on the same actor so the file
        // load + migrate-from-sessions runs without an actor hop. Tests
        // can inject an isolated tmpdir-backed store.
        self.workspaceStore = workspaceStore ?? WorkspaceStore()
        self.repoEnvResolver = repoEnvResolver
        self.vendorProvisioningService = vendorProvisioningService
        self.codeRunProfiles = CodeRunProfileService(repoEnvResolver: repoEnvResolver)
        // v16 Code V2: bounded receipt cache. The replay-from-audit-log
        // call is fire-and-forget — happens on the first request to an
        // idempotent endpoint (see `tryReplayIdempotent`).
        self.mobileCommandOutbox = mobileCommandOutbox ?? MobileCommandOutbox()
        // Phase 0b: the file resolver delegates Claude lookups to
        // `SessionChatStore.resolveSessionFileURL(repoCwd:)` and handles
        // Codex respawn lineage itself. The default `~/.codex/sessions`
        // path is correct for production; tests pass a tmpdir.
        let resolver = chatFileResolver ?? SessionFileResolver(
            resolveClaudeURL: { session in
                let cwd = session.effectiveCwd
                return SessionChatStore.resolveSessionFileURL(repoCwd: cwd)
            }
        )
        self.chatFileResolver = resolver
        // Phase 0a + 0b: the registry's URL resolver delegates to the
        // shared `SessionFileResolver`. Same default-isolation note as
        // before applies: the parameter default has to be `nil` and the
        // construction lives inside the @MainActor init body.
        self.chatStoreRegistry = chatStoreRegistry ?? DaemonChatStoreRegistry(
            resolveURL: { _, session in resolver.resolve(session: session) }
        )
        self.frontierTurnWinners = Self.loadFrontierTurnWinners()
    }

    /// Hand the daemon the live usage publishers + analytics store
    /// AppRuntime owns. Called once after AppRuntime's `init` finishes —
    /// we can't take these as init args because they all live on
    /// AppRuntime and we'd cycle. Idempotent.
    public func attachUsageSources(
        claude: AppModel?,
        codex: AppModel?,
        gemini: AppModel? = nil,
        cursor: AppModel? = nil,
        grok: AppModel? = nil,
        history: UsageHistoryStore?
    ) {
        self.claudeModel = claude
        self.codexModel = codex
        self.geminiModel = gemini
        self.cursorModel = cursor
        self.grokModel = grok
        self.usageHistory = history
    }

    // v0.27.0: attachDesignBridge(...) + the design-bridge port/token
    // provider properties removed along with the Design tab + Open Design
    // daemon. The /design/import-folder route + handler were stripped too.

    /// Audit P1 fix: 15-minute autopilot inactivity sweep. AutopilotState
    /// already implements the timing logic but nothing was calling
    /// expiredSessions() — so the 15-min safety guardrail advertised in
    /// the eng review was dead code. Started in `start()`, cancelled in
    /// `stop()`, ticks every 30s.
    private var autopilotSweepTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Start the server. Tries default port first, falls back on conflict.
    /// Best-effort: if no port in the range works, logs and returns
    /// without starting. The Sessions tab handles "daemon offline" gracefully.
    public func start() {
        guard listener == nil else { return }
        // Reap stale harness children (codex app-server / grok / cursor-agent)
        // left by a previous, crashed daemon. Real daemon only — a test server
        // (writesServerMetadata == false) must not touch the shared
        // ~/.clawdmeter pidfile or another live daemon's children.
        if writesServerMetadata {
            HarnessProcessReaper.shared.reapOrphans()
        }
        // Track A: start the idle PTY sweeper (a no-op until the
        // clawdmeter.claude.idleSuspend.enabled flag is on).
        idleSessionSweeper.start()
        let queue = DispatchQueue(label: "AgentControlServer.accept", qos: .userInitiated)
        self.listenerQueue = queue

        for port in listenPortRange {
            if startListening(on: port, queue: queue) {
                boundPort = port
                serverLogger.info("HTTP listening on 0.0.0.0:\(port)")
                break
            }
        }
        guard let httpPort = boundPort else {
            serverLogger.error("Could not bind HTTP listener to any port in \(self.listenPortRange.lowerBound)–\(self.listenPortRange.upperBound)")
            return
        }
        // Start the WS listener on httpPort + 1 (with fallback).
        for offset in 1...10 {
            let wsPort = UInt16(Int(httpPort) + offset)
            if startWSListening(on: wsPort, queue: queue) {
                boundWsPort = wsPort
                serverLogger.info("WS listening on 0.0.0.0:\(wsPort)")
                break
            }
        }
        if writesServerMetadata {
            writeServerJSON(port: httpPort, wsPort: boundWsPort ?? 0)
        }
        // v0.5.3: warm the chat-store registry for the most recently-
        // touched JSONLs across ~/.claude/projects/ and ~/.codex/sessions/.
        // The first iPhone /chat-snapshot or /transcript request after
        // Mac restart hits a warm store instead of a cold reparse.
        // Async on a detached Task so it doesn't block listener bind.
        //
        // v0.29.32: this read of ~/.claude + ~/.codex triggers the macOS
        // "access data from other apps" prompt at launch — only warm for
        // providers the user has enabled (opt-in). With both off, skip it.
        if ProviderEnablement.isEnabled("claude") || ProviderEnablement.isEnabled("codex") {
            chatStoreRegistry.warm(recentLimit: 5)
        }
        // v16 Code V2: replay the last 256 mobile-command audit entries
        // so a daemon restart still dedups in-flight iOS retries. Fire
        // and forget — the cache hydrates within tens of ms.
        Task.detached { [outbox = self.mobileCommandOutbox] in
            await outbox.replayFromAuditLog()
        }
        startAutopilotSweep()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        wsListener?.cancel()
        wsListener = nil
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        for (_, channel) in wsChannels {
            channel.stop()
        }
        self.wsChannels.removeAll()
        autopilotSweepTask?.cancel()
        autopilotSweepTask = nil
        serverLogger.info("Server stopped")
    }

    private static var frontierTurnWinnersURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("frontier-turn-winners.json")
    }

    private static func loadFrontierTurnWinners() -> [UUID: [String: FrontierTurnWinner]] {
        let url = frontierTurnWinnersURL
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UUID: [String: FrontierTurnWinner]].self, from: data)) ?? [:]
    }

    func saveFrontierTurnWinners() {
        let url = Self.frontierTurnWinnersURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(frontierTurnWinners)
            try data.write(to: url, options: [.atomic])
        } catch {
            serverLogger.warning("failed to persist frontier winners: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Audit P1 fix: tick AutopilotState every 30s, disable any sessions
    /// that have been idle for >15 min, and emit a statusChanged event
    /// so the UI clears the autopilot indicator. Without this loop the
    /// safety guardrail described in the CEO+Eng review never fires.
    private func startAutopilotSweep() {
        guard autopilotSweepTask == nil else { return }
        autopilotSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                let expired = await MainActor.run { AutopilotState.shared.expiredSessions() }
                guard !expired.isEmpty else { continue }
                for id in expired {
                    await self?.expireAutopilotSession(id)
                }
            }
        }
    }

    private func expireAutopilotSession(_ id: UUID) async {
        AutopilotState.shared.setEnabled(false, sessionId: id)
        AgentEventStream.recordEvent(
            sessionId: id,
            kind: .statusChanged,
            payload: ["autopilot": "false", "reason": "inactivity_timeout"]
        )
        let changer = SessionConfigChanger(registry: registry, tmux: tmux, repoEnvResolver: repoEnvResolver)
        let result = await changer.swap(sessionId: id)
        switch result {
        case .swapped:
            serverLogger.info(
                "autopilot disabled and session respawned after inactivity: session=\(id.uuidString, privacy: .public)"
            )
        case .resumeFailed(let restoredOriginal):
            serverLogger.error(
                "autopilot expiry respawn failed for \(id.uuidString, privacy: .public); restoredOriginal=\(restoredOriginal, privacy: .public)"
            )
        case .spawnError(let message):
            serverLogger.error(
                "autopilot expiry could not respawn \(id.uuidString, privacy: .public): \(message, privacy: .public)"
            )
        }
    }

    private func startListening(on port: UInt16, queue: DispatchQueue) -> Bool {
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let params = NWParameters.tcp
            // P1-Mac-8: don't set `requiredInterfaceType = .other` — that
            // pins the listener to non-loopback/non-wired/non-wifi/non-cell
            // interfaces, which excludes `lo0`. The Mac composer posts to
            // 127.0.0.1 (Workspace/Composer/MacComposerSender.swift) and
            // local Bonjour-less clients can be pinned to loopback, so the
            // HTTP path was silently failing on those code paths even
            // though the accept filter explicitly allows loopback. The
            // WebSocket listener (a few lines below) already didn't set
            // this; align the HTTP listener with it and rely on
            // `isAllowedPeer` to gate connections.
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params, on: nwPort)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }
            listener.stateUpdateHandler = { state in
                serverLogger.debug("Listener state: \(String(describing: state))")
            }
            listener.start(queue: queue)
            return true
        } catch {
            serverLogger.debug("Bind to port \(port) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Write the bound ports to disk so Mac Settings UI can render the
    /// pairing QR with the right ports.
    private func writeServerJSON(port: UInt16, wsPort: UInt16) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("Clawdmeter", isDirectory: true)
        guard let appSupport else { return }
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        let file = appSupport.appendingPathComponent("server.json")
        let payload: [String: Any] = [
            "port": Int(port),
            "wsPort": Int(wsPort),
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: file)
        }
    }

    // MARK: - Accept handling

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        // Filter on accept (per Codex Round 1): only loopback / Tailscale
        // CGNAT peers allowed. Token auth still required afterward.
        let allowed = Self.isAllowedPeer(connection.endpoint)
        if !allowed {
            serverLogger.warning("Rejecting non-tailnet peer: \(String(describing: connection.endpoint))")
            connection.cancel()
            connections.removeValue(forKey: id)
            return
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                Task { @MainActor in
                    self?.beginHTTPRead(on: connection)
                }
            case .failed(let error):
                serverLogger.debug("Connection failed: \(error.localizedDescription)")
                connection.cancel()
                Task { @MainActor in
                    self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                }
            case .cancelled:
                Task { @MainActor in
                    self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                }
            default:
                break
            }
        }
        connection.start(queue: listenerQueue ?? .global())
    }

    /// True if the connection's source IP is loopback or in the
    /// Tailscale CGNAT range (100.64.0.0/10).
    static func isAllowedPeer(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            if case .ipv4(let addr) = host {
                let bytes = addr.rawValue
                if bytes.count == 4 {
                    let b0 = bytes[0]
                    let b1 = bytes[1]
                    // 127.0.0.0/8 loopback
                    if b0 == 127 { return true }
                    // 100.64.0.0/10 = 100.64 .. 100.127
                    if b0 == 100 && (b1 >= 64 && b1 <= 127) { return true }
                }
                return false
            }
            if case .ipv6(let addr) = host {
                // ::1 loopback. Tailscale IPv6 prefix is fd7a:115c:a1e0::/48
                // which we recognize via the first 6 bytes.
                let bytes = addr.rawValue
                if bytes.count == 16 {
                    // Loopback (::1)
                    let isLoopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes.last == 1
                    if isLoopback { return true }
                    // Tailscale IPv6: fd7a:115c:a1e0:.../48
                    if bytes[0] == 0xFD, bytes[1] == 0x7A,
                       bytes[2] == 0x11, bytes[3] == 0x5C,
                       bytes[4] == 0xA1, bytes[5] == 0xE0 {
                        return true
                    }
                }
                return false
            }
            return false
        default:
            // .unix, .url etc — not used in our setup
            return false
        }
    }

    // MARK: - HTTP request parsing + dispatch

    private func beginHTTPRead(on connection: NWConnection) {
        // Minimal HTTP/1.1: read request line + headers up to the first
        // blank line. Body length determined by Content-Length header.
        let buffer = HTTPRequestBuffer()
        readMore(connection: connection, buffer: buffer)
    }

    private func readMore(connection: NWConnection, buffer: HTTPRequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            if let error {
                serverLogger.debug("Read error: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                buffer.append(data)
                do {
                    if let request = try buffer.tryParse() {
                        Task { @MainActor in
                            await self?.dispatch(request: request, connection: connection)
                        }
                        return
                    }
                } catch HTTPRequestBuffer.ParseError.payloadTooLarge {
                    Task { @MainActor in
                        self?.sendResponse(HTTPResponse(
                            status: 413, reason: "Payload Too Large",
                            contentType: "text/plain",
                            body: Data("Payload Too Large\n".utf8)
                        ), on: connection)
                    }
                    return
                } catch {
                    Task { @MainActor in
                        self?.sendResponse(.badRequest, on: connection)
                    }
                    return
                }
            }
            if isComplete {
                connection.cancel()
                return
            }
            Task { @MainActor in
                self?.readMore(connection: connection, buffer: buffer)
            }
        }
    }

    private func dispatch(request: HTTPRequest, connection: NWConnection) async {
        // Auth: every endpoint requires the bearer token, even loopback
        // (defense-in-depth against local processes that aren't us).
        // Accept either the pairing token (iOS) or the per-launch loopback
        // token (Mac's in-process MacLoopbackClient, PR #24a).
        guard let auth = request.headers["authorization"],
              auth.hasPrefix("Bearer "),
              isAuthorized(token: String(auth.dropFirst("Bearer ".count)))
        else {
            sendResponse(.unauthorized, on: connection)
            return
        }

        // For non-loopback peers, additionally check Tailscale whois.
        // (Loopback is `127.x.x.x` or `::1`.)
        if let endpoint = connection.endpoint as NWEndpoint?,
           !isLoopback(endpoint) {
            let peerString = Self.endpointString(endpoint)
            let loginName = await whois.userLoginName(for: peerString)
            if loginName == nil {
                serverLogger.warning("whois rejected non-loopback peer \(peerString, privacy: .public)")
                sendResponse(.unauthorized, on: connection)
                return
            }
        }

        // T18 Wire Inspector: record the incoming request body when enabled.
        // Also stash the request context so sendResponse can tag the
        // matching outbound entry with the right method+path. Check
        // isEnabledFast first to avoid the actor hop + body retain on
        // the hot path when the inspector is off (the common case).
        if WireInspector.isEnabledFast {
            let peerString = Self.endpointString(connection.endpoint)
            pendingRequests[ObjectIdentifier(connection)] = (request.method, request.path)
            await WireInspector.shared.recordRequest(
                method: request.method, path: request.path, peer: peerString,
                body: request.body.isEmpty ? nil : request.body,
                contentType: request.headers["content-type"]
            )
        }

        if let match = routes.match(method: request.method, path: request.path) {
            await match.handler(request, connection, match.params)
            return
        }
        sendResponse(.notFound, on: connection)
    }

    // MARK: - Route table (T10) — replaces the older switch dispatch.
    // Handler type lives on RouteTable for visibility reasons; see comment there.

    /// Lazily-built route table — registered once on first dispatch so all
    /// handler methods are visible. Routes match in registration order; put
    /// specific paths (`/sessions/needs-attention`) before parameterized
    /// patterns (`/sessions/:id`).
    private lazy var routes: RouteTable = {
        var t = RouteTable()

        // --- GETs ---
        t.register(method: "GET", pattern: "/health") { [weak self] _, conn, _ in
            self?.handleHealthV2(connection: conn)
        }
        t.register(method: "GET", pattern: "/repos") { [weak self] _, conn, _ in
            await self?.handleGetRepos(connection: conn)
        }
        t.register(method: "GET", pattern: "/models") { [weak self] _, conn, _ in
            await self?.handleGetModels(connection: conn)
        }
        t.register(method: "GET", pattern: "/provider-defaults") { [weak self] _, conn, _ in
            self?.handleGetProviderDefaults(connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions") { [weak self] _, conn, _ in
            self?.handleGetSessions(connection: conn)
        }
        // v16: persisted workspace registry. iOS new-session flow inherits
        // these per-repo defaults so the user doesn't have to re-pick
        // model/effort every time they spawn a new agent in the same repo.
        t.register(method: "GET", pattern: "/workspaces") { [weak self] _, conn, _ in
            self?.handleListWorkspaces(connection: conn)
        }
        t.register(method: "PATCH", pattern: "/workspaces/:id") { [weak self] req, conn, params in
            await self?.handleUpdateWorkspaceDefaults(
                workspaceId: params["id"] ?? "",
                request: req,
                connection: conn
            )
        }
        // v23: Add-Repo workspace onboarding endpoints. iOS posts here to
        // drive the Mac through one of the three Conductor-style flows.
        // Path validation (A9-B) + CGSession liveness (A3-A) gate the write
        // endpoints. All writes idempotent-keyed via MobileCommandOutbox.
        t.register(method: "POST", pattern: "/workspaces/open-local") { [weak self] req, conn, _ in
            await self?.handleOpenLocalFolder(request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/workspaces/from-github") { [weak self] req, conn, _ in
            await self?.handleCloneFromGitHub(request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/workspaces/quick-start") { [weak self] req, conn, _ in
            await self?.handleQuickStartRepo(request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/workspaces/wake-mac") { [weak self] req, conn, _ in
            await self?.handleWakeMac(request: req, connection: conn)
        }
        t.register(method: "GET", pattern: "/workspaces/allow-list") { [weak self] _, conn, _ in
            self?.handleGetWorkspaceAllowList(connection: conn)
        }
        // v24: vendor CLI/MCP provisioning. Install/auth actions launch
        // visible Terminal commands from an allowlisted catalog; env import
        // delegates to PR 201's RepoEnvStore + Keychain flow.
        t.register(method: "GET", pattern: "/vendor-provisioning/vendors") { [weak self] _, conn, _ in
            self?.handleGetVendorProvisioningVendors(connection: conn)
        }
        t.register(method: "POST", pattern: "/vendor-provisioning/check-device") { [weak self] _, conn, _ in
            await self?.handleCheckVendorProvisioning(connection: conn)
        }
        t.register(method: "POST", pattern: "/vendor-provisioning/vendors/:id/actions") { [weak self] req, conn, params in
            await self?.handleVendorProvisioningAction(
                vendorId: params["id"] ?? "",
                request: req,
                connection: conn
            )
        }
        t.register(method: "POST", pattern: "/vendor-provisioning/vendors/:id/env/preview") { [weak self] req, conn, params in
            self?.handleVendorEnvPreview(
                vendorId: params["id"] ?? "",
                request: req,
                connection: conn
            )
        }
        t.register(method: "POST", pattern: "/vendor-provisioning/vendors/:id/env/import") { [weak self] req, conn, params in
            self?.handleVendorEnvImport(
                vendorId: params["id"] ?? "",
                request: req,
                connection: conn
            )
        }
        t.register(method: "PUT", pattern: "/provider-defaults/:vendor") { [weak self] req, conn, params in
            await self?.handlePutProviderDefault(
                vendorId: params["vendor"] ?? "",
                request: req,
                connection: conn
            )
        }
        t.register(method: "GET", pattern: "/sessions/needs-attention") { [weak self] _, conn, _ in
            await self?.handleGetNeedsAttention(connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/preflight") { [weak self] req, conn, _ in
            await self?.handleGetPreflight(request: req, connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/lifecycle") { [weak self] _, conn, params in
            self?.handleGetLifecycle(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id") { [weak self] _, conn, params in
            self?.handleGetOneSession(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/chat-snapshot") { [weak self] req, conn, params in
            await self?.handleGetChatSnapshot(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/run-profile") { [weak self] _, conn, params in
            await self?.handleGetRunProfile(sessionId: params["id"] ?? "", connection: conn)
        }
        for method in ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"] {
            t.register(method: method, pattern: "/sessions/:id/run-profile/proxy/*") { [weak self] req, conn, params in
                await self?.handleRunProfileProxy(
                    sessionId: params["id"] ?? "",
                    request: req,
                    connection: conn
                )
            }
        }
        t.register(method: "GET", pattern: "/sessions/:id/checkpoints") { [weak self] _, conn, params in
            self?.handleListCheckpoints(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/diff") { [weak self] _, conn, params in
            await self?.handleGetDiff(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/diff/*") { [weak self] req, conn, params in
            await self?.handleGetDiffFile(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/pr") { [weak self] _, conn, params in
            await self?.handleGetPR(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/terminals") { [weak self] _, conn, params in
            self?.handleGetTerminals(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/artifact") { [weak self] req, conn, params in
            await self?.handleGetArtifact(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/markdown-document") { [weak self] req, conn, params in
            await self?.handleGetMarkdownDocument(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        // v0.6.0 wire v7: Antigravity Plan endpoint. Returns
        // AntigravityPlanSnapshot for a Gemini session — task.md + steps
        // + annotations + token usage estimate. Empty/awaitingFirstTurn
        // snapshot returned for fresh brain dirs.
        t.register(method: "GET", pattern: "/sessions/:id/antigravity-plan") { [weak self] _, conn, params in
            await self?.handleGetAntigravityPlan(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "GET", pattern: "/transcript") { [weak self] req, conn, _ in
            self?.handleGetTranscript(path: req.path, connection: conn)
        }
        t.register(method: "GET", pattern: "/usage") { [weak self] _, conn, _ in
            self?.handleGetUsage(connection: conn)
        }
        t.register(method: "GET", pattern: "/analytics") { [weak self] _, conn, _ in
            self?.handleGetAnalytics(connection: conn)
        }

        // v0.27.0: POST /design/import-folder route removed along with
        // the Design tab + Open Design daemon + clawdmeter-bridge-host sidecar.

        // --- POSTs ---
        t.register(method: "POST", pattern: "/sessions") { [weak self] req, conn, _ in
            await self?.handlePostSession(request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/approve-plan") { [weak self] req, conn, params in
            await self?.handleApprovePlan(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/archive") { [weak self] _, conn, params in
            await self?.handleArchive(sessionId: params["id"] ?? "", archived: true, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/unarchive") { [weak self] _, conn, params in
            await self?.handleArchive(sessionId: params["id"] ?? "", archived: false, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/rename") { [weak self] req, conn, params in
            await self?.handleRename(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/jsonl-aliases/rename") { [weak self] req, conn, _ in
            self?.handleRenameJSONLAlias(request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/model") { [weak self] req, conn, params in
            await self?.handleChangeModel(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/effort") { [weak self] req, conn, params in
            await self?.handleChangeEffort(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/mode") { [weak self] req, conn, params in
            await self?.handleChangeMode(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/send") { [weak self] req, conn, params in
            await self?.handleSendPrompt(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/run-profile/start") { [weak self] req, conn, params in
            await self?.handleStartRunProfile(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/run-profile/stop") { [weak self] _, conn, params in
            await self?.handleStopRunProfile(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/checkpoints") { [weak self] req, conn, params in
            await self?.handleCreateCheckpoint(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/checkpoints/:checkpointId/prepare-restore") { [weak self] _, conn, params in
            await self?.handlePrepareCheckpointRestore(
                sessionId: params["id"] ?? "",
                checkpointId: params["checkpointId"] ?? "",
                connection: conn
            )
        }
        t.register(method: "POST", pattern: "/sessions/:id/checkpoints/:checkpointId/restore") { [weak self] req, conn, params in
            await self?.handleRestoreCheckpoint(
                sessionId: params["id"] ?? "",
                checkpointId: params["checkpointId"] ?? "",
                request: req,
                connection: conn
            )
        }
        t.register(method: "POST", pattern: "/sessions/:id/diff-action/*") { [weak self] req, conn, params in
            await self?.handleDiffAction(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        // v0.7.7: SidecarAskCoordinator route. iPhone surface POSTs
        // decisions here for cross-surface ask_user(...) prompts the
        // Antigravity SDK sidecar fires. Mac inline path calls the
        // coordinator directly (in-proc).
        t.register(method: "POST", pattern: "/internal/sidecar-ask/:promptUUID/decide") { [weak self] req, conn, params in
            await self?.handleSidecarAskDecide(
                promptUUID: params["promptUUID"] ?? "",
                request: req,
                connection: conn
            )
        }
        t.register(method: "POST", pattern: "/sessions/:id/interrupt") { [weak self] req, conn, params in
            await self?.handleInterrupt(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/revive") { [weak self] req, conn, params in
            await self?.handleRevive(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/permission-respond") { [weak self] req, conn, params in
            await self?.handlePermissionRespond(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/autopilot") { [weak self] req, conn, params in
            await self?.handleSetAutopilot(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/ab-pair/pick-winner") { [weak self] req, conn, params in
            await self?.handlePickPairWinner(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/create-pr") { [weak self] req, conn, params in
            await self?.handleCreatePR(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/pr/review") { [weak self] req, conn, params in
            await self?.handleReviewPR(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/merge") { [weak self] req, conn, params in
            await self?.handleMerge(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/terminals") { [weak self] req, conn, params in
            await self?.handleAddTerminal(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/continue-readonly") { [weak self] req, conn, _ in
            await self?.handleContinueReadOnly(request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/attachments") { [weak self] req, conn, params in
            await self?.handleUploadAttachment(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/live-activities/push-token") { [weak self] req, conn, _ in
            await self?.handleRegisterPushToken(request: req, connection: conn)
        }
        // E6: remote-push device-token registration. iPhone posts here
        // when its `UIApplicationDelegate.didRegisterForRemoteNotificationsWithDeviceToken`
        // delivery callback fires. Distinct from the Live Activity push
        // token (which is per-activity, ephemeral); this one is the
        // long-lived per-app remote-push token.
        t.register(method: "POST", pattern: "/devices/apns-token") { [weak self] req, conn, _ in
            await self?.handleRegisterAPNSDeviceToken(request: req, connection: conn)
        }
        t.register(method: "DELETE", pattern: "/devices/apns-token") { [weak self] req, conn, _ in
            await self?.handleUnregisterAPNSDeviceToken(request: req, connection: conn)
        }
        // D4 (v0.17): per-provider auto-revive toggle. iOS Live tab
        // fans the per-provider switch through here; the daemon dispatches
        // to the right AppModel.setAutoReviveEnabled. Wire v12.
        t.register(method: "POST", pattern: "/providers/:id/auto-revive") { [weak self] req, conn, params in
            await self?.handleSetAutoRevive(
                providerId: params["id"] ?? "",
                request: req,
                connection: conn
            )
        }
        t.register(method: "POST", pattern: "/devices/ack-notifications") { [weak self] req, conn, _ in
            await self?.handleAckNotifications(request: req, connection: conn)
        }
        t.register(method: "DELETE", pattern: "/live-activities/push-token") { [weak self] req, conn, _ in
            await self?.handleUnregisterPushToken(request: req, connection: conn)
        }

        // --- PATCHes ---
        t.register(method: "PATCH", pattern: "/sessions/:id/terminals/:paneId") { [weak self] req, conn, params in
            await self?.handleRenameTerminal(
                sessionId: params["id"] ?? "",
                paneId: params["paneId"] ?? "",
                request: req,
                connection: conn
            )
        }

        // --- DELETEs ---
        // Specific delete first so /sessions/:id/terminals/:paneId beats /sessions/:id.
        t.register(method: "DELETE", pattern: "/sessions/:id/terminals/:paneId") { [weak self] _, conn, params in
            await self?.handleDeleteTerminal(
                sessionId: params["id"] ?? "",
                paneId: params["paneId"] ?? "",
                connection: conn
            )
        }
        t.register(method: "DELETE", pattern: "/sessions/:id") { [weak self] _, conn, params in
            await self?.handleDeleteSession(sessionId: params["id"] ?? "", connection: conn)
        }

        // --- v0.8 Chat tab (wire v9) ---
        t.register(method: "POST", pattern: "/chat-sessions") { [weak self] req, conn, _ in
            await self?.handlePostChatSession(request: req, connection: conn)
        }
        t.register(method: "GET", pattern: "/chat-providers") { [weak self] _, conn, _ in
            await self?.handleGetChatProviders(connection: conn)
        }
        t.register(method: "POST", pattern: "/chat-providers/refresh") { [weak self] _, conn, _ in
            await self?.handleRefreshChatProviders(connection: conn)
        }
        // Frontier endpoints back the 3-provider comparison surface.
        t.register(method: "POST", pattern: "/chat-sessions/frontier") { [weak self] req, conn, _ in
            await self?.handlePostFrontier(request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/chat-sessions/frontier/:groupId/send") { [weak self] req, conn, params in
            await self?.handleFrontierSend(request: req, connection: conn, groupId: params["groupId"] ?? "")
        }
        t.register(method: "POST", pattern: "/chat-sessions/frontier/:groupId/retry-slot") { [weak self] req, conn, params in
            await self?.handleFrontierRetrySlot(request: req, connection: conn, groupId: params["groupId"] ?? "")
        }
        t.register(method: "POST", pattern: "/chat-sessions/frontier/:groupId/pick-winner") { [weak self] req, conn, params in
            await self?.handlePickFrontierWinner(request: req, connection: conn, groupId: params["groupId"] ?? "")
        }
        t.register(method: "POST", pattern: "/chat-sessions/frontier/:groupId/turn-winner") { [weak self] req, conn, params in
            await self?.handleSetFrontierTurnWinner(request: req, connection: conn, groupId: params["groupId"] ?? "")
        }
        // v0.23 (Chat V2 wire v14): full-history search across JSONLs
        // on disk. Walks the chat sessions the registry knows about
        // and substring-scans their JSONL files for the query. Bounded
        // by a 200ms hard timeout + 50-result cap so the sidebar
        // search-as-you-type stays responsive.
        t.register(method: "GET", pattern: "/chat-sessions/search") { [weak self] req, conn, _ in
            await self?.handleChatSessionSearch(request: req, connection: conn)
        }

        return t
    }()

    private func handleHealthV2(connection: NWConnection) {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        sendJSON([
            "ok": true,
            "serverVersion": version,
            "wireVersion": AgentControlWireVersion.current,
        ], on: connection)
    }

    private func providerEnabledModelCatalog() async -> ModelCatalog {
        var catalog = ModelCatalog.bundled
        if ProviderEnablement.isEnabled("cursor") {
            catalog = catalog.replacingCursor(await CursorModelProbe.shared.currentModels())
        }
        if ProviderEnablement.isEnabled("opencode") {
            catalog = catalog.replacingOpenRouter(await OpenRouterModelProbe.shared.currentModels())
        }
        return catalog
    }

    private func handleGetModels(connection: NWConnection) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let catalog = await providerEnabledModelCatalog()
        if let body = try? encoder.encode(catalog) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleGetProviderDefaults(connection: NWConnection) {
        let store = ProviderDefaultsStore()
        sendCodable(ProviderDefaultsResponse(defaults: store.snapshot), on: connection)
    }

    private func handlePutProviderDefault(
        vendorId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let vendor = ChatVendor(rawValue: vendorId) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let req = try? decoder.decode(UpdateProviderDefaultRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }

        let catalog = await providerEnabledModelCatalog()
        if let model = req.model,
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !vendor.models(in: catalog).contains(where: { $0.id == model || $0.cliAlias == model }) {
            sendResponse(.badRequest, on: connection)
            return
        }

        let store = ProviderDefaultsStore()
        let snapshot = store.setDefault(
            for: vendor,
            model: req.model,
            effort: req.effort,
            clearModel: req.clearModel,
            clearEffort: req.clearEffort,
            catalog: catalog
        )
        sendCodable(ProviderDefaultsResponse(defaults: snapshot), on: connection)
    }

    // MARK: - Sessions v2 Phase 0 handlers

    private func handleChangeModel(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(ChangeModelRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        let liveCatalog = await providerEnabledModelCatalog()
        guard !req.model.isEmpty, liveCatalog.entry(forId: req.model) != nil else {
            sendResponse(.badRequest, on: connection); return
        }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        let oldModel = session.model
        let changer = SessionConfigChanger(registry: registry, tmux: tmux, repoEnvResolver: repoEnvResolver)
        let result = await changer.swap(
            sessionId: uuid,
            newModel: req.model,
            newEffort: req.effort == nil ? nil : .some(req.effort)
        )
        guard isSuccessfulSwap(result) else {
            sendResponse(.internalError, on: connection); return
        }
        let peer = Self.endpointString(connection.endpoint)
        await AuditLog.shared.recordSwap(
            sessionId: uuid, sourcePeer: peer,
            from: oldModel, to: req.model, effort: req.effort?.rawValue
        )
        await respondWithSession(
            uuid: uuid,
            idempotencyKey: req.idempotencyKey,
            kind: .changeModel,
            payloadHash: payloadHash,
            connection: connection
        )
    }

    private func handleChangeEffort(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(ChangeEffortRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        let changer = SessionConfigChanger(registry: registry, tmux: tmux, repoEnvResolver: repoEnvResolver)
        let result = await changer.swap(sessionId: uuid, newEffort: .some(req.effort))
        guard isSuccessfulSwap(result) else {
            sendResponse(.internalError, on: connection); return
        }
        let peer = Self.endpointString(connection.endpoint)
        await AuditLog.shared.recordEffortChange(
            sessionId: uuid, sourcePeer: peer,
            model: session.model, effort: req.effort.rawValue
        )
        await respondWithSession(
            uuid: uuid,
            idempotencyKey: req.idempotencyKey,
            kind: .changeEffort,
            payloadHash: payloadHash,
            connection: connection
        )
    }

    private func handleChangeMode(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(ChangeModeRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        if req.mode == .cloud {
            sendResponse(.badRequest, on: connection); return
        }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        let changer = SessionConfigChanger(registry: registry, tmux: tmux, repoEnvResolver: repoEnvResolver)
        let result = await changer.swap(
            sessionId: uuid,
            newPlanMode: req.planMode,
            newMode: req.mode
        )
        guard isSuccessfulSwap(result) else {
            sendResponse(.internalError, on: connection); return
        }
        let peer = Self.endpointString(connection.endpoint)
        await AuditLog.shared.recordModeChange(
            sessionId: uuid, sourcePeer: peer,
            mode: req.mode.rawValue, planMode: req.planMode
        )
        await respondWithSession(
            uuid: uuid,
            idempotencyKey: req.idempotencyKey,
            kind: .changeMode,
            payloadHash: payloadHash,
            connection: connection
        )
    }

    /// v25: respawn a degraded session whose tmux pane died. Same rate-limit
    /// + idempotency contract as the other config-swap commands so a retried
    /// or double-tapped revive can't double-spawn the agent.
    private func handleRevive(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection); return
        }
        // Body is optional: an empty POST (no idempotency key) is valid.
        let req = (try? JSONDecoder().decode(ReviveRequest.self, from: request.body)) ?? ReviveRequest()
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        let changer = SessionConfigChanger(registry: registry, tmux: tmux, repoEnvResolver: repoEnvResolver)
        let result = await changer.revive(sessionId: uuid)
        guard isSuccessfulSwap(result) else {
            sendResponse(.internalError, on: connection); return
        }
        let peer = Self.endpointString(connection.endpoint)
        await AuditLog.shared.recordSwap(
            sessionId: uuid, sourcePeer: peer,
            from: nil, to: "(revive)", effort: nil
        )
        await respondWithSession(
            uuid: uuid,
            idempotencyKey: req.idempotencyKey,
            kind: .revive,
            payloadHash: payloadHash,
            connection: connection
        )
    }

    // MARK: - Track A: Claude PTY host helpers

    /// Flag reader. When false (default), Claude routes to tmux exactly as
    /// before — the whole PTY path is dormant and there is zero behavior change.
    var claudePtyEnabled: Bool {
        UserDefaults.standard.bool(forKey: "clawdmeter.claude.ptyHost.enabled")
    }

    /// Build the routing context for a session, including the PTY flag. Single
    /// place so every handler resolves the same way.
    func routeContext(for session: AgentSession) -> SessionCommandRouter.SessionContext {
        SessionCommandRouter.SessionContext(
            agent: session.agent,
            kind: session.kind,
            codexChatBackend: session.codexChatBackend,
            runtimeIsACPDriven: session.runtimeBinding?.runtimeKind.isACPDriven == true,
            hasLiveBridge: harnessRegistry.bridge(for: session.id) != nil,
            claudePtyEnabled: claudePtyEnabled,
            // A session that already owns a tmux pane keeps using it even if the
            // PTY flag flips on mid-session — prevents a 2nd `claude` spawn.
            hasTmuxPane: session.tmuxPaneId != nil || session.tmuxWindowId != nil
        )
    }

    func commandRoute(for session: AgentSession) -> (
        context: SessionCommandRouter.SessionContext,
        route: SessionCommandRoute
    ) {
        let context = routeContext(for: session)
        return (context, SessionCommandRouter.resolve(context))
    }

    /// argv + cwd + env for a Claude PTY spawn. Mirrors the tmux spawn paths'
    /// `AgentSpawner.argv(for:)` so the PTY child is launched identically — and
    /// crucially carries the SAME env a tmux pane gets: the enriched login PATH
    /// (launchd's GUI PATH is thin → node/rg/hooks vanish) plus the managed repo
    /// env. Sanitized last so the subscription-billing rail still holds.
    func claudeSpawnPlan(for session: AgentSession) -> ClaudePtyRegistry.SpawnPlan? {
        let argv = AgentSpawner.argv(for: session)
        guard !argv.isEmpty else { return nil }
        let cwd = session.effectiveCwd
        // Managed repo env (.env.local + repo env set), best-effort — conflicts
        // are surfaced separately by the create path before we reach spawn.
        let repoEnv = (try? resolveRepoEnv(session: session, cwd: cwd))?.environment
        let env = AgentSpawner.claudePtyEnv(extra: repoEnv)
        return ClaudePtyRegistry.SpawnPlan(argv: argv, cwd: cwd, env: env)
    }

    /// Wire the registry's unexpected-exit callback once: a crashed Claude
    /// child marks its session `.degraded` (offers Resume) instead of looking
    /// frozen-but-running. Replaces TmuxSupervisor's role per session.
    private func ensureClaudePtyWiring() async {
        guard !claudePtyExitWired else { return }
        claudePtyExitWired = true
        await claudePtyRegistry.setOnUnexpectedExit { [weak self] sid, _ in
            Task { @MainActor in try? await self?.registry.updateStatus(id: sid, status: .degraded) }
        }
    }

    /// Resolve (or single-flight spawn/resume) the PTY host for a Claude
    /// session. Returns nil if no spawn plan (claude not on PATH).
    func claudePtyHost(for session: AgentSession) async -> ClaudePtyHost? {
        await ensureClaudePtyWiring()
        let plan = claudeSpawnPlan(for: session)
        let sid = session.id
        return try? await claudePtyRegistry.resumeOrSpawn(id: sid, plan: { plan })
    }

    /// Best-effort: extract the Claude CLI session id from the session's JSONL
    /// and persist it for `--resume`. Re-run per turn because Claude ROTATES the
    /// id after some operations (T7) — a spawn-time-only capture goes stale.
    /// Off the hot path (short delay lets the turn's JSONL line land).
    func captureClaudeSessionId(for session: AgentSession) {
        let sid = session.id
        let resolver = chatFileResolver
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let url = resolver.resolve(session: session),
                  let cli = JSONLSessionId.extract(from: url, provider: .claude),
                  !cli.isEmpty else { return }
            try? await self?.registry.setClaudeSessionId(id: sid, value: cli)
        }
    }

    /// T6: port the tmux trust-folder warmup to the PTY. Claude's first run in
    /// an untrusted directory shows a "trust this folder?" dialog that swallows
    /// the first keystroke — the tmux path scrapes capture-pane + sends
    /// Down/Up/Enter. The PTY equivalent polls `recentOutput()` (ANSI-stripped)
    /// and writes the same keys as bytes (Down=ESC[B, Up=ESC[A, Enter=CR). chat
    /// sessions are pre-trusted (markTrustedForClaude) so this is only needed for
    /// code sessions in new worktrees. Best-effort, bounded, runs in background.
    func warmupClaudePtyHost(_ host: ClaudePtyHost) {
        Task {
            func isTrustPrompt(_ s: String) -> Bool {
                s.contains("Quick safety check")
                    || s.range(of: "trust this folder", options: .caseInsensitive) != nil
                    || s.range(of: "Is this a project you created", options: .caseInsensitive) != nil
                    || s.contains("Do you trust")
            }
            for _ in 0..<40 {   // ~12s
                if isTrustPrompt(await host.recentOutput()) {
                    // Down, Up, Enter — mirrors the tmux send-keys sequence.
                    await host.writeBytes(Data([0x1b, 0x5b, 0x42, 0x1b, 0x5b, 0x41, 0x0d]))
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func handleSendPrompt(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(SendPromptRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        // v16 outbox: short-circuit duplicate retries before any side
        // effect. If we've already processed this idempotency key, replay
        // the cached response. The caller (iOS outbox) will mark the
        // outbox entry as `.acknowledged` and stop retrying.
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        let bytes = Array(req.text.utf8)
        guard !bytes.isEmpty, bytes.count <= 1_000_000 else {
            sendResponse(.badRequest, on: connection); return
        }
        // Phase 1: resolve the owning backend ONCE via SessionCommandRouter
        // (the tested single source of truth for the precedence below). Each
        // branch now checks its route instead of re-deriving the predicate;
        // the branch ORDER + bodies are unchanged — rate-limit still sits
        // between the agentapi branch and the rest, exactly as before.
        let routeResolution = commandRoute(for: session)
        let routeCtx = routeResolution.context
        let route = routeResolution.route
        guard RateLimiter.shared.tryAcquireSend(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSend, on: connection); return
        }
        // Track A: Claude over a per-session PTY (flag on). Resume-or-spawn the
        // host (single-flight) and submit; no tmux pane involved.
        if route == .claudePty {
            guard let host = await claudePtyHost(for: session) else {
                sendResponse(HTTPResponse(
                    status: 503, reason: "Service Unavailable",
                    contentType: "application/json",
                    body: Data(#"{"error":"agent_cli_not_found"}"#.utf8)
                ), on: connection)
                return
            }
            await host.submitPrompt(req.text, isChat: session.kind == .chat, isFollowUp: req.asFollowUp)
            captureClaudeSessionId(for: session)   // re-capture the (possibly rotated) CLI id
            let peer = Self.endpointString(connection.endpoint)
            await AuditLog.shared.recordSend(sessionId: uuid, sourcePeer: peer, text: req.text)
            await sendCommandResponse(
                body: ["ok": true], key: req.idempotencyKey, kind: .send,
                sessionId: uuid, payloadHash: payloadHash, on: connection
            )
            return
        }
        // v0.23.2 P1-04: OpenCode send. Wires the iOS / Mac composer's
        // POST /sessions/:id/send to opencode's `POST /session/<id>/message`.
        // The reply streams back asynchronously via the SSE `message.added`
        // events that OpencodeSSEAdapter routes into the session's
        // SessionChatStore — clients reading the chat-subscribe WS see
        // the assistant turn appear without an additional poll.
        if route == .opencodeServe {
            await sendOpencodePrompt(
                session: session,
                prompt: req.text,
                idempotencyKey: req.idempotencyKey,
                payloadHash: payloadHash,
                connection: connection
            )
            return
        }
        // ACP harness send (Grok, Cursor): drive the live `AcpHarnessBridge`.
        // The reply streams back into the session's SessionChatStore as the
        // driver emits HarnessEvents — clients on chat-subscribe see the turn
        // appear with no extra poll, like the opencode/agentapi paths. Keyed
        // off the bridge registry so legacy tmux sessions (no bridge) fall
        // through to the tmux path below.
        if route == .harnessBridge, let bridge = harnessRegistry.bridge(for: uuid) {
            await bridge.prompt(req.text)
            let peer = Self.endpointString(connection.endpoint)
            await AuditLog.shared.recordSend(sessionId: uuid, sourcePeer: peer, text: req.text)
            await sendCommandResponse(
                body: ["ok": true],
                key: req.idempotencyKey,
                kind: .send,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
            return
        }
        // An ACP session whose bridge died (daemon restart) has no tmux pane —
        // return an explicit 503 ("paste succeeded" ≠ "provider accepted")
        // instead of falling into the tmux-guard 500. Revive is Phase-1.
        if SessionCommandRouter.acpExpectedButNoBridge(routeCtx) {
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"acp_session_not_live","cta":"Start a new session"}"#.utf8)
            ), on: connection)
            return
        }
        guard let paneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            sendResponse(.internalError, on: connection); return
        }
        // v0.8 QA: chat-mode CLI sessions don't need the user-prompt echo
        // anymore — the rollout JSONL (Codex) / project JSONL (Claude)
        // contains the user turn directly, so JSONLTail picks it up and
        // appends to the store within ~1s. Echoing here AND parsing the
        // JSONL caused the user bubble to render twice on multi-turn
        // (two different message IDs → seen-IDs dedup missed both).
        // We DO still rename the session (D1 first-prompt-becomes-title)
        // and the snapshot's update-counter bumps via the JSONL parse.
        if session.kind == .chat {
            if (session.customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                let trimmed = req.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let cap = 40
                    let truncated = trimmed.count <= cap
                        ? trimmed
                        : String(trimmed[..<trimmed.index(trimmed.startIndex, offsetBy: cap - 1)]) + "…"
                    try? await registry.rename(id: session.id, name: truncated)
                }
            }
        }
        // v0.8 QA: for CLI sessions (code or chat), wait for the warmup
        // task (trust prompt + update prompt dismissal) to finish before
        // pasting the user's first prompt. Without this barrier, sends
        // arriving within ~3s of session creation race the dismissal —
        // bytes land in the wrong screen and either trigger options
        // (1/2/3) or are dropped.
        if let warmupTask = chatWarmupTasks[uuid],
           !(session.kind == .chat && session.agent == .claude) {
            await warmupTask.value
        }
        do {
            let data = Data(bytes)
            var sentChatEnterViaFreshClient = false
            // v0.8 QA: for chat-mode CLI sessions, clear the input line
            // before pasting so multi-turn prompts don't concatenate with
            // leftover text in the input box. C-u is a no-op when the
            // input is empty, so the first prompt isn't affected.
            if session.kind == .chat {
                try await tmux.command(["send-keys", "-t", paneId, "C-u"])
            }
            // v0.8 QA: Codex chat needs pasteBytes; its TUI input can drop
            // key bursts. Claude chat is the opposite on current CLI builds:
            // paste-buffer and hex-literal sends can be ignored by the
            // remote-control composer, while normal fresh-client send-keys
            // fills the prompt. Keep the provider split explicit instead of
            // using one "chat CLI" path for both TUIs.
            if session.kind == .chat
                && session.agent == .claude
                && bytes.count <= 4096
                && !req.text.contains("\n") {
                try await tmux.sendTextUsingFreshClient(paneId: paneId, text: req.text)
                try await submitClaudeChatPromptWhenReady(paneId: paneId, text: req.text, sessionId: session.id)
                Task { [weak self] in
                    await self?.dismissClaudeChatMCPPromptIfNeeded(paneId: paneId, sessionId: session.id)
                }
                sentChatEnterViaFreshClient = true
            } else if session.kind == .chat
                || req.asFollowUp
                || bytes.count > 256
                || req.text.contains("\n") {
                try await tmux.pasteBytes(paneId: paneId, bytes: data)
            } else {
                try await tmux.sendKeys(paneId: paneId, bytes: data)
            }
            // v0.8 QA: chat-mode CLI prompts need a trailing Enter so the
            // CLI's input box actually submits. The Enter key event must
            // be sent as a key name ("Enter" / "C-m") rather than a
            // literal CR byte — TUI apps differentiate between the two
            // (literal CR is text input, key Enter is a submit event).
            // Brief delay before Enter lets the CLI's input widget
            // settle after the paste — without it, Codex CLI's input
            // sometimes sees the Enter before its render loop has
            // committed the pasted text, dropping the submit on the floor.
            if session.kind == .chat && !sentChatEnterViaFreshClient {
                try? await Task.sleep(nanoseconds: 300_000_000)
                try await tmux.command(["send-keys", "-t", paneId, "Enter"])
            }
            let peer = Self.endpointString(connection.endpoint)
            await AuditLog.shared.recordSend(sessionId: uuid, sourcePeer: peer, text: req.text)
            await sendCommandResponse(
                body: ["ok": true],
                key: req.idempotencyKey,
                kind: .send,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
        } catch {
            serverLogger.error("send-prompt failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    /// `POST /sessions/continue-readonly` — server-side equivalent of the
    /// Mac UI's `SessionsModel.continueCurrentReadOnly`. Lets iOS promote
    /// a Recent JSONL row into a live Clawdmeter session without having
    /// to round-trip through the Mac UI.
    ///
    /// Flow: parse JSONL header for the CLI session id → spawn a fresh
    /// tmux pane with `--resume`/`resume` argv → register the new session
    /// → optionally paste the user's first prompt once the pane is ready.
    /// JSONL wiring picks up the existing JSONL automatically because
    /// `--resume` appends to the same file (it's the newest in the dir).
    private func handleContinueReadOnly(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(ContinueReadOnlyRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        // P1-Mac-7: defensively validate the repoKey before it flows into
        // `tmux.newWindow(cwd:)`. P1-Mac-6 already rejects CR/LF/control
        // bytes inside the tmux client, but a compromised paired client
        // could still ask the daemon to spawn an agent in `..`-traversed
        // paths or paths outside the user's home. Refuse any repoKey that
        // isn't an absolute, traversal-free path that resolves under the
        // user's home directory.
        guard Self.isValidRepoKey(req.repoKey) else {
            sendResponse(HTTPResponse(
                status: 400, reason: "Bad Request",
                contentType: "application/json",
                body: Data(#"{"error":"invalid_repo_key"}"#.utf8)
            ), on: connection)
            serverLogger.warning("continue-readonly: rejected repoKey \(req.repoKey, privacy: .public)")
            return
        }
        // Codex follow-up: also validate jsonlPath. The earlier patch
        // only checked repoKey; a paired compromised client could send
        // a valid repoKey together with an arbitrary local JSONL path
        // and have its session id extracted under that repo. Restrict
        // jsonlPath to ~/.claude/projects/, ~/.codex/sessions/,
        // ~/.codex/projects/, or ~/.gemini/.
        guard Self.isValidJsonlPath(req.jsonlPath) else {
            sendResponse(HTTPResponse(
                status: 400, reason: "Bad Request",
                contentType: "application/json",
                body: Data(#"{"error":"invalid_jsonl_path"}"#.utf8)
            ), on: connection)
            serverLogger.warning("continue-readonly: rejected jsonlPath \(req.jsonlPath, privacy: .public)")
            return
        }
        let jsonlURL = URL(fileURLWithPath: req.jsonlPath)
        guard FileManager.default.fileExists(atPath: req.jsonlPath) else {
            let body = #"{"error":"jsonl_not_found","path":"\#(req.jsonlPath)"}"#
            sendResponse(.notFound, on: connection)
            serverLogger.warning("continue-readonly: jsonl missing at \(req.jsonlPath, privacy: .public)")
            _ = body
            return
        }
        let provider: JSONLSessionId.Provider = (req.agent == .codex) ? .codex : .claude
        guard let cliSessionId = JSONLSessionId.extract(from: jsonlURL, provider: provider) else {
            let body = #"{"error":"no_session_id_in_jsonl"}"#
            sendResponse(HTTPResponse(
                status: 422, reason: "Unprocessable Entity",
                contentType: "application/json", body: Data(body.utf8)
            ), on: connection)
            return
        }

        // Build resume argv. New continued sessions inherit Claude Code
        // defaults (Opus 4.7 1M + Max) to match the Mac promote path.
        let defaults = ComposerStore.ChipDefaults.default
        let modelDefault: String? = (req.agent == .claude)
            ? defaults.modelId
            : ModelCatalog.bundled.codex.first?.id
        let argv: [String]
        switch req.agent {
        case .claude:
            argv = AgentSpawner.claudeArgv(
                model: modelDefault,
                planMode: false,
                effort: defaults.effort,
                autopilot: false,
                resumeSessionId: cliSessionId
            ) ?? []
        case .codex:
            // v27: codex is harness-driven; external "Continue here" resume is
            // deprioritized — no tmux resume argv. Empty → the missing-binary
            // surface returns a clean 4xx (start a fresh harness session instead).
            argv = []
        case .gemini:
            // No interactive Gemini CLI yet — fall through to the
            // missing-binary surface so the request returns a 4xx
            // instead of silently spawning an empty process.
            argv = []
        case .opencode:
            // PR #29: OpenCode sessions don't spawn through tmux argv;
            // they're SSE clients of the shared `opencode serve`
            // process. The handler routes opencode spawns to
            // OpencodeProcessManager + OpencodeSSEAdapter instead;
            // dropping into the 503 branch here is unreachable in
            // production but kept for exhaustiveness + safety.
            argv = []
        case .cursor:
            // Cursor imported-session resume needs a real Cursor chat id.
            // The current JSONL extractor only proves Claude/Codex ids, so
            // keep this conservative until the Cursor importer can prove one.
            argv = []
        case .grok:
            // ACP agent — driven via AcpAgentDriver, not a tmux argv. The
            // daemon ACP spawn path is not wired yet, so fall through to the
            // 503 (honest "not available" rather than an empty tmux spawn).
            argv = []
        case .unknown:
            // X3: forward-compat unknown agent — no argv builder. Fall
            // through to the 503 below so the iOS caller sees a clean
            // failure instead of an empty spawn.
            argv = []
        }
        guard !argv.isEmpty else {
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"agent_cli_not_found"}"#.utf8)
            ), on: connection)
            return
        }

        // Spawn into a new tmux window cwd'd to the repo. Local mode —
        // outside JSONLs don't carry a worktree.
        do {
            try await tmux.start()
            let resolvedEnv = try resolveRepoEnv(repoRoot: req.repoKey, cwd: req.repoKey)
            let window = try await tmux.newWindow(
                cwd: req.repoKey,
                child: argv,
                environment: resolvedEnv?.environment ?? [:]
            )
            let session = try await registry.create(
                repoKey: req.repoKey,
                repoDisplayName: (req.repoKey as NSString).lastPathComponent,
                agent: req.agent,
                model: modelDefault,
                goal: nil,
                worktreePath: nil,
                tmuxWindowId: window.windowId,
                tmuxPaneId: window.paneId,
                planMode: false,
                ownsWorktree: false,
                envSetId: resolvedEnv?.set?.id,
                envSetName: resolvedEnv?.set?.name
            )
            if req.agent == .claude {
                attachClaudeWiring(for: session, cwd: req.repoKey)
            }
            AgentEventStream.recordEvent(
                sessionId: session.id,
                kind: .sessionCreated,
                payload: [
                    "repo": req.repoKey,
                    "agent": req.agent.rawValue,
                    "resumed_from": req.jsonlPath
                ]
            )

            // If a prompt came along, paste it after the pane is ready.
            // Fire-and-forget so the HTTP response returns quickly with
            // the new session id; the client can also poll /sessions
            // for status.
            if let prompt = req.prompt, !prompt.isEmpty {
                let bytes = prompt.hasSuffix("\n")
                    ? Array(prompt.utf8)
                    : Array((prompt + "\n").utf8)
                Task { [tmux] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    try? await tmux.pasteBytes(paneId: window.paneId, bytes: Data(bytes))
                    await AuditLog.shared.recordSend(
                        sessionId: session.id,
                        sourcePeer: Self.endpointString(connection.endpoint),
                        text: prompt
                    )
                }
            }

            let response = ContinueReadOnlyResponse(sessionId: session.id)
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(response) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            if sendRepoEnvConflict(error, on: connection) { return }
            serverLogger.error("continue-readonly failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    /// `POST /sessions/:id/attachments?ext=png` — body is raw image
    /// bytes. Writes them to the session's staging dir via
    /// `AttachmentStaging.stage(data:ext:...)` and returns the absolute
    /// path. Lets iOS attach screenshots / photos from the camera roll
    /// without writing to its sandboxed app-support; the agent reads
    /// the resulting `@<path>` from the prompt body.
    ///
    /// Cap: 50MB (matches the Mac drag-drop cap). Auth + per-peer
    /// rate-limit + audit logging happen in the dispatcher before this
    /// handler is invoked.
    private func handleUploadAttachment(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let extArg: String = {
            guard let comps = URLComponents(string: request.path),
                  let raw = comps.queryItems?.first(where: { $0.name == "ext" })?.value,
                  !raw.isEmpty else { return "bin" }
            return raw
        }()
        // 50MB body cap. Bigger and we'd want a streaming multipart
        // path; for screenshots / photos this is plenty.
        guard request.body.count > 0, request.body.count <= 50 * 1024 * 1024 else {
            sendResponse(.badRequest, on: connection); return
        }
        guard let stagingDir = AttachmentStaging.stagingDir(for: session) else {
            sendResponse(.internalError, on: connection); return
        }
        let attachmentId = UUID()
        do {
            let staged = try AttachmentStaging.stage(
                data: request.body,
                ext: extArg,
                into: stagingDir,
                attachmentId: attachmentId
            )
            let response = UploadAttachmentResponse(id: attachmentId, path: staged.path)
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(response) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            serverLogger.error("attachment upload failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    /// v0.23 (Chat V2): full-history search across chat-session JSONLs.
    /// Walks `registry.sessions.filter { $0.kind == .chat }`, resolves
    /// each to its JSONL via `chatFileResolver`, and substring-scans
    /// the file's last 500 lines for the query. Bounded by 200ms hard
    /// timeout + 50-result cap so the V2 sidebar's search-as-you-type
    /// stays responsive even on machines with hundreds of chats.
    ///
    /// Why this exists: the in-memory `DaemonChatStoreRegistry` caps
    /// resident stores at 20 (iOS LRU-2). Searching ONLY the cache
    /// misses most history — Codex outside-voice review P1 #8 flagged
    /// the V2 sidebar's "Searchable" field as fake without daemon-side
    /// indexing. This endpoint is that indexing path.
    ///
    /// Match snippet: ≤120 chars, query centered with `…` on either
    /// side when truncated. We don't run a full text-rank algorithm
    /// here — order is `lastEventAt` descending so the most recent
    /// match leads. Future iterations can add term frequency / BM25;
    /// the wire shape accommodates it (`matches: [...]`, opaque order).
    private func handleChatSessionSearch(request: HTTPRequest, connection: NWConnection) async {
        guard let comps = URLComponents(string: request.path),
              let query = comps.queryItems?.first(where: { $0.name == "q" })?.value,
              !query.isEmpty else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let limit = min(
            Int(comps.queryItems?.first(where: { $0.name == "limit" })?.value ?? "") ?? 50,
            200
        )
        let normalized = query.lowercased()
        // Hard timeout — search-as-you-type can't block.
        let deadline = Date().addingTimeInterval(0.2)

        // Pull the chat-kind sessions ahead of any I/O so we don't hold
        // the registry actor across the scan.
        let chatSessions = registry.sessions
            .filter { $0.kind == .chat && $0.archivedAt == nil }
            .sorted { $0.lastEventAt > $1.lastEventAt }

        var matches: [ChatSessionSearchMatch] = []
        var truncated = false
        let resolver = chatFileResolver
        let fm = FileManager.default

        for session in chatSessions {
            if Date() >= deadline { truncated = true; break }
            if matches.count >= limit { truncated = true; break }
            guard let url = resolver.resolve(session: session) else { continue }
            guard fm.fileExists(atPath: url.path) else { continue }
            // Tail the last ~256KB so very-large JSONLs don't dominate
            // the timeout budget. JSONL is one-message-per-line, so
            // the last 256KB covers ~500 messages on the long tail.
            guard let snippet = findSnippet(in: url, lowercaseQuery: normalized, tailBytes: 256 * 1024) else {
                continue
            }
            let mtime: Date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? session.lastEventAt
            matches.append(ChatSessionSearchMatch(
                sessionId: session.id,
                frontierGroupId: session.frontierGroupId,
                jsonlPath: url.path,
                snippet: snippet,
                lastEventAt: mtime
            ))
        }

        let response = ChatSessionSearchResponse(matches: matches, truncated: truncated)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = (try? encoder.encode(response)) ?? Data("{\"matches\":[],\"truncated\":false}".utf8)
        sendResponse(HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: body), on: connection)
    }

    /// Read the tail of a JSONL file and look for `lowercaseQuery` (case-
    /// insensitive substring). Returns a ≤120-char snippet centered on
    /// the match, with `…` on either side when truncated. Nil when no
    /// match in the tail window.
    private func findSnippet(in url: URL, lowercaseQuery: String, tailBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Scan line-by-line; pick the first match line.
        for line in text.components(separatedBy: "\n") {
            let lowered = line.lowercased()
            guard let range = lowered.range(of: lowercaseQuery) else { continue }
            let matchOffset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            let radius = 60
            let startIdx = max(0, matchOffset - radius)
            let endIdx = min(line.count, matchOffset + lowercaseQuery.count + radius)
            let startStr = line.index(line.startIndex, offsetBy: startIdx)
            let endStr = line.index(line.startIndex, offsetBy: endIdx)
            var snippet = String(line[startStr..<endStr])
            if startIdx > 0 { snippet = "…" + snippet }
            if endIdx < line.count { snippet = snippet + "…" }
            // Strip JSON noise common in JSONL lines so the snippet
            // reads like prose rather than `","content":"..."`.
            snippet = snippet
                .replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: "\\\"", with: "\"")
            return snippet
        }
        return nil
    }

    private func handleInterrupt(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId) else {
            sendResponse(.notFound, on: connection); return
        }
        // v16 outbox: empty body is the legacy path (key=nil = no dedup).
        // Non-empty bodies decode as `InterruptRequest`; missing field
        // defaults to nil and the wrapper is a no-op.
        let req = (try? JSONDecoder().decode(InterruptRequest.self, from: request.body))
            ?? InterruptRequest(idempotencyKey: nil)
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        // ACP harness interrupt (Grok, Cursor): the SessionInterruptDispatcher
        // has no handle on the harness registry, so cancel the live bridge here
        // first. Keyed off the bridge registry (agent-agnostic); legacy tmux
        // sessions have no bridge and fall through to the dispatcher. Flip the
        // turn state up front (mirrors the dispatcher) so the V2 UI's Send
        // button restores immediately, then cancel the in-flight ACP turn.
        let session = registry.session(id: uuid)
        let route = session.map { commandRoute(for: $0).route }
        if route == .harnessBridge, let bridge = harnessRegistry.bridge(for: uuid) {
            if let session {
                chatStoreRegistry.snapshotStore(for: session)?.setCurrentTurnState(.interrupted)
            }
            await bridge.cancel()
            await sendCommandResponse(
                body: ["ok": true],
                key: req.idempotencyKey,
                kind: .interrupt,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
            return
        }
        // Track A: Claude PTY session — Stop = ESC written to the PTY (the raw
        // equivalent of the tmux ESC the dispatcher would send). The dispatcher
        // has no handle on the PTY registry, so we do it here (mirrors the
        // bridge branch above). A PTY session has no tmux pane, so the
        // dispatcher would otherwise return .notSupported.
        if let session, route == .claudePty {
            if let host = await claudePtyRegistry.host(for: uuid) {
                await host.writeBytes(Data([0x1b]))   // ESC
            }
            chatStoreRegistry.snapshotStore(for: session)?.setCurrentTurnState(.interrupted)
            await sendCommandResponse(
                body: ["ok": true], key: req.idempotencyKey, kind: .interrupt,
                sessionId: uuid, payloadHash: payloadHash, on: connection
            )
            return
        }
        // v0.23 (Chat V2 — audit P0 #2): route through
        // SessionInterruptDispatcher so Stop works for Codex SDK and
        // Gemini agentapi sessions too, not just tmux-backed ones.
        // The dispatcher flips currentTurnState to .interrupted up
        // front so the V2 UI's stopwatch + Send button restore
        // immediately, then dispatches the per-backend cancel.
        let dispatcher = SessionInterruptDispatcher(
            registry: registry,
            tmux: tmux,
            chatStoreRegistry: chatStoreRegistry
        )
        let result = await dispatcher.interrupt(sessionId: uuid)
        switch result {
        case .interrupted:
            await sendCommandResponse(
                body: ["ok": true],
                key: req.idempotencyKey,
                kind: .interrupt,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
        case .sessionNotFound:
            sendResponse(.notFound, on: connection)
        case .tmuxFailed:
            sendResponse(.internalError, on: connection)
        case .notSupported:
            sendJSON(["ok": false, "error": "notSupported"], on: connection, status: 501)
        }
    }

    /// v0.7.7: iPhone surface POSTs ask_user(...) decisions here. Body
    /// shape: `{"decision":"approve|deny", "source":"ios"}`. Returns:
    ///   - 200 `{outcome:"won", decision:"..."}` if first to decide.
    ///   - 409 `{outcome:"lost", prior:"approve|deny", priorSource:"mac|ios|timeout"}`
    ///     if another surface beat us. iOS UI renders "Already answered
    ///     on <surface>" + dismisses.
    ///   - 404 `{outcome:"unknown_prompt"}` if the UUID is GC'd or never
    ///     existed.
    private func handleSidecarAskDecide(promptUUID: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: promptUUID) else {
            sendResponse(.badRequest, on: connection); return
        }
        struct DecidePayload: Codable {
            let decision: String
            let source: String?
        }
        let body = request.body ?? Data()
        guard let payload = try? JSONDecoder().decode(DecidePayload.self, from: body),
              let decision = SidecarAskCoordinator.Decision(rawValue: payload.decision)
        else {
            sendResponse(.badRequest, on: connection); return
        }
        let source: SidecarAskCoordinator.Source = {
            if let s = payload.source, let parsed = SidecarAskCoordinator.Source(rawValue: s) {
                return parsed
            }
            return .ios  // default: only iPhone hits the HTTP route
        }()
        let result = await SidecarAskCoordinator.shared.decide(
            promptUUID: uuid,
            decision: decision,
            source: source
        )
        switch result {
        case .won(let d):
            sendJSON(["outcome": "won", "decision": d.rawValue], on: connection)
        case .lost(let prior, let priorSource):
            let payload: [String: Any] = [
                "outcome": "lost",
                "prior": prior.rawValue,
                "priorSource": priorSource.rawValue,
            ]
            let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            sendResponse(HTTPResponse(
                status: 409, reason: "Conflict",
                contentType: "application/json", body: body
            ), on: connection)
        case .unknownPrompt:
            let body = Data(#"{"outcome":"unknown_prompt"}"#.utf8)
            sendResponse(HTTPResponse(
                status: 404, reason: "Not Found",
                contentType: "application/json", body: body
            ), on: connection)
        }
    }

    private func handleSetAutopilot(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(AutopilotRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        // Autopilot crosses a real security boundary (per-repo trust list).
        // Throttle the toggle so a misbehaving client can't flap it.
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        // v0.8: autopilot is a code-session concept (requires a trusted
        // repo). Chat sessions don't run shell or write files so the
        // trust model doesn't apply — reject the toggle outright.
        guard session.kind == .code, let repoKey = session.repoKey else {
            sendResponse(.badRequest, on: connection); return
        }
        // E7 wire-level guard: enabling autopilot requires the repo to be on
        // the trust list. A peer with the bearer token can't bypass the UI
        // confirm-sheet by hitting this endpoint directly (review §3 finding
        // 2026-05-18). Disabling autopilot is always allowed (kill switch).
        if req.enabled, !AutopilotState.shared.isRepoTrusted(repoKey) {
            let peer = Self.endpointString(connection.endpoint)
            await AuditLog.shared.recordAutopilotToggle(
                sessionId: uuid, sourcePeer: peer,
                enabled: false, repoKey: repoKey
            )
            serverLogger.warning("autopilot enable rejected for untrusted repo \(repoKey, privacy: .public)")
            let body = #"{"error":"repo not trusted for autopilot","repoKey":"\#(repoKey)"}"#
            sendResponse(.forbidden(body: Data(body.utf8)), on: connection)
            return
        }
        AutopilotState.shared.setEnabled(req.enabled, sessionId: uuid)
        let peer = Self.endpointString(connection.endpoint)
        await AuditLog.shared.recordAutopilotToggle(
            sessionId: uuid, sourcePeer: peer,
            enabled: req.enabled, repoKey: repoKey
        )
        await respondWithSession(
            uuid: uuid,
            idempotencyKey: req.idempotencyKey,
            kind: .setAutopilot,
            payloadHash: payloadHash,
            connection: connection
        )
    }

    private func handlePickPairWinner(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(PickWinnerRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        let result: AgentSessionRegistry.PickPairResult?
        do {
            result = try await registry.pickPairWinner(sessionId: uuid, winner: req.winnerSessionId)
        } catch {
            sendResponse(.internalError, on: connection); return
        }
        guard let result else {
            sendResponse(.notFound, on: connection); return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch result {
        case .decided(let winner, let decidedAt):
            var body: [String: Any] = [
                "winnerSessionId": winner.uuidString,
                "decidedAt": ISO8601DateFormatter().string(from: decidedAt),
            ]
            if let key = req.idempotencyKey {
                let receipt = MobileCommandReceipt(idempotencyKey: key, status: .acknowledged, processedAt: Date())
                body["receipt"] = receipt.jsonDictionary
            }
            let bytes = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            await recordIdempotent(
                key: req.idempotencyKey, kind: .pickWinner,
                sessionId: uuid, connection: connection, payloadHash: payloadHash,
                responseBody: bytes, responseStatus: 200
            )
            sendResponse(.ok(contentType: "application/json", body: bytes), on: connection)
        case .alreadyDecided(let winner, let decidedAt):
            let payload = PickWinnerConflictResponse(winnerSessionId: winner, decidedAt: decidedAt)
            let body = (try? encoder.encode(payload)) ?? Data()
            // 409 stays uncached — a second client racing the same key
            // should still see the conflict. The pick-winner endpoint is
            // safe to replay with the same key because it's intentionally
            // idempotent at the registry layer.
            sendResponse(HTTPResponse(status: 409, reason: "Conflict",
                                      contentType: "application/json", body: body), on: connection)
        case .notPaired, .invalidWinner:
            sendResponse(.badRequest, on: connection)
        }
    }

    private func handleGetChatSnapshot(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        // Phase 0a: prefer the long-lived registry store. On cold misses
        // (first request after server boot or after idle eviction) the
        // store's reverse-tail hasn't ingested yet, so we fall back to
        // the legacy synchronous reparse to keep the first request fast.
        // Subsequent requests within the idle window read the warm
        // snapshot.
        let registryStore = chatStoreRegistry.snapshotStore(for: session)
        let snapshotItems: [ChatItem]
        let snapshotCounter: UInt64
        let snapshotLastEventAt: Date?
        // v0.8 QA: for chat-kind sessions, NEVER fall back to chatFileResolver —
        // its parent-walk fuzzy match surfaces unrelated Codex/Claude JSONLs
        // (e.g. a fresh chat session shows transcripts from someone's old
        // debugging session). The registry's sdkOnly store is the single
        // source of truth; CodexSDKEventIngestor populates it via appendSDKMessages.
        // Code sessions keep the cold-fallback path so JSONL tail catches up.
        if session.kind == .chat {
            snapshotItems = registryStore?.snapshot.items ?? []
            snapshotCounter = registryStore?.snapshot.updateCounter ?? 0
            snapshotLastEventAt = registryStore?.snapshot.lastEventAt ?? session.lastEventAt
        } else if let store = registryStore, !store.snapshot.items.isEmpty {
            snapshotItems = store.snapshot.items
            // Phase 0a / Codex P0: this is the real chat cursor now.
            // Pre-v5, this field was populated from session.lastEventSeq
            // (registry/status counter); the transcript cursor lives on
            // SessionChatStore.updateCounter and only bumps on actual
            // chat-state changes. iOS uses this for delta detection.
            snapshotCounter = store.snapshot.updateCounter
            snapshotLastEventAt = store.snapshot.lastEventAt ?? session.lastEventAt
        } else {
            // Cold-store fallback: legacy synchronous reparse path. The
            // background store will catch up; the next request gets the
            // warm snapshot. Phase 0b: URL resolution goes through the
            // shared `SessionFileResolver` so Codex respawn lineage is
            // honored even in the cold path.
            let url = chatFileResolver.resolve(session: session)
            let messages = url.map { TranscriptLoader.load(from: $0, maxMessages: 200) } ?? []
            var builder = ChatItemBuilder()
            for message in messages {
                builder.ingest(message)
            }
            builder.flushPending()
            snapshotItems = builder.items
            // Even on cold fallback, prefer the registry's (still-warming)
            // counter when available; only fall through to session.lastEventSeq
            // when the resolver returned nil (no live store).
            snapshotCounter = registryStore?.snapshot.updateCounter ?? session.lastEventSeq
            snapshotLastEventAt = session.lastEventAt
        }
        let warmSnapshot = registryStore?.snapshot
        let snapshot = WireChatSnapshot(
            sessionId: session.id,
            items: snapshotItems,
            planSteps: warmSnapshot?.planSteps ?? [],
            sourceEntries: warmSnapshot?.sourceEntries ?? [],
            artifactEntries: warmSnapshot?.artifactEntries ?? [],
            // v0.7.8: forward Codex SDK todos when the warm store has them.
            // Cold fallback keeps empty — codex todos only land via SDK
            // events, which the store accumulates while live.
            codexTodos: warmSnapshot?.codexTodos ?? [],
            // v0.8 QA: forward any pending CLI permission prompt so iOS
            // (or HTTP-polling clients) can render the AskUserQuestion-
            // style card too. Mac UI reads the @Published property
            // directly on SessionChatStore.
            pendingPermissionPrompt: registryStore?.pendingPermissionPrompt,
            totalInputTokens: warmSnapshot?.totalInputTokens ?? 0,
            totalOutputTokens: warmSnapshot?.totalOutputTokens ?? 0,
            cacheReadTokens: warmSnapshot?.totalCacheReadTokens ?? 0,
            cacheCreationTokens: warmSnapshot?.totalCacheCreationTokens ?? 0,
            lastEventAt: snapshotLastEventAt,
            updateCounter: snapshotCounter,
            // v14: surface the store's lifecycle so V2 clients can drive
            // the Stop↔Send button + stopwatch clamp without polling
            // for "last item arrived in last N seconds" heuristics.
            // `.idle` fallback when there's no registry store (cold path).
            currentTurnState: warmSnapshot?.currentTurnState ?? .idle
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(snapshot) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleGetPreflight(request: HTTPRequest, connection: NWConnection) async {
        guard let comps = URLComponents(string: request.path),
              let items = comps.queryItems else {
            sendResponse(.badRequest, on: connection); return
        }
        func qp(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let repoKey = qp("repoKey"),
              let agentRaw = qp("agent"), let agent = AgentKind(rawValue: agentRaw),
              let model = qp("model") else {
            sendResponse(.badRequest, on: connection); return
        }
        let effort: ReasoningEffort? = qp("effort").flatMap { ReasoningEffort(rawValue: $0) }
        let goalLength = Int(qp("goalLength") ?? "0") ?? 0

        // Cost estimate from the analytics snapshot.
        let snapshot = usageHistory?.snapshot ?? UsageHistorySnapshot.empty
        let estimatedCost = LiveCostCalculator.shared.estimate(
            snapshot: snapshot,
            repoKey: repoKey,
            agent: agent,
            model: model,
            effort: effort,
            goalLength: goalLength
        )

        // Weekly-cap projection from live usage. Pick the provider's
        // poller matching the requested agent.
        let liveUsage: UsageData? = (agent == .claude)
            ? claudeModel?.usage
            : codexModel?.usage
        let currentWeeklyPct = liveUsage?.weeklyPct ?? 0

        // Reverse the per-model cost back to a token estimate so the
        // projection has the right units. Falls back to a conservative
        // 50k tokens when pricing is unknown (unpriced model).
        let estimatedTokens: Int = {
            guard let dollars = estimatedCost, dollars > 0 else { return 50_000 }
            let perTokenInput = Pricing.shared.cost(
                for: model,
                tokens: TokenTotals(inputTokens: 1, outputTokens: 0)
            )
            if perTokenInput > 0 {
                let perTokenDouble = NSDecimalNumber(decimal: perTokenInput).doubleValue
                return max(1, Int(dollars / perTokenDouble))
            }
            return 50_000
        }()
        let projected = RateLimitChecker.shared.projectedWeeklyCap(
            currentWeeklyPct: currentWeeklyPct,
            estimatedTokens: estimatedTokens
        )
        let wouldCap = projected >= 0.95  // D11 soft-warn threshold
        let suggested = wouldCap
            ? RateLimitChecker.shared.suggestedSwap(currentModel: model)
            : nil

        let staleData: Bool = {
            let age = Date().timeIntervalSince(snapshot.computedAt)
            return age > 3600
        }()

        let response = PreflightResponse(
            estimatedCostUSD: estimatedCost,
            weeklyCapPct: liveUsage == nil ? nil : projected,
            wouldCap: wouldCap,
            suggestedSwap: suggested,
            staleData: staleData
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(response) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    // MARK: - PR #30: OpenCode session dispatch (wire v13)

    /// Spawn an OpenCode-backed AgentSession. Diverges from the
    /// tmux argv path because opencode sessions are SSE clients of the
    /// shared `opencode serve` process (P1 singleton). Flow:
    ///   1. Ensure `opencode serve` is running (boots on first request).
    ///   2. POST to the server's `/session` endpoint to mint an
    ///      opencode session id.
    ///   3. Register the (clawdmeterID ↔ opencodeID) mapping in
    ///      OpencodeSSEAdapter so subsequent message.added events
    ///      route to the right Clawdmeter session.
    ///   4. Create a placeholder AgentSession in the registry so the
    ///      session shows up in the iOS Code tab + Mac sidebar.
    ///   5. Return the AgentSession JSON.
    ///
    /// Failure surfaces:
    ///   - opencode binary not installed → 503 with install hint.
    ///   - opencode serve spawn failed → 503 with detail.
    ///   - /session POST failed → 502.
    private func handleSpawnOpencodeSession(
        req: NewSessionRequest,
        connection: NWConnection,
        worktreePath: String?,
        provisioning: WorktreeProvisioningMetadata?,
        provisionalSessionId: UUID?
    ) async {
        // Step 1: ensure the singleton server is running.
        guard let _ = await OpencodeProcessManager.shared.ensureRunning() else {
            let state = OpencodeProcessManager.shared.state
            let body: String
            switch state {
            case .notInstalled:
                body = #"{"error":"opencode_not_installed","hint":"run: brew install opencode"}"#
            case .failed(let detail):
                body = #"{"error":"opencode_serve_failed","detail":"\#(detail)"}"#
            default:
                body = #"{"error":"opencode_not_running"}"#
            }
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json", body: Data(body.utf8)
            ), on: connection)
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId,
                context: "opencode serve preflight"
            )
            return
        }

        // Make sure the SSE adapter is consuming events. start() is
        // idempotent — safe to call on every spawn even if already
        // running.
        OpencodeSSEAdapter.shared.start()

        // v0.23.2: wire the chat-store accessor so message.added
        // events route into the per-session SessionChatStore. Idempotent
        // — re-setting on every spawn is cheap and resists the rare
        // race where the adapter restarted (e.g. after opencode serve
        // crashed) and lost the closure. Weak capture on self keeps
        // the closure from pinning AgentControlServer.
        if OpencodeSSEAdapter.shared.chatStoreAccessor == nil {
            let registry = self.registry
            let chatStoreRegistry = self.chatStoreRegistry
            OpencodeSSEAdapter.shared.chatStoreAccessor = { [weak registry, weak chatStoreRegistry] uuid in
                guard let registry, let chatStoreRegistry else { return nil }
                guard let session = registry.session(id: uuid) else { return nil }
                return chatStoreRegistry.acquire(for: session)
            }
        }

        // Step 2: mint an opencode session id via the server's
        // `/session` POST. Body is minimal — title is optional but
        // surfaces in the OpenCode TUI's session list (which the
        // user can still drive from a terminal if they want).
        let opencodeDirectory = worktreePath ?? req.repoKey
        let resolvedEnv: RepoEnvResolvedEnvironment?
        do {
            resolvedEnv = try resolveRepoEnv(repoRoot: req.repoKey, cwd: opencodeDirectory)
        } catch {
            if sendRepoEnvConflict(error, on: connection) {
                await cleanupUnregisteredWorktree(
                    repoRoot: req.repoKey,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    provisionalSessionId: provisionalSessionId,
                    context: "opencode repo env conflict"
                )
                return
            }
            sendResponse(.internalError, on: connection)
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId,
                context: "opencode repo env resolve"
            )
            return
        }
        guard var sessionReq = OpencodeProcessManager.shared.makeAuthorizedRequest(
            path: "/session",
            directory: opencodeDirectory
        ) else {
            sendResponse(.internalError, on: connection)
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId,
                context: "opencode request authorization"
            )
            return
        }
        sessionReq.httpMethod = "POST"
        sessionReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let titleSource = req.goal?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? req.goal!
            : (req.repoKey as NSString).lastPathComponent
        let postBody: [String: Any] = ["title": String(titleSource.prefix(60))]
        sessionReq.httpBody = try? JSONSerialization.data(withJSONObject: postBody)

        let opencodeID: String
        do {
            let session = URLSession(configuration: .ephemeral)
            let (data, resp) = try await session.data(for: sessionReq)
            guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                serverLogger.error("opencode /session POST returned \(status, privacy: .public)")
                sendResponse(.internalError, on: connection)
                await cleanupUnregisteredWorktree(
                    repoRoot: req.repoKey,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    provisionalSessionId: provisionalSessionId,
                    context: "opencode session POST status"
                )
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String else {
                serverLogger.error("opencode /session POST returned malformed body")
                sendResponse(.internalError, on: connection)
                await cleanupUnregisteredWorktree(
                    repoRoot: req.repoKey,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    provisionalSessionId: provisionalSessionId,
                    context: "opencode session POST body"
                )
                return
            }
            opencodeID = id
        } catch {
            serverLogger.error("opencode /session POST failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId,
                context: "opencode session POST failure"
            )
            return
        }

        // Step 3: create the Clawdmeter-side AgentSession + register
        // the bidirectional id mapping. opencode sessions don't carry
        // a tmux pane, but every OpenCode HTTP call is scoped with the
        // same directory so code-mode sessions operate in the prepared cwd.
        let session: AgentSession
        do {
            session = try await registry.create(
                repoKey: req.repoKey,
                repoDisplayName: (req.repoKey as NSString).lastPathComponent,
                agent: .opencode,
                model: req.model,
                goal: req.goal,
                worktreePath: worktreePath,
                provisioning: provisioning,
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                planMode: false,  // opencode handles plan/approval internally
                mode: worktreePath == nil ? .local : .worktree,
                effort: req.effort,
                ownsWorktree: worktreePath != nil,
                envSetId: resolvedEnv?.set?.id,
                envSetName: resolvedEnv?.set?.name,
                id: provisionalSessionId ?? UUID()
            )
        } catch {
            serverLogger.error("registry.create write-ahead failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId,
                context: "opencode registry create failure"
            )
            return
        }
        recordWorkspaceSession(repoRoot: req.repoKey, sessionId: session.id)
        // PR #32: stash repo too so opencode `usage` events tag
        // analytics records with the right cwd instead of "(unknown)".
        OpencodeSSEAdapter.shared.register(
            clawdmeterID: session.id, opencodeID: opencodeID, repo: opencodeDirectory
        )
        AgentEventStream.recordEvent(
            sessionId: session.id, kind: .sessionCreated,
            payload: [
                "repo": opencodeDirectory,
                "agent": "opencode",
                "opencodeID": opencodeID
            ]
        )

        // Step 4: return the session JSON.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(session) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// The single switch deciding which providers are driven over the native
    /// ACP harness (vs tmux / SDK / serve). Returns the agent's spawn+auth
    /// policy, or nil for non-ACP agents (Claude/Codex/Gemini/OpenCode).
    static func acpSupport(for agent: AgentKind) -> AcpAgentSupport? {
        switch agent {
        // Grok has NO ACP server in the shipping binary (cmux "Grok Build" is a
        // TUI + headless one-shot + MCP client). It drives via GrokHeadlessDriver,
        // not ACP. Cursor IS a real ACP agent (`cursor-agent acp`, verified live).
        case .cursor: return CursorAcpSupport()
        default: return nil
        }
    }

    /// v27 Code-tab harness migration: true when a live harness bridge is
    /// driving this session (paneless codex/cursor/gemini/grok). The Code-tab
    /// chat-store routing + first-send readiness use this to treat the session
    /// like the Chat tab's harness sessions instead of waiting on a tmux pane.
    func isHarnessLive(_ id: UUID) -> Bool { harnessRegistry.contains(id) }

    /// v27: tear down a session's harness bridge (stdio child / gRPC channel)
    /// and release the chat store it pinned. Idempotent (no-op when no bridge
    /// is registered). The Mac's `endSession` + the optimistic-"+" failure path
    /// call this so a harness child isn't leaked when the registry row is
    /// deleted in-process out-of-band (the full `handleDeleteSession` only runs
    /// for an explicit `DELETE /sessions/:id`). Mirrors that handler's harness
    /// branch (AgentControlServer.swift handleDeleteSession).
    func teardownHarnessSession(_ id: UUID) async {
        guard harnessRegistry.contains(id) else { return }
        await harnessRegistry.remove(id)
        chatStoreRegistry.release(sessionId: id)
    }

    /// Generic harness spawn (Grok/Cursor over ACP, Codex over app-server,
    /// Antigravity over gRPC). Mirrors `handleSpawnOpencodeSession`: no tmux pane
    /// — the daemon drives an `AgentDriver` via `AcpHarnessBridge` (built by
    /// `makeBridge`), projecting its event stream into the session's
    /// `SessionChatStore`. Two-phase failure contract (A3): `bridge.start()`
    /// throws synchronously on spawn/handshake/auth failure, so a failed start
    /// tears the write-ahead session back down and returns a real HTTP error.
    /// `binary`/`arguments` are the stdio launch (nil/[] for gRPC drivers).
    private func handleSpawnHarnessSession(
        req: NewSessionRequest,
        displayName: String,
        binary: String?,
        arguments: [String],
        cwd: String,
        worktreePath: String?,
        provisioning: WorktreeProvisioningMetadata?,
        provisionalSessionId: UUID?,
        connection: NWConnection,
        makeBridge: (UUID, SessionChatStore) -> AcpHarnessBridge
    ) async {
        // Resolve the per-repo env set (same path as the tmux/opencode spawns).
        let resolvedEnv: RepoEnvResolvedEnvironment?
        do {
            resolvedEnv = try resolveRepoEnv(repoRoot: req.repoKey, cwd: cwd)
        } catch {
            if sendRepoEnvConflict(error, on: connection) {
                await cleanupUnregisteredWorktree(
                    repoRoot: req.repoKey, worktreePath: worktreePath,
                    provisioning: provisioning, provisionalSessionId: provisionalSessionId,
                    context: "acp repo env conflict")
                return
            }
            sendResponse(.internalError, on: connection)
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey, worktreePath: worktreePath,
                provisioning: provisioning, provisionalSessionId: provisionalSessionId,
                context: "acp repo env resolve")
            return
        }

        // The ACP child REPLACES its environment (Process.environment), so it
        // must carry the full inherited env (PATH/HOME — Grok and Cursor both
        // need them) plus the repo-env overrides layered on top.
        var childEnv = ProcessInfo.processInfo.environment
        for (k, v) in (resolvedEnv?.environment ?? [:]) { childEnv[k] = v }

        // Step 1: write-ahead the Clawdmeter session (no tmux pane). The
        // runtime kind is inferred as `.acpGrok` from `agent: .grok`.
        let session: AgentSession
        if let pre = provisionalSessionId, let existing = registry.session(id: pre) {
            // v27 optimistic "+": the Mac already created this provisional row up
            // front and drove the provisioning trail against it. `registry.create`
            // has no id-dedup (it appends), so ADOPT the row in place — attach the
            // worktree, clear plan/pane, mark running — rather than create a
            // duplicate. The live bridge registered in Step 4 is what drives it.
            // On failure the Mac owns the row + worktree cleanup (its createSession
            // call throws), so we don't tear them down here.
            do {
                try await registry.updateRuntime(
                    id: existing.id,
                    worktreePath: worktreePath,
                    runtimeCwd: cwd,
                    tmuxWindowId: nil,
                    tmuxPaneId: nil,
                    mode: worktreePath == nil ? .local : .worktree,
                    ownsWorktree: worktreePath != nil
                )
                try await registry.updateStatus(id: existing.id, status: .running)
            } catch {
                serverLogger.error("acp registry adopt failed: \(error.localizedDescription, privacy: .public)")
                sendResponse(.internalError, on: connection)
                return
            }
            session = registry.session(id: existing.id) ?? existing
        } else {
            do {
                session = try await registry.create(
                    repoKey: req.repoKey,
                    repoDisplayName: (req.repoKey as NSString).lastPathComponent,
                    agent: req.agent,
                    model: req.model,
                    goal: req.goal,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    tmuxWindowId: nil,
                    tmuxPaneId: nil,
                    planMode: false,  // ACP plan/approval flows through permission prompts, not the Codex synthetic-plan card
                    mode: worktreePath == nil ? .local : .worktree,
                    effort: req.effort,
                    ownsWorktree: worktreePath != nil,
                    envSetId: resolvedEnv?.set?.id,
                    envSetName: resolvedEnv?.set?.name,
                    id: provisionalSessionId ?? UUID()
                )
            } catch {
                serverLogger.error("acp registry.create write-ahead failed: \(error.localizedDescription, privacy: .public)")
                sendResponse(.internalError, on: connection)
                await cleanupUnregisteredWorktree(
                    repoRoot: req.repoKey, worktreePath: worktreePath,
                    provisioning: provisioning, provisionalSessionId: provisionalSessionId,
                    context: "acp registry create failure")
                return
            }
        }

        // Step 2: acquire the per-session chat store the bridge projects into.
        // `acquire` (not `snapshotStore`) because the bridge is a long-lived
        // writer — it must pin the store against idle eviction while driving.
        // Released on bridge teardown / session delete (lifecycle, Phase 1).
        guard let store = chatStoreRegistry.acquire(for: session) else {
            serverLogger.error("acp chat store acquire failed for \(session.id, privacy: .public)")
            try? await registry.delete(id: session.id)
            sendResponse(.internalError, on: connection)
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey, worktreePath: worktreePath,
                provisioning: provisioning, provisionalSessionId: provisionalSessionId,
                context: "acp chat store acquire")
            return
        }

        // Step 3: build + start the bridge. Model/effort selection is deferred
        // to a follow-up (Grok takes them launch-time, Cursor via
        // set_config_option) — v1 spawns with the agent's defaults until we map
        // `initialize.availableModels`; the bundled catalog ids are placeholders,
        // not real CLI models. alwaysApprove=false so the agent raises
        // permission prompts we surface (a harness, not a blind auto-runner).
        let bridge = makeBridge(session.id, store)
        do {
            try await bridge.start(
                binary: binary,
                arguments: arguments,
                cwd: cwd,
                env: childEnv,
                effort: nil,
                alwaysApprove: false
            )
        } catch {
            serverLogger.error("acp bridge.start failed: \(error.localizedDescription, privacy: .public)")
            await bridge.teardown()
            chatStoreRegistry.release(sessionId: session.id)
            try? await registry.delete(id: session.id)
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey, worktreePath: worktreePath,
                provisioning: provisioning, provisionalSessionId: provisionalSessionId,
                context: "acp bridge start")
            let payload = ["error": "acp_start_failed", "detail": String(describing: error)]
            let body = (try? JSONSerialization.data(withJSONObject: payload))
                ?? Data(#"{"error":"acp_start_failed"}"#.utf8)
            sendResponse(HTTPResponse(status: 503, reason: "Service Unavailable",
                                      contentType: "application/json", body: body), on: connection)
            return
        }

        // Step 4: register the live bridge, record the workspace + event, and
        // return the session JSON (same shape as every other spawn path).
        harnessRegistry.register(bridge, for: session.id)
        recordWorkspaceSession(repoRoot: req.repoKey, sessionId: session.id)
        AgentEventStream.recordEvent(
            sessionId: session.id, kind: .sessionCreated,
            payload: ["repo": cwd, "agent": req.agent.rawValue])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(session) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func respondWithSession(uuid: UUID, connection: NWConnection) async {
        guard let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(session) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// v16 outbox variant: serializes the session, inlines the receipt
    /// when present, caches the response bytes for replay. Used by
    /// change-model/effort/mode handlers that need to return the
    /// updated `AgentSession`.
    private func respondWithSession(
        uuid: UUID,
        idempotencyKey: String?,
        kind: MobileCommandKind,
        payloadHash: String,
        connection: NWConnection
    ) async {
        guard let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(session),
              var dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            sendResponse(.internalError, on: connection); return
        }
        if let key = idempotencyKey, !key.isEmpty {
            let receipt = MobileCommandReceipt(
                idempotencyKey: key,
                status: .acknowledged,
                processedAt: Date()
            )
            dict["receipt"] = receipt.jsonDictionary
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: dict) else {
            sendResponse(.internalError, on: connection); return
        }
        await recordIdempotent(
            key: idempotencyKey,
            kind: kind,
            sessionId: uuid,
            connection: connection,
            payloadHash: payloadHash,
            responseBody: bytes,
            responseStatus: 200
        )
        sendResponse(.ok(contentType: "application/json", body: bytes), on: connection)
    }

    private func isSuccessfulSwap(_ result: SessionConfigChanger.SwapResult) -> Bool {
        if case .swapped = result { return true }
        return false
    }

    private func handlePostSession(request: HTTPRequest, connection: NWConnection) async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let req = try? decoder.decode(NewSessionRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }

        // Audit P0 fix: validate `repoKey` BEFORE either dispatch path
        // — the OpenCode branch and the worktree/tmux branch both use
        // it as cwd / worktree-root / registry-state. Without this
        // guard, an authenticated paired client could POST a /tmp or
        // symlink-escaping path and the Mac would spawn the agent
        // rooted there. The sibling readonly-continuation handler
        // already validates against this same boundary.
        guard Self.isValidRepoKey(req.repoKey) else {
            sendResponse(
                .badRequest(detail: "repoKey rejects traversal/control bytes/symlinks/out-of-root"),
                on: connection
            )
            return
        }

        if let reason = providerDisabledReason(provider: req.agent) {
            sendProviderDisabled(provider: req.agent, reason: reason, on: connection)
            return
        }

        if req.agent == .cursor {
            guard !req.planMode else {
                sendResponse(HTTPResponse(
                    status: 400,
                    reason: "Bad Request",
                    contentType: "application/json",
                    body: Data(#"{"error":"cursor_plan_mode_not_supported","cta":"Start Cursor in code mode until Cursor resume ids are available."}"#.utf8)
                ), on: connection)
                return
            }
            let cursorState = await CursorModelProbe.shared.currentState()
            guard cursorState.binaryPath != nil else {
                sendResponse(HTTPResponse(
                    status: 503, reason: "Service Unavailable",
                    contentType: "application/json",
                    body: Data(#"{"error":"agent_cli_not_found"}"#.utf8)
                ), on: connection)
                return
            }
            guard cursorState.authenticated else {
                sendResponse(HTTPResponse(
                    status: 503, reason: "Service Unavailable",
                    contentType: "application/json",
                    body: Data(#"{"error":"cursor_not_authenticated","cta":"Run cursor-agent login, then try again."}"#.utf8)
                ), on: connection)
                return
            }
            if let model = req.model,
               !CursorModelCatalog.isAutoModel(model),
               !cursorState.models.contains(where: { $0.id == model || $0.cliAlias == model }) {
                sendResponse(.badRequest(detail: "Cursor model is not available for the authenticated account"), on: connection)
                return
            }
        }

        if req.agent == .opencode {
            guard let _ = await OpencodeProcessManager.shared.ensureRunning() else {
                let state = OpencodeProcessManager.shared.state
                let body: String
                switch state {
                case .notInstalled:
                    body = #"{"error":"opencode_not_installed","hint":"run: brew install opencode"}"#
                case .failed(let detail):
                    body = #"{"error":"opencode_serve_failed","detail":"\#(detail)"}"#
                default:
                    body = #"{"error":"opencode_not_running"}"#
                }
                sendResponse(HTTPResponse(
                    status: 503, reason: "Service Unavailable",
                    contentType: "application/json", body: Data(body.utf8)
                ), on: connection)
                return
            }
        }

        let effectivePlanMode = req.agent == .cursor ? false : req.planMode
        let transportPolicy = AgentTransportPolicy.codeSessionTransport(
            for: req.agent,
            acpSupported: Self.acpSupport(for: req.agent) != nil
        )
        // Managed harness/OpenCode transports do not have a tmux argv. Their
        // binary/auth checks live in the provider-specific branches below, so
        // this preflight only guards providers that genuinely spawn via argv.
        let preflightArgv = transportPolicy.requiresArgvPreflight
            ? AgentSpawner.argv(for: req, workspacePath: req.repoKey)
            : [transportPolicy.managedPreflightToken]
        guard !preflightArgv.isEmpty else {
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"agent_cli_not_found"}"#.utf8)
            ), on: connection)
            return
        }

        // Determine the cwd: repo root, or new worktree path if useWorktree.
        // v0.7.9: worktrees are now the default for every new session, and
        // we use the session's CityNamer-assigned city as both the worktree
        // path slug AND the git branch name. Result: `git branch` lists
        // `cape-town` / `oslo` / `kyoto` instead of `<goal>-abcd12`, and
        // the worktree lives at `<repo>/.claude/worktrees/cape-town/`.
        var cwd = req.repoKey  // assume repoKey is an absolute path
        var worktreePath: String? = nil
        var provisioning: WorktreeProvisioningMetadata? = nil
        // v27 Code-tab harness migration: honor a pre-minted session id so the
        // Mac's optimistic provisional row and this session are one row.
        var provisionalSessionId: UUID? = req.sessionId
        if let existing = req.existingWorkspacePath, !existing.isEmpty {
            // v27: the Mac client already provisioned this git worktree locally
            // (to drive the optimistic "+" provisioning trail) and owns its
            // lifecycle. Reuse it rather than provisioning a second worktree.
            worktreePath = existing
            cwd = existing
        } else if req.useWorktree {
            // Mint a city up front so the worktree path + branch use the
            // same name. The session id we'll register with is captured
            // here so CityNamer's mapping is stable.
            let sessionId = provisionalSessionId ?? UUID()
            provisionalSessionId = sessionId
            let city = await MainActor.run {
                CityNamer.shared.cityName(for: sessionId)
            }
            let slug = WorktreeManager.slug(city: city)
            do {
                let provisioned = try await WorktreeManager.shared.provision(
                    repoRoot: req.repoKey,
                    slug: slug,
                    branchName: slug,
                    baseBranch: req.baseBranch,
                    filesToCopy: filesToCopySettings(forRepoRoot: req.repoKey),
                    setupScript: RepoSetupScriptStore.script(forRepoRoot: req.repoKey)
                )
                worktreePath = provisioned.path
                provisioning = provisioned.metadata
                cwd = provisioned.path
            } catch {
                serverLogger.error("worktree provision failed: \(error.localizedDescription, privacy: .public)")
                // Release the city back to the pool — we didn't actually
                // create the session.
                await MainActor.run {
                    CityNamer.shared.release(sessionId)
                }
                sendResponse(.internalError, on: connection)
                return
            }
        }

        if req.agent == .opencode {
            await handleSpawnOpencodeSession(
                req: req,
                connection: connection,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
            return
        }

        // Harness-driven providers bypass tmux: the daemon drives an AgentDriver
        // and projects its events into the chat store. Each branch owns its own
        // session-create + response, returning before the tmux argv/spawn below.
        // (1) ACP stdio agents (Cursor — `cursor-agent acp`, verified live).
        // Grok is NOT ACP; it's handled by the headless branch (1c) below.
        if let support = Self.acpSupport(for: req.agent) {
            let display = providerDisplayName(req.agent)
            // Phase 6: the agent's fs read/write capability is granted ONLY for
            // autopilot-trusted repos, bound to the repo root + session cwd via
            // RepoTrustGate (symlink/`..`/TOCTOU-safe). Untrusted repos pass nil
            // → fs stays unadvertised + every fs request is refused.
            let trustGate = AutopilotState.shared.isRepoTrusted(req.repoKey)
                ? RepoTrustGate(repoRoot: req.repoKey, sessionCwd: cwd)
                : nil
            let auditFs: (@Sendable (String, String, Bool) async -> Void)? = trustGate == nil ? nil : { op, path, allowed in
                serverLogger.info("acp fs \(op, privacy: .public) allowed=\(allowed, privacy: .public) path=\(MobileCommandPayloadHasher.hex(Data(path.utf8)), privacy: .public)")
            }
            await handleSpawnHarnessSession(
                req: req, displayName: display,
                binary: (AgentSpawner.cursorBinaryPath() ?? support.binaryName),
                arguments: support.spawnArgv(model: nil, effort: nil, alwaysApprove: false),
                cwd: cwd, worktreePath: worktreePath, provisioning: provisioning,
                provisionalSessionId: provisionalSessionId, connection: connection,
                makeBridge: { sid, store in
                    .acp(sessionId: sid, support: support, store: store,
                         model: req.model, agentDisplayName: display,
                         trustGate: trustGate, onFileAccess: auditFs,
                         cursorUsageSurface: .code,
                         cursorUsageRepo: cwd)
                })
            return
        }
        // (1c) Grok — headless driver. The shipping grok binary has no ACP
        // server, so the GrokHeadlessDriver spawns `grok --output-format
        // streaming-json` per turn (transport-owning; no stdio child).
        if req.agent == .grok {
            guard let grokPath = ShellRunner.locateBinary("grok") else {
                await cleanupUnregisteredWorktree(
                    repoRoot: req.repoKey,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    provisionalSessionId: provisionalSessionId,
                    context: "grok preflight"
                )
                sendResponse(HTTPResponse(
                    status: 503, reason: "Service Unavailable", contentType: "application/json",
                    body: Data(#"{"error":"grok_not_found","cta":"Install Grok / cmux first."}"#.utf8)
                ), on: connection)
                return
            }
            let display = providerDisplayName(req.agent)
            await handleSpawnHarnessSession(
                req: req, displayName: display,
                binary: nil, arguments: [],
                cwd: cwd, worktreePath: worktreePath, provisioning: provisioning,
                provisionalSessionId: provisionalSessionId, connection: connection,
                makeBridge: { sid, store in
                    .transportOwning(sessionId: sid, store: store, model: req.model,
                                     agentDisplayName: display,
                                     driver: GrokHeadlessDriver(binaryPath: grokPath),
                                     usageProvider: .grok,
                                     usageRepo: cwd)
                })
            return
        }
        // (2) Codex over `codex app-server` — the only Codex drive path for
        // new Code sessions. Legacy tmux/SDK Codex routes remain decode-only.
        if req.agent == .codex {
            let display = providerDisplayName(req.agent)
            await handleSpawnHarnessSession(
                req: req, displayName: display,
                binary: (ShellRunner.locateBinary("codex") ?? "codex"), arguments: ["app-server"],
                cwd: cwd, worktreePath: worktreePath, provisioning: provisioning,
                provisionalSessionId: provisionalSessionId, connection: connection,
                makeBridge: { sid, store in
                    .codexAppServer(sessionId: sid, store: store,
                                    model: req.model, agentDisplayName: display)
                })
            return
        }
        // (3) Gemini via Antigravity — headless `agy` CLI (Antigravity 2.0
        // decoupled the agent from the IDE: no app, no gRPC, no provisional protos;
        // verified live 2026-06-04). The reverse-engineered Cascade gRPC drive was
        // removed once agy was proven.
        if req.agent == .gemini {
            let display = providerDisplayName(req.agent)
            guard let agyPath = ShellRunner.locateBinary("agy") else {
                await cleanupUnregisteredWorktree(
                    repoRoot: req.repoKey,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    provisionalSessionId: provisionalSessionId,
                    context: "agy preflight"
                )
                sendResponse(HTTPResponse(
                    status: 503, reason: "Service Unavailable", contentType: "application/json",
                    body: Data(#"{"error":"agy_not_found","cta":"Install Antigravity 2 (the agy CLI) first."}"#.utf8)
                ), on: connection)
                return
            }
            await handleSpawnHarnessSession(
                req: req, displayName: display,
                binary: nil, arguments: [],   // the headless driver owns its per-turn processes
                cwd: cwd, worktreePath: worktreePath, provisioning: provisioning,
                provisionalSessionId: provisionalSessionId, connection: connection,
                makeBridge: { sid, store in
                    .transportOwning(sessionId: sid, store: store, model: req.model,
                                     agentDisplayName: display,
                                     driver: AntigravityHeadlessDriver(binaryPath: agyPath))
                })
            return
        }

        // Build agent argv per E4.
        let argv = req.useWorktree
            ? AgentSpawner.argv(for: req, workspacePath: cwd)
            : preflightArgv
        guard !argv.isEmpty else {
            if let worktreePath {
                do {
                    let result = try await WorktreeManager.shared.cleanupProvisionedWorktree(
                        repoRoot: req.repoKey,
                        worktreePath: worktreePath,
                        expectedMarkerId: provisioning?.ownershipMarkerId
                    )
                    if case .skipped(let reason) = result {
                        serverLogger.error("worktree cleanup after spawn preflight failed: \(reason, privacy: .public)")
                    }
                } catch {
                    serverLogger.error("worktree cleanup after spawn preflight threw: \(error.localizedDescription, privacy: .public)")
                }
            }
            if let provisionalSessionId {
                await MainActor.run {
                    CityNamer.shared.release(provisionalSessionId)
                }
            }
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"agent_cli_not_found"}"#.utf8)
            ), on: connection)
            return
        }

        // Spawn into a new tmux window — OR, for Claude with the PTY flag on,
        // a per-session PseudoTerminal (Track A). The two paths differ only in
        // how the child is launched + whether the session carries a tmux pane;
        // everything downstream (workspace record, JSONL wiring, response) is
        // shared. Errors from either path land in the same catch below.
        do {
            let resolvedEnv = try resolveRepoEnv(repoRoot: req.repoKey, cwd: cwd)
            let usePty = claudePtyEnabled && req.agent == .claude
            let session: AgentSession
            if usePty {
                // Create the session FIRST (no tmux pane), then single-flight
                // spawn the PTY host keyed by its id. argv was already verified
                // non-empty above, so the spawn plan is present.
                session = try await registry.create(
                    repoKey: req.repoKey,
                    repoDisplayName: (req.repoKey as NSString).lastPathComponent,
                    agent: req.agent,
                    model: req.model,
                    goal: req.goal,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    tmuxWindowId: nil,
                    tmuxPaneId: nil,
                    planMode: effectivePlanMode,
                    mode: req.useWorktree ? .worktree : .local,
                    effort: req.effort,
                    ownsWorktree: worktreePath != nil,
                    envSetId: resolvedEnv?.set?.id,
                    envSetName: resolvedEnv?.set?.name,
                    id: provisionalSessionId ?? UUID()
                )
                await ensureClaudePtyWiring()
                let plan = claudeSpawnPlan(for: session)
                do {
                    let host = try await claudePtyRegistry.resumeOrSpawn(id: session.id, plan: { plan })
                    // Code sessions can hit the first-run trust dialog in a fresh
                    // worktree; dismiss it on the PTY (chat is pre-trusted).
                    warmupClaudePtyHost(host)
                } catch {
                    // Unlike the tmux path (which spawns the window BEFORE create),
                    // the PTY path persists the session first, so a spawn failure
                    // would otherwise leave an orphan nil-pane record in
                    // sessions.json. Delete it before rethrowing into the outer
                    // catch (which does worktree/city cleanup).
                    await claudePtyRegistry.suspend(session.id)
                    try? await registry.delete(id: session.id)
                    throw error
                }
            } else {
                try await tmux.start()  // idempotent
                let window = try await tmux.newWindow(
                    cwd: cwd,
                    child: argv,
                    environment: resolvedEnv?.environment ?? [:]
                )
                // Phase 2 simplification: pane id = first pane of the new window.
                session = try await registry.create(
                    repoKey: req.repoKey,
                    repoDisplayName: (req.repoKey as NSString).lastPathComponent,
                    agent: req.agent,
                    model: req.model,
                    goal: req.goal,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    tmuxWindowId: window.windowId,
                    tmuxPaneId: window.paneId,
                    planMode: effectivePlanMode,
                    mode: req.useWorktree ? .worktree : .local,
                    effort: req.effort,
                    ownsWorktree: worktreePath != nil,
                    envSetId: resolvedEnv?.set?.id,
                    envSetName: resolvedEnv?.set?.name,
                    id: provisionalSessionId ?? UUID()
                )
            }
            recordWorkspaceSession(repoRoot: req.repoKey, sessionId: session.id)
            // Wire up JSONL tail + done-detector + plan-watcher for this
            // session (Phase 4). Best-effort: find the agent's JSONL file
            // under ~/.claude/projects/<encoded-cwd>/.
            if req.agent == .claude {
                attachClaudeWiring(for: session, cwd: cwd)
            }
            // Codex doesn't emit an `ExitPlanMode` tool call — its
            // plan-mode shape is just "read-only sandbox until the
            // user says go". Seed a synthetic planText so the chat's
            // existing plan card (PlanCardView) renders an Approve &
            // run button right away. The user reads the agent's
            // proposal in the regular chat stream, then taps approve
            // to flip the sandbox to workspace-write.
            if req.agent == .codex && effectivePlanMode {
                try await registry.setPlanText(
                    id: session.id,
                    planText: """
                    Codex is running in read-only plan mode. Review its messages in \
                    the chat — when the proposal looks right, tap **Approve & run** \
                    to restart with workspace-write access.
                    """
                )
            }
            AgentEventStream.recordEvent(
                sessionId: session.id,
                kind: .sessionCreated,
                payload: ["repo": req.repoKey, "agent": req.agent.rawValue]
            )
            // v0.8 QA: same permission-prompt warmup as chat sessions.
            // Code sessions usually run in trusted git repos and don't
            // see Codex's "trust this directory" prompt, but they can
            // still hit the "Update available!" splash on first launch
            // — those get auto-accepted per user spec. If the trust
            // prompt does fire (e.g. brand-new worktree), it surfaces
            // through the same PermissionPromptCard the chat workspace
            // renders.
            // tmux warmup only — a PTY session has no pane (warmup port is T6).
            if let warmupPane = session.tmuxPaneId {
                let warmupSession = session
                let warmupTask = Task { [weak self] in
                    await self?.warmupCLIPane(session: warmupSession, paneId: warmupPane)
                    await MainActor.run { [weak self] in
                        self?.chatWarmupTasks[warmupSession.id] = nil
                    }
                }
                chatWarmupTasks[session.id] = warmupTask
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let body = try? encoder.encode(session) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            if sendRepoEnvConflict(error, on: connection) {
                await cleanupUnregisteredWorktree(
                    repoRoot: req.repoKey,
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    provisionalSessionId: provisionalSessionId,
                    context: "spawn repo env conflict"
                )
                return
            }
            await cleanupUnregisteredWorktree(
                repoRoot: req.repoKey,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId,
                context: "spawn tmux failure"
            )
            serverLogger.error("Failed to spawn session: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    private func cleanupUnregisteredWorktree(
        repoRoot: String,
        worktreePath: String?,
        provisioning: WorktreeProvisioningMetadata? = nil,
        provisionalSessionId: UUID?,
        context: String
    ) async {
        if let worktreePath {
            do {
                let result = try await WorktreeManager.shared.cleanupProvisionedWorktree(
                    repoRoot: repoRoot,
                    worktreePath: worktreePath,
                    expectedMarkerId: provisioning?.ownershipMarkerId
                )
                if case .skipped(let reason) = result {
                    serverLogger.error("worktree cleanup after \(context, privacy: .public) skipped: \(reason, privacy: .public)")
                }
            } catch {
                serverLogger.error("worktree cleanup after \(context, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let provisionalSessionId {
            await MainActor.run {
                CityNamer.shared.release(provisionalSessionId)
            }
        }
    }

    private func filesToCopySettings(forRepoRoot repoRoot: String) -> WorkspaceFilesToCopySettings {
        workspaceStore.workspace(forRepoRoot: repoRoot)?.filesToCopy ?? WorkspaceFilesToCopySettings()
    }

    private func resolveRepoEnv(repoRoot: String, cwd: String) throws -> RepoEnvResolvedEnvironment? {
        try repoEnvResolver?.resolveForLaunch(repoRoot: repoRoot, cwd: cwd)
    }

    private func resolveRepoEnv(session: AgentSession, cwd: String? = nil) throws -> RepoEnvResolvedEnvironment? {
        try repoEnvResolver?.resolveForLaunch(session: session, cwd: cwd)
    }

    private struct RepoEnvConflictPayload: Encodable {
        let error: String
        let detail: String
        let conflicts: [RepoEnvConflict]
    }

    @discardableResult
    func sendRepoEnvConflict(_ error: Error, on connection: NWConnection) -> Bool {
        guard case RepoEnvError.manualConflicts(let conflicts) = error else { return false }
        let payload = RepoEnvConflictPayload(
            error: "repo_env_conflict",
            detail: "Manual .env.local values conflict with managed repo env variables.",
            conflicts: conflicts
        )
        let body = (try? JSONEncoder().encode(payload))
            ?? Data(#"{"error":"repo_env_conflict"}"#.utf8)
        sendResponse(HTTPResponse(
            status: 409,
            reason: "Conflict",
            contentType: "application/json",
            body: body
        ), on: connection)
        return true
    }

    private func recordWorkspaceSession(repoRoot: String, sessionId: UUID) {
        let existing = workspaceStore.workspace(forRepoRoot: repoRoot)?.activeSessionIds ?? []
        var ids = existing.filter { $0 != sessionId }
        ids.append(sessionId)
        workspaceStore.syncActiveSessions(repoRoot: repoRoot, sessionIds: ids)
    }

    /// v0.8 QA: prepare a CLI pane (code or chat) for the user's first
    /// prompt. Same flow either way:
    /// - **Codex update prompt**: auto-update (per user spec — always
    ///   take the latest, no question asked).
    /// - **Codex trust prompt**: auto-accept only for verified
    ///   Clawdmeter-owned worktrees; otherwise surface to the user.
    /// - **Claude welcome**: just give the TUI time to render.
    ///
    /// Renamed from `warmupChatPane` — the flow works for both code and
    /// chat sessions. Code sessions usually skip the trust prompt (they
    /// run in trusted git repos) so the cycle is fast.
    func warmupCLIPane(session: AgentSession, paneId: String) async {
        switch session.agent {
        case .codex:
            // For code sessions, the embedded terminal IS the input path
            // already — no backend gate. For chat sessions we restrict
            // to CLI backend (SDK has no tmux pane).
            if session.kind == .chat, session.codexChatBackend != .cli {
                return
            }
            // First pane probe lets the CLI render its initial screen.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Step 1: auto-update if the update prompt is showing. Per
            // user spec we always take the latest version — no UI prompt.
            var captured = (try? await tmux.command(["capture-pane", "-p", "-t", paneId]))?.lines.joined(separator: "\n") ?? ""
            if captured.contains("Update available") {
                serverLogger.info("chat warmup: auto-updating Codex CLI for \(session.id.uuidString, privacy: .public)")
                try? await tmux.sendKeys(paneId: paneId, bytes: Data([0x31, 0x0d]))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                captured = (try? await tmux.command(["capture-pane", "-p", "-t", paneId]))?.lines.joined(separator: "\n") ?? ""
            }
            // Step 2: surface the trust prompt to the user if shown. Only
            // surfaces ONCE per warmup — the CLI flickers the trust screen
            // briefly during MCP init even after dismissal, and the
            // continuation already resolved so we don't double-prompt.
            if captured.contains("Do you trust the contents") {
                if await isVerifiedOwnedWorktree(session) {
                    serverLogger.info("chat warmup: auto-trusting Codex owned worktree for \(session.id.uuidString, privacy: .public)")
                    try? await tmux.command(["send-keys", "-t", paneId, "Down", "Up", "Enter"])
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return
                }
                serverLogger.info("chat warmup: surfacing Codex trust prompt for \(session.id.uuidString, privacy: .public)")
                let cwd = session.effectiveCwd
                let prompt = PendingPermissionPrompt(
                    id: "codex-trust-\(UUID().uuidString)",
                    title: "Trust this directory?",
                    detail: "Codex wants to run in \(cwd). Trusting it allows project-local config, hooks, and exec policies to load. Working with untrusted contents has higher risk of prompt injection.",
                    header: "Codex CLI",
                    options: [
                        PermissionOption(
                            id: "yes",
                            label: "Yes, continue",
                            description: "Trust this directory and allow Codex to run.",
                            isRecommended: true
                        ),
                        PermissionOption(
                            id: "no",
                            label: "No, quit",
                            description: "Quit the Codex CLI for this chat.",
                            isDestructive: true
                        ),
                    ]
                )
                let dispatch: [String: [String]] = [
                    // Down + Up refreshes selection back to option 1
                    // ("Yes, continue") — the dialog ignores a bare
                    // Enter until a nav key wakes its input handler.
                    "yes": ["Down", "Up", "Enter"],
                    // To select "No, quit" we go Down then Enter.
                    "no": ["Down", "Enter"],
                ]
                let chosen = await surfacePermissionPrompt(
                    session: session,
                    prompt: prompt,
                    dispatch: dispatch
                )
                // v0.8 QA F2: handleDeleteSession may wake us with the
                // cancellation sentinel. Bail without dispatching keys —
                // the session is being torn down anyway.
                if chosen == Self.cancelledPermissionOptionId {
                    return
                }
                if chosen == "no" {
                    return
                }
                try? await tmux.command(["send-keys", "-t", paneId] + (dispatch[chosen] ?? ["Down", "Up", "Enter"]))
                // Give the CLI 3s to finish dismissing + start MCP init.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            // Give the CLI another 3s to finish MCP setup + wire up its
            // input handler before the first user prompt can paste.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        case .claude:
            // Claude Code shows a one-time "Do you trust the files in this
            // folder?" prompt on first launch in a directory. For a CHAT the cwd
            // is a throwaway /tmp sandbox, so auto-accept it — otherwise the TUI
            // sits at the prompt, the first /send pastes into the dialog instead
            // of the composer, no reply ever streams, and the client times out.
            // Claude Code's first-run dialog (verified live 2026-06-03):
            //   "Quick safety check: Is this a project you created or one you
            //    trust? ... ❯ 1. Yes, I trust this folder / 2. No, exit"
            // It renders ~5-7s after launch (a single 1.5s capture missed it),
            // so POLL for it, accept it (Down/Up wakes the handler + keeps the
            // default "Yes" highlighted, Enter confirms — verified to reach the
            // composer), then settle before the first paste. Without this the TUI
            // sits at the prompt, /send pastes into the dialog, and the client
            // times out.
            func isClaudeTrustPrompt(_ s: String) -> Bool {
                s.contains("Quick safety check")
                    || s.localizedCaseInsensitiveContains("trust this folder")
                    || s.localizedCaseInsensitiveContains("Is this a project you created")
                    || s.contains("Do you trust")
            }
            var claudeAccepted = false
            var claudeReady = false
            // Poll fast (0.6s) so we detect the composer the moment it renders
            // instead of waiting out a coarse interval — shaves seconds off the
            // first send. ~28 × 0.6s ≈ 17s window covers a heavy MCP/plugin boot.
            for _ in 0..<28 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let cap = (try? await tmux.command(["capture-pane", "-p", "-t", paneId]))?.lines.joined(separator: "\n") ?? ""
                if isClaudeTrustPrompt(cap) {
                    serverLogger.info("chat warmup: auto-accepting Claude trust prompt for \(session.id.uuidString, privacy: .public)")
                    try? await tmux.command(["send-keys", "-t", paneId, "Down", "Up", "Enter"])
                    claudeAccepted = true
                    // Don't break — keep polling for the composer so we settle on
                    // real readiness, not a fixed guess after the keypress.
                    continue
                }
                // Composer is up (pre-trusted boot, or post-accept) → ready.
                if cap.contains("? for shortcuts")
                    || cap.contains("Welcome back")
                    || cap.contains("Remote Control active")
                    || cap.contains("plan mode on") {
                    claudeReady = true
                    break
                }
            }
            // Settle so the composer's input handler is wired before the paste.
            // Short when we confirmed the composer; longer as a fallback when the
            // boot outran the poll window (paste-into-not-quite-ready insurance).
            let fallbackDelay: UInt64 = claudeAccepted ? 1_500_000_000 : 2_500_000_000
            try? await Task.sleep(nanoseconds: claudeReady ? 800_000_000 : fallbackDelay)
        case .gemini:
            break
        case .opencode:
            // PR #29: opencode sessions never enter the tmux warmup
            // choreography — they're SSE clients of `opencode serve`,
            // which OpencodeProcessManager + OpencodeSSEAdapter handle
            // out-of-band.
            break
        case .cursor, .grok:
            // ACP agents (cursor-agent acp / grok headless) have no tmux pane —
            // no warmup choreography.
            break
        case .unknown:
            // X3: forward-compat unknown agent — no warmup choreography
            // plumbed.
            break
        }
    }

    func dismissClaudeChatMCPPromptIfNeeded(paneId: String, sessionId: UUID) async {
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let cap = (try? await tmux.command(["capture-pane", "-p", "-t", paneId]))?.lines.joined(separator: "\n") ?? ""
            guard cap.contains("New MCP server found")
                || cap.contains("MCP servers may execute code")
                || cap.contains("Continue without using this MCP server") else {
                continue
            }
            serverLogger.info("claude chat: dismissing MCP server prompt for \(sessionId.uuidString, privacy: .public)")
            try? await tmux.command(["send-keys", "-t", paneId, "Down", "Down", "Enter"])
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
    }

    func submitClaudeChatPromptWhenReady(paneId: String, text: String, sessionId: UUID) async throws {
        var sawPromptText = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let cap = (try? await tmux.command(["capture-pane", "-p", "-t", paneId]))?.lines.joined(separator: "\n") ?? ""
            if cap.contains(text) {
                sawPromptText = true
                break
            }
        }
        if sawPromptText {
            try? await Task.sleep(nanoseconds: 700_000_000)
        } else {
            serverLogger.info("claude chat: submitting before text appeared in capture for \(sessionId.uuidString, privacy: .public)")
        }
        for attempt in 0..<3 {
            try await tmux.sendKeyUsingFreshClient(paneId: paneId, key: "Enter")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let cap = (try? await tmux.command(["capture-pane", "-p", "-t", paneId]))?.lines.joined(separator: "\n") ?? ""
            if !cap.contains(text)
                || cap.contains("New MCP server found")
                || cap.contains("MCP servers may execute code")
                || cap.contains("esc to interrupt") {
                return
            }
            serverLogger.info("claude chat: retrying Enter for staged prompt \(sessionId.uuidString, privacy: .public) attempt=\(attempt + 1, privacy: .public)")
        }
    }

    private func isVerifiedOwnedWorktree(_ session: AgentSession) async -> Bool {
        guard session.kind == .code,
              let provisioning = session.provisioning,
              let worktreePath = session.worktreePath,
              !provisioning.ownershipMarkerId.isEmpty,
              provisioning.worktreePath == worktreePath,
              session.effectiveCwd == worktreePath else {
            return false
        }
        return await WorktreeManager.shared.hasOwnershipMarker(
            worktreePath: worktreePath,
            markerId: provisioning.ownershipMarkerId
        )
    }

    /// Surface a permission prompt to the user via the chat store and
    /// await their response. Returns the option-id they chose. Never
    /// times out — the prompt persists until the user clicks (the
    /// continuation map is the source of truth).
    @MainActor
    private func surfacePermissionPrompt(
        session: AgentSession,
        prompt: PendingPermissionPrompt,
        dispatch: [String: [String]]
    ) async -> String {
        // Register the dispatch map + promptId so handlePermissionRespond
        // can look up the keys (F2) and reject stale clicks (F4).
        permissionOptionDispatch[session.id] = dispatch
        pendingPermissionPromptIds[session.id] = prompt.id
        // Publish the prompt to the store so the Mac UI re-renders.
        if let store = chatStoreRegistry.snapshotStore(for: session) {
            store.setPendingPermissionPrompt(prompt)
        }
        // E6: fire an APNS push so the paired iPhone surfaces the
        // permission card on the lock screen. Best-effort; failure here
        // doesn't block the user clicking on the Mac.
        let captureSessionId = session.id
        let captureTitle = prompt.title
        let captureHeader = prompt.header ?? "Permission required"
        Task.detached {
            let body = APNSPushBody(
                kind: "permissionPrompt",
                sessionId: captureSessionId.uuidString,
                title: captureHeader,
                body: captureTitle,
                triggerAt: UInt64(Date().timeIntervalSince1970)
            )
            let outcome = await APNSGatewayPushCoordinator.shared.notify(
                surface: .permissionPrompt,
                body: body
            )
            if let outcome {
                serverLogger.info("APNS permission-prompt push outcome=\(outcome.response.rawValue, privacy: .public) elapsed=\(outcome.elapsedSeconds, privacy: .public)s")
            }
        }
        // Await the user's response via the continuation.
        let optionId: String = await withCheckedContinuation { cont in
            pendingPermissionContinuations[session.id] = cont
        }
        // Clear the published prompt + dispatch map + promptId.
        if let store = chatStoreRegistry.snapshotStore(for: session) {
            store.setPendingPermissionPrompt(nil)
        }
        permissionOptionDispatch[session.id] = nil
        pendingPermissionPromptIds[session.id] = nil
        return optionId
    }

    /// POST `/sessions/:id/permission-respond` body `{promptId, optionId}`.
    /// Validates that both the promptId AND optionId belong to the
    /// currently-pending prompt (rejects stale clicks where the UI is
    /// behind the daemon's current prompt — e.g. iOS surface with a
    /// cached prompt, or future Claude per-tool flow where multiple
    /// prompts queue per session). Resumes the warmup/poll continuation
    /// with the chosen optionId on success.
    private func handlePermissionRespond(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(PermissionRespondRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        // ACP harness permission (Grok, Cursor): the pending prompt lives in the
        // bridge (keyed by the ACP request id), not the daemon's continuation
        // map, so this must run BEFORE the continuation-based checks below.
        // Keyed off the bridge registry (agent-agnostic); legacy sessions have
        // no bridge and use the continuation path. The bridge answers the
        // agent's `session/request_permission` and clears the store's prompt; a
        // non-match means a stale / already-answered click.
        let route = registry.session(id: uuid).map { commandRoute(for: $0).route }
        if route == .harnessBridge, let bridge = harnessRegistry.bridge(for: uuid) {
            let matched = await bridge.respondToPermission(promptId: req.promptId, optionId: req.optionId)
            if matched {
                serverLogger.info("acp permission respond session=\(uuid.uuidString, privacy: .public) option=\(req.optionId, privacy: .public)")
                sendJSON(["ok": true], on: connection)
            } else {
                sendResponse(HTTPResponse(
                    status: 409, reason: "Conflict",
                    contentType: "application/json",
                    body: Data(#"{"error":"no_pending_prompt"}"#.utf8)
                ), on: connection)
            }
            return
        }
        // Reject stale clicks where the UI's promptId doesn't match the
        // currently-pending prompt. Done BEFORE removing the continuation
        // so legitimate clicks against the live prompt still succeed.
        guard let currentPromptId = pendingPermissionPromptIds[uuid] else {
            sendResponse(HTTPResponse(
                status: 409, reason: "Conflict",
                contentType: "application/json",
                body: Data(#"{"error":"no_pending_prompt"}"#.utf8)
            ), on: connection)
            return
        }
        guard currentPromptId == req.promptId else {
            sendResponse(HTTPResponse(
                status: 409, reason: "Conflict",
                contentType: "application/json",
                body: Data(#"{"error":"stale_prompt","current":"\#(currentPromptId)"}"#.utf8)
            ), on: connection)
            return
        }
        guard let dispatch = permissionOptionDispatch[uuid],
              dispatch[req.optionId] != nil else {
            sendResponse(.badRequest, on: connection)
            return
        }
        guard let cont = pendingPermissionContinuations.removeValue(forKey: uuid) else {
            // Should not happen given the promptId check above, but be
            // defensive — promptId map and continuation map can briefly
            // disagree under concurrent cancellation.
            sendResponse(HTTPResponse(
                status: 409, reason: "Conflict",
                contentType: "application/json",
                body: Data(#"{"error":"no_pending_prompt"}"#.utf8)
            ), on: connection)
            return
        }
        serverLogger.info("permission respond session=\(uuid.uuidString, privacy: .public) option=\(req.optionId, privacy: .public)")
        cont.resume(returning: req.optionId)
        sendJSON(["ok": true], on: connection)
    }

    /// v0.8 QA F2: wake any pending permission continuation with the
    /// cancel sentinel. Used by handleDeleteSession and stop() so
    /// orphaned warmup tasks don't hang waiting for a user click on a
    /// session that's been torn down. Idempotent — safe to call when
    /// nothing is pending.
    @MainActor
    private func cancelPendingPermissionPrompt(sessionId: UUID) {
        guard let cont = pendingPermissionContinuations.removeValue(forKey: sessionId) else {
            return
        }
        pendingPermissionPromptIds[sessionId] = nil
        permissionOptionDispatch[sessionId] = nil
        if let session = registry.session(id: sessionId),
           let store = chatStoreRegistry.snapshotStore(for: session) {
            store.setPendingPermissionPrompt(nil)
        }
        cont.resume(returning: Self.cancelledPermissionOptionId)
    }

    /// One-shot guard for a CheckedContinuation race. Used by
    /// handlePostChatSession's tmux-timeout path: two Tasks (spawn +
    /// 10s sleep) race to resume the continuation; only the first
    /// claim wins. The other resume call is silently dropped, which
    /// also prevents Swift's runtime trap on double-resume.
    /// `final class` + atomic-style flag keeps the Sendable story
    /// simple — the box is captured by both racing Tasks.
    final class ResumeOnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func tryClaim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }


    private func attachClaudeWiring(for session: AgentSession, cwd: String) {
        // Claude encodes the cwd as a directory name with `/` → `-`.
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let projectDir = ClawdmeterRealHome.url()
            .appendingPathComponent(".claude/projects/\(encoded)")
        // The actual session JSONL is named with a fresh UUID. We watch
        // the parent dir and pick up the newest `.jsonl` once it appears.
        // For Phase 4, point the tail at the directory; the JSONLTail's
        // delayed-creation path handles "find the file when it lands".
        // Pragmatic v1: re-scan in 5s for the newest file.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            if let url = self.newestClaudeJSONL(in: projectDir) {
                let wiring = SessionEventWiring(
                    sessionId: session.id,
                    sessionFileURL: url,
                    goal: session.goal,
                    registry: self.registry,
                    notifications: self.notifications
                )
                wiring.start()
                self.sessionWiring[session.id] = wiring
                serverLogger.info("Attached JSONL wiring for session \(session.id.uuidString, privacy: .public) at \(url.path, privacy: .public)")
            } else {
                serverLogger.debug("No JSONL yet under \(projectDir.path, privacy: .public); skipping wiring")
            }
        }
    }

    private nonisolated func newestClaudeJSONL(in dir: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let jsonl = contents.filter { $0.pathExtension == "jsonl" }
        return jsonl.max { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad < bd
        }
    }

    private func handleApprovePlan(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        // Track A: a Claude PTY session has NO tmux window, so the old
        // `let windowId = session.tmuxWindowId else notFound` guard 404'd every
        // PTY chat (chat sessions always run plan-mode → the Approve button was
        // dead). For a PTY session, approve-plan is a swap to acceptEdits on the
        // host (handled below). For non-PTY sessions a missing window is still a
        // genuine notFound.
        let route = commandRoute(for: session).route
        let isClaudePtyApprove = session.tmuxWindowId == nil && route == .claudePty
        if !isClaudePtyApprove && session.tmuxWindowId == nil {
            sendResponse(.notFound, on: connection)
            return
        }
        // v16 outbox: approve-plan is a fire-and-forget POST with no
        // body schema. Optional InterruptRequest-shaped body carries
        // the idempotency key; missing body keeps the legacy path.
        let req = (try? JSONDecoder().decode(InterruptRequest.self, from: request.body))
            ?? InterruptRequest(idempotencyKey: nil)
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        if await !beginIdempotentCommand(key: req.idempotencyKey, on: connection, payloadHash: payloadHash) { return }
        defer { Task { [outbox = mobileCommandOutbox, key = req.idempotencyKey] in
            if let key { await outbox.releaseInFlight(key) }
        } }
        guard session.status == .planning,
              session.planText?.isEmpty == false || session.agent == .codex || session.agent == .cursor else {
            sendResponse(HTTPResponse(
                status: 409, reason: "Conflict",
                contentType: "application/json",
                body: Data(#"{"error":"session is not awaiting plan approval"}"#.utf8)
            ), on: connection)
            return
        }
        // Approve-plan is functionally a swap (kill pane + respawn). Use
        // the swap rate-limit so a misbehaving client can't flap approval.
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        // Per D13: kill the plan-mode pane, spawn a fresh execution pane
        // in the same window. Overlay covers the swap UI-side.
        //
        // Agent-specific replacement argv:
        //   Claude → `claude --permission-mode acceptEdits` (the
        //            user has approved the plan; switch to "agent can
        //            edit without asking"). Resume via `--resume <id>`
        //            isn't reliable on plan-mode → acceptEdits swaps
        //            because Claude rotates the session id when plan
        //            mode exits, so we spawn fresh.
        //   Codex  → `codex -s workspace-write` (spawn fresh in the
        //            same cwd; we don't track the Codex rollout id in
        //            the registry yet, so resume isn't an option. The
        //            new rollout writes its own JSONL alongside the
        //            plan-mode one in `~/.codex/sessions/`; the
        //            user-facing chat picks up the newest file).
        let argv: [String]?
        switch session.agent {
        case .claude:
            argv = AgentSpawner.claudeArgv(
                model: session.model,
                planMode: false,
                effort: session.effort,
                autopilot: false
            )
        case .codex, .gemini, .grok:
            // v27: codex/gemini/grok are harness-driven; approve-plan flows
            // through the bridge (permission response / set_mode), not a tmux
            // respawn. Surfaces as 500 below for any legacy tmux codex session.
            argv = nil
        case .opencode:
            // PR #29: opencode has no plan-mode → respawn-with-write
            // flow; OpenCode handles its own tool-call approval inside
            // `opencode serve`. Surfaces as 500 here so a misrouted
            // approve-plan from a stale UI doesn't pretend to succeed.
            argv = nil
        case .cursor:
            // v27: cursor is harness-driven; approve-plan flows through the ACP
            // session (set_mode / permission), not a tmux respawn. Surfaces as
            // 500 below for any legacy tmux cursor session.
            argv = nil
        case .unknown:
            // X3: forward-compat unknown agent — no respawn path.
            // Surfaces as 500 below.
            argv = nil
        }
        guard let replacementArgv = argv else {
            serverLogger.error("approve-plan: missing CLI binary for \(session.agent.rawValue, privacy: .public)")
            sendResponse(.internalError, on: connection)
            return
        }
        // Track A: PTY Claude approve = swap to acceptEdits on the host. No tmux
        // window to kill; suspend the plan-mode host + resume-or-spawn fresh with
        // the post-approval argv. Spawn fresh (not --resume): Claude rotates its
        // session id on plan-exit, same rationale as the tmux path above.
        if isClaudePtyApprove {
            let cwd = session.effectiveCwd
            let repoEnv = (try? resolveRepoEnv(session: session, cwd: cwd))?.environment
            let env = AgentSpawner.claudePtyEnv(extra: repoEnv)
            await claudePtyRegistry.suspend(uuid)
            let approveSpawn = ClaudePtyRegistry.SpawnPlan(argv: replacementArgv, cwd: cwd, env: env)
            guard (try? await claudePtyRegistry.resumeOrSpawn(id: uuid, plan: { approveSpawn })) != nil else {
                sendResponse(.internalError, on: connection)
                return
            }
            try? await registry.updateStatus(id: uuid, status: .running)
            try? await registry.markPlanApproved(id: uuid)
            AgentEventStream.recordEvent(
                sessionId: uuid, kind: .statusChanged, payload: ["status": "running"]
            )
            let peer = Self.endpointString(connection.endpoint)
            await AuditLog.shared.recordPlanApprove(
                sessionId: uuid, sourcePeer: peer, agent: session.agent.rawValue
            )
            chatFileResolver.invalidate(sessionId: uuid)
            await sendCommandResponse(
                body: ["ok": true], key: req.idempotencyKey, kind: .approve,
                sessionId: uuid, payloadHash: payloadHash, on: connection
            )
            return
        }
        do {
            // Non-PTY path: a tmux window is guaranteed here (the head guard
            // returned notFound otherwise).
            guard let windowId = session.tmuxWindowId else {
                sendResponse(.internalError, on: connection); return
            }
            let cwd = session.effectiveCwd
            let resolvedEnv = try resolveRepoEnv(session: session, cwd: cwd)
            try await tmux.killWindow(windowId)
            let newWindow = try await tmux.newWindow(
                cwd: cwd,
                child: replacementArgv,
                environment: resolvedEnv?.environment ?? [:]
            )
            try await registry.updateRuntime(
                id: uuid,
                worktreePath: session.worktreePath,
                tmuxWindowId: newWindow.windowId,
                tmuxPaneId: newWindow.paneId,
                mode: session.mode
            )
            // Clear the plan card and flip status to running so the
            // approve button disappears from the chat UI.
            try await registry.updateStatus(id: uuid, status: .running)
            try await registry.markPlanApproved(id: uuid)
            AgentEventStream.recordEvent(
                sessionId: uuid,
                kind: .statusChanged,
                payload: ["status": "running", "newWindowId": newWindow.windowId]
            )
            // T13: plan approval is a mid-session respawn that exits plan
            // mode and gives the agent edit permission. Recorded AFTER the
            // respawn succeeds — a failed approval shouldn't leave an
            // audit entry implying it landed.
            let peer = Self.endpointString(connection.endpoint)
            await AuditLog.shared.recordPlanApprove(
                sessionId: uuid, sourcePeer: peer,
                agent: session.agent.rawValue
            )
            // Phase 0b: Codex respawn-lineage. approve-plan kills the
            // plan-mode pane and spawns a fresh rollout (new JSONL file
            // with a new Codex session id). Invalidate the resolver's
            // cached link so the next chat-snapshot request rescans for
            // the new file. Claude's resume path keeps the same JSONL so
            // invalidation there is a cheap no-op. Belt to the suspenders
            // anyway: invalidate both paths.
            chatFileResolver.invalidate(sessionId: uuid)
            await sendCommandResponse(
                body: ["ok": true],
                key: req.idempotencyKey,
                kind: .approve,
                sessionId: uuid,
                payloadHash: payloadHash,
                on: connection
            )
        } catch {
            if sendRepoEnvConflict(error, on: connection) { return }
            serverLogger.error("approve-plan failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    /// Archive / unarchive a session (G7). Hides it from the default
    /// sidebar but the JSONL + worktree stay on disk. Reversible by
    /// POSTing `/unarchive`.
    private func handleArchive(
        sessionId: String,
        archived: Bool,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              registry.session(id: uuid) != nil
        else {
            sendResponse(.notFound, on: connection)
            return
        }
        do {
            if archived {
                try await registry.archive(id: uuid)
            } else {
                try await registry.unarchive(id: uuid)
            }
            sendResponse(.ok(contentType: "application/json", body: Data("{}".utf8)), on: connection)
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    /// v0.5.4 — `POST /sessions/:id/rename` with body `{name: String?}`.
    /// Empty/whitespace-only names normalize to nil at the registry
    /// (clearing the custom name → sidebar falls back to repoDisplayName).
    private func handleRename(
        sessionId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              registry.session(id: uuid) != nil
        else {
            sendResponse(.notFound, on: connection)
            return
        }
        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(RenameSessionRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        // Cap inbound name length so a paired-but-malicious device can't
        // push a multi-MB string into sessions.json (matches the
        // compose-draft 64KB cap pattern; 200 chars is generous for a
        // human-readable label).
        if let n = body.name, n.count > 200 {
            sendResponse(.badRequest, on: connection)
            return
        }
        do {
            try await registry.rename(id: uuid, name: body.name)
            sendResponse(.ok(contentType: "application/json", body: Data("{}".utf8)), on: connection)
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    /// v0.5.10 — `POST /jsonl-aliases/rename` with body `{path, name}`.
    /// Rename a Recent JSONL row (not a Clawdmeter-owned session). Persists
    /// to `~/.clawdmeter/jsonl-aliases.json` keyed by path. Empty/whitespace
    /// `name` clears the alias.
    private func handleRenameJSONLAlias(
        request: HTTPRequest,
        connection: NWConnection
    ) {
        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(RenameJSONLRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        // Match the session-rename cap so a malicious paired peer can't
        // wedge a multi-MB string into the on-disk store.
        if let n = body.name, n.count > 200 {
            sendResponse(.badRequest, on: connection)
            return
        }
        // Belt-and-braces: insist the path is absolute and lives under one
        // of the two well-known JSONL roots. Prevents a paired peer from
        // wedging arbitrary keys into the alias file.
        let home = ClawdmeterRealHome.path()
        let allowedRoots = [
            home + "/.claude/projects/",
            home + "/.codex/sessions/"
        ]
        guard body.path.hasPrefix("/"),
              allowedRoots.contains(where: { body.path.hasPrefix($0) })
        else {
            sendResponse(.badRequest, on: connection)
            return
        }
        JSONLAliasStore.shared.setAlias(path: body.path, name: body.name)
        // Refresh the RepoIndex snapshot so the new name shows in the
        // sidebar without waiting for the 60s tick.
        Task { [repoIndex] in await repoIndex.refresh() }
        sendResponse(.ok(contentType: "application/json", body: Data("{}".utf8)), on: connection)
    }

    private func handleDeleteSession(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        // v0.8 QA F2: wake any pending permission continuation BEFORE
        // teardown so a stuck warmup task can return cleanly instead of
        // hanging on a session we're about to delete. Idempotent.
        cancelPendingPermissionPrompt(sessionId: uuid)
        // v0.8 QA F2: cancel the warmup task (lets it return early via
        // the cancellation sentinel from the line above), and drop the
        // entry from the map so handleSendPrompt can't await it later.
        if let task = chatWarmupTasks.removeValue(forKey: uuid) {
            task.cancel()
        }
        // ACP harness teardown (Grok): terminate the stdio child + driver and
        // release the chat store the bridge pinned. Idempotent on non-ACP
        // sessions (remove is a no-op when no bridge is registered).
        if harnessRegistry.contains(uuid) {
            await harnessRegistry.remove(uuid)
            chatStoreRegistry.release(sessionId: uuid)
        }
        // Track A: tear down the Claude PTY host (no-op if this session never
        // had one). Done unconditionally so a flag flip mid-session still cleans up.
        await claudePtyRegistry.suspend(uuid)
        // Kill the tmux window.
        if let windowId = session.tmuxWindowId {
            do {
                try await tmux.killWindow(windowId)
            } catch {
                serverLogger.warning("kill-window \(windowId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // v0.8 REV-DELETE: chat sessions clean up via FileManager
        // (chat-cwd is a plain dir under chat-sessions/, not a git
        // worktree). Code sessions go through WorktreeManager.delete as
        // before.
        if session.kind == .chat {
            do {
                try ChatCwdManager.remove(for: uuid)
            } catch {
                serverLogger.warning("chat-cwd cleanup failed for \(uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            // v0.9.x.1: also delete the SDK transcript mirror so a
            // deleted chat doesn't leak its history under
            // ~/Library/Application Support/Clawdmeter/sdk-chat-transcripts/.
            SDKChatTranscriptMirror.removeMirror(sessionId: uuid)
        } else if session.kind == .code, session.ownsWorktree, let worktreePath = session.worktreePath, let repoRoot = session.repoKey {
            do {
                let result = try await WorktreeManager.shared.delete(
                    repoRoot: repoRoot,
                    worktreePath: worktreePath,
                    registryOwned: true,
                    attachedPanePaths: []
                )
                serverLogger.info("Worktree GC for session \(uuid.uuidString, privacy: .public): \(String(describing: result), privacy: .public)")
            } catch {
                serverLogger.warning("Worktree delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Stop the JSONL wiring for this session.
        if let wiring = sessionWiring.removeValue(forKey: uuid) {
            wiring.stop()
        }
        // v0.8 F3: drop the chat store from the registry now that the
        // session is gone. Without this the store sticks around until
        // the 60s sweep tick — small leak, but it also means a stale
        // store can shadow a freshly-created session if uuids ever
        // collide across a daemon restart. Idempotent.
        chatStoreRegistry.evict(sessionId: uuid)
        do {
            try await registry.delete(id: uuid)
        } catch {
            serverLogger.error("registry.delete write-ahead failed for \(uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection); return
        }
        AgentEventStream.recordEvent(sessionId: uuid, kind: .sessionDeleted, payload: [:])
        sendResponse(.ok(contentType: "application/json", body: Data("{}".utf8)), on: connection)
    }

    func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        if case .ipv4(let addr) = host, addr.rawValue.first == 127 { return true }
        if case .ipv6(let addr) = host {
            let bytes = addr.rawValue
            return bytes.count == 16 && bytes.prefix(15).allSatisfy { $0 == 0 } && bytes.last == 1
        }
        return false
    }

    static func isValidTmuxPaneId(_ paneId: String) -> Bool {
        guard paneId.first == "%", paneId.count > 1 else { return false }
        return paneId.dropFirst().allSatisfy { $0.isNumber }
    }

    static func endpointString(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            if case .ipv6 = host {
                return "[\(host)]:\(port.rawValue)"
            }
            return "\(host):\(port.rawValue)"
        default:
            return "\(endpoint)"
        }
    }

}
