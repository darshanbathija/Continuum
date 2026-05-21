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

    public init(
        pairingTokens: PairingTokenStore = .shared,
        repoIndex: RepoIndex,
        registry: AgentSessionRegistry,
        tmux: TmuxControlClient,
        notifications: NotificationDispatcher,
        whois: TailscaleWhois = .shared,
        chatStoreRegistry: DaemonChatStoreRegistry? = nil,
        chatFileResolver: SessionFileResolver? = nil
    ) {
        self.pairingTokens = pairingTokens
        self.repoIndex = repoIndex
        self.registry = registry
        self.tmux = tmux
        self.notifications = notifications
        self.whois = whois
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

    // MARK: - Lifecycle

    /// Start the server. Tries default port first, falls back on conflict.
    /// Best-effort: if no port in the range works, logs and returns
    /// without starting. The Sessions tab handles "daemon offline" gracefully.
    public func start() {
        guard listener == nil else { return }
        let queue = DispatchQueue(label: "AgentControlServer.accept", qos: .userInitiated)
        self.listenerQueue = queue

        for port in AgentControlServer.portFallbackRange {
            if startListening(on: port, queue: queue) {
                boundPort = port
                serverLogger.info("HTTP listening on 0.0.0.0:\(port)")
                break
            }
        }
        guard let httpPort = boundPort else {
            serverLogger.error("Could not bind HTTP listener to any port in \(AgentControlServer.portFallbackRange.lowerBound)–\(AgentControlServer.portFallbackRange.upperBound)")
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
        writeServerJSON(port: httpPort, wsPort: boundWsPort ?? 0)
        // v0.5.3: warm the chat-store registry for the most recently-
        // touched JSONLs across ~/.claude/projects/ and ~/.codex/sessions/.
        // The first iPhone /chat-snapshot or /transcript request after
        // Mac restart hits a warm store instead of a cold reparse.
        // Async on a detached Task so it doesn't block listener bind.
        chatStoreRegistry.warm(recentLimit: 5)
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
        serverLogger.info("Server stopped")
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
                        ?? FileManager.default.homeDirectoryForCurrentUser.path
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
            // long-lived WS subscription. Server pushes the full
            // `WireChatSnapshot` on each coalesced 100ms commit window.
            // No delta encoding in v1 — Codex's outside-voice review (D6)
            // explicitly cut that scope until measurements show it's
            // needed.
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
                registry: chatStoreRegistry
            )
            wsChannels[ObjectIdentifier(connection)] = chatChannel
            chatChannel.start()
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
                sessionRegistry: registry
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
        let op: String           // "terminal" | "events" | "compose-draft" | "chat-subscribe" | "frontier-subscribe" | "codex-stream-subscribe"
        let token: String
        let sessionId: String?   // required for "terminal", "chat-subscribe", "codex-stream-subscribe"
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
            self?.handleGetModels(connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions") { [weak self] _, conn, _ in
            self?.handleGetSessions(connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/needs-attention") { [weak self] _, conn, _ in
            await self?.handleGetNeedsAttention(connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/preflight") { [weak self] req, conn, _ in
            await self?.handleGetPreflight(request: req, connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id") { [weak self] _, conn, params in
            self?.handleGetOneSession(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/chat-snapshot") { [weak self] req, conn, params in
            await self?.handleGetChatSnapshot(sessionId: params["id"] ?? "", request: req, connection: conn)
        }
        t.register(method: "GET", pattern: "/sessions/:id/diff") { [weak self] _, conn, params in
            await self?.handleGetDiff(sessionId: params["id"] ?? "", connection: conn)
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

        // --- POSTs ---
        t.register(method: "POST", pattern: "/sessions") { [weak self] req, conn, _ in
            await self?.handlePostSession(request: req, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/approve-plan") { [weak self] _, conn, params in
            await self?.handleApprovePlan(sessionId: params["id"] ?? "", connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/archive") { [weak self] _, conn, params in
            self?.handleArchive(sessionId: params["id"] ?? "", archived: true, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/unarchive") { [weak self] _, conn, params in
            self?.handleArchive(sessionId: params["id"] ?? "", archived: false, connection: conn)
        }
        t.register(method: "POST", pattern: "/sessions/:id/rename") { [weak self] req, conn, params in
            self?.handleRename(sessionId: params["id"] ?? "", request: req, connection: conn)
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
        t.register(method: "POST", pattern: "/sessions/:id/interrupt") { [weak self] _, conn, params in
            await self?.handleInterrupt(sessionId: params["id"] ?? "", connection: conn)
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
        t.register(method: "POST", pattern: "/devices/ack-notifications") { [weak self] req, conn, _ in
            await self?.handleAckNotifications(request: req, connection: conn)
        }
        t.register(method: "DELETE", pattern: "/live-activities/push-token") { [weak self] req, conn, _ in
            await self?.handleUnregisterPushToken(request: req, connection: conn)
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
        // v0.9 — Frontier endpoints. v0.8 shipped them as 501 stubs;
        // v0.9 lights them up alongside the chat-via-agentapi Gemini
        // backend so 3-pane Frontier (Claude / Codex / Gemini) is the
        // first surface with true 3-provider comparison.
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

    private func handleGetModels(connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(ModelCatalog.bundled) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    // MARK: - Sessions v2 Phase 0 handlers

    private func handleChangeModel(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(ChangeModelRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        guard !req.model.isEmpty, ModelCatalog.bundled.entry(forId: req.model) != nil else {
            sendResponse(.badRequest, on: connection); return
        }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        let oldModel = session.model
        let changer = SessionConfigChanger(registry: registry, tmux: tmux)
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
        await respondWithSession(uuid: uuid, connection: connection)
    }

    private func handleChangeEffort(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(ChangeEffortRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        let changer = SessionConfigChanger(registry: registry, tmux: tmux)
        let result = await changer.swap(sessionId: uuid, newEffort: .some(req.effort))
        guard isSuccessfulSwap(result) else {
            sendResponse(.internalError, on: connection); return
        }
        let peer = Self.endpointString(connection.endpoint)
        await AuditLog.shared.recordEffortChange(
            sessionId: uuid, sourcePeer: peer,
            model: session.model, effort: req.effort.rawValue
        )
        await respondWithSession(uuid: uuid, connection: connection)
    }

    private func handleChangeMode(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(ChangeModeRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        if req.mode == .cloud {
            sendResponse(.badRequest, on: connection); return
        }
        guard RateLimiter.shared.tryAcquireSwap(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSwap, on: connection); return
        }
        let changer = SessionConfigChanger(registry: registry, tmux: tmux)
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
        await respondWithSession(uuid: uuid, connection: connection)
    }

    private func handleSendPrompt(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(SendPromptRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
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
                sendJSON(["ok": true], on: connection)
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
            await sendChatSDKPrompt(session: session, prompt: req.text, connection: connection)
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
                    registry.rename(id: session.id, name: truncated)
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
            sendJSON(["ok": true], on: connection)
        } catch {
            serverLogger.error("send-prompt failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
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
            let projectsDir = FileManager.default.homeDirectoryForCurrentUser
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
        connection: NWConnection
    ) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
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

        let session = registry.createChat(
            provider: .gemini,
            model: model,
            chatCwd: "",
            effort: effort
        )
        let chatCwd: String
        do {
            let url = try ChatCwdManager.ensure(for: session.id)
            chatCwd = url.path
        } catch {
            serverLogger.error("agentapi chat-cwd create failed: \(error.localizedDescription, privacy: .public)")
            registry.delete(id: session.id)
            sendResponse(.internalError, on: connection); return
        }
        registry.updateRuntime(
            id: session.id, worktreePath: chatCwd,
            tmuxWindowId: nil, tmuxPaneId: nil, mode: .local
        )

        let modelTier = AgentapiModelTier.from(modelCatalogId: model)
        do {
            let conversationIdString = try await lsClient.newConversation(
                modelTier: modelTier,
                prompt: "(starting new chat)",
                projectId: projectId
            )
            guard let conversationId = UUID(uuidString: conversationIdString) else {
                serverLogger.error("agentapi returned non-UUID conversation id: \(conversationIdString, privacy: .public)")
                registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                sendResponse(.internalError, on: connection); return
            }
            registry.setAntigravityChatBinding(
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
            registry.delete(id: session.id)
            try? ChatCwdManager.remove(for: session.id)
            sendResponse(HTTPResponse(
                status: 503, reason: "Service Unavailable", contentType: "application/json",
                body: Data(#"{"error":"antigravity_not_running","cta":"Open Antigravity 2 to continue this session"}"#.utf8)
            ), on: connection)
        } catch {
            serverLogger.error("agentapi new-conversation failed: \(error.localizedDescription, privacy: .public)")
            registry.delete(id: session.id)
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
                resumeSessionId: cliSessionId
            ) ?? []
        case .gemini:
            // No interactive Gemini CLI yet — fall through to the
            // missing-binary surface so the request returns a 4xx
            // instead of silently spawning an empty process.
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
            let window = try await tmux.newWindow(cwd: req.repoKey, child: argv)
            let session = registry.create(
                repoKey: req.repoKey,
                repoDisplayName: (req.repoKey as NSString).lastPathComponent,
                agent: req.agent,
                model: modelDefault,
                goal: nil,
                worktreePath: nil,
                tmuxWindowId: window.windowId,
                tmuxPaneId: window.paneId,
                planMode: false
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

    private func handleInterrupt(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid),
              let paneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            sendResponse(.notFound, on: connection); return
        }
        do {
            try await tmux.sendKeys(paneId: paneId, bytes: Data([0x1b]))  // ESC
            sendJSON(["ok": true], on: connection)
        } catch {
            sendResponse(.internalError, on: connection)
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
        await respondWithSession(uuid: uuid, connection: connection)
    }

    private func handlePickPairWinner(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(PickWinnerRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        guard let result = registry.pickPairWinner(sessionId: uuid, winner: req.winnerSessionId) else {
            sendResponse(.notFound, on: connection); return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch result {
        case .decided(let winner, let decidedAt):
            let body = try? encoder.encode([
                "winnerSessionId": winner.uuidString,
                "decidedAt": ISO8601DateFormatter().string(from: decidedAt),
            ])
            sendResponse(.ok(contentType: "application/json", body: body ?? Data()), on: connection)
        case .alreadyDecided(let winner, let decidedAt):
            let payload = PickWinnerConflictResponse(winnerSessionId: winner, decidedAt: decidedAt)
            let body = (try? encoder.encode(payload)) ?? Data()
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
        let cwd = session.effectiveCwd
        guard let gitBin = ShellRunner.locateBinary("git") else {
            sendResponse(.internalError, on: connection); return
        }
        // Refuse to diff mid-rebase/merge (Codex #11 / T11).
        if FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git/rebase-merge"))
            || FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git/MERGE_HEAD")) {
            sendResponse(HTTPResponse(
                status: 409, reason: "Conflict",
                contentType: "application/json",
                body: Data(#"{"error":"Repo is in rebase/merge state, finish on Mac"}"#.utf8)
            ), on: connection)
            return
        }
        do {
            let numstat = try await ShellRunner.shared.run(
                executable: gitBin,
                arguments: ["diff", "--numstat", "HEAD"],
                cwd: cwd,
                timeout: 10
            )
            var files: [ClawdmeterShared.GitDiffFile] = []
            for line in numstat.stdoutString.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3,
                      let additions = Int(parts[0]),
                      let deletions = Int(parts[1]) else { continue }
                files.append(ClawdmeterShared.GitDiffFile(
                    path: parts[2], status: "M",
                    additions: additions, deletions: deletions,
                    hunks: [], truncated: true
                ))
            }
            let encoder = JSONEncoder()
            if let body = try? encoder.encode(files) {
                sendResponse(.ok(contentType: "application/json", body: body), on: connection)
            } else {
                sendResponse(.internalError, on: connection)
            }
        } catch {
            serverLogger.error("git diff failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleGetPR(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), registry.session(id: uuid) != nil else {
            sendResponse(.notFound, on: connection); return
        }
        // Phase 4 wires PRMirror; Phase 0 returns null (iOS shows "Create PR" CTA).
        sendJSON(["pr": NSNull()], on: connection)
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
            sendJSON(["url": prURL], on: connection)
        } catch {
            sendResponse(.internalError, on: connection)
        }
    }

    private func handleMerge(sessionId: String, request: HTTPRequest, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        let cwd = session.effectiveCwd
        guard let gitBin = ShellRunner.locateBinary("git") else {
            sendResponse(.internalError, on: connection); return
        }
        do {
            let branchResult = try await ShellRunner.shared.run(
                executable: gitBin, arguments: ["symbolic-ref", "--short", "HEAD"],
                cwd: cwd, timeout: 5
            )
            let target = branchResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let isProtected = ["main", "master"].contains(target)
            let override = request.path.contains("override=true")
            if isProtected && !override {
                sendResponse(HTTPResponse(
                    status: 409, reason: "Conflict",
                    contentType: "application/json",
                    body: Data(#"{"error":"Target branch is protected; pass override=true or open a PR","requireExplicitOverride":true}"#.utf8)
                ), on: connection); return
            }
            sendJSON(["ok": true, "merged": false, "note": "Phase 4 merge impl pending"], on: connection)
        } catch {
            sendResponse(.internalError, on: connection)
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
            registry.addTerminalPane(sessionId: uuid, pane: pane)
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
            registry.removeTerminalPane(sessionId: uuid, paneRefId: pane.id)
            sendJSON(["ok": true], on: connection)
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
            let messages = url.map { TranscriptLoader.load(from: $0, maxMessages: 500) } ?? []
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
        let snapshot = WireChatSnapshot(
            sessionId: session.id,
            items: snapshotItems,
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            // v0.7.8: forward Codex SDK todos when the warm store has them.
            // Cold fallback keeps empty — codex todos only land via SDK
            // events, which the store accumulates while live.
            codexTodos: registryStore?.snapshot.codexTodos ?? [],
            // v0.8 QA: forward any pending CLI permission prompt so iOS
            // (or HTTP-polling clients) can render the AskUserQuestion-
            // style card too. Mac UI reads the @Published property
            // directly on SessionChatStore.
            pendingPermissionPrompt: registryStore?.pendingPermissionPrompt,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            lastEventAt: snapshotLastEventAt,
            updateCounter: snapshotCounter
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
        var maxMessages = 500
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let value = kv[1].removingPercentEncoding ?? kv[1]
            switch kv[0] {
            case "path": jsonlPath = value
            case "limit": maxMessages = max(1, min(2000, Int(value) ?? 500))
            default: break
            }
        }
        guard let jsonlPath else {
            sendResponse(.notFound, on: connection)
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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
        // 500 messages on every request. Cold miss falls back to the
        // legacy synchronous TranscriptLoader.load path; the store
        // warms up in the background and subsequent requests within
        // the 5-minute idle window hit the cache.
        let registryStore = chatStoreRegistry.snapshotStore(forJSONLPath: url)
        let messages: [ChatMessage]
        if let store = registryStore, !store.snapshot.messages.isEmpty {
            // Cap to the requested maxMessages, taking the tail so the
            // most recent messages are surfaced — matches what
            // TranscriptLoader.load(maxMessages:) does today.
            let all = store.snapshot.messages
            messages = all.suffix(maxMessages).map { $0 }
        } else {
            messages = TranscriptLoader.load(from: url, maxMessages: maxMessages)
        }
        let envelope = TranscriptEnvelope(
            path: jsonlPath,
            messages: messages,
            truncated: messages.count >= maxMessages
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

    private func handlePostSession(request: HTTPRequest, connection: NWConnection) async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let req = try? decoder.decode(NewSessionRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
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
        if req.useWorktree {
            // Mint a city up front so the worktree path + branch use the
            // same name. The session id we'll register with is captured
            // here so CityNamer's mapping is stable.
            let provisionalSessionId = UUID()
            let city = await MainActor.run {
                CityNamer.shared.cityName(for: provisionalSessionId)
            }
            let slug = WorktreeManager.slug(city: city)
            do {
                worktreePath = try await WorktreeManager.shared.add(
                    repoRoot: req.repoKey,
                    slug: slug,
                    branchName: slug,
                    baseBranch: req.baseBranch
                )
                cwd = worktreePath!
            } catch {
                serverLogger.error("worktree add failed: \(error.localizedDescription, privacy: .public)")
                // Release the city back to the pool — we didn't actually
                // create the session.
                await MainActor.run {
                    CityNamer.shared.release(provisionalSessionId)
                }
                sendResponse(.internalError, on: connection)
                return
            }
        }

        // Build agent argv per E4.
        let argv = AgentSpawner.argv(for: req)
        guard !argv.isEmpty else {
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
            let window = try await tmux.newWindow(cwd: cwd, child: argv)
            // Phase 2 simplification: pane id = first pane of the new window.
            // tmux's `list-windows -F '#{pane_id}'` would tell us, but we
            // derive it lazily for now.
            let session = registry.create(
                repoKey: req.repoKey,
                repoDisplayName: (req.repoKey as NSString).lastPathComponent,
                agent: req.agent,
                model: req.model,
                goal: req.goal,
                worktreePath: worktreePath,
                tmuxWindowId: window.windowId,
                tmuxPaneId: window.paneId,
                planMode: req.planMode
            )
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
            if req.agent == .codex && req.planMode {
                registry.setPlanText(
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
            serverLogger.error("Failed to spawn session: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
    }

    // MARK: - v0.8 Chat tab (wire v9)

    /// `POST /chat-sessions`: spawn a new chat-kind AgentSession in an
    /// empty per-session chat-cwd. Forces plan-mode. Branches on
    /// (agent, codexChatBackend) per RE1. Gemini chat returns 501 in
    /// v0.8 (deferred to v0.9 alongside Antigravity-via-agy).
    private func handlePostChatSession(request: HTTPRequest, connection: NWConnection) async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let req = try? decoder.decode(CreateChatSessionRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection)
            return
        }
        // v0.9: Gemini chat dispatches to Antigravity 2's agentapi via
        // a new daemon-side handler. Chat has no repoKey, so the helper
        // picks the first available Antigravity project as a scratch
        // workspace. Surfaces 503 with structured CTA bodies when
        // Antigravity isn't installed / signed in / running / has no
        // projects open. The v0.8 501 stub is gone now that agentapi-
        // via-chat is live (wire v11 / antigravityChatMinimum=11 gate).
        if req.provider == .gemini {
            await handlePostGeminiChatSession(
                model: req.model,
                effort: req.effort,
                connection: connection
            )
            return
        }
        // Determine the Codex backend choice for this session. For non-
        // Codex providers, leave it nil. For Codex, honor the per-request
        // override if present; otherwise fall back to the global default
        // (RE1: ship .sdk as the v0.8 default).
        let codexBackend: CodexChatBackend? = {
            guard req.provider == .codex else { return nil }
            return req.codexChatBackend ?? .sdk
        }()
        // Create the session record first (assigns a UUID we can use to
        // name the chat-cwd).
        let session = registry.createChat(
            provider: req.provider,
            model: req.model,
            chatCwd: "",  // placeholder; we'll patch it post-cwd-creation
            codexChatBackend: codexBackend,
            effort: req.effort
        )
        let chatCwd: String
        do {
            let url = try ChatCwdManager.ensure(for: session.id)
            chatCwd = url.path
        } catch {
            serverLogger.error("chat-cwd create failed for \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            registry.delete(id: session.id)
            sendResponse(.internalError, on: connection)
            return
        }
        // Patch the worktreePath on the created session so effectiveCwd
        // resolves to the chat-cwd. The createChat helper stored it as
        // empty-string; rewrite via the existing update pattern.
        registry.updateRuntime(
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
            registry.delete(id: session.id)
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
                registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                sendResponse(HTTPResponse(
                    status: 504, reason: "Gateway Timeout",
                    contentType: "application/json",
                    body: Data(#"{"error":"tmux_unresponsive","hint":"Quit Clawdmeter and relaunch; if the issue persists, kill any stale tmux processes with: pkill -9 -f tmux"}"#.utf8)
                ), on: connection)
                return
            }
            registry.updateRuntime(
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

    /// Frontier endpoints stub. Returns 501 in v0.8 — the routes exist
    /// for forward-compat (clients can probe), but the full implementation
    /// (real spawn, FrontierWebSocketChannel, per-slot retry, pick-winner
    /// fork) lands in v0.9 alongside the Antigravity replacement so the
    /// 3-pane UI can use the full Claude+Codex+Gemini matrix.
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
    /// to every non-failed child. Each child is a regular chat session
    /// so we reuse the existing /sessions/:id/send semantics by
    /// dispatching to the underlying send logic per child.
    private func handleFrontierSend(
        request: HTTPRequest,
        connection: NWConnection,
        groupId: String
    ) async {
        guard let uuid = UUID(uuidString: groupId) else {
            sendResponse(.badRequest, on: connection); return
        }
        let children = registry.frontierGroupChildren(groupId: uuid)
        guard !children.isEmpty else {
            sendResponse(.notFound, on: connection); return
        }
        guard let req = try? JSONDecoder().decode(SendPromptRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        // Fan-out. Each child swallows + logs its own error so the
        // others continue (D10 partial). Per-child results are
        // observable via chat-subscribe WS frames on each session id;
        // the aggregate HTTP response is just 202 Accepted.
        for child in children {
            Task { [weak self] in
                await self?.forwardFrontierChildSend(session: child, text: req.text)
            }
        }
        sendResponse(HTTPResponse(
            status: 202, reason: "Accepted",
            contentType: "application/json",
            body: Data("{\"ok\":true,\"childCount\":\(children.count)}".utf8)
        ), on: connection)
        if let counter = frontierUpdateCounters[uuid] {
            frontierUpdateCounters[uuid] = counter + 1
        }
    }

    /// Best-effort send to one Frontier child. Mirrors the dispatch
    /// inside handleSendPrompt (agentapi vs SDK vs tmux) but does NOT
    /// touch the HTTP connection — Frontier fan-out caller already
    /// returned a 202. Errors are logged + dropped.
    private func forwardFrontierChildSend(session: AgentSession, text: String) async {
        // agentapi (Gemini)
        if session.geminiBackend == .agentapi,
           let conversationId = session.antigravityConversationId {
            do {
                try await sendAntigravityMessage(
                    session: session, conversationId: conversationId, content: text
                )
            } catch {
                serverLogger.warning("frontier child gemini send failed: \(error.localizedDescription, privacy: .public)")
            }
            return
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
                        skipGitRepoCheck: true
                    )
                } else {
                    _ = try CodexSubscriptionRelay.shared.start(
                        session: session,
                        workingDirectory: cwd,
                        initialPrompt: text,
                        threadId: nil,
                        sandboxMode: "read-only",
                        skipGitRepoCheck: true
                    )
                }
            } catch {
                serverLogger.warning("frontier child codex-sdk send failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        // CLI (Claude / Codex CLI)
        guard let paneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            serverLogger.warning("frontier child has no pane id — skipping send")
            return
        }
        do {
            let bytes = text.data(using: .utf8) ?? Data()
            try await tmux.pasteBytes(paneId: paneId, bytes: bytes + Data([0x0D]))
        } catch {
            serverLogger.warning("frontier child tmux paste failed: \(error.localizedDescription, privacy: .public)")
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
            codexChatBackend: existing.codexChatBackend
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
        registry.delete(id: existing.id)
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
    /// non-winning children, return the winner's sessionId. The winner
    /// becomes a regular Solo chat (still tagged with frontierGroupId so
    /// history is preserved; the sidebar promotes it out of the group).
    private func handlePickFrontierWinner(
        request: HTTPRequest,
        connection: NWConnection,
        groupId: String
    ) async {
        guard let uuid = UUID(uuidString: groupId),
              let req = try? JSONDecoder().decode(PickFrontierWinnerRequest.self, from: request.body) else {
            sendResponse(.badRequest, on: connection); return
        }
        let children = registry.frontierGroupChildren(groupId: uuid)
        guard let winner = children.first(where: { $0.frontierChildIndex == req.childIndex }) else {
            sendResponse(.notFound, on: connection); return
        }
        // Archive the losers. Existing archive path persists archivedAt
        // and the sidebar's Show-Archived toggle keeps them reachable.
        for child in children where child.id != winner.id {
            registry.archive(id: child.id)
        }
        if let counter = frontierUpdateCounters[uuid] {
            frontierUpdateCounters[uuid] = counter + 1
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
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
        switch slot.provider {
        case .claude, .codex:
            // Reuse the same plumbing as Solo chat: createChat → chat-cwd →
            // spawn tmux (or SDK relay) → warm chat store. We don't need
            // the full HTTP wrapper since we already have all the data.
            let codexBackend: CodexChatBackend? = slot.provider == .codex
                ? (slot.codexChatBackend ?? .sdk)
                : nil
            let session = registry.createChat(
                provider: slot.provider,
                model: slot.model,
                chatCwd: "",
                codexChatBackend: codexBackend,
                frontierGroupId: groupId,
                frontierChildIndex: childIndex
            )
            let chatCwd: String
            do {
                let url = try ChatCwdManager.ensure(for: session.id)
                chatCwd = url.path
            } catch {
                registry.delete(id: session.id)
                throw SpawnFailure.message("chat_cwd_create_failed: \(error.localizedDescription)")
            }
            registry.updateRuntime(
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
                registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("agent_cli_not_found")
            }
            // CLI: spawn tmux. Best-effort — children that fail to spawn
            // are surfaced as a slot failure, not a 500.
            do {
                try await tmux.start()
                let window = try await tmux.newWindow(cwd: chatCwd, child: argv)
                registry.updateRuntime(
                    id: session.id, worktreePath: chatCwd,
                    tmuxWindowId: window.windowId, tmuxPaneId: window.paneId, mode: .local
                )
                _ = chatStoreRegistry.snapshotStore(for: registry.session(id: session.id) ?? updated)
                return registry.session(id: session.id) ?? updated
            } catch {
                registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("tmux_spawn_failed: \(error.localizedDescription)")
            }
        case .gemini:
            // Delegate to the agentapi spawn flow. We can't reuse
            // handlePostGeminiChatSession directly (it owns the
            // connection write), but we lift the same body into a
            // shared helper-style inline call here.
            let home = FileManager.default.homeDirectoryForCurrentUser
            let projectsDir = home.appendingPathComponent(".gemini/config/projects", isDirectory: true)
            let lsClient = LanguageServerClient()
            let resolver = AntigravityProjectResolver(projectsDir: projectsDir)
            let projects = await resolver.allProjects()
            guard let projectId = projects.first?.id else {
                throw SpawnFailure.message("antigravity_no_projects")
            }
            let session = registry.createChat(
                provider: .gemini,
                model: slot.model,
                chatCwd: "",
                frontierGroupId: groupId,
                frontierChildIndex: childIndex
            )
            let chatCwd: String
            do {
                let url = try ChatCwdManager.ensure(for: session.id)
                chatCwd = url.path
            } catch {
                registry.delete(id: session.id)
                throw SpawnFailure.message("chat_cwd_create_failed: \(error.localizedDescription)")
            }
            registry.updateRuntime(
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
                    registry.delete(id: session.id)
                    try? ChatCwdManager.remove(for: session.id)
                    throw SpawnFailure.message("agentapi_bad_conversation_id")
                }
                registry.setAntigravityChatBinding(
                    id: session.id, conversationId: conversationId, projectId: projectId
                )
                let updated = registry.session(id: session.id) ?? session
                _ = chatStoreRegistry.snapshotStore(for: updated)
                return updated
            } catch let LanguageServerClientError.notRunning {
                registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("antigravity_not_running")
            } catch {
                registry.delete(id: session.id)
                try? ChatCwdManager.remove(for: session.id)
                throw SpawnFailure.message("agentapi_new_conversation_failed: \(error.localizedDescription)")
            }
        case .unknown:
            // X3: forward-compat unknown agent — no frontier-child spawn
            // path. Surfaces as a slot failure to the broadcast caller.
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
    private func sendChatSDKPrompt(
        session: AgentSession,
        prompt: String,
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
                registry.rename(id: session.id, name: truncated)
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
                    skipGitRepoCheck: true
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
                                registryRef?.setCodexChatThreadId(id: session.id, threadId: threadId)
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
        if let body = try? encoder.encode(updated) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.ok(contentType: "application/json", body: Data("{}".utf8)), on: connection)
        }
    }

    /// v0.8 QA: prepare a CLI pane (code or chat) for the user's first
    /// prompt. Same flow either way:
    /// - **Codex update prompt**: auto-update (per user spec — always
    ///   take the latest, no question asked).
    /// - **Codex trust prompt**: surface to the user via the
    ///   PermissionPromptCard; await their click; never auto-dismiss.
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
        case .unknown:
            // X3: forward-compat unknown agent — no warmup choreography
            // plumbed. Future adapters (e.g. opencode in PR #28) take
            // their own non-tmux warmup path before reaching here.
            break
        }
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
        let projectDir = FileManager.default.homeDirectoryForCurrentUser
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
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
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

    private func handleApprovePlan(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid),
              let windowId = session.tmuxWindowId else {
            sendResponse(.notFound, on: connection)
            return
        }
        guard session.status == .planning,
              session.planText?.isEmpty == false || session.agent == .codex else {
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
                autopilot: false
            )
        case .gemini:
            // approve-plan from Gemini is unsupported in v6 — there's no
            // gemini CLI to respawn. Surfaces as 500 below.
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
        do {
            try await tmux.killWindow(windowId)
            let cwd = session.effectiveCwd
            let newWindow = try await tmux.newWindow(cwd: cwd, child: replacementArgv)
            registry.updateRuntime(
                id: uuid,
                worktreePath: session.worktreePath,
                tmuxWindowId: newWindow.windowId,
                tmuxPaneId: newWindow.paneId,
                mode: session.mode
            )
            // Clear the plan card and flip status to running so the
            // approve button disappears from the chat UI.
            registry.updateStatus(id: uuid, status: .running)
            registry.setPlanText(id: uuid, planText: "")
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
            sendResponse(.ok(contentType: "application/json", body: Data(#"{"ok":true}"#.utf8)), on: connection)
        } catch {
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
    ) {
        guard let uuid = UUID(uuidString: sessionId),
              registry.session(id: uuid) != nil
        else {
            sendResponse(.notFound, on: connection)
            return
        }
        if archived {
            registry.archive(id: uuid)
        } else {
            registry.unarchive(id: uuid)
        }
        sendResponse(.ok(contentType: "application/json", body: Data("{}".utf8)), on: connection)
    }

    /// v0.5.4 — `POST /sessions/:id/rename` with body `{name: String?}`.
    /// Empty/whitespace-only names normalize to nil at the registry
    /// (clearing the custom name → sidebar falls back to repoDisplayName).
    private func handleRename(
        sessionId: String,
        request: HTTPRequest,
        connection: NWConnection
    ) {
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
        registry.rename(id: uuid, name: body.name)
        sendResponse(.ok(contentType: "application/json", body: Data("{}".utf8)), on: connection)
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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
        } else if session.kind == .code, let worktreePath = session.worktreePath, let repoRoot = session.repoKey {
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
        registry.delete(id: uuid)
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
        PathValidator.isValidJsonlPath(path)
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
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

        let home = FileManager.default.homeDirectoryForCurrentUser
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
