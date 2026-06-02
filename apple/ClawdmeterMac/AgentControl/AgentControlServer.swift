import Foundation
import Network
import OSLog
import ClawdmeterShared

private let serverLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AgentControlServer")

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
    private let repoIndex: RepoIndex
    private let whois: TailscaleWhois
    private let registry: AgentSessionRegistry
    private let tmux: TmuxControlClient
    private let notifications: NotificationDispatcher
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
    private let codeRunProfiles: CodeRunProfileService
    /// Prepared checkpoint restore plans are intentionally short-lived:
    /// iOS must preview a restore before it can confirm it.
    private var checkpointRestorePlans: [UUID: CheckpointRestorePlan] = [:]
    /// Phase 0a: long-lived per-session chat-store registry. Replaces the
    /// "reparse JSONL on every /chat-snapshot request" path. Used by the
    /// HTTP handler (snapshotStore) and, in Phase 2, by the WS dispatcher
    /// for `chat-subscribe` long-lived subscriptions (acquire / release).
    private let chatStoreRegistry: DaemonChatStoreRegistry
    /// Phase 0b: shared file resolver. Owns the Codex respawn-lineage
    /// tracking — `approve-plan` invalidates the resolver so the next
    /// chat-snapshot request rescans for the new rollout file. The
    /// `chatStoreRegistry` delegates JSONL URL resolution to this.
    private let chatFileResolver: SessionFileResolver
    /// ACP harness: live `AcpHarnessBridge`s keyed by session id. Grok (and,
    /// later, every migrated ACP/SDK provider) is driven through one of these
    /// instead of a tmux pane. Claude/Codex/Cursor stay on their existing
    /// paths; the registry only holds the new harness-driven sessions.
    private let harnessRegistry = HarnessSessionRegistry()
    /// T18 Wire Inspector: per-connection request context so the
    /// outgoing-response recorder can tag entries with the original
    /// method+path. Each NWConnection serves one request before
    /// `connection.cancel()` runs in sendResponse's completion handler,
    /// so the dict never has more than one entry per connection at a
    /// time. Cleared in sendResponse after the response is queued.
    private var pendingRequests: [ObjectIdentifier: (method: String, path: String)] = [:]
    /// Wired by AppRuntime after construction so the iPhone can pull live
    /// Claude/Codex usage AND the historical analytics snapshot over
    /// Tailscale instead of needing iCloud KV sync. Nil-tolerant — the
    /// endpoints just return empty payloads when the runtime hasn't
    /// attached yet (cold start, tests).
    private weak var claudeModel: AppModel?
    private weak var codexModel: AppModel?
    private weak var geminiModel: AppModel?
    private weak var usageHistory: UsageHistoryStore?

    private var listener: NWListener?
    private var wsListener: NWListener?
    private var listenerQueue: DispatchQueue?
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
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Active WebSocket channels keyed by connection. Both terminal +
    /// event streams conform to `WSChannel`.
    private var wsChannels: [ObjectIdentifier: any WSChannel] = [:]

    /// JSONL tail + done-detector + plan-watcher wired per active session.
    private var sessionWiring: [UUID: SessionEventWiring] = [:]

    @MainActor
    public var ownedSessionJSONLPaths: Set<String> {
        Set(sessionWiring.values.map { $0.sessionFileURL.path })
    }

    /// v0.8 Phase 4.5: per-session Codex SDK chat ingestors. Created on
    /// the first /send for an SDK chat session; torn down on DELETE or
    /// SDK chat-session idle evict. Holding a strong reference keeps the
    /// Combine sink alive across the session lifetime.
    private var sdkChatIngestors: [UUID: CodexSDKEventIngestor] = [:]

    /// v0.8 QA: per-session warmup task for chat-mode CLI sessions. The
    /// handler that handles `POST /sessions/:id/send` awaits the task
    /// before pasting so the first prompt doesn't race the trust-prompt
    /// / update-prompt dismissal. Cleared once the task completes.
    private var chatWarmupTasks: [UUID: Task<Void, Never>] = [:]

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
    private var frontierGroupIdempotency: [UUID: (groupId: UUID, response: CreateFrontierResponse, createdAt: Date)] = [:]
    /// Per-group monotonic snapshot counter; advances on every child
    /// status change. Used by the frontier-subscribe WS channel (TBD)
    /// and by the response from /retry-slot.
    private var frontierUpdateCounters: [UUID: Int] = [:]
    private var frontierTurnWinners: [UUID: [String: FrontierTurnWinner]] = [:]

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
        history: UsageHistoryStore?
    ) {
        self.claudeModel = claude
        self.codexModel = codex
        self.geminiModel = gemini
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

    private func saveFrontierTurnWinners() {
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
                    await MainActor.run {
                        AutopilotState.shared.setEnabled(false, sessionId: id)
                    }
                    // `AgentEventStream.recordEvent` expects
                    // `payload: [String: String]`; the original `false`
                    // Bool literal made the dictionary infer to
                    // `[String: any Sendable]` and the call site
                    // refused to type-check. Stringify so the autopilot
                    // sweep ships at all.
                    AgentEventStream.recordEvent(
                        sessionId: id,
                        kind: .statusChanged,
                        payload: ["autopilot": "false", "reason": "inactivity_timeout"]
                    )
                    // `serverLogger` is a module-level `private let`
                    // (top of this file), not an instance member —
                    // `self?.serverLogger` doesn't resolve. Reference
                    // the global directly; the weak self capture
                    // covers the actor isolation around AutopilotState.
                    serverLogger.info(
                        "autopilot disabled by 15-min inactivity sweep: session=\(id.uuidString, privacy: .public)"
                    )
                }
            }
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

    /// Spin up a WebSocket-enabled listener. The first message from the
    /// client must be a JSON subscription envelope identifying the channel
    /// (terminal vs events) + bearer token.
    private func startWSListening(on port: UInt16, queue: DispatchQueue) -> Bool {
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            let params = NWParameters.tcp
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params, on: nwPort)
            self.wsListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewWSConnection(connection)
                }
            }
            listener.start(queue: queue)
            return true
        } catch {
            serverLogger.debug("WS bind \(port) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Accept a WebSocket connection. Apply the same peer filter as HTTP;
    /// the first WS message authenticates and subscribes to a channel.
    private func handleNewWSConnection(_ connection: NWConnection) {
        guard Self.isAllowedPeer(connection.endpoint) else {
            serverLogger.warning("WS: rejecting non-tailnet peer \(String(describing: connection.endpoint))")
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                Task { @MainActor in
                    await self?.routeWSSubscription(on: connection)
                }
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                    if let channel = self?.wsChannels.removeValue(forKey: ObjectIdentifier(connection)) {
                        channel.stop()
                    }
                }
            default: break
            }
        }
        connection.start(queue: listenerQueue ?? .global())
    }

    private func routeWSSubscription(on connection: NWConnection) async {
        // Read the first WebSocket message: a JSON envelope with op, token,
        // and channel-specific params.
        let firstMessage: Data
        do {
            firstMessage = try await receiveOne(on: connection)
        } catch {
            serverLogger.debug("WS: failed to receive subscription envelope: \(error.localizedDescription)")
            connection.cancel()
            return
        }
        let wsDecoder = JSONDecoder()
        // ComposeDraft carries an ISO-8601 `createdAt` field (X1 cross-Apple
        // handoff). iOS encodes with `.iso8601` via `encodedJSONObject()`;
        // without setting the strategy here, the default `.deferredToDate`
        // would expect a Double and the whole envelope would silently fail
        // to decode — X1 broken end-to-end (caught by review 2026-05-18).
        wsDecoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? wsDecoder.decode(WSSubscription.self, from: firstMessage) else {
            serverLogger.debug("WS: malformed subscription envelope")
            sendWSClose(on: connection, code: .protocolCode(.protocolError))
            return
        }
        // Auth — accept either the pairing token (iOS) or the per-launch
        // loopback token (Mac's in-process MacLoopbackClient, PR #24a).
        guard isAuthorized(token: envelope.token) else {
            serverLogger.warning("WS: bad bearer token")
            sendWSClose(on: connection, code: .protocolCode(.policyViolation))
            return
        }
        // Tailscale whois for non-loopback.
        if !isLoopback(connection.endpoint) {
            let peerString = Self.endpointString(connection.endpoint)
            if await whois.userLoginName(for: peerString) == nil {
                serverLogger.warning("WS: whois rejected \(peerString, privacy: .public)")
                sendWSClose(on: connection, code: .protocolCode(.policyViolation))
                return
            }
        }

        switch envelope.op {
        case "compose-draft":
            // X1 cross-Apple handoff. Phone POSTs a draft, daemon broadcasts
            // to any Mac /events subscriber. Here on the *server* side, the
            // initial WS message contains the draft itself (single-shot
            // post-as-WS) — fan it out via NotificationCenter to the local
            // Mac UI process. The connection is then closed; we don't keep
            // a long-lived state.
            if let payload = envelope.draft {
                // Cap inbound text length so a misbehaving / malicious paired
                // device can't push a multi-MB blob into the SwiftUI TextField
                // (review §3 finding 2026-05-18). 64KB ≈ ~10K tokens — far
                // larger than any plausible composer prompt.
                guard payload.text.count <= 64 * 1024 else {
                    serverLogger.warning("compose-draft rejected: text length \(payload.text.count) > 64KB cap")
                    sendWSClose(on: connection, code: .protocolCode(.policyViolation))
                    return
                }
                NotificationCenter.default.post(
                    name: .composeDraftIncoming,
                    object: nil,
                    userInfo: ["draft": payload]
                )
                let peer = Self.endpointString(connection.endpoint)
                await AuditLog.shared.recordSend(
                    sessionId: UUID(),  // synthetic — drafts don't belong to a session yet
                    sourcePeer: peer,
                    text: "[compose-draft] repo=\(payload.repoKey ?? "-") len=\(payload.text.count)"
                )
                serverLogger.info("compose-draft received: text length=\(payload.text.count, privacy: .public), repo=\(payload.repoKey ?? "-", privacy: .public), peer=\(peer, privacy: .public)")

                // v0.7.2 wire v8 additive: when the iOS client attaches a
                // `codexThreadId` AND the draft suggests Codex agent, dispatch
                // the prompt to the Codex SDK's one-shot resume. Posts the
                // resume_result back to the iOS client over the same WS as a
                // second JSON frame before closing. SDK runs against the
                // user's ChatGPT subscription quota (no per-token billing).
                if let threadId = payload.codexThreadId,
                   !threadId.isEmpty,
                   payload.suggestedAgent == .codex,
                   await CodexSDKManager.shared.isProvisioned {
                    // Resolve workingDirectory: prefer the draft's repoKey,
                    // fall back to the user's home dir so the SDK can run
                    // outside a git repo too.
                    let workingDirectory = payload.repoKey
                        ?? ClawdmeterRealHome.path()
                    do {
                        let result = try await CodexSDKManager.shared.runResume(
                            threadId: threadId,
                            prompt: payload.text,
                            workingDirectory: workingDirectory,
                            timeout: 120
                        )
                        // Post a structured result frame so iOS can render the
                        // resumed-thread response inline. The wire format is a
                        // single JSON line: {type, threadId, finalResponse,
                        // usage}. iOS parses this from the WS receive.
                        let response: [String: Any] = [
                            "type": "codex_resume_result",
                            "threadId": result.threadId,
                            "finalResponse": result.finalResponse,
                            "usage": [
                                "inputTokens": result.usage?.inputTokens ?? 0,
                                "cachedInputTokens": result.usage?.cachedInputTokens ?? 0,
                                "outputTokens": result.usage?.outputTokens ?? 0,
                                "reasoningOutputTokens": result.usage?.reasoningOutputTokens ?? 0,
                            ]
                        ]
                        if let body = try? JSONSerialization.data(withJSONObject: response),
                           let text = String(data: body, encoding: .utf8) {
                            sendWSText(text, on: connection)
                            serverLogger.info("compose-draft codex-resume succeeded: threadId=\(threadId, privacy: .public), tokens=\(result.usage?.outputTokens ?? 0, privacy: .public)")
                        }
                    } catch {
                        // Send a structured error frame; iOS can show "Resume
                        // failed" without conflating it with the original
                        // draft delivery.
                        let response: [String: Any] = [
                            "type": "codex_resume_error",
                            "threadId": threadId,
                            "msg": error.localizedDescription,
                        ]
                        if let body = try? JSONSerialization.data(withJSONObject: response),
                           let text = String(data: body, encoding: .utf8) {
                            sendWSText(text, on: connection)
                        }
                        serverLogger.warning("compose-draft codex-resume failed: \(error.localizedDescription, privacy: .public)")
                    }
                }

                // Send a 1-byte application-layer ACK before closing so the
                // iOS caller can `task.receive()` instead of guessing a
                // sleep duration. Replaces the prior 200ms hope-it-flushed
                // race (review §10 finding 2026-05-18).
                sendWSText("ok", on: connection)
            }
            sendWSClose(on: connection, code: .protocolCode(.normalClosure))
        case "terminal":
            guard let sessionIdString = envelope.sessionId,
                  let sessionId = UUID(uuidString: sessionIdString),
                  let session = registry.session(id: sessionId)
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            // G12: envelope can target a specific pane within the session
            // (multi-terminal tab strip). Only actual pane ids owned by the
            // session are accepted; tmux output is keyed by "%pane", not
            // "@window".
            let paneId: String? = {
                if let explicit = envelope.paneId, !explicit.isEmpty {
                    guard Self.isValidTmuxPaneId(explicit),
                          explicit == session.tmuxPaneId || session.terminalPanes.contains(where: { $0.paneId == explicit })
                    else { return nil }
                    return explicit
                }
                return session.tmuxPaneId
            }()
            guard let paneId else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let channel = TerminalWebSocketChannel(
                connection: connection,
                tmux: tmux,
                paneId: paneId,
                registry: registry,
                sessionId: sessionId
            )
            wsChannels[ObjectIdentifier(connection)] = channel
            channel.start()
        case "events":
            let since = envelope.since ?? 0
            let stream = AgentEventStream(
                connection: connection,
                registry: registry,
                sinceSeq: since
            )
            wsChannels[ObjectIdentifier(connection)] = stream
            stream.start()
        case "chat-subscribe":
            // Phase 2 of the WhatsApp-smooth Sessions pipeline. Replaces
            // iOS's 3-second `GET /chat-snapshot` HTTP polling with a
            // long-lived WS subscription. A10 (wire v21) layered the
            // shell/detail split on top:
            //   - Client reports `wireVersion`. v21+ receives shell +
            //     detail event pairs (one shell frame + one detail frame
            //     per 100ms coalesced commit); v20 and earlier keep
            //     receiving the legacy single `WireChatSnapshot` frame.
            //   - Branch is selected ONCE in the channel constructor and
            //     never re-evaluated mid-connection (clients that
            //     dynamically upgrade their wire shape would have to
            //     reconnect — which they already do across app launches).
            // No delta encoding in v1 — Codex's outside-voice review (D6)
            // explicitly cut that scope until measurements show it's
            // needed; the split lands first.
            guard let sessionIdString = envelope.sessionId,
                  let sessionId = UUID(uuidString: sessionIdString),
                  let session = registry.session(id: sessionId)
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let chatChannel = ChatStreamWebSocketChannel(
                connection: connection,
                session: session,
                registry: chatStoreRegistry,
                clientWireVersion: envelope.wireVersion
            )
            wsChannels[ObjectIdentifier(connection)] = chatChannel
            chatChannel.start()
        case "lifecycle-subscribe":
            // v19 lifecycle spine: full session lifecycle snapshots over WS.
            // The first frame is immediate; subsequent frames coalesce
            // registry changes at 50ms so UI surfaces can bind directly to
            // phase/blocker/next-action changes.
            guard let sessionIdString = envelope.sessionId,
                  let sessionId = UUID(uuidString: sessionIdString),
                  registry.session(id: sessionId) != nil
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let lifecycleChannel = LifecycleWebSocketChannel(
                connection: connection,
                sessionId: sessionId,
                registry: registry,
                checkpointProvider: { [weak self] id in
                    guard let self else { return [] }
                    return self.storedCheckpoints(for: id).map(self.codeCheckpoint)
                }
            )
            wsChannels[ObjectIdentifier(connection)] = lifecycleChannel
            lifecycleChannel.start()
        case "frontier-subscribe":
            // v0.9.x — typed aggregator for the 3-pane Frontier UI.
            // Acquires every child's chat store, observes them in
            // parallel via Combine, emits one FrontierGroupSnapshot
            // envelope per debounced 100ms commit window. Same auth
            // gate as chat-subscribe; same idle-eviction lifecycle.
            guard let groupIdString = envelope.groupId,
                  let groupId = UUID(uuidString: groupIdString)
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let frontierChannel = FrontierWebSocketChannel(
                connection: connection,
                groupId: groupId,
                registry: chatStoreRegistry,
                sessionRegistry: registry,
                turnWinnersProvider: { [weak self] in
                    self?.frontierTurnWinners[groupId]?.values.sorted { $0.decidedAt < $1.decidedAt } ?? []
                }
            )
            wsChannels[ObjectIdentifier(connection)] = frontierChannel
            frontierChannel.start()
        case "codex-stream-subscribe":
            // v0.7.4: live SDK observation. Each event the Codex SDK
            // observer sidecar emits flows here as a JSON text frame.
            // Multi-subscriber by construction — the local ingestor can
            // be reading the same session in parallel without contending.
            guard let sessionIdString = envelope.sessionId,
                  let sessionId = UUID(uuidString: sessionIdString),
                  let session = registry.session(id: sessionId)
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            let codexChannel = CodexStreamWebSocketChannel(
                connection: connection,
                session: session,
                relay: CodexSubscriptionRelay.shared
            )
            wsChannels[ObjectIdentifier(connection)] = codexChannel
            codexChannel.start()
        default:
            sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
        }
    }

    private func sendWSClose(on connection: NWConnection, code: NWProtocolWebSocket.CloseCode) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = code
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        connection.send(content: nil, contentContext: ctx, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Send a single text frame on the WS connection. Used as a tiny
    /// application-layer ACK for one-shot ops like `compose-draft` so the
    /// iOS caller can await receipt instead of guessing a sleep duration.
    private func sendWSText(_ text: String, on connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws-text", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: ctx,
                        isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receiveOne(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receiveMessage { data, _, _, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    /// Subscription envelope for WS connections.
    private struct WSSubscription: Codable {
        let op: String           // "terminal" | "events" | "compose-draft" | "chat-subscribe" | "lifecycle-subscribe" | "frontier-subscribe" | "codex-stream-subscribe"
        let token: String
        let sessionId: String?   // required for "terminal", "chat-subscribe", "lifecycle-subscribe", "codex-stream-subscribe"
        let since: UInt64?       // optional for "events"
        /// G12: target a specific pane (multi-terminal tab strip). When nil,
        /// the server falls back to the session's primary pane.
        let paneId: String?
        /// X1: compose-draft single-shot payload. Only populated when
        /// `op == "compose-draft"`. The Mac UI consumes via NotificationCenter.
        let draft: ComposeDraft?
        /// v0.9.x: required for `frontier-subscribe` — the group whose
        /// aggregate `FrontierGroupSnapshot` envelopes the client wants.
        let groupId: String?
        /// A10 (wire v21): client's reported wireVersion. The server picks
        /// the dispatch branch ONCE per connection: `wireVersion >= 21`
        /// receives shell + detail event pairs on `chat-subscribe`; older
        /// clients receive the legacy `WireChatSnapshot` frame on each
        /// commit (back-compat). Optional; absent on v20 and earlier
        /// clients that don't know to send it (the default-to-legacy path
        /// covers them).
        let wireVersion: Int?
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
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
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
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
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
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
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
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
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
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        let bytes = Array(req.text.utf8)
        guard !bytes.isEmpty, bytes.count <= 1_000_000 else {
            sendResponse(.badRequest, on: connection); return
        }
        // v0.8.1 agy-migration (Codex P1.3): Antigravity 2 agentapi
        // sessions have no tmux pane — sends route through
        // `LanguageServerClient.sendMessage` against the running
        // language_server. Same rate-limit + audit-log path as tmux
        // sends; the only difference is the transport. This branch
        // runs BEFORE the chat-tab SDK dispatch + paneId guard below.
        if session.geminiBackend == .agentapi,
           let conversationId = session.antigravityConversationId {
            guard RateLimiter.shared.tryAcquireSend(sessionId: uuid) else {
                sendResponse(.tooManyRequestsSend, on: connection); return
            }
            do {
                try await sendAntigravityMessage(
                    session: session,
                    conversationId: conversationId,
                    content: req.text
                )
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
            } catch let LanguageServerClientError.notRunning {
                serverLogger.warning("send-prompt for agentapi session \(uuid.uuidString, privacy: .public): LS not running")
                sendResponse(HTTPResponse(
                    status: 503, reason: "Service Unavailable",
                    contentType: "application/json",
                    body: Data(#"{"error":"antigravity_not_running","cta":"Open Antigravity 2 to continue this session"}"#.utf8)
                ), on: connection)
            } catch {
                serverLogger.error("send-prompt agentapi failed: \(error.localizedDescription, privacy: .public)")
                sendResponse(.internalError, on: connection)
            }
            return
        }
        guard RateLimiter.shared.tryAcquireSend(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSend, on: connection); return
        }
        // v0.8 Phase 4.5: SDK chat sessions route to CodexSubscriptionRelay
        // instead of tmux. Detect via (kind=.chat, agent=.codex,
        // backend=.sdk) — those sessions have no tmux pane.
        if session.kind == .chat
            && session.agent == .codex
            && session.codexChatBackend == .sdk {
            await sendChatSDKPrompt(
                session: session,
                prompt: req.text,
                idempotencyKey: req.idempotencyKey,
                payloadHash: payloadHash,
                connection: connection
            )
            return
        }
        // v0.23.2 P1-04: OpenCode send. Wires the iOS / Mac composer's
        // POST /sessions/:id/send to opencode's `POST /session/<id>/message`.
        // The reply streams back asynchronously via the SSE `message.added`
        // events that OpencodeSSEAdapter routes into the session's
        // SessionChatStore — clients reading the chat-subscribe WS see
        // the assistant turn appear without an additional poll.
        if session.agent == .opencode {
            await sendOpencodePrompt(
                session: session,
                prompt: req.text,
                idempotencyKey: req.idempotencyKey,
                payloadHash: payloadHash,
                connection: connection
            )
            return
        }
        // ACP harness send (Grok): drive the live `AcpHarnessBridge`. The reply
        // streams back into the session's SessionChatStore as the driver emits
        // HarnessEvents — clients on chat-subscribe see the turn appear with no
        // extra poll, exactly like the opencode/agentapi structured paths.
        if session.agent == .grok {
            guard let bridge = harnessRegistry.bridge(for: uuid) else {
                // No live bridge — the daemon restarted and the ACP child is
                // gone. Revive (respawn + session/load) is a Phase-1 lifecycle
                // item; surface a clear 503 so the client re-creates instead of
                // a false 200 ("paste succeeded" ≠ "provider accepted").
                sendResponse(HTTPResponse(
                    status: 503, reason: "Service Unavailable",
                    contentType: "application/json",
                    body: Data(#"{"error":"acp_session_not_live","cta":"Start a new Grok session"}"#.utf8)
                ), on: connection)
                return
            }
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
        if let warmupTask = chatWarmupTasks[uuid] {
            await warmupTask.value
        }
        do {
            let data = Data(bytes)
            // v0.8 QA: for chat-mode CLI sessions, clear the input line
            // before pasting so multi-turn prompts don't concatenate with
            // leftover text in the input box. C-u is a no-op when the
            // input is empty, so the first prompt isn't affected.
            if session.kind == .chat {
                try await tmux.command(["send-keys", "-t", paneId, "C-u"])
            }
            // v0.8 QA: chat-mode CLI sessions must use pasteBytes (not
            // sendKeys -l -H). tmux's hex-literal sendKeys sends each byte
            // as a SEPARATE key event, which Codex CLI's TUI input
            // ignores — bytes drop on the floor and the trailing Enter
            // submits the placeholder text instead of the user's prompt.
            // paste-buffer + paste-buffer lands the entire string atomically
            // and the input widget treats it as a paste.
            if session.kind == .chat
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
            if session.kind == .chat {
                try? await Task.sleep(nanoseconds: 300_000_000)
                try await tmux.command(["send-keys", "-t", paneId, "Enter"])
            }
            let peer = Self.endpointString(connection.endpoint)
            await AuditLog.shared.recordSend(sessionId: uuid, sourcePeer: peer, text: req.text)
            if session.agent == .cursor {
                appendCursorTranscriptEcho(session: session, prompt: req.text, paneId: paneId)
            }
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

    private func appendCursorTranscriptEcho(session: AgentSession, prompt: String, paneId: String) {
        guard let store = chatStoreRegistry.snapshotStore(for: session) else { return }
        let now = Date()
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var messages: [ChatMessage] = []
        if !trimmedPrompt.isEmpty {
            messages.append(ChatMessage(
                id: "cursor-user-\(UUID().uuidString)",
                kind: .userText,
                title: "You",
                body: trimmedPrompt,
                at: now
            ))
        }
        let hasMirror = !SDKChatTranscriptMirror.readAll(sessionId: session.id).isEmpty
        if !hasMirror && store.snapshot.items.isEmpty {
            messages.append(ChatMessage(
                id: "cursor-meta-\(UUID().uuidString)",
                kind: .meta,
                title: "Cursor",
                body: "Cursor Agent is running in the Terminal pane. Clawdmeter mirrors sends and terminal snapshots here until native Cursor transcript import can attach a proven Cursor chat id.",
                at: now
            ))
        }
        store.appendSDKMessages(messages, at: now)
        store.setCurrentTurnState(.streaming)

        Task { @MainActor [weak self, sessionId = session.id] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self,
                  let refreshed = self.registry.session(id: sessionId),
                  let refreshedStore = self.chatStoreRegistry.snapshotStore(for: refreshed),
                  let captured = try? await self.tmux.command(["capture-pane", "-p", "-t", paneId, "-S", "-80"])
            else { return }
            let body = captured.lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                refreshedStore.setCurrentTurnState(.completed)
                return
            }
            let cappedBody = String(body.suffix(6_000))
            refreshedStore.appendSDKMessages([
                ChatMessage(
                    id: "cursor-terminal-\(UUID().uuidString)",
                    kind: .assistantText,
                    title: "Cursor terminal",
                    body: cappedBody,
                    at: Date()
                )
            ])
            refreshedStore.setCurrentTurnState(.completed)
        }
    }

    /// v0.8.1 agentapi send-message bridge. Resolves the Antigravity
    /// project for this session's repoKey (cached by 60s TTL inside
    /// `AntigravityProjectResolver`), then dispatches the user's text
    /// through `LanguageServerClient.sendMessage`. Throws on LS-not-
    /// running or RPC error so the caller can surface a proper CTA.
    private func sendAntigravityMessage(
        session: AgentSession,
        conversationId: UUID,
        content: String
    ) async throws {
        let lsClient = LanguageServerClient()
        let projectId: String
        // v0.9: prefer the persisted `antigravityProjectId` (chat
        // sessions set this at create-time; v0.9+ code sessions can opt
        // in too). Fall back to the v0.8.1 repoKey-resolution path so
        // pre-v0.9 sessions.json records still send cleanly.
        if let persistedProjectId = session.antigravityProjectId {
            projectId = persistedProjectId
        } else {
            let projectsDir = ClawdmeterRealHome.url()
                .appendingPathComponent(".gemini/config/projects", isDirectory: true)
            let resolver = AntigravityProjectResolver(projectsDir: projectsDir)
            guard let repoKey = session.repoKey,
                  let info = await resolver.resolve(forRepoKey: repoKey) else {
                throw LanguageServerClientError.notRunning
            }
            projectId = info.id
        }
        do {
            try await lsClient.sendMessage(
                conversationId: conversationId.uuidString,
                content: content,
                projectId: projectId
            )
        } catch let LanguageServerClientError.rpcError(message) {
            // v0.9.x — CM3 hook: 401 / auth-class errors flip the
            // ChatProviderProbe override so /chat-providers surfaces
            // the failure to iOS without a fresh re-probe wait.
            if message.contains("401") || message.lowercased().contains("auth") {
                await ChatProviderAuthObserver.shared.recordAntigravityAuthError(
                    sessionId: session.id,
                    message: message
                )
            }
            throw LanguageServerClientError.rpcError(message)
        }
    }

    /// v0.9 — daemon-side spawn for Gemini chat sessions. Picks the
    /// first available Antigravity project as a scratch workspace
    /// (chat has no repoKey), creates a placeholder conversation via
    /// agentapi `new-conversation`, persists conversationId + projectId
    /// on the session, and warms the chat store so chat-subscribe WS
    /// clients can attach immediately. Errors surface as 503 with
    /// structured CTA bodies the iOS Chat tab can map directly to
    /// user-facing prompts.
    private func handlePostGeminiChatSession(
        model: String?,
        effort: ReasoningEffort?,
        deepResearch: Bool = false,
        chatVendor: ChatVendor = .antigravity,
        billingProvider: String? = nil,
        connection: NWConnection
    ) async {
        let home = ClawdmeterRealHome.url()
        let projectsDir = home.appendingPathComponent(".gemini/config/projects", isDirectory: true)
        let lsClient = LanguageServerClient()
        let resolver = AntigravityProjectResolver(projectsDir: projectsDir)

        let install = await AntigravityInstall.preflight(
            forRepoKey: "",
            isLanguageServerLive: {
                if case .live = lsClient.discoverLive() { return true }
                return false
            },
            resolveProject: { _ in
                let projects = await resolver.allProjects()
                return projects.first?.id
            },
            homeDirectory: home,
            applicationsRoot: URL(fileURLWithPath: "/Applications", isDirectory: true)
        )

        let projectId: String
        switch install {
        case .absent:
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable", contentType: "application/json",
                body: Data(#"{"error":"antigravity_absent","cta":"Install Antigravity 2 from antigravity.google to start a Gemini chat."}"#.utf8)
            ), on: connection); return
        case .installedNotSignedIn:
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable", contentType: "application/json",
                body: Data(#"{"error":"antigravity_not_signed_in","cta":"Sign into Antigravity 2 first, then try again."}"#.utf8)
            ), on: connection); return
        case .appOnlyNotRunning:
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable", contentType: "application/json",
                body: Data(#"{"error":"antigravity_not_running","cta":"Open Antigravity 2 to start a Gemini chat."}"#.utf8)
            ), on: connection); return
        case .noProjectForRepo:
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable", contentType: "application/json",
                body: Data(#"{"error":"antigravity_no_projects","cta":"Open any repo in Antigravity 2 first — Clawdmeter Chat uses your first available project as a scratch workspace."}"#.utf8)
            ), on: connection); return
        case .ready(_, let resolvedProjectId):
            projectId = resolvedProjectId
        }

        // v0.23 (Chat V2 — T7 Gemini Deep Research): when DR is on,
        // pin the model to gemini-3-pro (max thinking) per the eng-
        // review D3 decision. Antigravity already enables WebSearch
        // by default in plan mode; the deep-research system prompt
        // we prepend to the first turn (below) drives the structured
        // research trace [research-step] convention. The user-picked
        // model is overridden because the trade is intentional:
        // Deep Research needs the heaviest reasoning, not whatever
        // model the user had selected for fast iteration.
        let effectiveModel = deepResearch ? "gemini-3-pro" : model
        let session: AgentSession
        do {
            session = try await registry.createChat(
                provider: .gemini,
                model: effectiveModel,
                chatCwd: "",
                effort: effort,
                deepResearch: deepResearch,
                chatVendor: chatVendor,
                billingProvider: billingProvider
            )
        } catch {
            serverLogger.error("createChat write-ahead failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection); return
        }
        let chatCwd: String
        do {
            let url = try ChatCwdManager.ensure(for: session.id)
            chatCwd = url.path
        } catch {
            serverLogger.error("agentapi chat-cwd create failed: \(error.localizedDescription, privacy: .public)")
            try? await registry.delete(id: session.id)
            sendResponse(.internalError, on: connection); return
        }
        try? await registry.updateRuntime(
            id: session.id, worktreePath: chatCwd,
            tmuxWindowId: nil, tmuxPaneId: nil, mode: .local
        )

        let modelTier = AgentapiModelTier.from(modelCatalogId: effectiveModel)
        // v0.23 T7 Gemini DR: prepend the deep-research contract as
        // the conversation's seed prompt so the agentapi initial-turn
        // ingests it before any user input. The bundled
        // deep-research-prompt.txt is the same contract Claude /
        // Codex SDK use — the `[research-step] N. ...` convention is
        // what the V2 UI's trace extractor reads.
        let seedPrompt: String = {
            guard deepResearch,
                  let header = AgentSpawner.loadDeepResearchPrompt() else {
                return "(starting new chat)"
            }
            return "\(header)\n\nYou are now ready to receive the user's research question."
        }()
        do {
            let conversationIdString = try await lsClient.newConversation(
                modelTier: modelTier,
                prompt: seedPrompt,
                projectId: projectId
            )
            guard let conversationId = UUID(uuidString: conversationIdString) else {
                serverLogger.error("agentapi returned non-UUID conversation id: \(conversationIdString, privacy: .public)")
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                sendResponse(.internalError, on: connection); return
            }
            try? await registry.setAntigravityChatBinding(
                id: session.id,
                conversationId: conversationId,
                projectId: projectId
            )
            let updated = registry.session(id: session.id) ?? session
            _ = chatStoreRegistry.snapshotStore(for: updated)
            AgentEventStream.recordEvent(sessionId: session.id, kind: .sessionCreated, payload: [
                "agent": "gemini",
                "geminiBackend": "agentapi",
                "conversationId": conversationId.uuidString,
                "projectId": projectId
            ])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let body = try? encoder.encode(updated) {
                sendResponse(HTTPResponse(
                    status: 201, reason: "Created",
                    contentType: "application/json", body: body
                ), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch let LanguageServerClientError.notRunning {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable", contentType: "application/json",
                body: Data(#"{"error":"antigravity_not_running","cta":"Open Antigravity 2 to continue this session"}"#.utf8)
            ), on: connection)
        } catch {
            // `error.localizedDescription` on a bare Swift Error enum returns
            // "(Module.Type error N.)" with a CASE INDEX, not the case name —
            // and Swift's NSError bridging orders payload-carrying cases
            // BEFORE payload-less ones, so reading the index against the
            // enum's source-order is misleading (e.g. "error 3" looks like
            // `binaryNotFound` but is actually `malformedResponse(String)`).
            // Render via `String(describing:)` so the associated payload
            // (stdout preview, stderr, exit code) shows up in /tmp/clawd.log.
            serverLogger.error("agentapi new-conversation failed: \(String(describing: error), privacy: .public)")
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
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
            argv = AgentSpawner.codexArgv(
                model: modelDefault,
                planMode: false,
                effort: defaults.effort,
                autopilot: false,
                resumeSessionId: cliSessionId,
                workspacePath: req.repoKey
            ) ?? []
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
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
        // ACP harness interrupt (Grok): the SessionInterruptDispatcher has no
        // handle on the harness registry, so cancel the live bridge here first.
        // Flip the turn state up front (mirrors the dispatcher) so the V2 UI's
        // Send button restores immediately, then cancel the in-flight ACP turn.
        if let grokSession = registry.session(id: uuid), grokSession.agent == .grok {
            chatStoreRegistry.snapshotStore(for: grokSession)?.setCurrentTurnState(.interrupted)
            if let bridge = harnessRegistry.bridge(for: uuid) {
                await bridge.cancel()
            }
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
        // v0.23 (Chat V2 — audit P0 #2): route through
        // SessionInterruptDispatcher so Stop works for Codex SDK and
        // Gemini agentapi sessions too, not just tmux-backed ones.
        // The dispatcher flips currentTurnState to .interrupted up
        // front so the V2 UI's stopwatch + Send button restore
        // immediately, then dispatches the per-backend cancel.
        let dispatcher = SessionInterruptDispatcher(
            registry: registry,
            codexRelay: CodexSubscriptionRelay.shared,
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
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
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
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
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

    // MARK: - Diff / PR / Merge / Terminals (Phase 4)

    private func handleGetDiff(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let gitBin = ShellRunner.locateBinary("git") else {
            sendResponse(.internalError, on: connection); return
        }
        do {
            let files = try await loadDiffFiles(session: session, gitBin: gitBin)
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(files) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            serverLogger.error("git diff failed: \(error.localizedDescription, privacy: .public)")
            if (error as NSError).code == 409 {
                sendResponse(HTTPResponse(
                    status: 409, reason: "Conflict",
                    contentType: "application/json",
                    body: Data(#"{"error":"Repo is in rebase/merge state, finish on Mac"}"#.utf8)
                ), on: connection)
                return
            }
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleGetDiffFile(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let gitBin = ShellRunner.locateBinary("git") else {
            sendResponse(.internalError, on: connection); return
        }
        guard let relPath = diffRelativePath(sessionId: sessionId, requestPath: request.path),
              isSafeGitRelativePath(relPath) else {
            sendResponse(.badRequest, on: connection); return
        }
        let context = diffContext(from: request.path)
        do {
            let numstat = try await ShellRunner.shared.run(
                executable: gitBin,
                arguments: ["diff", "--numstat", "HEAD", "--", relPath],
                cwd: session.effectiveCwd,
                timeout: 10
            )
            let counts = parseDiffCounts(numstat.stdoutString)
            let diff = try await ShellRunner.shared.run(
                executable: gitBin,
                arguments: ["diff", "--unified=\(context)", "HEAD", "--", relPath],
                cwd: session.effectiveCwd,
                timeout: 10
            )
            let file = ClawdmeterShared.GitDiffFile(
                path: relPath,
                status: "M",
                additions: counts.additions,
                deletions: counts.deletions,
                hunks: parseUnifiedDiffHunks(diff.stdoutString),
                truncated: false,
                changeState: nil
            )
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(file) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            serverLogger.error("git diff file failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleDiffAction(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let gitBin = ShellRunner.locateBinary("git") else {
            sendResponse(.internalError, on: connection); return
        }
        guard let relPath = diffActionRelativePath(sessionId: sessionId, requestPath: request.path),
              isSafeGitRelativePath(relPath) else {
            sendResponse(.badRequest, on: connection); return
        }
        let req = (try? JSONDecoder().decode(GitDiffActionRequest.self, from: request.body))
            ?? GitDiffActionRequest(action: .stageFile)
        do {
            switch req.action {
            case .stageFile:
                try await runGitDiffAction(gitBin: gitBin, cwd: session.effectiveCwd, arguments: ["add", "--", relPath])
            case .unstageFile:
                try await runGitDiffAction(gitBin: gitBin, cwd: session.effectiveCwd, arguments: ["restore", "--staged", "--", relPath])
            case .discardFile:
                if try await isUntracked(gitBin: gitBin, cwd: session.effectiveCwd, relPath: relPath) {
                    try trashUntrackedFile(cwd: session.effectiveCwd, relPath: relPath)
                } else {
                    try await runGitDiffAction(
                        gitBin: gitBin,
                        cwd: session.effectiveCwd,
                        arguments: ["restore", "--staged", "--worktree", "--", relPath]
                    )
                }
            }
            let files = try await loadDiffFiles(session: session, gitBin: gitBin)
            let receipt = req.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .acknowledged, processedAt: Date())
            }
            sendCodable(GitDiffActionResponse(ok: true, files: files, receipt: receipt), on: connection)
        } catch {
            sendCodable(GitDiffActionResponse(ok: false, error: "\(error)"), on: connection)
        }
    }

    private func loadDiffFiles(
        session: AgentSession,
        gitBin: String
    ) async throws -> [ClawdmeterShared.GitDiffFile] {
        let cwd = session.effectiveCwd
        // Refuse to diff mid-rebase/merge (Codex #11 / T11).
        if FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git/rebase-merge"))
            || FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git/MERGE_HEAD")) {
            throw NSError(
                domain: "AgentControlServer.Diff",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Repo is in rebase/merge state, finish on Mac"]
            )
        }
        let head = try await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["diff", "--numstat", "HEAD"],
            cwd: cwd,
            timeout: 10
        )
        let unstaged = try? await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["diff", "--numstat"],
            cwd: cwd,
            timeout: 10
        )
        let staged = try? await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["diff", "--cached", "--numstat"],
            cwd: cwd,
            timeout: 10
        )
        let status = try? await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["status", "--porcelain=v1", "-z"],
            cwd: cwd,
            timeout: 10
        )
        let unstagedPaths = Set(parseNumstatFiles(unstaged?.stdoutString ?? "").map(\.path))
        let stagedPaths = Set(parseNumstatFiles(staged?.stdoutString ?? "").map(\.path))
        let statusMap = parsePorcelainStatus(status?.stdout ?? Data())

        var seen = Set<String>()
        var files: [ClawdmeterShared.GitDiffFile] = parseNumstatFiles(head.stdoutString).map { item in
            seen.insert(item.path)
            let staged = stagedPaths.contains(item.path)
            let unstaged = unstagedPaths.contains(item.path)
            return ClawdmeterShared.GitDiffFile(
                path: item.path,
                status: statusMap[item.path] ?? "M",
                additions: item.additions,
                deletions: item.deletions,
                hunks: [],
                truncated: true,
                changeState: diffChangeState(staged: staged, unstaged: unstaged)
            )
        }

        let untracked = try? await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            cwd: cwd,
            timeout: 10
        )
        for path in parseNulSeparatedPaths(untracked?.stdout ?? Data()) where !seen.contains(path) {
            files.append(ClawdmeterShared.GitDiffFile(
                path: path,
                status: "A",
                additions: countTextLines(cwd: cwd, relPath: path),
                deletions: 0,
                hunks: [],
                truncated: true,
                changeState: "untracked"
            ))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func diffRelativePath(sessionId: String, requestPath: String) -> String? {
        let pathOnly = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestPath
        let prefix = "/sessions/\(sessionId)/diff/"
        guard pathOnly.hasPrefix(prefix) else { return nil }
        let encoded = String(pathOnly.dropFirst(prefix.count))
        return encoded.removingPercentEncoding
    }

    private func diffActionRelativePath(sessionId: String, requestPath: String) -> String? {
        let pathOnly = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestPath
        let prefix = "/sessions/\(sessionId)/diff-action/"
        guard pathOnly.hasPrefix(prefix) else { return nil }
        let encoded = String(pathOnly.dropFirst(prefix.count))
        return encoded.removingPercentEncoding
    }

    private func isSafeGitRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        guard !path.contains("\0"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func diffContext(from requestPath: String) -> Int {
        guard let comps = URLComponents(string: requestPath),
              let raw = comps.queryItems?.first(where: { $0.name == "context" })?.value,
              let value = Int(raw) else {
            return 80
        }
        return min(max(value, 0), 500)
    }

    private func runGitDiffAction(gitBin: String, cwd: String, arguments: [String]) async throws {
        let result = try await ShellRunner.shared.run(
            executable: gitBin,
            arguments: arguments,
            cwd: cwd,
            timeout: 15
        )
        guard result.exitStatus == 0 else {
            throw NSError(
                domain: "AgentControlServer.DiffAction",
                code: Int(result.exitStatus),
                userInfo: [NSLocalizedDescriptionKey: result.stderrString]
            )
        }
    }

    private func isUntracked(gitBin: String, cwd: String, relPath: String) async throws -> Bool {
        let result = try await ShellRunner.shared.run(
            executable: gitBin,
            arguments: ["ls-files", "--error-unmatch", "--", relPath],
            cwd: cwd,
            timeout: 10
        )
        return result.exitStatus != 0
    }

    private func trashUntrackedFile(cwd: String, relPath: String) throws {
        guard let fileURL = safeFileURL(cwd: cwd, relPath: relPath) else {
            throw NSError(
                domain: "AgentControlServer.DiffAction",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "unsafe path"]
            )
        }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
    }

    private func safeFileURL(cwd: String, relPath: String) -> URL? {
        guard isSafeGitRelativePath(relPath) else { return nil }
        let root = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(relPath).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return nil
        }
        return candidate
    }

    private func parseNulSeparatedPaths(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private struct DiffNumstatItem {
        let path: String
        let additions: Int
        let deletions: Int
    }

    private func parseNumstatFiles(_ stdout: String) -> [DiffNumstatItem] {
        stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return DiffNumstatItem(
                path: normalizeNumstatPath(parts[2]),
                additions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0
            )
        }
    }

    private func normalizeNumstatPath(_ path: String) -> String {
        // Rename numstat can emit "{old => new}/file"; fall back to the
        // post-image path when the compact rename syntax is obvious.
        guard let arrow = path.range(of: " => ") else { return path }
        var normalized = path
        normalized.removeSubrange(path.startIndex..<arrow.upperBound)
        normalized.removeAll { $0 == "{" || $0 == "}" }
        return normalized
    }

    private func parsePorcelainStatus(_ data: Data) -> [String: String] {
        let entries = parseNulSeparatedPaths(data)
        var out: [String: String] = [:]
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard entry.count >= 4 else {
                index += 1
                continue
            }
            let xy = String(entry.prefix(2))
            var path = String(entry.dropFirst(3))
            if (xy.contains("R") || xy.contains("C")), index + 1 < entries.count {
                index += 1
                path = entries[index]
            }
            out[path] = gitStatus(from: xy)
            index += 1
        }
        return out
    }

    private func gitStatus(from xy: String) -> String {
        if xy == "??" { return "A" }
        if xy.contains("R") { return "R" }
        if xy.contains("C") { return "C" }
        if xy.contains("A") { return "A" }
        if xy.contains("D") { return "D" }
        return "M"
    }

    private func diffChangeState(staged: Bool, unstaged: Bool) -> String {
        if staged && unstaged { return "mixed" }
        if staged { return "staged" }
        return "unstaged"
    }

    private func countTextLines(cwd: String, relPath: String) -> Int {
        guard let url = safeFileURL(cwd: cwd, relPath: relPath),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= 512_000,
              !data.contains(0) else {
            return 0
        }
        if data.isEmpty { return 0 }
        return data.reduce(0) { $1 == 10 ? $0 + 1 : $0 } + (data.last == 10 ? 0 : 1)
    }

    private func parseDiffCounts(_ stdout: String) -> (additions: Int, deletions: Int) {
        guard let line = stdout.split(separator: "\n").first else { return (0, 0) }
        let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }

    private func parseUnifiedDiffHunks(_ stdout: String) -> [ClawdmeterShared.GitDiffHunk] {
        var hunks: [ClawdmeterShared.GitDiffHunk] = []
        var currentHeader: String?
        var currentLines: [ClawdmeterShared.GitDiffHunk.Line] = []

        func flush() {
            guard let header = currentHeader else { return }
            hunks.append(ClawdmeterShared.GitDiffHunk(header: header, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix("@@") {
                flush()
                currentHeader = rawLine
                continue
            }
            guard currentHeader != nil else { continue }
            if rawLine.hasPrefix("+") {
                currentLines.append(.init(kind: .addition, text: String(rawLine.dropFirst())))
            } else if rawLine.hasPrefix("-") {
                currentLines.append(.init(kind: .deletion, text: String(rawLine.dropFirst())))
            } else if rawLine.hasPrefix(" ") {
                currentLines.append(.init(kind: .context, text: String(rawLine.dropFirst())))
            } else {
                currentLines.append(.init(kind: .context, text: rawLine))
            }
        }
        flush()
        return hunks
    }

    private func fetchPRStatus(cwd: String) async throws -> PRStatus? {
        guard let ghBin = ShellRunner.locateBinary("gh") else { return nil }
        let fields = [
            "url",
            "number",
            "title",
            "body",
            "state",
            "isDraft",
            "additions",
            "deletions",
            "changedFiles",
            "reviewDecision",
            "statusCheckRollup",
        ].joined(separator: ",")
        let result = try await ShellRunner.shared.run(
            executable: ghBin,
            arguments: ["pr", "view", "--json", fields],
            cwd: cwd,
            timeout: 20
        )
        guard result.exitStatus == 0 else {
            let stderr = result.stderrString.lowercased()
            if stderr.contains("no pull requests found")
                || stderr.contains("no open pull requests")
                || stderr.contains("could not find")
                || stderr.contains("not found") {
                return nil
            }
            throw NSError(
                domain: "AgentControlServer.PR",
                code: Int(result.exitStatus),
                userInfo: [NSLocalizedDescriptionKey: result.stderrString]
            )
        }
        guard let obj = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw NSError(
                domain: "AgentControlServer.PR",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not parse gh pr view JSON"]
            )
        }
        let isDraft = obj["isDraft"] as? Bool ?? false
        let state: PRStatus.State = {
            if isDraft { return .draft }
            switch (obj["state"] as? String ?? "").lowercased() {
            case "open": return .open
            case "merged": return .merged
            case "closed": return .closed
            default: return .open
            }
        }()
        let checksRollup = Self.checksRollup(from: obj["statusCheckRollup"])
        let mergeability: PRMergeability = {
            if state == .closed { return .blocked }
            if state == .merged { return .mergeable }
            switch checksRollup {
            case "failure", "pending": return .blocked
            default: return .mergeable
            }
        }()
        return PRStatus(
            url: obj["url"] as? String ?? "",
            number: obj["number"] as? Int ?? 0,
            title: obj["title"] as? String ?? "",
            body: obj["body"] as? String ?? "",
            state: state,
            additions: obj["additions"] as? Int ?? 0,
            deletions: obj["deletions"] as? Int ?? 0,
            changedFiles: obj["changedFiles"] as? Int ?? 0,
            reviewDecision: obj["reviewDecision"] as? String,
            checksRollup: checksRollup,
            checks: Self.checkMirrors(from: obj["statusCheckRollup"]),
            mergeability: mergeability,
            lastCheckedAt: Date()
        )
    }

    private static func checksRollup(from value: Any?) -> String? {
        guard let checks = value as? [[String: Any]], !checks.isEmpty else { return nil }
        var sawPending = false
        for check in checks {
            let status = ((check["status"] as? String) ?? "").lowercased()
            let conclusion = ((check["conclusion"] as? String) ?? "").lowercased()
            if ["failure", "failed", "timed_out", "cancelled", "action_required"].contains(conclusion) {
                return "failure"
            }
            if conclusion.isEmpty || status == "queued" || status == "in_progress" || status == "pending" {
                sawPending = true
            }
        }
        return sawPending ? "pending" : "success"
    }

    private static func checkMirrors(from value: Any?) -> [PRCheckMirror] {
        guard let checks = value as? [[String: Any]], !checks.isEmpty else { return [] }
        let formatter = ISO8601DateFormatter()
        return checks.enumerated().map { index, check in
            let name = (check["name"] as? String)
                ?? (check["workflowName"] as? String)
                ?? (check["context"] as? String)
                ?? "Check \(index + 1)"
            let status = ((check["status"] as? String) ?? "").lowercased()
            let conclusion = ((check["conclusion"] as? String) ?? "").lowercased()
            let state: PRCheckState
            if ["success", "passed"].contains(conclusion) {
                state = .success
            } else if ["failure", "failed", "timed_out", "cancelled", "action_required"].contains(conclusion) {
                state = .failure
            } else if ["skipped", "neutral"].contains(conclusion) {
                state = .skipped
            } else if conclusion.isEmpty || ["queued", "in_progress", "pending"].contains(status) {
                state = .pending
            } else {
                state = .unknown
            }
            let completedAt = (check["completedAt"] as? String).flatMap { formatter.date(from: $0) }
            let url = (check["detailsUrl"] as? String) ?? (check["targetUrl"] as? String)
            return PRCheckMirror(name: name, state: state, url: url, completedAt: completedAt)
        }
    }

    private func handleGetPR(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard ShellRunner.locateBinary("gh") != nil else {
            sendJSON(["error": "gh CLI not found on Mac. Install: brew install gh"], on: connection, status: 503)
            return
        }
        do {
            guard let status = try await fetchPRStatus(cwd: session.effectiveCwd) else {
                sendJSON(["pr": NSNull()], on: connection)
                return
            }
            sendCodable(status, on: connection)
        } catch {
            sendJSON(["error": "gh pr view failed", "detail": "\(error)"], on: connection, status: 502)
        }
    }

    private func handleCreatePR(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let req = (try? JSONDecoder().decode(CreatePRRequest.self, from: request.body)) ?? CreatePRRequest()
        let cwd = session.effectiveCwd
        guard let ghBin = ShellRunner.locateBinary("gh") else {
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"gh CLI not found on Mac. Install: brew install gh"}"#.utf8)
            ), on: connection); return
        }
        var args = ["pr", "create", "--fill"]
        if let title = req.title, !title.isEmpty { args += ["--title", title] }
        if let body = req.body, !body.isEmpty { args += ["--body", body] }
        if let base = req.baseBranch, !base.isEmpty { args += ["--base", base] }
        do {
            let result = try await ShellRunner.shared.run(
                executable: ghBin, arguments: args, cwd: cwd, timeout: 60
            )
            if result.exitStatus != 0 {
                let payload: [String: Any] = ["error": "gh pr create failed", "stderr": result.stderrString]
                let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                sendResponse(HTTPResponse(status: 500, reason: "Internal Server Error",
                                          contentType: "application/json", body: body), on: connection)
                return
            }
            let prURL = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            var payload: [String: Any] = ["url": prURL]
            if let key = req.idempotencyKey {
                payload["receipt"] = [
                    "idempotencyKey": key,
                    "status": MobileCommandStatus.acknowledged.rawValue,
                    "receivedAt": ISO8601DateFormatter().string(from: Date()),
                    "serverReceiptId": UUID().uuidString,
                ]
            }
            sendJSON(payload, on: connection)
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleReviewPR(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let ghBin = ShellRunner.locateBinary("gh") else {
            sendJSON(["error": "gh CLI not found on Mac. Install: brew install gh"], on: connection, status: 503)
            return
        }
        let req = (try? JSONDecoder().decode(PRReviewRequest.self, from: request.body)) ?? PRReviewRequest()
        var args = ["pr", "review"]
        switch req.action {
        case .approve:
            args.append("--approve")
        case .comment:
            args.append("--comment")
        case .requestChanges:
            args.append("--request-changes")
        }
        if let body = req.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            args += ["--body", body]
        }
        do {
            let result = try await ShellRunner.shared.run(
                executable: ghBin,
                arguments: args,
                cwd: session.effectiveCwd,
                timeout: 45
            )
            guard result.exitStatus == 0 else {
                sendCodable(PRReviewResponse(ok: false, error: result.stderrString), on: connection)
                return
            }
            let refreshed = try? await fetchPRStatus(cwd: session.effectiveCwd)
            let receipt = req.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .acknowledged, processedAt: Date())
            }
            sendCodable(PRReviewResponse(ok: true, pr: refreshed ?? nil, receipt: receipt), on: connection)
        } catch {
            sendCodable(PRReviewResponse(ok: false, error: "\(error)"), on: connection)
        }
    }

    private func handleMerge(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let cwd = session.effectiveCwd
        guard let ghBin = ShellRunner.locateBinary("gh") else {
            sendJSON(["error": "gh CLI not found on Mac. Install: brew install gh"], on: connection, status: 503)
            return
        }
        let mergeRequest = (try? JSONDecoder().decode(MergePRRequest.self, from: request.body)) ?? MergePRRequest()
        let explicitOverride = mergeRequest.adminOverride || request.path.contains("override=true")
        do {
            guard let pr = try await fetchPRStatus(cwd: cwd) else {
                sendJSON(["error": "No PR found for this branch"], on: connection, status: 404)
                return
            }
            if !explicitOverride {
                if pr.checksRollup == "failure" {
                    sendJSON(["error": "Checks are failing", "requireExplicitOverride": true], on: connection, status: 409)
                    return
                }
                if pr.checksRollup == "pending" {
                    sendJSON(["error": "Checks are still pending", "requireExplicitOverride": true], on: connection, status: 409)
                    return
                }
                if pr.state == .closed {
                    sendJSON(["error": "PR is closed"], on: connection, status: 409)
                    return
                }
                if pr.state == .merged {
                    let receipt = mergeRequest.idempotencyKey.map {
                        MobileCommandReceipt(idempotencyKey: $0, status: .acknowledged, processedAt: Date())
                    }
                    sendCodable(MergePRResponse(ok: true, merged: true, pr: pr, receipt: receipt), on: connection)
                    return
                }
            }
            var args = ["pr", "merge", String(pr.number)]
            switch mergeRequest.method {
            case .merge: args.append("--merge")
            case .squash: args.append("--squash")
            case .rebase: args.append("--rebase")
            }
            if mergeRequest.deleteBranch { args.append("--delete-branch") }
            if mergeRequest.auto { args.append("--auto") }
            if explicitOverride { args.append("--admin") }
            let result = try await ShellRunner.shared.run(
                executable: ghBin,
                arguments: args,
                cwd: cwd,
                timeout: 90
            )
            if result.exitStatus != 0 {
                sendJSON([
                    "ok": false,
                    "merged": false,
                    "error": "gh pr merge failed",
                    "stderr": result.stderrString,
                ], on: connection, status: 409)
                return
            }
            let refreshed = try? await fetchPRStatus(cwd: cwd)
            let receipt = mergeRequest.idempotencyKey.map {
                MobileCommandReceipt(idempotencyKey: $0, status: .acknowledged, processedAt: Date())
            }
            sendCodable(MergePRResponse(ok: true, merged: true, pr: refreshed ?? pr, receipt: receipt), on: connection)
        } catch {
            sendJSON(["ok": false, "merged": false, "error": "\(error)"], on: connection, status: 500)
        }
    }

    private func handleGetTerminals(sessionId: String, connection: NWConnection) {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(session.terminalPanes) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// GET /sessions/:id/artifact?path=<relative-or-abs>
    ///
    /// Streams an artifact file (PDF, image, doc) the agent wrote to the
    /// session's worktree. Path is path-component validated so callers
    /// can only read inside the session's worktree or repo. Cap at 50MB
    /// to keep the daemon responsive when an agent writes a giant file.
    private func handleGetArtifact(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let comps = URLComponents(string: request.path),
              let pathArg = comps.queryItems?.first(where: { $0.name == "path" })?.value,
              !pathArg.isEmpty else {
            sendResponse(.badRequest, on: connection); return
        }
        let repoCwd = session.effectiveCwd
        // Defense-in-depth: refuse to anchor on an empty or non-absolute
        // repoCwd. If the worktree/repo path is missing the prefix check
        // below degenerates (`hasPrefix("/")` matches every absolute
        // path) and the symlink resolve can't constrain anything either.
        guard !repoCwd.isEmpty, repoCwd.hasPrefix("/") else {
            sendResponse(.internalError, on: connection); return
        }
        let absolute: String = pathArg.hasPrefix("/")
            ? pathArg
            : (repoCwd as NSString).appendingPathComponent(pathArg)
        // Two-stage path safety:
        //   1. Canonicalize `..` / `~` / `//` via standardizingPath, then
        //      require the result to live under the repo root. Blocks
        //      `?path=../../../etc/passwd`.
        //   2. Resolve symlinks via `resolvingSymlinksInPath` and re-check
        //      the prefix. Blocks an agent (or anyone with worktree write
        //      access) from planting a symlink inside the worktree that
        //      points outside it. standardizingPath alone does NOT resolve
        //      symlinks, so without step 2 the read would follow the link.
        let repoStandard = (repoCwd as NSString).standardizingPath
        let canonical = (absolute as NSString).standardizingPath
        let resolved = (canonical as NSString).resolvingSymlinksInPath
        let repoResolved = (repoStandard as NSString).resolvingSymlinksInPath
        let underCanonicalRepo = canonical.hasPrefix(repoStandard + "/") || canonical == repoStandard
        let underResolvedRepo = resolved.hasPrefix(repoResolved + "/") || resolved == repoResolved
        guard underCanonicalRepo && underResolvedRepo else {
            sendResponse(HTTPResponse(
                status: 403, reason: "Forbidden",
                contentType: "text/plain",
                body: Data("path escapes session worktree\n".utf8)
            ), on: connection)
            return
        }
        let url = URL(fileURLWithPath: resolved)
        // v0.7.4 TOCTOU fix: validate-then-read had a window where an
        // agent with worktree write could swap the post-validate path
        // for a symlink before `Data(contentsOf:)` followed it. Use
        // POSIX `open(O_RDONLY | O_NOFOLLOW)` so any symlink at the
        // final component fails immediately, then `fstat` the live fd
        // to enforce the 50MB cap on the file we ACTUALLY have open.
        // This means the size check + read both operate on the same
        // inode — no race window.
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            // ELOOP (symlink at final component) → 403, anything else → 404.
            let code = errno == ELOOP ? 403 : 404
            let reason = errno == ELOOP ? "Forbidden" : "Not Found"
            let body = errno == ELOOP
                ? "symlink at artifact path is not allowed\n"
                : "artifact not found\n"
            sendResponse(HTTPResponse(
                status: code, reason: reason,
                contentType: "text/plain",
                body: Data(body.utf8)
            ), on: connection)
            return
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            sendResponse(.internalError, on: connection); return
        }
        // Require a regular file. fstat after open(NOFOLLOW) means S_IFLNK
        // never appears here, but reject anything that's not a regular file
        // (dirs, fifos, devices) defensively.
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            sendResponse(HTTPResponse(
                status: 403, reason: "Forbidden",
                contentType: "text/plain",
                body: Data("artifact path is not a regular file\n".utf8)
            ), on: connection)
            return
        }
        let size = Int(st.st_size)
        guard size <= 50_000_000 else {
            sendResponse(.notFound, on: connection); return
        }
        // Read the open fd. FileHandle takes ownership of closing, so
        // pass `closeOnDealloc: false` and let our `defer { close(fd) }`
        // win — double-close on a Foundation FileHandle is undefined.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else {
            sendResponse(.internalError, on: connection); return
        }
        sendResponse(.ok(contentType: contentType(for: url), body: data), on: connection)
    }

    /// GET /sessions/:id/markdown-document?path=<relative-or-abs>
    ///
    /// Read-only Markdown document fetch for iOS Code document tabs. This is
    /// intentionally separate from `/artifact`: artifact reads stay scoped to
    /// the session worktree, while generated review/plan Markdown often lives
    /// under `~/.gstack/projects/...` outside the workspace. The route still
    /// keeps document-specific guardrails so it cannot serve large, binary, or
    /// non-text files.
    private func handleGetMarkdownDocument(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let comps = URLComponents(string: request.path),
              let pathArg = comps.queryItems?.first(where: { $0.name == "path" })?.value,
              !pathArg.isEmpty else {
            sendResponse(.badRequest(detail: "missing document path"), on: connection); return
        }
        guard let path = Self.standardizedMarkdownDocumentPath(pathArg, relativeTo: session.effectiveCwd) else {
            sendResponse(.badRequest(detail: "invalid document path"), on: connection); return
        }
        let ext = (path as NSString).pathExtension
        guard ext.isEmpty || GeneratedArtifactDetector.isMarkdownPath(path) else {
            sendResponse(HTTPResponse(
                status: 415,
                reason: "Unsupported Media Type",
                contentType: "text/plain",
                body: Data("document path is not Markdown\n".utf8)
            ), on: connection)
            return
        }

        let resolved = (path as NSString).resolvingSymlinksInPath
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let code: Int
            let reason: String
            let body: String
            switch errno {
            case EACCES, EPERM, ELOOP:
                code = 403
                reason = "Forbidden"
                body = "document path is not readable\n"
            default:
                code = 404
                reason = "Not Found"
                body = "document not found\n"
            }
            sendResponse(HTTPResponse(
                status: code,
                reason: reason,
                contentType: "text/plain",
                body: Data(body.utf8)
            ), on: connection)
            return
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            sendResponse(.internalError, on: connection); return
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            sendResponse(HTTPResponse(
                status: 403,
                reason: "Forbidden",
                contentType: "text/plain",
                body: Data("document path is not a regular file\n".utf8)
            ), on: connection)
            return
        }
        let size = Int(st.st_size)
        guard size <= Self.markdownDocumentMaxBytes else {
            sendResponse(HTTPResponse(
                status: 413,
                reason: "Payload Too Large",
                contentType: "text/plain",
                body: Data("document is larger than 2 MB\n".utf8)
            ), on: connection)
            return
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else {
            sendResponse(.internalError, on: connection); return
        }
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            sendResponse(HTTPResponse(
                status: 415,
                reason: "Unsupported Media Type",
                contentType: "text/plain",
                body: Data("document is not readable UTF-8 Markdown text\n".utf8)
            ), on: connection)
            return
        }
        sendResponse(.ok(contentType: "text/markdown; charset=utf-8", body: data), on: connection)
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "json": return "application/json"
        case "txt", "log", "md": return "text/plain"
        case "html": return "text/html"
        case "csv": return "text/csv"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }

    private func handleAddTerminal(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid),
              let windowId = session.tmuxWindowId else {
            sendResponse(.notFound, on: connection); return
        }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        guard session.terminalPanes.count < 7 else {
            sendResponse(HTTPResponse(
                status: 409, reason: "Conflict",
                contentType: "application/json",
                body: Data(#"{"error":"terminal pane limit reached"}"#.utf8)
            ), on: connection)
            return
        }
        struct AddTerminalRequest: Codable { let title: String? }
        let req = (try? JSONDecoder().decode(AddTerminalRequest.self, from: request.body)) ?? AddTerminalRequest(title: nil)
        do {
            let paneId = try await tmux.splitWindow(
                windowId: windowId,
                cwd: session.effectiveCwd,
                horizontal: false
            )
            let pane = TerminalPaneRef(paneId: paneId, title: req.title ?? "", isPrimary: false)
            try await registry.addTerminalPane(sessionId: uuid, pane: pane)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let body = try? encoder.encode(pane) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleDeleteTerminal(sessionId: String, paneId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid),
              let pane = session.terminalPanes.first(where: { $0.id.uuidString == paneId }) else {
            sendResponse(.notFound, on: connection); return
        }
        if pane.isPrimary {
            sendResponse(.badRequest, on: connection); return
        }
        do {
            try await tmux.killPane(pane.paneId)
            try await registry.removeTerminalPane(sessionId: uuid, paneRefId: pane.id)
            sendJSON(["ok": true], on: connection)
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleRenameTerminal(sessionId: String, paneId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let paneUUID = UUID(uuidString: paneId),
              registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection); return
        }
        struct RenameTerminalRequest: Codable { let title: String? }
        guard let req = try? JSONDecoder().decode(RenameTerminalRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let title = (req.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let pane = try await registry.renameTerminalPane(sessionId: uuid, paneRefId: paneUUID, title: title) else {
                sendResponse(.notFound, on: connection); return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let body = try? encoder.encode(pane) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            sendResponse(.internalError, on: connection)
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

    /// ACP harness spawn (Grok in v1). Mirrors `handleSpawnOpencodeSession`:
    /// no tmux pane — we launch the agent as a piped stdio child and drive it
    /// over ACP via `AcpHarnessBridge`, projecting its event stream into the
    /// session's `SessionChatStore`. Two-phase failure contract (A3):
    /// `bridge.start()` throws synchronously on spawn/handshake/auth failure,
    /// so a failed start tears the write-ahead session back down and returns a
    /// real HTTP error instead of stranding a dead session.
    private func handleSpawnAcpSession(
        req: NewSessionRequest,
        support: AcpAgentSupport,
        cwd: String,
        worktreePath: String?,
        provisioning: WorktreeProvisioningMetadata?,
        provisionalSessionId: UUID?,
        connection: NWConnection
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

        // Step 3: build + start the bridge. Model/effort are launch-time only
        // for Grok, but the bundled catalog id ("grok-build") is a placeholder,
        // not a real CLI model — so v1 spawns with the agent's defaults and
        // defers model selection until we map `initialize.availableModels`.
        // alwaysApprove=false so the agent raises permission prompts we surface
        // (the point of being a harness, not a blind auto-runner).
        let bridge = AcpHarnessBridge(
            sessionId: session.id, support: support, store: store, model: req.model
        )
        do {
            try await bridge.start(
                binary: support.binaryName,
                arguments: support.spawnArgv(model: nil, effort: nil, alwaysApprove: false),
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

    // MARK: - D4: per-provider auto-revive RPC (wire v12)

    /// POST body for `/providers/:id/auto-revive`. The `:id` path
    /// component carries the AgentKind raw value (`claude`/`codex`/`gemini`);
    /// body carries `{"enabled": Bool}`. Forward-compat: an unknown id
    /// returns 400 (X3 unknown kinds aren't user-toggleable).
    private struct SetAutoReviveBody: Codable {
        let enabled: Bool
    }

    /// D4 (v0.17): handle `POST /providers/:id/auto-revive`. iOS Live tab
    /// sends a per-provider toggle here; the daemon dispatches to the
    /// matching AppModel.setAutoReviveEnabled via `setAutoReviveCallback`.
    /// Returns 200 with `{"ok": true}` on success, 400 on unknown
    /// provider, 503 if the callback isn't wired (test/Preview paths).
    private func handleSetAutoRevive(
        providerId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        // X3 / D4: only known AgentKind raws are accepted. `.unknown`
        // sessions never reach here from the iOS UI (the toggle isn't
        // rendered for unknown providers), and an arbitrary path id
        // should 400 rather than silently fall through to `.unknown`.
        guard let kind = AgentKind(rawValue: providerId),
              kind != .unknown else {
            sendResponse(
                .badRequest,
                on: connection
            )
            return
        }
        guard let body = try? JSONDecoder().decode(SetAutoReviveBody.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        guard let callback = setAutoReviveCallback else {
            // No AppRuntime wired (test harness / Preview) — surface a
            // 503 so the caller knows the daemon isn't ready instead of
            // pretending success.
            sendResponse(.internalError, on: connection)
            return
        }
        await MainActor.run {
            callback(kind, body.enabled)
        }
        serverLogger.info("auto-revive toggle: \(providerId, privacy: .public) → \(body.enabled, privacy: .public)")
        sendResponse(
            .ok(contentType: "application/json", body: Data(#"{"ok":true}"#.utf8)),
            on: connection
        )
    }

    // MARK: - Phase 10: ActivityKit push-token registration

    private struct RegisterPushTokenBody: Codable {
        let token: String
        let bundleId: String
    }

    private struct UnregisterPushTokenBody: Codable {
        let token: String
    }

    private func handleRegisterPushToken(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(RegisterPushTokenBody.self, from: request.body),
              !req.token.isEmpty, !req.bundleId.isEmpty else {
            sendResponse(.badRequest, on: connection); return
        }
        await MacAPNSPusher.shared.register(token: req.token, bundleId: req.bundleId)
        sendJSON(["ok": true, "registered": true], on: connection)
    }

    private func handleUnregisterPushToken(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(UnregisterPushTokenBody.self, from: request.body),
              !req.token.isEmpty else {
            sendResponse(.badRequest, on: connection); return
        }
        await MacAPNSPusher.shared.unregister(token: req.token)
        sendJSON(["ok": true], on: connection)
    }

    // MARK: - E6: remote-push (gateway) device token

    private struct RegisterAPNSDeviceTokenBody: Codable {
        /// 64 hex chars (Apple's APNS token format).
        let deviceToken: String
        /// iPhone bundle id — used to derive the APNS topic.
        let bundleId: String
        /// The pairing session id the iPhone is reporting under. The Mac
        /// uses this to scope the token under the current pairing.
        let sessionId: String
    }

    private struct UnregisterAPNSDeviceTokenBody: Codable {
        let sessionId: String
    }

    private func handleRegisterAPNSDeviceToken(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(RegisterAPNSDeviceTokenBody.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        // Basic schema validation — mirrors the Worker's `HEX_64` check
        // (`infra/apns-gateway/src/schema.ts:49`).
        let token = req.deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 64,
              token.unicodeScalars.allSatisfy({ ($0.value >= 0x30 && $0.value <= 0x39)
                                                || ($0.value >= 0x41 && $0.value <= 0x46)
                                                || ($0.value >= 0x61 && $0.value <= 0x66) }) else {
            sendResponse(.badRequest, on: connection); return
        }
        guard !req.bundleId.isEmpty, !req.sessionId.isEmpty else {
            sendResponse(.badRequest, on: connection); return
        }
        APNSPushDeviceTokenStore.shared.register(
            sessionId: req.sessionId,
            deviceToken: token,
            bundleId: req.bundleId
        )
        sendJSON(["ok": true, "registered": true], on: connection)
    }

    private func handleUnregisterAPNSDeviceToken(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(UnregisterAPNSDeviceTokenBody.self, from: request.body),
              !req.sessionId.isEmpty else {
            sendResponse(.badRequest, on: connection); return
        }
        APNSPushDeviceTokenStore.shared.purge(sessionId: req.sessionId)
        sendJSON(["ok": true], on: connection)
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

    // MARK: - Usage / Analytics endpoints

    /// Live UsageData snapshot for Claude + Codex, served from the
    /// AppModels' last-poll state. Lets the iPhone show fresh gauges
    /// over Tailscale without depending on iCloud KV sync (which
    /// requires a paid Apple Developer entitlement). Wire shape:
    /// `{claude: UsageData?, codex: UsageData?, lastChecked: Date}`.
    private func handleGetUsage(connection: NWConnection) {
        // Dual-shape envelope per E2/X1 contract: emit BOTH legacy
        // `{claude, codex}` top-level fields AND new `usage` dict. v5
        // clients read legacy; v6+ prefer dict with per-provider fallback
        // to legacy. Servers always emit both while wireVersion == 6
        // (legacy fields removed at v7, future v0.8).
        var dict: [String: UsageData] = [:]
        if let c = claudeModel?.usage { dict["claude"] = c }
        if let x = codexModel?.usage  { dict["codex"]  = x }
        if let g = geminiModel?.usage { dict["gemini"] = g }
        let payload = UsageEnvelope(
            claude: claudeModel?.usage,
            codex: codexModel?.usage,
            usage: dict,
            lastChecked: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(payload) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// Historical analytics snapshot — same data the Mac dashboard's
    /// Analytics view shows. Served verbatim so iPhone renders identical
    /// totals + daily chart + by-repo split. Replaces iCloud KV sync
    /// for users without a paid Apple Developer account.
    private func handleGetAnalytics(connection: NWConnection) {
        let snapshot = usageHistory?.snapshot ?? UsageHistorySnapshot.empty
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(snapshot) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    // v0.27.0: Design import-folder proxy (POST /design/import-folder)
    // removed along with the Design tab + Open Design daemon +
    // clawdmeter-bridge-host sidecar. `isSafeDesignImportBase(_:)` and
    // `allowedDesignBaseDirs()` (the allow-list guard) were stripped too.

    // MARK: - Transcript endpoint

    /// Parse a JSONL on the Mac and return its chat messages as JSON so
    /// the iPhone can render the actual conversation instead of just a
    /// JSONL path + last-write timestamp. Security: the path must live
    /// under `~/.claude/projects/` or `~/.codex/sessions/` — anything
    /// else returns 401 so a paired-but-malicious iPhone can't read
    /// arbitrary Mac files via the daemon.
    private func handleGetTranscript(path queryPath: String, connection: NWConnection) {
        guard let queryStart = queryPath.firstIndex(of: "?") else {
            sendResponse(.notFound, on: connection)
            return
        }
        let query = String(queryPath[queryPath.index(after: queryStart)...])
        var jsonlPath: String?
        var maxMessages = 200
        // v0.23 (Chat V2 — T13): `beforeId` paginates older messages.
        // The V2 transcript renders the most-recent 200 in memory;
        // when the user scrolls past the top edge it calls
        // `/transcript?path=&beforeId=<oldestRenderedId>&limit=200`
        // and prepends the returned window. Older Macs that don't
        // understand the param just return the tail as before — V2
        // clients detect "no older content" by comparing the returned
        // messages' ids to what they already hold.
        var beforeId: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let value = kv[1].removingPercentEncoding ?? kv[1]
            switch kv[0] {
            case "path": jsonlPath = value
            case "limit": maxMessages = max(1, min(200, Int(value) ?? 200))
            case "beforeId": beforeId = value.isEmpty ? nil : value
            default: break
            }
        }
        guard let jsonlPath else {
            sendResponse(.notFound, on: connection)
            return
        }
        let home = ClawdmeterRealHome.path()
        let allowedPrefixes = [
            home + "/.claude/projects/",
            home + "/.codex/sessions/",
        ]
        guard allowedPrefixes.contains(where: { jsonlPath.hasPrefix($0) }) else {
            serverLogger.warning("transcript: refusing read outside allow-list — \(jsonlPath, privacy: .public)")
            sendResponse(.unauthorized, on: connection)
            return
        }
        let url = URL(fileURLWithPath: jsonlPath)
        // v0.5.3: route through the daemon-owned chat-store registry so
        // burst polling reuses the parsed state instead of reparsing
        // 200 messages on every request. Cold miss falls back to the
        // legacy synchronous TranscriptLoader.load path; the store
        // warms up in the background and subsequent requests within
        // the 5-minute idle window hit the cache.
        let messages: [ChatMessage]
        let truncated: Bool
        if let beforeId {
            // Pagination: return the maxMessages messages immediately
            // before the client's oldest-rendered id. This is the only
            // path that may scan the full file; first open stays bounded
            // to the recent tail window.
            let page = TranscriptLoader.loadWindowBefore(
                from: url,
                beforeId: beforeId,
                limit: maxMessages
            )
            if page.cursorFound {
                messages = page.messages
                truncated = page.truncated
            } else {
                // beforeId not found — return empty (the cursor is from
                // a different transcript or already at head). Honest.
                messages = []
                truncated = false
            }
        } else {
            // Tail window — bounded to the same recent window the UI
            // renders. Warm registry snapshots avoid disk parsing; cold
            // fallback reverse-reads a tail chunk instead of loading the
            // full transcript.
            if let store = chatStoreRegistry.snapshotStore(forJSONLPath: url),
               !store.snapshot.messages.isEmpty {
                messages = store.snapshot.messages.suffix(maxMessages).map { $0 }
                truncated = store.hasOlderHistory || store.snapshot.messages.count > maxMessages
            } else {
                let page = TranscriptLoader.loadRecent(from: url, maxMessages: maxMessages)
                messages = page.messages
                truncated = page.truncated
            }
        }
        let envelope = TranscriptEnvelope(
            path: jsonlPath,
            messages: messages,
            truncated: truncated
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(envelope) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    // MARK: - Session endpoints (Phase 2)

    private func handleGetSessions(connection: NWConnection) {
        let sessions = registry.sessions
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(sessions) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    // MARK: - v16 workspaces

    /// `GET /workspaces` → `WorkspaceListResponse`. Wire v16+ only.
    private func handleListWorkspaces(connection: NWConnection) {
        let response = WorkspaceListResponse(workspaces: workspaceStore.all())
        sendCodable(response, on: connection)
    }

    /// `PATCH /workspaces/:id` body `UpdateWorkspaceDefaultsRequest`.
    /// Partial merge: omitted provider/file-copy fields are preserved.
    /// Returns the updated `CodeWorkspaceRecord`. 404 when no workspace
    /// matches the path id.
    private func handleUpdateWorkspaceDefaults(
        workspaceId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: workspaceId) else {
            sendResponse(.badRequest, on: connection); return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let req = try? decoder.decode(UpdateWorkspaceDefaultsRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        guard let updated = workspaceStore.updateDefaults(
            id: uuid,
            providerDefaults: req.providerDefaults,
            filesToCopy: req.filesToCopy
        ) else {
            sendResponse(.notFound, on: connection); return
        }
        // Inline the receipt into the response body so clients with a
        // pending outbox entry can match by idempotencyKey.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let recordData = try? encoder.encode(updated),
              var dict = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any]
        else {
            sendResponse(.internalError, on: connection); return
        }
        if let key = req.idempotencyKey {
            let receipt = MobileCommandReceipt(
                idempotencyKey: key,
                status: .acknowledged,
                processedAt: Date()
            )
            dict["receipt"] = receipt.jsonDictionary
        }
        sendJSON(dict, on: connection)
    }

    private func handleGetOneSession(sessionId: String, connection: NWConnection) {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(session) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleGetLifecycle(sessionId: String, connection: NWConnection) {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let snapshot = SessionLifecycleReducer.snapshot(
            for: session,
            checkpoints: storedCheckpoints(for: uuid).map(codeCheckpoint)
        )
        sendCodable(SessionLifecycleSnapshotResponse(snapshot: snapshot), on: connection)
    }

    // MARK: - v18 remote Code workbench

    private func handleGetRunProfile(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let snapshot = await codeRunProfiles.snapshot(
            session: session,
            messages: chatMessages(for: session)
        )
        sendCodable(CodeRunProfileResponse(profile: snapshot), on: connection)
    }

    private func handleStartRunProfile(
        sessionId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let body = request.body.isEmpty
            ? CodeRunProfileStartRequest()
            : (try? decoder.decode(CodeRunProfileStartRequest.self, from: request.body))
        guard let body else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let snapshot = await codeRunProfiles.start(
            session: session,
            command: body.command,
            messages: chatMessages(for: session)
        )
        sendCodable(CodeRunProfileResponse(profile: snapshot), on: connection)
    }

    private func handleStopRunProfile(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let snapshot = await codeRunProfiles.stop(
            session: session,
            messages: chatMessages(for: session)
        )
        sendCodable(CodeRunProfileResponse(profile: snapshot), on: connection)
    }

    private func handleRunProfileProxy(
        sessionId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let snapshot = await codeRunProfiles.snapshot(
            session: session,
            messages: chatMessages(for: session)
        )
        guard let target = proxiedRunProfileURL(
            from: request.path,
            sessionId: sessionId,
            detectedURL: snapshot.detectedURL
        ) else {
            sendResponse(.badRequest(detail: "no detected preview URL for run-profile proxy"), on: connection)
            return
        }
        do {
            var upstream = URLRequest(url: target)
            upstream.httpMethod = request.method
            upstream.httpBody = request.body.isEmpty ? nil : request.body
            if let accept = request.headers["accept"] {
                upstream.setValue(accept, forHTTPHeaderField: "Accept")
            }
            if let contentType = request.headers["content-type"] {
                upstream.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            if let userAgent = request.headers["user-agent"] {
                upstream.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            let (data, response) = try await URLSession.shared.data(for: upstream)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            sendResponse(
                HTTPResponse(
                    status: status,
                    reason: HTTPURLResponse.localizedString(forStatusCode: status),
                    contentType: contentType,
                    body: request.method.uppercased() == "HEAD" ? Data() : data
                ),
                on: connection
            )
        } catch {
            sendJSON(["error": error.localizedDescription], on: connection, status: 502)
        }
    }

    private func handleListCheckpoints(sessionId: String, connection: NWConnection) {
        guard let uuid = UUID(uuidString: sessionId),
              registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection)
            return
        }
        sendCodable(
            CodeCheckpointListResponse(checkpoints: storedCheckpoints(for: uuid).map(codeCheckpoint)),
            on: connection
        )
    }

    private func handleCreateCheckpoint(
        sessionId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let body = request.body.isEmpty
            ? CodeCheckpointCreateRequest()
            : (try? decoder.decode(CodeCheckpointCreateRequest.self, from: request.body))
        guard let body else {
            sendResponse(.badRequest, on: connection)
            return
        }
        do {
            let trimmedSummary = body.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let checkpoint = try await CheckpointService().createCheckpoint(
                session: session,
                summary: (trimmedSummary?.isEmpty == false) ? trimmedSummary : "Manual checkpoint"
            )
            recordCheckpoint(checkpoint)
            sendCodable(CodeCheckpointCreateResponse(checkpoint: codeCheckpoint(checkpoint)), on: connection)
        } catch {
            sendJSON(["error": error.localizedDescription], on: connection, status: 409)
        }
    }

    private func handlePrepareCheckpointRestore(
        sessionId: String,
        checkpointId: String,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let checkpointUUID = UUID(uuidString: checkpointId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        guard let checkpoint = storedCheckpoint(sessionId: uuid, checkpointId: checkpointUUID) else {
            sendResponse(.notFound, on: connection)
            return
        }
        do {
            let plan = try await CheckpointService().prepareRestore(checkpoint, session: session)
            recordCheckpoint(plan.safety)
            checkpointRestorePlans[plan.id] = plan
            sendCodable(
                CodeCheckpointRestorePreviewResponse(preview: codeRestorePreview(plan)),
                on: connection
            )
        } catch {
            sendJSON(["error": error.localizedDescription], on: connection, status: 409)
        }
    }

    private func handleRestoreCheckpoint(
        sessionId: String,
        checkpointId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) async {
        guard let uuid = UUID(uuidString: sessionId),
              let checkpointUUID = UUID(uuidString: checkpointId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let body = try? decoder.decode(CodeCheckpointRestoreRequest.self, from: request.body),
              let plan = checkpointRestorePlans[body.previewId],
              plan.target.id == checkpointUUID,
              plan.target.sessionId == uuid else {
            sendResponse(.badRequest(detail: "restore requires a current previewId for this checkpoint"), on: connection)
            return
        }
        do {
            try await CheckpointService().restore(plan, in: session.effectiveCwd)
            checkpointRestorePlans.removeValue(forKey: body.previewId)
            sendCodable(
                CodeCheckpointRestoreResponse(
                    restored: true,
                    checkpoint: codeCheckpoint(plan.target),
                    safety: codeCheckpoint(plan.safety)
                ),
                on: connection
            )
        } catch {
            sendJSON(["error": error.localizedDescription], on: connection, status: 409)
        }
    }

    private func chatMessages(for session: AgentSession) -> [ChatMessage] {
        chatStoreRegistry.snapshotStore(for: session)?.snapshot.messages ?? []
    }

    private func storedCheckpoints(for sessionId: UUID) -> [CheckpointStateSnapshot] {
        WorkbenchStateStore().load().checkpoints[sessionId] ?? []
    }

    private func storedCheckpoint(sessionId: UUID, checkpointId: UUID) -> CheckpointStateSnapshot? {
        storedCheckpoints(for: sessionId).first { $0.id == checkpointId }
    }

    private func recordCheckpoint(_ checkpoint: CheckpointStateSnapshot) {
        let store = WorkbenchStateStore()
        var snapshot = store.load()
        var checkpoints = snapshot.checkpoints[checkpoint.sessionId] ?? []
        checkpoints.removeAll { $0.id == checkpoint.id }
        checkpoints.append(checkpoint)
        snapshot.checkpoints[checkpoint.sessionId] = checkpoints
        store.save(snapshot)
        LifecycleWebSocketChannel.notifyCheckpointStateChanged(sessionId: checkpoint.sessionId)
    }

    private func codeCheckpoint(_ checkpoint: CheckpointStateSnapshot) -> CodeCheckpointSnapshot {
        CodeCheckpointSnapshot(
            id: checkpoint.id,
            sessionId: checkpoint.sessionId,
            refName: checkpoint.refName,
            turnId: checkpoint.turnId,
            createdAt: checkpoint.createdAt,
            summary: checkpoint.summary
        )
    }

    private func codeRestorePreview(_ plan: CheckpointRestorePlan) -> CodeCheckpointRestorePreview {
        CodeCheckpointRestorePreview(
            id: plan.id,
            target: codeCheckpoint(plan.target),
            safety: codeCheckpoint(plan.safety),
            diffStat: plan.diffStat,
            diffPatch: plan.diffPatch,
            patchTruncated: plan.patchTruncated,
            dirtyStatusLines: plan.dirtyStatusLines,
            untrackedOverwritePaths: plan.untrackedOverwritePaths,
            untrackedSnapshotPaths: plan.untrackedSnapshotPaths,
            blockingReasons: plan.blockingReasons
        )
    }

    private func proxiedRunProfileURL(
        from requestPath: String,
        sessionId: String,
        detectedURL: String?
    ) -> URL? {
        guard let detectedURL,
              var target = URLComponents(string: detectedURL) else {
            return nil
        }
        let pieces = requestPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathOnly = pieces.first.map(String.init) ?? requestPath
        let query = pieces.count > 1 ? String(pieces[1]) : nil
        let prefix = "/sessions/\(sessionId)/run-profile/proxy"
        guard pathOnly.hasPrefix(prefix) else { return target.url }
        var suffix = String(pathOnly.dropFirst(prefix.count))
        if suffix.isEmpty || suffix == "/" {
            if target.percentEncodedPath.isEmpty {
                target.percentEncodedPath = "/"
            }
            if query != nil {
                target.percentEncodedQuery = query
            }
        } else {
            if !suffix.hasPrefix("/") {
                suffix = "/" + suffix
            }
            target.percentEncodedPath = suffix
            target.percentEncodedQuery = query
        }
        return target.url
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
        let preflightArgv = req.agent == .opencode
            ? ["opencode-managed-session"]
            : AgentSpawner.argv(for: req, workspacePath: req.repoKey)
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
        var provisionalSessionId: UUID?
        if req.useWorktree {
            // Mint a city up front so the worktree path + branch use the
            // same name. The session id we'll register with is captured
            // here so CityNamer's mapping is stable.
            let sessionId = UUID()
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

        // ACP harness providers (Grok) bypass tmux entirely: we spawn the
        // agent as a piped stdio child and drive it over ACP. Like opencode,
        // this branch owns its own session-create + response, so it returns
        // before the tmux argv/spawn path below.
        if req.agent == .grok {
            await handleSpawnAcpSession(
                req: req,
                support: GrokAcpSupport(),
                cwd: cwd,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId,
                connection: connection
            )
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

        // Spawn into a new tmux window.
        do {
            try await tmux.start()  // idempotent
            let resolvedEnv = try resolveRepoEnv(repoRoot: req.repoKey, cwd: cwd)
            let window = try await tmux.newWindow(
                cwd: cwd,
                child: argv,
                environment: resolvedEnv?.environment ?? [:]
            )
            // Phase 2 simplification: pane id = first pane of the new window.
            // tmux's `list-windows -F '#{pane_id}'` would tell us, but we
            // derive it lazily for now.
            let session = try await registry.create(
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
            let warmupSession = session
            let warmupPane = window.paneId
            let warmupTask = Task { [weak self] in
                await self?.warmupCLIPane(session: warmupSession, paneId: warmupPane)
                await MainActor.run { [weak self] in
                    self?.chatWarmupTasks[warmupSession.id] = nil
                }
            }
            chatWarmupTasks[session.id] = warmupTask
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

    // MARK: - v0.8 Chat tab (wire v9)

    private struct ResolvedChatRuntimeMetadata {
        let vendor: ChatVendor
        let billingProvider: String?
        let codexBackend: CodexChatBackend?
    }

    private enum ChatRuntimeValidationError: Error {
        case unknownProvider(AgentKind)
        case vendorProviderMismatch(provider: AgentKind, vendor: ChatVendor)
        case billingProviderMismatch(vendor: ChatVendor, expected: String?, actual: String)
    }

    private func resolveChatRuntimeMetadata(
        provider: AgentKind,
        requestedVendor: ChatVendor?,
        requestedBillingProvider: String?,
        requestedCodexBackend: CodexChatBackend?
    ) throws -> ResolvedChatRuntimeMetadata {
        guard let vendor = requestedVendor ?? ChatVendor.migrated(from: provider) else {
            throw ChatRuntimeValidationError.unknownProvider(provider)
        }
        guard vendor.backingProvider == provider else {
            throw ChatRuntimeValidationError.vendorProviderMismatch(provider: provider, vendor: vendor)
        }

        let normalizedBilling = requestedBillingProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedBilling = (normalizedBilling?.isEmpty == false) ? normalizedBilling : nil
        let expectedBilling = canonicalBillingProvider(for: vendor)
        if let requestedBilling, requestedBilling != expectedBilling {
            throw ChatRuntimeValidationError.billingProviderMismatch(
                vendor: vendor,
                expected: expectedBilling,
                actual: requestedBilling
            )
        }

        let codexBackend = provider == .codex
            ? (requestedCodexBackend ?? vendor.codexBackend ?? .sdk)
            : nil
        return ResolvedChatRuntimeMetadata(
            vendor: vendor,
            billingProvider: expectedBilling,
            codexBackend: codexBackend
        )
    }

    private func canonicalBillingProvider(for vendor: ChatVendor) -> String? {
        if let explicit = vendor.billingProvider {
            return explicit
        }
        switch vendor.backingProvider {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "antigravity"
        case .cursor: return "cursor"
        case .opencode: return "opencode"
        case .grok: return "grok"
        case .unknown: return nil
        }
    }

    private func sendChatRuntimeValidationError(
        _ error: ChatRuntimeValidationError,
        on connection: NWConnection
    ) {
        var body: [String: Any] = ["error": "invalid_chat_runtime_metadata"]
        switch error {
        case .unknownProvider(let provider):
            body["provider"] = provider.rawValue
            body["reason"] = "provider has no chat vendor mapping"
        case .vendorProviderMismatch(let provider, let vendor):
            body["provider"] = provider.rawValue
            body["chatVendor"] = vendor.rawValue
            body["expectedProvider"] = vendor.backingProvider.rawValue
            body["reason"] = "chatVendor does not match provider"
        case .billingProviderMismatch(let vendor, let expected, let actual):
            body["chatVendor"] = vendor.rawValue
            body["billingProvider"] = actual
            if let expected {
                body["expectedBillingProvider"] = expected
            } else {
                body["expectedBillingProvider"] = NSNull()
            }
            body["reason"] = "billingProvider must be derived by the server for the selected chatVendor"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(HTTPResponse(
            status: 400,
            reason: "Bad Request",
            contentType: "application/json",
            body: data
        ), on: connection)
    }

    private func chatRuntimeValidationMessage(_ error: ChatRuntimeValidationError) -> String {
        switch error {
        case .unknownProvider(let provider):
            return "invalid_chat_runtime_metadata: provider \(provider.rawValue) has no chat vendor mapping"
        case .vendorProviderMismatch(let provider, let vendor):
            return "invalid_chat_runtime_metadata: chatVendor \(vendor.rawValue) does not match provider \(provider.rawValue)"
        case .billingProviderMismatch(let vendor, let expected, let actual):
            let expectedText = expected ?? "nil"
            return "invalid_chat_runtime_metadata: billingProvider \(actual) does not match \(expectedText) for \(vendor.rawValue)"
        }
    }

    private func frontierProviderUnavailableReason(
        provider: AgentKind,
        codexBackend: CodexChatBackend?
    ) async -> String? {
        switch provider {
        case .cursor, .opencode:
            return await chatProviderUnavailableReason(provider: provider, codexBackend: codexBackend)
        default:
            return nil
        }
    }

    /// `POST /chat-sessions`: spawn a new chat-kind AgentSession in an
    /// empty per-session chat-cwd. Forces plan-mode. Branches on
    /// (agent, codexChatBackend) per RE1. Gemini chat dispatches through
    /// Antigravity 2 agentapi when the paired Mac supports wire v11+.
    private func handlePostChatSession(request: HTTPRequest, connection: NWConnection) async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let req = try? decoder.decode(CreateChatSessionRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        let metadata: ResolvedChatRuntimeMetadata
        do {
            metadata = try resolveChatRuntimeMetadata(
                provider: req.provider,
                requestedVendor: req.chatVendor,
                requestedBillingProvider: req.billingProvider,
                requestedCodexBackend: req.codexChatBackend
            )
        } catch let error as ChatRuntimeValidationError {
            sendChatRuntimeValidationError(error, on: connection)
            return
        } catch {
            sendResponse(.badRequest, on: connection)
            return
        }
        if let reason = providerDisabledReason(provider: req.provider, vendor: metadata.vendor) {
            sendProviderDisabled(provider: req.provider, reason: reason, on: connection)
            return
        }
        // v0.9: Gemini chat dispatches to Antigravity 2's agentapi via
        // a new daemon-side handler. Chat has no repoKey, so the helper
        // picks the first available Antigravity project as a scratch
        // workspace. Surfaces 503 with structured CTA bodies when
        // Antigravity isn't installed / signed in / running / has no
        // projects open. agentapi-via-chat is live behind the wire v11 /
        // antigravityChatMinimum=11 gate.
        if req.provider == .gemini {
            await handlePostGeminiChatSession(
                model: req.model,
                effort: req.effort,
                deepResearch: req.deepResearch,
                chatVendor: metadata.vendor,
                billingProvider: metadata.billingProvider,
                connection: connection
            )
            return
        }
        if req.provider == .opencode {
            await handlePostOpencodeChatSession(request: req, metadata: metadata, connection: connection)
            return
        }
        if req.provider == .cursor,
           let reason = await chatProviderUnavailableReason(provider: .cursor) {
            sendChatProviderUnavailable(provider: .cursor, reason: reason, on: connection)
            return
        }
        // Determine the Codex backend choice for this session. For non-
        // Codex providers, leave it nil. For Codex, honor the per-request
        // override if present; otherwise fall back to the global default
        // (RE1: ship .sdk as the v0.8 default).
        let codexBackend = metadata.codexBackend
        // Create the session record first (assigns a UUID we can use to
        // name the chat-cwd). v0.23 (Chat V2): persist deepResearch on
        // the session so respawn/restore preserves it (Codex outside-
        // voice review P1 #6).
        let session: AgentSession
        do {
            session = try await registry.createChat(
                provider: req.provider,
                model: req.model,
                chatCwd: "",  // placeholder; we'll patch it post-cwd-creation
                codexChatBackend: codexBackend,
                effort: req.effort,
                deepResearch: req.deepResearch,
                chatVendor: metadata.vendor,
                billingProvider: metadata.billingProvider
            )
        } catch {
            serverLogger.error("createChat write-ahead failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection); return
        }
        let chatCwd: String
        do {
            let url = try ChatCwdManager.ensure(for: session.id)
            chatCwd = url.path
        } catch {
            serverLogger.error("chat-cwd create failed for \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? await registry.delete(id: session.id)
            sendResponse(.internalError, on: connection)
            return
        }
        // Patch the worktreePath on the created session so effectiveCwd
        // resolves to the chat-cwd. The createChat helper stored it as
        // empty-string; rewrite via the existing update pattern.
        try? await registry.updateRuntime(
            id: session.id,
            worktreePath: chatCwd,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            mode: .local
        )
        // Spawn dispatch — Phase 3 dispatch handles the kind branches.
        // For SDK chat (codex + .sdk) argv is empty and the daemon needs
        // to route to CodexSubscriptionRelay; Phase 4.5 wires that. For
        // CLI chat (claude / codex+.cli) we spawn a tmux window now.
        let updatedSession = registry.session(id: session.id) ?? session
        let argv = AgentSpawner.argv(for: updatedSession)
        if argv.isEmpty && updatedSession.agent == .codex && updatedSession.codexChatBackend == .sdk {
            // SDK chat: pre-create the SDK-only SessionChatStore via the
            // registry so `chat-subscribe` WS subscribers and
            // `/chat-snapshot` HTTP polls can find it immediately. The
            // actual CodexSubscriptionRelay.start() is deferred until the
            // first /send (we don't have an initial prompt at create
            // time, and the SDK requires one to begin streaming).
            _ = chatStoreRegistry.snapshotStore(for: updatedSession)
        } else if argv.isEmpty {
            // No binary on PATH for this provider — clean up + surface 503.
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"agent_cli_not_found"}"#.utf8)
            ), on: connection)
            return
        } else {
            // CLI chat path: spawn tmux window in the chat-cwd. v0.8 QA
            // surfaced a wedged-tmux scenario where tmux.newWindow hung
            // forever — the handler never returned, AgentSession +
            // chat-cwd were left orphaned in the registry. Use a
            // continuation-race timeout that returns even when the
            // underlying tmux await is unrecoverably stuck (Swift Task
            // cancellation is cooperative; tmux.command's
            // withCheckedThrowingContinuation never resumes on a wedged
            // PTY). The spawn task may leak if tmux stays wedged, but
            // leaking one wrapping Task is much better than leaking a
            // registry entry + chat-cwd dir + a confused user.
            let tmuxRef = self.tmux
            let spawnResult: (windowId: String, paneId: String)? = await withCheckedContinuation { (cont: CheckedContinuation<(String, String)?, Never>) in
                let resumedBox = ResumeOnceBox()
                Task {
                    do {
                        try await tmuxRef.start()
                        let window = try await tmuxRef.newWindow(cwd: chatCwd, child: argv)
                        if resumedBox.tryClaim() { cont.resume(returning: (window.windowId, window.paneId)) }
                    } catch {
                        if resumedBox.tryClaim() { cont.resume(returning: nil) }
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if resumedBox.tryClaim() { cont.resume(returning: nil) }
                }
            }
            guard let spawn = spawnResult else {
                serverLogger.error("chat spawn failed or timed out for \(session.id.uuidString, privacy: .public) — tmux unresponsive after 10s")
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                sendResponse(HTTPResponse(
                    status: 504, reason: "Gateway Timeout",
                    contentType: "application/json",
                    body: Data(#"{"error":"tmux_unresponsive","hint":"Quit Clawdmeter and relaunch; if the issue persists, kill any stale tmux processes with: pkill -9 -f tmux"}"#.utf8)
                ), on: connection)
                return
            }
            try? await registry.updateRuntime(
                id: session.id,
                worktreePath: chatCwd,
                tmuxWindowId: spawn.windowId,
                tmuxPaneId: spawn.paneId,
                mode: .local
            )
            // v0.8 QA: dismiss Codex CLI's in-pane prompts (update, trust)
            // and any Claude TUI welcome that swallows the first keystroke.
            // Runs in the background so chat-session creation returns
            // immediately — handleSendPrompt awaits the task before pasting
            // so the user's first send doesn't race the dismissal.
            let warmupSession = registry.session(id: session.id) ?? session
            let warmupPane = spawn.paneId
            let warmupTask = Task { [weak self] in
                await self?.warmupCLIPane(session: warmupSession, paneId: warmupPane)
                await MainActor.run { [weak self] in
                    self?.chatWarmupTasks[warmupSession.id] = nil
                }
            }
            chatWarmupTasks[session.id] = warmupTask
        }
        AgentEventStream.recordEvent(
            sessionId: session.id, kind: .sessionCreated,
            payload: ["chat": "true", "provider": req.provider.rawValue]
        )
        let finalSession = registry.session(id: session.id) ?? session
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(finalSession) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handlePostOpencodeChatSession(
        request req: CreateChatSessionRequest,
        metadata: ResolvedChatRuntimeMetadata,
        connection: NWConnection
    ) async {
        if let reason = await chatProviderUnavailableReason(provider: .opencode) {
            sendChatProviderUnavailable(provider: .opencode, reason: reason, on: connection)
            return
        }
        guard let _ = await OpencodeProcessManager.shared.ensureRunning() else {
            let body: String
            switch OpencodeProcessManager.shared.state {
            case .notInstalled:
                body = #"{"error":"opencode_not_installed","hint":"Install OpenCode, then add an OpenRouter key in Settings."}"#
            case .failed(let detail):
                body = #"{"error":"opencode_serve_failed","detail":"\#(detail)"}"#
            default:
                body = #"{"error":"opencode_not_running"}"#
            }
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(body.utf8)
            ), on: connection)
            return
        }

        OpencodeSSEAdapter.shared.start()
        if OpencodeSSEAdapter.shared.chatStoreAccessor == nil {
            let registry = self.registry
            let chatStoreRegistry = self.chatStoreRegistry
            OpencodeSSEAdapter.shared.chatStoreAccessor = { [weak registry, weak chatStoreRegistry] uuid in
                guard let registry, let chatStoreRegistry else { return nil }
                guard let session = registry.session(id: uuid) else { return nil }
                return chatStoreRegistry.acquire(for: session)
            }
        }

        let vendor = metadata.vendor
        let session: AgentSession
        do {
            session = try await registry.createChat(
                provider: .opencode,
                model: req.model,
                chatCwd: "",
                effort: req.effort,
                deepResearch: req.deepResearch,
                chatVendor: vendor,
                billingProvider: metadata.billingProvider
            )
        } catch {
            serverLogger.error("createChat write-ahead failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection); return
        }
        let chatCwd: String
        do {
            let url = try ChatCwdManager.ensure(for: session.id)
            chatCwd = url.path
        } catch {
            try? await registry.delete(id: session.id)
            sendResponse(.internalError, on: connection)
            return
        }
        try? await registry.updateRuntime(
            id: session.id,
            worktreePath: chatCwd,
            runtimeCwd: .some(chatCwd),
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            mode: .local
        )

        guard var sessionReq = await OpencodeProcessManager.shared.makeAuthorizedRequest(
            path: "/session",
            directory: chatCwd
        ) else {
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(.internalError, on: connection)
            return
        }
        sessionReq.httpMethod = "POST"
        sessionReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let title = req.model.map { "\(vendor.displayName) - \($0)" } ?? "Chat - \(vendor.displayName)"
        sessionReq.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": String(title.prefix(60))
        ])

        let opencodeID: String
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: sessionReq)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                sendResponse(.internalError, on: connection)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String else {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                sendResponse(.internalError, on: connection)
                return
            }
            opencodeID = id
        } catch {
            serverLogger.error("opencode chat /session POST failed: \(error.localizedDescription, privacy: .public)")
            try? await registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(.internalError, on: connection)
            return
        }

        let updated = registry.session(id: session.id) ?? session
        OpencodeSSEAdapter.shared.register(
            clawdmeterID: updated.id,
            opencodeID: opencodeID,
            repo: chatCwd
        )
        _ = chatStoreRegistry.snapshotStore(for: updated)
        AgentEventStream.recordEvent(
            sessionId: updated.id,
            kind: .sessionCreated,
            payload: [
                "chat": "true",
                "provider": "opencode",
                "chatVendor": vendor.rawValue,
                "opencodeID": opencodeID
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(updated) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func chatProviderUnavailableReason(
        provider: AgentKind,
        codexBackend: CodexChatBackend? = nil
    ) async -> String? {
        let response = await ChatProviderProbe.shared.currentProviders()
        let row = response.providers.first {
            guard $0.provider == provider else { return false }
            guard let codexBackend else { return true }
            return $0.codexBackend == codexBackend
        }
        guard let row else {
            return "Provider probe did not return \(provider.rawValue)"
        }
        guard row.available, row.authenticated, row.capabilityProbePassed else {
            return row.reason ?? "\(provider.rawValue) is unavailable"
        }
        return nil
    }

    private func providerDisabledReason(provider: AgentKind, vendor: ChatVendor? = nil) -> String? {
        guard ProviderEnablement.isEnabled(provider) else {
            return "Enable \(vendor?.displayName ?? providerDisplayName(provider)) in Settings → Providers."
        }
        return nil
    }

    private func providerDisplayName(_ provider: AgentKind) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        case .gemini: return "Antigravity"
        case .cursor: return "Cursor"
        case .opencode: return "OpenRouter"
        case .grok: return "Grok"
        case .unknown: return "this provider"
        }
    }

    private func sendProviderDisabled(provider: AgentKind, reason: String, on connection: NWConnection) {
        let body = [
            "error": "provider_disabled",
            "provider": provider.rawValue,
            "reason": reason,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(HTTPResponse(
            status: 403,
            reason: "Forbidden",
            contentType: "application/json",
            body: data
        ), on: connection)
    }

    private func sendChatProviderUnavailable(provider: AgentKind, reason: String, on connection: NWConnection) {
        let body = [
            "error": "chat_provider_unavailable",
            "provider": provider.rawValue,
            "reason": reason,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(HTTPResponse(
            status: 503,
            reason: "Service Unavailable",
            contentType: "application/json",
            body: data
        ), on: connection)
    }

    /// `GET /chat-providers`: returns the per-provider availability +
    /// auth + capability-probe state per DG4. v0.8 ships a minimal
    /// implementation that checks binary-on-PATH; the full P1-actor
    /// ChatProviderProbe + CM3 ChatProviderAuthObserver land in v0.8.x
    /// polish phase. Gemini row is hardcoded `available: false, reason:
    /// "v0.9"` until Antigravity (agy) replacement ships.
    private func handleGetChatProviders(connection: NWConnection) async {
        // v0.9.x: delegate to the ChatProviderProbe actor. Cache +
        // in-flight de-dup live there now; the inline binary checks
        // are gone. Auth state reflects ChatProviderAuthObserver
        // overrides (Claude/Codex stderr + JSONL parsers, Antigravity
        // agentapi 401 catch) when set.
        let resp = await ChatProviderProbe.shared.currentProviders()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(resp) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleRefreshChatProviders(connection: NWConnection) async {
        await ChatProviderProbe.shared.invalidate()
        await OpenRouterModelProbe.shared.invalidate()
        await CursorModelProbe.shared.invalidate()
        await handleGetChatProviders(connection: connection)
    }

    /// Frontier handlers. These routes create live sibling chat sessions,
    /// stream per-slot state, and persist winner choices for the comparison UI.
    // MARK: - v0.9 Frontier handlers

    /// POST /chat-sessions/frontier — spawn 2-3 sibling chat sessions
    /// sharing a `frontierGroupId`, one per `FrontierModelSlot` in the
    /// request. Returns per-slot results (E2): each spawn is independent
    /// so a partial Frontier (e.g. Gemini fails because Antigravity isn't
    /// running) still surfaces the live slots + the failure reason.
    /// CM5: replays the cached response when `clientRequestId` repeats.
    private func handlePostFrontier(request: HTTPRequest, connection: NWConnection) async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let req = try? decoder.decode(CreateFrontierRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        // CM5 idempotency: if we've seen this clientRequestId before,
        // return the cached response verbatim.
        if let cached = frontierGroupIdempotency[req.clientRequestId] {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            if let body = try? encoder.encode(cached.response) {
                sendResponse(HTTPResponse(
                    status: 200, reason: "OK (idempotent replay)",
                    contentType: "application/json", body: body
                ), on: connection)
                return
            }
        }
        // Slot count guard: 2-3 per v0.9 spec.
        guard (2...3).contains(req.models.count) else {
            sendResponse(HTTPResponse(
                status: 400, reason: "Bad Request",
                contentType: "application/json",
                body: Data(#"{"error":"frontier_slot_count","reason":"frontier requires 2-3 slots"}"#.utf8)
            ), on: connection)
            return
        }

        let groupId = UUID()
        var slotResults: [FrontierSlotResult] = []
        for (idx, slot) in req.models.enumerated() {
            do {
                let session = try await spawnFrontierChild(
                    groupId: groupId,
                    childIndex: idx,
                    slot: slot
                )
                slotResults.append(FrontierSlotResult(index: idx, sessionId: session.id, reason: nil))
            } catch let SpawnFailure.message(reason) {
                slotResults.append(FrontierSlotResult(index: idx, sessionId: nil, reason: reason))
            } catch {
                slotResults.append(FrontierSlotResult(index: idx, sessionId: nil, reason: error.localizedDescription))
            }
        }
        let response = CreateFrontierResponse(groupId: groupId, slots: slotResults)
        // Cache for CM5 replay. Trim oldest entries when crossing 256.
        frontierGroupIdempotency[req.clientRequestId] = (groupId, response, Date())
        if frontierGroupIdempotency.count > 256 {
            let cutoff = frontierGroupIdempotency.values
                .sorted { $0.createdAt < $1.createdAt }
                .prefix(64)
                .map { $0.groupId }
            frontierGroupIdempotency = frontierGroupIdempotency.filter {
                !cutoff.contains($0.value.groupId)
            }
        }
        frontierUpdateCounters[groupId] = 1
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(response) {
            sendResponse(HTTPResponse(
                status: 201, reason: "Created",
                contentType: "application/json", body: body
            ), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// POST /chat-sessions/frontier/:groupId/send — fan out the prompt
    /// to every live (non-archived) child. Each child is a regular chat
    /// session so we reuse the existing /sessions/:id/send semantics by
    /// dispatching to the underlying send logic per child.
    ///
    /// v0.23.9: accepts both `FrontierSendRequest` (preferred — supports
    /// per-child text overrides for broadcast attachments) and the
    /// legacy `SendPromptRequest` shape for back-compat with the
    /// smoke script + first iOS build.
    private func handleFrontierSend(
        request: HTTPRequest,
        connection: NWConnection,
        groupId: String
    ) async {
        guard let uuid = UUID(uuidString: groupId) else {
            sendResponse(.badRequest, on: connection); return
        }
        // Frontier sends must only hit live children. Archived siblings
        // (e.g. losers after a pick-winner) keep their JSONL for the
        // history sidebar but should never receive new prompts.
        let children = registry.frontierGroupChildren(groupId: uuid)
        guard !children.isEmpty else {
            sendResponse(.notFound, on: connection); return
        }
        let decoder = JSONDecoder()
        let frontierReq = try? decoder.decode(FrontierSendRequest.self, from: request.body)
        let legacyReq = frontierReq == nil ? try? decoder.decode(SendPromptRequest.self, from: request.body) : nil
        let sharedText: String
        let perChild: [String: String]?
        if let frontierReq {
            sharedText = frontierReq.text
            perChild = frontierReq.perChildText
        } else if let legacyReq {
            sharedText = legacyReq.text
            perChild = nil
        } else {
            sendResponse(.badRequest, on: connection); return
        }
        var results: [FrontierChildSendResult] = []
        for child in children {
            let text = perChild?[child.id.uuidString] ?? sharedText
            results.append(await forwardFrontierChildSend(session: child, text: text))
        }
        let response = FrontierSendResponse(groupId: uuid, childCount: children.count, results: results)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = (try? encoder.encode(response)) ?? Data("{\"ok\":false}".utf8)
        sendResponse(HTTPResponse(
            status: 202, reason: "Accepted",
            contentType: "application/json",
            body: body
        ), on: connection)
        if let counter = frontierUpdateCounters[uuid] {
            frontierUpdateCounters[uuid] = counter + 1
        }
    }

    /// Best-effort send to one Frontier child. Mirrors the dispatch
    /// inside handleSendPrompt (agentapi vs SDK vs tmux) but does NOT
    /// touch the HTTP connection — Frontier fan-out caller already
    /// returned a 202. Errors are logged + dropped.
    private func forwardFrontierChildSend(session: AgentSession, text: String) async -> FrontierChildSendResult {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 1_000_000 else {
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "invalid_prompt")
        }
        // v0.23.9 adversarial-review fix: handleFrontierSend snapshots
        // the child list before iterating, then awaits per-child sends
        // serially. While we're awaiting child[i]'s tmux/SDK/agentapi
        // call, a concurrent /pick-winner can archive child[i+1] on
        // the same @MainActor registry. Re-fetch the live session
        // immediately before each send so a just-archived loser
        // doesn't still receive the prompt.
        let currentArchivedAt = registry.session(id: session.id)?.archivedAt
        if currentArchivedAt != nil {
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "archived_mid_send")
        }
        guard RateLimiter.shared.tryAcquireSend(sessionId: session.id) else {
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "rate_limited")
        }
        // agentapi (Gemini)
        if session.geminiBackend == .agentapi,
           let conversationId = session.antigravityConversationId {
            do {
                try await sendAntigravityMessage(
                    session: session, conversationId: conversationId, content: text
                )
                await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: "frontier", text: text)
                return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: true)
            } catch {
                serverLogger.warning("frontier child gemini send failed: \(error.localizedDescription, privacy: .public)")
                return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: error.localizedDescription)
            }
        }
        // SDK (Codex)
        if session.kind == .chat && session.agent == .codex && session.codexChatBackend == .sdk {
            do {
                let cwd = session.effectiveCwd
                if session.codexChatThreadId != nil {
                    try CodexSubscriptionRelay.shared.forwardPrompt(
                        sessionId: session.id,
                        workingDirectory: cwd,
                        prompt: text,
                        threadId: session.codexChatThreadId,
                        skipGitRepoCheck: true,
                        deepResearch: session.deepResearch
                    )
                } else {
                    _ = try CodexSubscriptionRelay.shared.start(
                        session: session,
                        workingDirectory: cwd,
                        initialPrompt: text,
                        threadId: nil,
                        model: session.model,
                        sandboxMode: "read-only",
                        modelReasoningEffort: session.effort?.codexConfigValue,
                        skipGitRepoCheck: true
                    )
                }
                await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: "frontier", text: text)
                return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: true)
            } catch {
                serverLogger.warning("frontier child codex-sdk send failed: \(error.localizedDescription, privacy: .public)")
                return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: error.localizedDescription)
            }
        }
        // OpenCode sidecar
        if session.kind == .chat && session.agent == .opencode {
            do {
                try await forwardOpencodePrompt(session: session, prompt: text)
                await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: "frontier", text: text)
                return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: true)
            } catch {
                serverLogger.warning("frontier child opencode send failed: \(error.localizedDescription, privacy: .public)")
                return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: error.localizedDescription)
            }
        }
        // CLI (Claude / Codex CLI)
        guard let paneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            serverLogger.warning("frontier child has no pane id — skipping send")
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: "missing_pane_id")
        }
        do {
            let bytes = text.data(using: .utf8) ?? Data()
            try await tmux.pasteBytes(paneId: paneId, bytes: bytes + Data([0x0D]))
            if session.agent == .cursor {
                appendCursorTranscriptEcho(session: session, prompt: text, paneId: paneId)
            }
            await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: "frontier", text: text)
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: true)
        } catch {
            serverLogger.warning("frontier child tmux paste failed: \(error.localizedDescription, privacy: .public)")
            return FrontierChildSendResult(childIndex: session.frontierChildIndex ?? 0, sessionId: session.id, ok: false, reason: error.localizedDescription)
        }
    }

    /// POST /chat-sessions/frontier/:groupId/retry-slot — replace one
    /// child session with a fresh spawn of the same provider/model.
    /// Useful when one slot failed at create time (D10) and the user
    /// wants to try again.
    private func handleFrontierRetrySlot(
        request: HTTPRequest,
        connection: NWConnection,
        groupId: String
    ) async {
        guard let uuid = UUID(uuidString: groupId),
              let req = try? JSONDecoder().decode(RetryFrontierSlotRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let children = registry.frontierGroupChildren(groupId: uuid)
        guard !children.isEmpty else {
            sendResponse(.notFound, on: connection); return
        }
        // Find the existing child at this index (may exist with failed
        // status, or may have been hard-deleted). Either way, look up
        // the original slot spec from one of the surviving siblings'
        // peer entries — we don't persist the slot spec separately, so
        // we reconstruct it from the child's session record itself.
        guard let existing = children.first(where: { $0.frontierChildIndex == req.index }) else {
            sendResponse(HTTPResponse(
                status: 404, reason: "Not Found",
                contentType: "application/json",
                body: Data(#"{"error":"slot_not_found","index":\#(req.index)}"#.utf8)
            ), on: connection)
            return
        }
        let slot = FrontierModelSlot(
            provider: existing.agent,
            model: existing.model,
            effort: existing.effort,
            codexChatBackend: existing.codexChatBackend,
            deepResearch: existing.deepResearch,
            chatVendor: existing.runtimeBinding?.metadata["chatVendor"].flatMap(ChatVendor.init(rawValue:)),
            billingProvider: existing.runtimeBinding?.billingProvider
        )
        // Delete the old session (cleans up chat-cwd + chat store entry).
        await teardownSDKChat(sessionId: existing.id)
        if let wiring = sessionWiring.removeValue(forKey: existing.id) {
            wiring.stop()
        }
        chatStoreRegistry.evict(sessionId: existing.id)
        if existing.kind == .chat {
            try? ChatCwdManager.remove(for: existing.id)
        }
        try? await registry.delete(id: existing.id)
        // Re-spawn with the same childIndex.
        do {
            let fresh = try await spawnFrontierChild(
                groupId: uuid,
                childIndex: req.index,
                slot: slot
            )
            if let counter = frontierUpdateCounters[uuid] {
                frontierUpdateCounters[uuid] = counter + 1
            }
            let result = FrontierSlotResult(index: req.index, sessionId: fresh.id, reason: nil)
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(result) {
                sendResponse(HTTPResponse(
                    status: 200, reason: "OK",
                    contentType: "application/json", body: body
                ), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch let SpawnFailure.message(reason) {
            let result = FrontierSlotResult(index: req.index, sessionId: nil, reason: reason)
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(result) {
                sendResponse(HTTPResponse(
                    status: 200, reason: "OK (still failed)",
                    contentType: "application/json", body: body
                ), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    /// POST /chat-sessions/frontier/:groupId/pick-winner — archive the
    /// non-winning children and promote the winner out of the broadcast
    /// group so the sidebar/history treat it as a normal Solo chat.
    /// Returns the promoted winner session (with `frontierGroupId` /
    /// `frontierChildIndex` cleared).
    ///
    /// v0.23.9: previously the winner kept its `frontierGroupId`, which
    /// meant follow-up sends still mapped back to the Frontier group
    /// and the snapshot WS still considered the group "live". Both UIs
    /// now also flip `openTarget` to `.solo(winner.id)` after this call
    /// returns. Belt + suspenders: Frontier send / snapshot also filter
    /// `archivedAt == nil` so even before the next refresh, the
    /// archived losers cannot receive sends.
    private func handlePickFrontierWinner(
        request: HTTPRequest,
        connection: NWConnection,
        groupId: String
    ) async {
        guard let uuid = UUID(uuidString: groupId),
              let req = try? JSONDecoder().decode(PickFrontierWinnerRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        // Enumerate everyone (including any already-archived siblings)
        // so we cleanly archive the full loser set even if pick-winner
        // is invoked a second time.
        let allChildren = registry.frontierGroupChildren(groupId: uuid, includeArchived: true)
        guard let winner = allChildren.first(where: { $0.frontierChildIndex == req.childIndex && $0.archivedAt == nil }) else {
            sendResponse(.notFound, on: connection); return
        }
        // Archive the losers. Existing archive path persists archivedAt
        // and the sidebar's Show-Archived toggle keeps them reachable.
        for child in allChildren where child.id != winner.id && child.archivedAt == nil {
            try? await registry.archive(id: child.id)
        }
        // Promote the winner out of the Frontier group. From this point
        // on, every history/search row, every Frontier send, and every
        // FrontierWebSocket snapshot treats this session as a regular
        // Solo chat.
        try? await registry.clearFrontierGroupBinding(id: winner.id)
        let promoted = registry.session(id: winner.id) ?? winner
        if let counter = frontierUpdateCounters[uuid] {
            frontierUpdateCounters[uuid] = counter + 1
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(promoted) {
            sendResponse(HTTPResponse(
                status: 200, reason: "OK",
                contentType: "application/json", body: body
            ), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleSetFrontierTurnWinner(
        request: HTTPRequest,
        connection: NWConnection,
        groupId: String
    ) async {
        guard let uuid = UUID(uuidString: groupId),
              let req = try? JSONDecoder().decode(SetFrontierTurnWinnerRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let children = registry.frontierGroupChildren(groupId: uuid)
        guard children.contains(where: { $0.frontierChildIndex == req.childIndex }) else {
            sendResponse(.notFound, on: connection); return
        }
        let winner = FrontierTurnWinner(groupId: uuid, turnId: req.turnId, childIndex: req.childIndex)
        var group = frontierTurnWinners[uuid] ?? [:]
        group[req.turnId] = winner
        frontierTurnWinners[uuid] = group
        saveFrontierTurnWinners()
        if let counter = frontierUpdateCounters[uuid] {
            frontierUpdateCounters[uuid] = counter + 1
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(winner) {
            sendResponse(HTTPResponse(
                status: 200, reason: "OK",
                contentType: "application/json", body: body
            ), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// Internal spawn dispatch shared by handlePostFrontier +
    /// handleFrontierRetrySlot. Throws SpawnFailure.message on per-slot
    /// failure so the caller can surface a per-slot reason string.
    private enum SpawnFailure: Error {
        case message(String)
    }

    private func spawnFrontierChild(
        groupId: UUID,
        childIndex: Int,
        slot: FrontierModelSlot
    ) async throws -> AgentSession {
        let metadata: ResolvedChatRuntimeMetadata
        do {
            metadata = try resolveChatRuntimeMetadata(
                provider: slot.provider,
                requestedVendor: slot.chatVendor,
                requestedBillingProvider: slot.billingProvider,
                requestedCodexBackend: slot.codexChatBackend
            )
        } catch let error as ChatRuntimeValidationError {
            throw SpawnFailure.message(chatRuntimeValidationMessage(error))
        }

        if let reason = providerDisabledReason(provider: slot.provider, vendor: metadata.vendor) {
            throw SpawnFailure.message(reason)
        }

        if let reason = await frontierProviderUnavailableReason(
            provider: slot.provider,
            codexBackend: metadata.codexBackend
        ) {
            throw SpawnFailure.message(reason)
        }

        switch slot.provider {
        case .claude, .codex, .cursor:
            // Reuse the same plumbing as Solo chat: createChat → chat-cwd →
            // spawn tmux (or SDK relay) → warm chat store. We don't need
            // the full HTTP wrapper since we already have all the data.
            let session = try await registry.createChat(
                provider: slot.provider,
                model: slot.model,
                chatCwd: "",
                codexChatBackend: metadata.codexBackend,
                effort: slot.effort,
                frontierGroupId: groupId,
                frontierChildIndex: childIndex,
                deepResearch: slot.deepResearch,
                chatVendor: metadata.vendor,
                billingProvider: metadata.billingProvider
            )
            let chatCwd: String
            do {
                let url = try ChatCwdManager.ensure(for: session.id)
                chatCwd = url.path
            } catch {
                try? await registry.delete(id: session.id)
                throw SpawnFailure.message("chat_cwd_create_failed: \(error.localizedDescription)")
            }
            try? await registry.updateRuntime(
                id: session.id, worktreePath: chatCwd,
                tmuxWindowId: nil, tmuxPaneId: nil, mode: .local
            )
            let updated = registry.session(id: session.id) ?? session
            let argv = AgentSpawner.argv(for: updated)
            if argv.isEmpty && updated.agent == .codex && updated.codexChatBackend == .sdk {
                // SDK: warm store; sidecar starts on first send (per Phase 4.5).
                _ = chatStoreRegistry.snapshotStore(for: updated)
                return updated
            }
            if argv.isEmpty {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("agent_cli_not_found")
            }
            // CLI: spawn tmux. Best-effort — children that fail to spawn
            // are surfaced as a slot failure, not a 500.
            do {
                try await tmux.start()
                let window = try await tmux.newWindow(cwd: chatCwd, child: argv)
                try? await registry.updateRuntime(
                    id: session.id, worktreePath: chatCwd,
                    tmuxWindowId: window.windowId, tmuxPaneId: window.paneId, mode: .local
                )
                _ = chatStoreRegistry.snapshotStore(for: registry.session(id: session.id) ?? updated)
                return registry.session(id: session.id) ?? updated
            } catch {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("tmux_spawn_failed: \(error.localizedDescription)")
            }
        case .gemini:
            // Delegate to the agentapi spawn flow. We can't reuse
            // handlePostGeminiChatSession directly (it owns the
            // connection write), but we lift the same body into a
            // shared helper-style inline call here.
        let home = ClawdmeterRealHome.url()
        let projectsDir = home.appendingPathComponent(".gemini/config/projects", isDirectory: true)
            let lsClient = LanguageServerClient()
            let resolver = AntigravityProjectResolver(projectsDir: projectsDir)
            let projects = await resolver.allProjects()
            guard let projectId = projects.first?.id else {
                throw SpawnFailure.message("antigravity_no_projects")
            }
            let session = try await registry.createChat(
                provider: .gemini,
                model: slot.model,
                chatCwd: "",
                frontierGroupId: groupId,
                frontierChildIndex: childIndex,
                deepResearch: slot.deepResearch,
                chatVendor: metadata.vendor,
                billingProvider: metadata.billingProvider
            )
            let chatCwd: String
            do {
                let url = try ChatCwdManager.ensure(for: session.id)
                chatCwd = url.path
            } catch {
                try? await registry.delete(id: session.id)
                throw SpawnFailure.message("chat_cwd_create_failed: \(error.localizedDescription)")
            }
            try? await registry.updateRuntime(
                id: session.id, worktreePath: chatCwd,
                tmuxWindowId: nil, tmuxPaneId: nil, mode: .local
            )
            let modelTier = AgentapiModelTier.from(modelCatalogId: slot.model)
            do {
                let conversationIdString = try await lsClient.newConversation(
                    modelTier: modelTier,
                    prompt: "(starting Frontier child)",
                    projectId: projectId
                )
                guard let conversationId = UUID(uuidString: conversationIdString) else {
                    try? await registry.delete(id: session.id)
                    try? ChatCwdManager.remove(for: session.id)
                    throw SpawnFailure.message("agentapi_bad_conversation_id")
                }
                try? await registry.setAntigravityChatBinding(
                    id: session.id, conversationId: conversationId, projectId: projectId
                )
                let updated = registry.session(id: session.id) ?? session
                _ = chatStoreRegistry.snapshotStore(for: updated)
                return updated
            } catch let LanguageServerClientError.notRunning {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("antigravity_not_running")
            } catch {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("agentapi_new_conversation_failed: \(error.localizedDescription)")
            }
        case .opencode:
            guard let _ = await OpencodeProcessManager.shared.ensureRunning() else {
                switch OpencodeProcessManager.shared.state {
                case .notInstalled:
                    throw SpawnFailure.message("opencode_not_installed")
                case .failed(let detail):
                    throw SpawnFailure.message("opencode_serve_failed: \(detail)")
                default:
                    throw SpawnFailure.message("opencode_not_running")
                }
            }
            OpencodeSSEAdapter.shared.start()
            if OpencodeSSEAdapter.shared.chatStoreAccessor == nil {
                let registry = self.registry
                let chatStoreRegistry = self.chatStoreRegistry
                OpencodeSSEAdapter.shared.chatStoreAccessor = { [weak registry, weak chatStoreRegistry] uuid in
                    guard let registry, let chatStoreRegistry else { return nil }
                    guard let session = registry.session(id: uuid) else { return nil }
                    return chatStoreRegistry.acquire(for: session)
                }
            }
            let session = try await registry.createChat(
                provider: .opencode,
                model: slot.model,
                chatCwd: "",
                effort: slot.effort,
                frontierGroupId: groupId,
                frontierChildIndex: childIndex,
                deepResearch: slot.deepResearch,
                chatVendor: metadata.vendor,
                billingProvider: metadata.billingProvider
            )
            let chatCwd: String
            do {
                let url = try ChatCwdManager.ensure(for: session.id)
                chatCwd = url.path
            } catch {
                try? await registry.delete(id: session.id)
                throw SpawnFailure.message("chat_cwd_create_failed: \(error.localizedDescription)")
            }
            try? await registry.updateRuntime(
                id: session.id,
                worktreePath: chatCwd,
                runtimeCwd: .some(chatCwd),
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                mode: .local
            )
            guard var request = await OpencodeProcessManager.shared.makeAuthorizedRequest(
                path: "/session",
                directory: chatCwd
            ) else {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("opencode_not_running")
            }
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "title": "Frontier #\(childIndex + 1) - OpenCode"
            ])
            let opencodeID: String
            do {
                let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                    try? await registry.delete(id: session.id)
                    try? ChatCwdManager.remove(for: session.id)
                    throw SpawnFailure.message("opencode_session_create_failed")
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"] as? String else {
                    try? await registry.delete(id: session.id)
                    try? ChatCwdManager.remove(for: session.id)
                    throw SpawnFailure.message("opencode_bad_session_response")
                }
                opencodeID = id
            } catch let failure as SpawnFailure {
                throw failure
            } catch {
                try? await registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("opencode_session_create_failed: \(error.localizedDescription)")
            }
            let updated = registry.session(id: session.id) ?? session
            OpencodeSSEAdapter.shared.register(
                clawdmeterID: updated.id, opencodeID: opencodeID, repo: chatCwd
            )
            _ = chatStoreRegistry.snapshotStore(for: updated)
            AgentEventStream.recordEvent(
                sessionId: updated.id,
                kind: .sessionCreated,
                payload: ["repo": chatCwd, "agent": "opencode", "opencodeID": opencodeID]
            )
            return updated
        case .unknown, .grok:
            // X3: forward-compat unknown agent — no frontier-child spawn
            // path. grok (ACP) isn't wired for broadcast/Frontier yet.
            // Surfaces as a slot failure to the broadcast caller.
            throw SpawnFailure.message("unknown_agent_kind")
        }
    }

    /// v0.8 Phase 4.5: route a prompt for a Codex-SDK chat session to
    /// CodexSubscriptionRelay instead of tmux. Lazy-starts the relay on
    /// the first send (we don't have a prompt to seed it with at chat-
    /// session create time). On subsequent sends, uses `forwardPrompt`
    /// with the persisted threadId so the SDK reuses the same server-
    /// side thread (and resume-after-evict works per NEW-T13).
    ///
    /// D1 (first-message-becomes-title): if the session has no
    /// customName yet, derive a 40-char title from the prompt body and
    /// persist via `registry.rename(...)`. Future renames via /rename
    /// override this.
    /// v0.23.2 P1-04: send a prompt into an OpenCode session.
    ///
    /// Flow:
    ///   1. Echo the user prompt into the SessionChatStore so the
    ///      composer clears the "sending…" state and the user bubble
    ///      renders immediately (mirrors how sendChatSDKPrompt does it).
    ///   2. Resolve the opencode session id (registered when the
    ///      AgentSession was spawned via `handleSpawnOpencodeSession`).
    ///   3. POST to `opencode serve`'s `/session/<oc-id>/message` with
    ///      a minimal `parts: [{type: "text", text: <prompt>}]` body.
    ///      opencode picks the user's default provider+model — we
    ///      don't override unless a session-specific override is set.
    ///   4. Return 200; the reply streams back asynchronously via
    ///      `message.added` SSE events that OpencodeSSEAdapter routes
    ///      into the same SessionChatStore.
    ///
    /// Error surfaces:
    ///   - opencode serve down → 503 `opencode_server_unreachable`
    ///   - no opencode session-id registered → 503 `opencode_session_not_registered`
    ///     (caller should retry after a brief delay; the SSE
    ///     `session.created` event populates the map asynchronously)
    ///   - opencode returns non-2xx → 502 `opencode_send_failed` w/
    ///     the upstream status code
    private func sendOpencodePrompt(
        session: AgentSession,
        prompt: String,
        idempotencyKey: String? = nil,
        payloadHash: String = "",
        connection: NWConnection
    ) async {
        // First-prompt naming, same convention as sendChatSDKPrompt.
        if (session.customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let cap = 40
                let truncated = trimmed.count <= cap
                    ? trimmed
                    : String(trimmed[..<trimmed.index(trimmed.startIndex, offsetBy: cap - 1)]) + "…"
                try? await registry.rename(id: session.id, name: truncated)
            }
        }
        // Echo the user prompt into the chat store so the UI clears
        // its "sending…" state and the user bubble renders without
        // waiting on the SSE round-trip.
        if let store = chatStoreRegistry.snapshotStore(for: session) {
            let userMsgId = "opencode-user-\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8))"
            store.appendSDKMessages([
                ChatMessage(
                    id: userMsgId,
                    kind: .userText,
                    title: "You",
                    body: prompt,
                    at: Date()
                )
            ])
        }
        // Resolve the opencode session id.
        guard let opencodeID = await OpencodeSSEAdapter.shared.opencodeSessionId(for: session.id) else {
            serverLogger.warning("opencode send: no session-id mapping for \(session.id.uuidString, privacy: .public)")
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"opencode_session_not_registered","detail":"Opencode session has not been registered yet — retry in a moment."}"#.utf8)
            ), on: connection)
            return
        }
        // Build the upstream POST.
        guard var req = await OpencodeProcessManager.shared.makeAuthorizedRequest(
            path: "/session/\(opencodeID)/message",
            directory: session.effectiveCwd
        ) else {
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"opencode_server_unreachable","detail":"opencode serve is not running"}"#.utf8)
            ), on: connection)
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // OpenCode's local OpenAPI expects a single text part plus an
        // optional `model` object (`providerID`/`modelID`) and `variant`.
        // Keep the body inside that schema so current and older serve
        // builds reject neither unknown top-level provider fields nor
        // missing default-model state.
        let body = opencodeMessageBody(session: session, prompt: prompt)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if !(200..<300).contains(http.statusCode) {
                serverLogger.warning("opencode send: upstream returned \(http.statusCode, privacy: .public)")
                let detailBody = #"{"error":"opencode_send_failed","upstreamStatus":\#(http.statusCode)}"#
                sendResponse(HTTPResponse(
                    status: 502, reason: "Bad Gateway",
                    contentType: "application/json",
                    body: Data(detailBody.utf8)
                ), on: connection)
                return
            }
            // v16 outbox: idempotency receipt + cache. Routing through
            // sendCommandResponse so a retried request with the same key
            // returns the cached ok-response without re-posting to the
            // OpenCode sidecar (which would double-send the user's prompt).
            await sendCommandResponse(
                body: ["ok": true],
                key: idempotencyKey,
                kind: .send,
                sessionId: session.id,
                payloadHash: payloadHash,
                on: connection
            )
        } catch {
            serverLogger.warning("opencode send: \(error.localizedDescription, privacy: .public)")
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable",
                contentType: "application/json",
                body: Data(#"{"error":"opencode_server_unreachable","detail":"\#(error.localizedDescription)"}"#.utf8)
            ), on: connection)
        }
    }

    private func forwardOpencodePrompt(session: AgentSession, prompt: String) async throws {
        if let store = chatStoreRegistry.snapshotStore(for: session) {
            let userMsgId = "opencode-user-\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8))"
            store.appendSDKMessages([
                ChatMessage(
                    id: userMsgId,
                    kind: .userText,
                    title: "You",
                    body: prompt,
                    at: Date()
                )
            ])
        }
        guard let opencodeID = await OpencodeSSEAdapter.shared.opencodeSessionId(for: session.id) else {
            throw NSError(
                domain: "AgentControlServer.OpenCode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "opencode_session_not_registered"]
            )
        }
        guard var req = await OpencodeProcessManager.shared.makeAuthorizedRequest(
            path: "/session/\(opencodeID)/message",
            directory: session.effectiveCwd
        ) else {
            throw NSError(
                domain: "AgentControlServer.OpenCode",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "opencode_server_unreachable"]
            )
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: opencodeMessageBody(session: session, prompt: prompt))
        req.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "AgentControlServer.OpenCode",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "opencode_send_failed: \(status)"]
            )
        }
    }

    /// Body posted to `opencode serve`'s `/session/<id>/message`
    /// endpoint. v0.29.9: stripped of the `model`/`variant` override —
    /// auth and model selection now flow entirely from the user's
    /// `opencode` CLI configuration (`opencode auth login` + the CLI's
    /// own default-model state). The serve daemon picks the upstream
    /// provider and model from its own state; Clawdmeter no longer
    /// second-guesses that selection.
    private func opencodeMessageBody(session: AgentSession, prompt: String) -> [String: Any] {
        _ = session
        return [
            "parts": [
                ["type": "text", "text": prompt]
            ]
        ]
    }

    private func sendChatSDKPrompt(
        session: AgentSession,
        prompt: String,
        idempotencyKey: String? = nil,
        payloadHash: String = "",
        connection: NWConnection
    ) async {
        // D1 chat naming: tag the customName from the first user prompt
        // when none is set yet. Trim + truncate to 40 chars (with ellipsis
        // if longer). Existing rename handler normalizes empties to nil
        // so the placeholder "New <Provider> chat" still renders pre-send.
        if (session.customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let truncated: String = {
                    let cap = 40
                    if trimmed.count <= cap { return trimmed }
                    let idx = trimmed.index(trimmed.startIndex, offsetBy: cap - 1)
                    return String(trimmed[..<idx]) + "…"
                }()
                try? await registry.rename(id: session.id, name: truncated)
            }
        }
        let chatCwd = session.effectiveCwd
        // v0.8 QA: echo the user's prompt into the SessionChatStore so it
        // shows up as a user bubble in the thread immediately. Without
        // this, the user sees nothing until the SDK assistant response
        // streams in (or never, if there's a network hiccup). Marks the
        // message with an SDK-prefixed id so it doesn't collide with
        // assistant events that come back through the ingestor.
        if let store = chatStoreRegistry.snapshotStore(for: session) {
            let userMsgId = "user-\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8))"
            store.appendSDKMessages([
                ChatMessage(
                    id: userMsgId,
                    kind: .userText,
                    title: "You",
                    body: prompt,
                    at: Date()
                )
            ], at: Date())
        }
        do {
            if CodexSubscriptionRelay.shared.isActive(sessionId: session.id) {
                // Subsequent prompt — forward to the running sidecar with
                // the resume threadId so the SDK reuses the same server-
                // side thread.
                try CodexSubscriptionRelay.shared.forwardPrompt(
                    sessionId: session.id,
                    workingDirectory: chatCwd,
                    prompt: prompt,
                    threadId: session.codexChatThreadId,
                    skipGitRepoCheck: true,
                    deepResearch: session.deepResearch
                )
            } else {
                // First prompt — spawn the relay + ingestor. The ingestor
                // captures `thread.started` and persists the threadId on
                // the session record for resume-after-evict (NEW-T13).
                let registryRef = self.registry
                if let store = chatStoreRegistry.snapshotStore(for: session) {
                    let ingestor = CodexSDKEventIngestor(
                        sessionId: session.id,
                        store: store,
                        onThreadStarted: { [weak registryRef] threadId in
                            Task { @MainActor in
                                // F2-wire: best-effort; thread-id binding
                                // failure here doesn't break the chat,
                                // it just means resume-after-evict will
                                // miss this thread.
                                try? await registryRef?.setCodexChatThreadId(id: session.id, threadId: threadId)
                            }
                        }
                    )
                    ingestor.start()
                    sdkChatIngestors[session.id] = ingestor
                }
                // v0.8 QA: chat-cwd (~/Library/.../chat-sessions/<uuid>/) is
                // not a git repo. The Codex CLI rejects the call without
                // `--skip-git-repo-check` and the SDK silently hangs with
                // a stream_error sidecar-side ("Not inside a trusted
                // directory…"). Pass true unconditionally for chat — the
                // chat-cwd is sandboxed inside the app's Application
                // Support dir and never holds user code.
                _ = try CodexSubscriptionRelay.shared.start(
                    session: session,
                    workingDirectory: chatCwd,
                    initialPrompt: prompt,
                    threadId: session.codexChatThreadId,
                    model: session.model,
                    sandboxMode: "read-only",
                    modelReasoningEffort: session.effort?.codexConfigValue,
                    skipGitRepoCheck: true
                )
            }
        } catch {
            serverLogger.error("SDK chat send failed for \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
            return
        }
        let peer = Self.endpointString(connection.endpoint)
        await AuditLog.shared.recordSend(sessionId: session.id, sourcePeer: peer, text: prompt)
        let updated = registry.session(id: session.id) ?? session
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // v16 outbox: inline the receipt into the AgentSession body and
        // cache the response bytes so a retried same-key request returns
        // the same payload without re-driving CodexSubscriptionRelay
        // (which would silently fire a second turn through the SDK).
        if let body = try? encoder.encode(updated),
           var dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let key = idempotencyKey, !key.isEmpty {
                let receipt = MobileCommandReceipt(
                    idempotencyKey: key, status: .acknowledged, processedAt: Date()
                )
                dict["receipt"] = receipt.jsonDictionary
            }
            if let merged = try? JSONSerialization.data(withJSONObject: dict) {
                await recordIdempotent(
                    key: idempotencyKey,
                    kind: .send,
                    sessionId: session.id,
                    connection: connection,
                    payloadHash: payloadHash,
                    responseBody: merged,
                    responseStatus: 200
                )
                sendResponse(.ok(contentType: "application/json", body: merged), on: connection)
            } else {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            }
        } else {
            sendResponse(.ok(contentType: "application/json", body: Data("{}".utf8)), on: connection)
        }
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
    private func warmupCLIPane(session: AgentSession, paneId: String) async {
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
            // Claude welcome auto-dismisses on render. Probe to give it
            // ~1.5s, then drop into the permission-poll loop.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = try? await tmux.command(["capture-pane", "-p", "-t", paneId])
        case .gemini:
            break
        case .opencode:
            // PR #29: opencode sessions never enter the tmux warmup
            // choreography — they're SSE clients of `opencode serve`,
            // which OpencodeProcessManager + OpencodeSSEAdapter handle
            // out-of-band.
            break
        case .cursor:
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = try? await tmux.command(["capture-pane", "-p", "-t", paneId])
        case .grok:
            // ACP agents have no tmux pane — no warmup choreography.
            break
        case .unknown:
            // X3: forward-compat unknown agent — no warmup choreography
            // plumbed.
            break
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
        // ACP harness permission (Grok): the pending prompt lives in the bridge
        // (keyed by the ACP request id), not the daemon's continuation map, so
        // this must run BEFORE the continuation-based checks below. The bridge
        // answers the agent's `session/request_permission` and clears the
        // store's prompt; a non-match means a stale / already-answered click.
        if let grokSession = registry.session(id: uuid), grokSession.agent == .grok {
            guard let bridge = harnessRegistry.bridge(for: uuid) else {
                sendResponse(HTTPResponse(
                    status: 409, reason: "Conflict",
                    contentType: "application/json",
                    body: Data(#"{"error":"no_pending_prompt"}"#.utf8)
                ), on: connection)
                return
            }
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
    fileprivate final class ResumeOnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func tryClaim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// v0.8 Phase 4.5 cleanup: tear down SDK chat ingestor + relay for a
    /// session. Called from handleDeleteSession when removing a chat
    /// session, and idempotent on non-SDK sessions / sessions that never
    /// started a relay.
    private func teardownSDKChat(sessionId: UUID) async {
        if let ingestor = sdkChatIngestors.removeValue(forKey: sessionId) {
            ingestor.stop()
        }
        if CodexSubscriptionRelay.shared.isActive(sessionId: sessionId) {
            await CodexSubscriptionRelay.shared.stop(sessionId: sessionId)
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

    private nonisolated func newestCodexJSONL() -> URL? {
        let sessionsDir = ClawdmeterRealHome.url()
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date > newestDate {
                newestDate = date
                newest = url
            }
        }
        return newest
    }

    private func handleApprovePlan(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid),
              let windowId = session.tmuxWindowId else {
            sendResponse(.notFound, on: connection)
            return
        }
        // v16 outbox: approve-plan is a fire-and-forget POST with no
        // body schema. Optional InterruptRequest-shaped body carries
        // the idempotency key; missing body keeps the legacy path.
        let req = (try? JSONDecoder().decode(InterruptRequest.self, from: request.body))
            ?? InterruptRequest(idempotencyKey: nil)
        if await tryReplayIdempotent(key: req.idempotencyKey, on: connection) { return }
        let payloadHash = MobileCommandPayloadHasher.hex(request.body)
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
        case .codex:
            argv = AgentSpawner.codexArgv(
                model: session.model,
                planMode: false,
                effort: session.effort,
                autopilot: false,
                workspacePath: session.effectiveCwd
            )
        case .gemini, .grok:
            // approve-plan via tmux respawn doesn't apply: Gemini has no CLI
            // to respawn, and grok (ACP) approves via session/set_mode, which
            // the daemon doesn't route yet. Surfaces as 500 below.
            argv = nil
        case .opencode:
            // PR #29: opencode has no plan-mode → respawn-with-write
            // flow; OpenCode handles its own tool-call approval inside
            // `opencode serve`. Surfaces as 500 here so a misrouted
            // approve-plan from a stale UI doesn't pretend to succeed.
            argv = nil
        case .cursor:
            guard let cursorResumeId = Self.cursorResumeId(for: session) else {
                try? await registry.setPlanText(
                    id: uuid,
                    planText: "Cursor approval needs a real Cursor chat id. Start Cursor in code mode or import a Cursor session with a proven id."
                )
                try? await registry.updateStatus(id: uuid, status: .degraded)
                sendResponse(HTTPResponse(
                    status: 409,
                    reason: "Conflict",
                    contentType: "application/json",
                    body: Data(#"{"error":"cursor_resume_id_missing","cta":"Cursor approval needs a real Cursor chat id. Start Cursor in code mode or import a Cursor session with a proven id."}"#.utf8)
                ), on: connection)
                return
            }
            argv = AgentSpawner.cursorArgv(
                model: session.model,
                planMode: false,
                effort: session.effort,
                autopilot: false,
                resumeSessionId: cursorResumeId,
                workspacePath: session.effectiveCwd
            )
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
        do {
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

    private static func cursorResumeId(for session: AgentSession) -> String? {
        let candidate = session.runtimeBinding?.externalSessionId
            ?? session.runtimeBinding?.externalThreadId
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
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
        // v0.8 Phase 4.5: tear down any SDK chat infrastructure first
        // (ingestor sink + relay sidecar). Idempotent on non-SDK sessions.
        await teardownSDKChat(sessionId: uuid)
        // ACP harness teardown (Grok): terminate the stdio child + driver and
        // release the chat store the bridge pinned. Idempotent on non-ACP
        // sessions (remove is a no-op when no bridge is registered).
        if harnessRegistry.contains(uuid) {
            await harnessRegistry.remove(uuid)
            chatStoreRegistry.release(sessionId: uuid)
        }
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

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
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
            return "\(host):\(port.rawValue)"
        default:
            return "\(endpoint)"
        }
    }

    // MARK: - Endpoint handlers

    private func handleGetRepos(connection: NWConnection) async {
        let repos = await repoIndex.snapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(repos) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleGetNeedsAttention(connection: NWConnection) async {
        let response = NeedsAttentionResponse(events: await notifications.snapshotEvents(), serverTime: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(response) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleAckNotifications(request: HTTPRequest, connection: NWConnection) async {
        guard let req = try? JSONDecoder().decode(AckNotificationsRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        await notifications.ack(through: req.ackId)
        sendResponse(.ok(contentType: "application/json", body: Data(#"{"ok":true}"#.utf8)), on: connection)
    }

    // MARK: - Response sending

    /// HTTP responses used by daemon handlers. Sessions v2 promoted the
    /// enum to a struct so endpoints can emit arbitrary statuses (409
    /// Conflict, 426 Upgrade Required, 503 Service Unavailable) with a
    /// structured JSON body. Common cases stay reachable via static
    /// constants / factories so existing call sites don't change.
    struct HTTPResponse {
        let status: Int
        let reason: String
        let contentType: String
        let body: Data
        /// Extra response headers (e.g. `Retry-After`). Emitted verbatim
        /// after the standard headers in `httpResponseBytes`. Empty for
        /// most responses; the static `tooManyRequests` factories set it.
        let extraHeaders: [(String, String)]

        init(status: Int, reason: String, contentType: String, body: Data, extraHeaders: [(String, String)] = []) {
            self.status = status
            self.reason = reason
            self.contentType = contentType
            self.body = body
            self.extraHeaders = extraHeaders
        }

        static func ok(contentType: String, body: Data) -> HTTPResponse {
            HTTPResponse(status: 200, reason: "OK", contentType: contentType, body: body)
        }
        static let badRequest = HTTPResponse(
            status: 400, reason: "Bad Request",
            contentType: "text/plain", body: Data("Bad Request\n".utf8)
        )
        static func badRequest(detail: String) -> HTTPResponse {
            HTTPResponse(
                status: 400, reason: "Bad Request",
                contentType: "text/plain",
                body: Data("Bad Request: \(detail)\n".utf8)
            )
        }
        static let notFound = HTTPResponse(
            status: 404, reason: "Not Found",
            contentType: "text/plain", body: Data("Not Found\n".utf8)
        )
        static let unauthorized = HTTPResponse(
            status: 401, reason: "Unauthorized",
            contentType: "text/plain", body: Data("Unauthorized\n".utf8)
        )
        static let internalError = HTTPResponse(
            status: 500, reason: "Internal Server Error",
            contentType: "text/plain", body: Data("Internal Server Error\n".utf8)
        )
        /// 403 Forbidden with a JSON body for policy denials (e.g. autopilot
        /// enable on an untrusted repo — review §3 finding 2026-05-18).
        static func forbidden(body: Data) -> HTTPResponse {
            HTTPResponse(
                status: 403, reason: "Forbidden",
                contentType: "application/json", body: body
            )
        }
        /// Generic 429 (kept for the dispatch-time auth/peer rejection
        /// path). Prefer `tooManyRequestsSend` / `tooManyRequestsSwap` from
        /// the per-handler call sites — those set a real `Retry-After`.
        static let tooManyRequests = tooManyRequestsSwap

        static let tooManyRequestsSend = HTTPResponse(
            status: 429, reason: "Too Many Requests",
            contentType: "application/json",
            body: Data(#"{"error":"rate_limited","retryAfterSeconds":1}"#.utf8),
            extraHeaders: [("Retry-After", "1")]
        )
        static let tooManyRequestsSwap = HTTPResponse(
            status: 429, reason: "Too Many Requests",
            contentType: "application/json",
            body: Data(#"{"error":"rate_limited","retryAfterSeconds":5}"#.utf8),
            extraHeaders: [("Retry-After", "5")]
        )
    }

    /// P1-Mac-7: validate untrusted repoKey before forwarding to tmux. The
    /// path must be absolute, contain no `..` segments, hold no CR/LF or
    /// control bytes, and resolve under the user's home directory.
    ///
    /// Codex follow-up: also resolve symlinks before the home-prefix
    /// check. The earlier patch only standardized (collapses `..` /
    /// `./`); a symlink at `/Users/me/link → /etc` would pass the
    /// hasPrefix test and let tmux escape the home sandbox. Resolve the
    /// real path and re-check.
    static func isValidRepoKey(_ key: String) -> Bool {
        // v0.7.7: delegated to the shared PathValidator helper that
        // consolidates the three near-clone validators that used to
        // live across this file + iOSArtifactsPane.
        PathValidator.isValidRepoKey(key)
    }

    /// Codex follow-up to P1-Mac-7: also validate jsonlPath in the
    /// continue-readonly handler. The repoKey check alone left a
    /// trust-boundary gap — a compromised client could send a valid
    /// repoKey and a jsonlPath pointing at an unrelated session, and
    /// the handler would happily resume that one. Restrict jsonlPath
    /// to live under the user's Claude/Codex project directories and
    /// reject the same traversal / control-byte / symlink-escape shapes
    /// covered by isValidRepoKey.
    static func isValidJsonlPath(_ path: String) -> Bool {
        // v0.7.7: delegated to PathValidator. Allowlist of agent project
        // directories lives in the shared helper now.
        PathValidator.isValidJsonlPath(path, homeDirectory: ClawdmeterRealHome.path())
    }

    static let markdownDocumentMaxBytes = 2 * 1024 * 1024

    static func standardizedMarkdownDocumentPath(_ rawPath: String, relativeTo cwd: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !PathValidator.isEmpty(trimmed),
              !PathValidator.containsControlBytes(trimmed),
              !PathValidator.containsTraversal(trimmed)
        else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            guard !cwd.isEmpty,
                  cwd.hasPrefix("/"),
                  !PathValidator.containsControlBytes(cwd),
                  !PathValidator.containsTraversal(cwd)
            else { return nil }
            absolute = (cwd as NSString).appendingPathComponent(expanded)
        }
        return (absolute as NSString).standardizingPath
    }

    // v0.27.0: isSafeDesignImportBase(_:) removed along with the Design
    // tab + Open Design /design/import-folder route.

    func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let bytes = httpResponseBytes(
            status: response.status,
            statusText: response.reason,
            contentType: response.contentType,
            body: response.body,
            extraHeaders: response.extraHeaders
        )
        // T18 Wire Inspector: record outgoing response on a best-effort
        // Task; bypassing the actor would let the inspector skew under
        // load. Read the request context stashed in dispatch() so the
        // outbound row carries the original method+path (without this,
        // every response showed `— —`, useless for request/response
        // correlation).
        //
        // Hot-path gate: only build the closure + retain the body when
        // the inspector is on. For the /artifact endpoint (up to 50MB)
        // this avoids pinning the full Data behind a detached Task that
        // the actor would just drop inside.
        if WireInspector.isEnabledFast {
            let peerString = Self.endpointString(connection.endpoint)
            let ctx = pendingRequests.removeValue(forKey: ObjectIdentifier(connection))
            let method = ctx?.method ?? "—"
            let path = ctx?.path ?? "—"
            let status = response.status
            let contentType = response.contentType
            let body = response.body
            Task.detached { @Sendable in
                await WireInspector.shared.recordResponse(
                    method: method, path: path, peer: peerString,
                    status: status, body: body.isEmpty ? nil : body,
                    contentType: contentType
                )
            }
        } else {
            // Still drop the per-connection map entry so it can't leak
            // if the inspector flips on between request and response.
            pendingRequests.removeValue(forKey: ObjectIdentifier(connection))
        }
        connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()  // HTTP/1.1 keep-alive is not implemented; close after each response
        })
    }

    private func sendJSON(_ object: [String: Any], on connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    }

    // MARK: - v16 idempotency helpers

    /// Returns true after writing a cached response to `connection`.
    /// The caller short-circuits its handler logic in that case so the
    /// side effect (send to tmux, swap model, merge PR) doesn't repeat.
    /// `kind` is recorded into the audit log but is not strictly required
    /// for the lookup itself — keys are globally unique by construction.
    ///
    /// `payloadHash` (optional) enables the payload-mismatch gate. When
    /// supplied AND the cached entry has a stored hash that DIFFERS, the
    /// daemon sends `422 Unprocessable` instead of replaying — protects
    /// against an iOS retry that reused the persisted key but edited
    /// the request body (e.g. user edited the GitHub spec between
    /// taps). Callers without a hash skip the check (back-compat).
    @discardableResult
    func tryReplayIdempotent(
        key: String?,
        on connection: NWConnection,
        payloadHash: String? = nil
    ) async -> Bool {
        guard let key, !key.isEmpty else { return false }
        guard let cached = await mobileCommandOutbox.entry(forKey: key) else { return false }
        // Payload-mismatch gate. Cached entries without a stored hash
        // (audit-log replay seeds, old entries from before this field)
        // skip the check — we can't distinguish a real mismatch from a
        // missing-record without the hash, and we'd rather replay than
        // surface a spurious 422.
        if let incoming = payloadHash,
           let stored = cached.payloadHash,
           !stored.isEmpty,
           incoming != stored {
            let body = Data(#"{"error":"idempotency-key-reused-with-different-payload"}"#.utf8)
            sendResponse(
                HTTPResponse(
                    status: 422,
                    reason: "Unprocessable",
                    contentType: "application/json",
                    body: body
                ),
                on: connection
            )
            serverLogger.warning("idempotent payload mismatch (key=\(key.prefix(8), privacy: .public)…)")
            return true
        }
        // Re-emit the cached response bytes. When the cache only carried
        // the receipt (audit-log replay path, no body), synthesize a
        // minimal JSON body that still carries the receipt so iOS can
        // mark the outbox entry done.
        let body: Data
        let contentType: String
        if let cachedBody = cached.responseBody {
            body = cachedBody
            contentType = cached.responseContentType
        } else {
            let payload: [String: Any] = ["receipt": cached.receipt.jsonDictionary, "replay": true]
            body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            contentType = "application/json"
        }
        let response: HTTPResponse
        if cached.responseStatus == 200 {
            response = .ok(contentType: contentType, body: body)
        } else {
            // Non-200 cached responses (failed commands) replay with
            // the original status code so iOS preserves the original
            // error treatment.
            response = HTTPResponse(
                status: cached.responseStatus,
                reason: "Cached Response",
                contentType: contentType,
                body: body
            )
        }
        sendResponse(response, on: connection)
        serverLogger.info("idempotent replay (key=\(key.prefix(8), privacy: .public)…, kind=\(cached.kind.rawValue, privacy: .public))")
        return true
    }

    /// Cache a freshly-processed command's response under `key` so the
    /// next retry with the same key replays. Also writes a hashed audit
    /// row to `~/.clawdmeter/audit/mobile-commands.jsonl`.
    private func recordIdempotent(
        key: String?,
        kind: MobileCommandKind,
        sessionId: UUID?,
        connection: NWConnection,
        payloadHash: String,
        responseBody: Data?,
        responseContentType: String = "application/json",
        responseStatus: Int = 200,
        failed: Bool = false,
        errorMessage: String? = nil
    ) async {
        guard let key, !key.isEmpty else { return }
        let entry: MobileCommandOutbox.CachedEntry
        if failed {
            entry = await mobileCommandOutbox.recordFailure(
                key: key,
                kind: kind,
                error: errorMessage ?? "unknown",
                responseStatus: responseStatus,
                responseBody: responseBody,
                payloadHash: payloadHash
            )
        } else {
            entry = await mobileCommandOutbox.record(
                key: key,
                kind: kind,
                responseBody: responseBody,
                responseContentType: responseContentType,
                responseStatus: responseStatus,
                payloadHash: payloadHash
            )
        }
        await AuditLog.shared.recordMobileCommand(
            idempotencyKey: key,
            kind: kind.rawValue,
            sessionId: sessionId,
            sourcePeer: Self.endpointString(connection.endpoint),
            status: entry.receipt.status.rawValue,
            payloadHash: payloadHash,
            serverReceiptId: entry.receipt.serverReceiptId
        )
    }

    /// One-shot helper for idempotent JSON success responses. Inlines the
    /// receipt into the body dict so iOS can match by idempotencyKey,
    /// caches the bytes for replay, and writes the audit row. Equivalent
    /// to `sendJSON(body)` when `key` is nil (legacy clients).
    func sendCommandResponse(
        body: [String: Any],
        key: String?,
        kind: MobileCommandKind,
        sessionId: UUID?,
        payloadHash: String,
        on connection: NWConnection
    ) async {
        var body = body
        if let key, !key.isEmpty {
            let receipt = MobileCommandReceipt(
                idempotencyKey: key,
                status: .acknowledged,
                processedAt: Date()
            )
            body["receipt"] = receipt.jsonDictionary
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: body) else {
            sendResponse(.internalError, on: connection)
            return
        }
        if key != nil {
            await recordIdempotent(
                key: key,
                kind: kind,
                sessionId: sessionId,
                connection: connection,
                payloadHash: payloadHash,
                responseBody: bytes,
                responseStatus: 200
            )
        }
        sendResponse(.ok(contentType: "application/json", body: bytes), on: connection)
    }

    private func sendCodable<T: Encodable>(_ value: T, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(value) else {
            sendResponse(.internalError, on: connection)
            return
        }
        sendResponse(.ok(contentType: "application/json", body: body), on: connection)
    }

    /// v0.14.0: sendJSON with arbitrary HTTP status (used by T20 design
    /// bridge proxy to surface 503/400/502 with structured error JSON).
    private func sendJSON(_ object: [String: Any], on connection: NWConnection, status: Int) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        case 501: reason = "Not Implemented"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        default:  reason = "Status"
        }
        sendResponse(
            HTTPResponse(status: status, reason: reason, contentType: "application/json", body: body),
            on: connection
        )
    }

    private func httpResponseBytes(
        status: Int,
        statusText: String,
        contentType: String,
        body: Data,
        extraHeaders: [(String, String)] = []
    ) -> Data {
        var out = Data()
        out.append(Data("HTTP/1.1 \(status) \(statusText)\r\n".utf8))
        out.append(Data("Content-Type: \(contentType)\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n".utf8))
        for (name, value) in extraHeaders {
            out.append(Data("\(name): \(value)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }
}

// MARK: - Antigravity Plan endpoint (wire v7)

extension AgentControlServer {
    /// `GET /sessions/:id/antigravity-plan` — returns the parsed Plan
    /// snapshot for a Gemini session. Works in Disk mode (default);
    /// SDK mode (Commit 10) extends the data source via the sidecar.
    ///
    /// Brain resolution strategy:
    ///   1. Look up `~/.gemini/antigravity/agyhub_summaries_proto.pb` for
    ///      brain UUIDs whose cwd matches the session's repoKey.
    ///   2. If multiple, pick the brain dir with the newest mtime.
    ///   3. Parse the brain dir via BrainPlanParser.
    ///   4. Encode as AntigravityPlanSnapshot and send.
    func handleGetAntigravityPlan(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        // REV-Antigravity-polling (v0.8): chat sessions never have an
        // Antigravity brain — short-circuit before touching session.repoKey
        // (which is nil for chat sessions, would crash the URL constructor).
        guard session.kind == .code else {
            sendResponse(.notFound, on: connection); return
        }
        // Only respond for Gemini sessions. Claude/Codex sessions don't
        // have an Antigravity brain — return 404 with a clear shape so
        // iOS can fall back to "Plan tab not applicable for this agent".
        guard session.agent == .gemini else {
            sendResponse(.notFound, on: connection); return
        }

        let home = ClawdmeterRealHome.url()
        let antigravityDir = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let indexURL = antigravityDir.appendingPathComponent("agyhub_summaries_proto.pb", isDirectory: false)
        let stateURL = antigravityDir.appendingPathComponent("antigravity_state.pbtxt", isDirectory: false)

        let index = BrainSummaryIndexer.read(at: indexURL)
        // session.repoKey is non-nil here because the kind-guard above
        // short-circuits chat sessions; force-unwrap is safe.
        let cwdURL = URL(fileURLWithPath: session.repoKey!)
        var candidateUUIDs = BrainSummaryIndexer.lookup(cwd: cwdURL, in: index)
        if candidateUUIDs.isEmpty {
            // Fallback: glob all brain dirs and let mtime drive the pick.
            let brainsDir = antigravityDir.appendingPathComponent("brain", isDirectory: true)
            if let entries = try? FileManager.default.contentsOfDirectory(at: brainsDir, includingPropertiesForKeys: nil) {
                candidateUUIDs = entries.map { $0.lastPathComponent }
            }
        }

        let brainsDir = antigravityDir.appendingPathComponent("brain", isDirectory: true)
        let bestBrain = candidateUUIDs
            .map { brainsDir.appendingPathComponent($0, isDirectory: true) }
            .max(by: { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            })

        let state = try? AntigravityStateReader.read(at: stateURL)
        let sdkModeActive = UserDefaults.standard.bool(forKey: "clawdmeter.antigravity.sdkMode")
        let modelName = state?.displayModelName

        let snapshot: AntigravityPlanSnapshot
        if let brain = bestBrain {
            let planState = BrainPlanParser.parse(brainURL: brain)
            switch planState {
            case .ready(let plan):
                let convURL = antigravityDir
                    .appendingPathComponent("conversations", isDirectory: true)
                    .appendingPathComponent("\(plan.brainUUID).pb", isDirectory: false)
                let probe = ConversationProtoParser.probe(conversationURL: convURL, brainURL: brain)
                let totalUsage = WireTokenUsage(
                    total: probe.estimatedTokens,
                    prompt: nil, candidate: nil, thoughts: nil, cached: nil,
                    isEstimate: true
                )
                snapshot = AntigravityPlanSnapshot(
                    sessionId: session.id,
                    brainUUID: plan.brainUUID,
                    taskHeadline: plan.taskHeadline,
                    taskBody: plan.taskBody,
                    planSteps: Self.flatten(steps: plan.steps),
                    annotations: plan.annotations.map { WireBrainArtifact(id: $0.id, filename: $0.filename, body: $0.body) },
                    totalUsage: totalUsage,
                    lastUpdated: plan.lastUpdated,
                    model: modelName,
                    sdkModeActive: sdkModeActive,
                    awaitingFirstTurn: false
                )
            case .awaitingFirstTurn, .absent:
                snapshot = AntigravityPlanSnapshot(
                    sessionId: session.id,
                    brainUUID: brain.lastPathComponent,
                    taskHeadline: "",
                    taskBody: "",
                    planSteps: [],
                    annotations: [],
                    totalUsage: nil,
                    lastUpdated: Date(),
                    model: modelName,
                    sdkModeActive: sdkModeActive,
                    awaitingFirstTurn: true
                )
            }
        } else {
            // No brain dir at all — same shape as awaiting first turn,
            // empty brainUUID so iOS doesn't pretend it has a real id.
            snapshot = AntigravityPlanSnapshot(
                sessionId: session.id,
                brainUUID: "",
                taskHeadline: "",
                taskBody: "",
                planSteps: [],
                annotations: [],
                totalUsage: nil,
                lastUpdated: Date(),
                model: modelName,
                sdkModeActive: sdkModeActive,
                awaitingFirstTurn: true
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(snapshot) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// Flattens a nested tree of `BrainPlanStep` into a depth-indexed
    /// list of `WirePlanStep`. iOS renders the flat list with
    /// `.padding(.leading, CGFloat(step.depth) * 16)`.
    private static func flatten(steps: [BrainPlanStep]) -> [WirePlanStep] {
        var out: [WirePlanStep] = []
        for step in steps {
            out.append(WirePlanStep(id: step.id, label: step.label, isComplete: step.isComplete, depth: step.depth))
            out.append(contentsOf: flatten(steps: step.children))
        }
        return out
    }
}

// MARK: - HTTP request parsing helpers

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]  // lower-cased header names
    let body: Data
}

/// Streaming HTTP/1.1 request buffer. Accumulates bytes until a complete
/// request (headers + Content-Length body) is available, then returns it
/// from `tryParse()`. Reuses the same buffer across multiple `receive`
/// callbacks until parse succeeds.
///
/// @unchecked Sendable: this buffer is only ever mutated from within a
/// single NWConnection.receive callback chain; the callback shape isn't
/// quite Sendable-checkable but the runtime invariant holds.
private final class HTTPRequestBuffer: @unchecked Sendable {
    enum ParseError: Error {
        case badRequest
        case payloadTooLarge
    }

    private static let maxHeaderBytes = 32 * 1024
    /// Raised from 1MB → 50MB in v0.4.8 so iOS can POST raw image
    /// bytes to `/sessions/:id/attachments`. Tailscale ACL + bearer
    /// auth still gate who can reach the daemon, so the worst case is
    /// a paired peer wasting Mac memory on one malformed upload — and
    /// per-endpoint handlers still enforce their own caps (the send
    /// path stays at 1MB, the artifact endpoint at 50MB, attachment
    /// uploads at 50MB).
    private static let maxBodyBytes = 50 * 1024 * 1024

    var data = Data()

    func append(_ chunk: Data) {
        data.append(chunk)
    }

    /// Attempt to extract a complete HTTP request. Returns nil if more bytes
    /// are needed.
    func tryParse() throws -> HTTPRequest? {
        guard data.count <= Self.maxHeaderBytes + Self.maxBodyBytes else {
            throw ParseError.payloadTooLarge
        }
        // Find headers/body boundary.
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > Self.maxHeaderBytes { throw ParseError.payloadTooLarge }
            return nil
        }
        guard headerEndRange.lowerBound <= Self.maxHeaderBytes else {
            throw ParseError.payloadTooLarge
        }
        let headerBytes = data[..<headerEndRange.lowerBound]
        let headerText = String(decoding: headerBytes, as: UTF8.self)
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { throw ParseError.badRequest }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { throw ParseError.badRequest }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLengthRaw = headers["content-length"] ?? "0"
        guard let contentLength = Int(contentLengthRaw),
              contentLength >= 0 else {
            throw ParseError.badRequest
        }
        guard contentLength <= Self.maxBodyBytes else {
            throw ParseError.payloadTooLarge
        }
        let bodyStart = headerEndRange.upperBound
        let availableBody = data.count - bodyStart
        if availableBody < contentLength {
            return nil  // need more bytes
        }

        let body = data[bodyStart..<(bodyStart + contentLength)]
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }
}
