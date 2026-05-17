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

    /// Tracks live connections so we can drain on shutdown.
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Active WebSocket channels keyed by connection. Both terminal +
    /// event streams conform to `WSChannel`.
    private var wsChannels: [ObjectIdentifier: any WSChannel] = [:]

    /// JSONL tail + done-detector + plan-watcher wired per active session.
    private var sessionWiring: [UUID: SessionEventWiring] = [:]

    public init(
        pairingTokens: PairingTokenStore = .shared,
        repoIndex: RepoIndex,
        registry: AgentSessionRegistry,
        tmux: TmuxControlClient,
        notifications: NotificationDispatcher,
        whois: TailscaleWhois = .shared
    ) {
        self.pairingTokens = pairingTokens
        self.repoIndex = repoIndex
        self.registry = registry
        self.tmux = tmux
        self.notifications = notifications
        self.whois = whois
    }

    /// Hand the daemon the live usage publishers + analytics store
    /// AppRuntime owns. Called once after AppRuntime's `init` finishes —
    /// we can't take these as init args because they all live on
    /// AppRuntime and we'd cycle. Idempotent.
    public func attachUsageSources(
        claude: AppModel?,
        codex: AppModel?,
        history: UsageHistoryStore?
    ) {
        self.claudeModel = claude
        self.codexModel = codex
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
            // Bind 0.0.0.0 — Network.framework defaults to localhost.
            // We filter on accept in `handleNewConnection`.
            params.requiredInterfaceType = .other  // any interface
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
        guard let envelope = try? JSONDecoder().decode(WSSubscription.self, from: firstMessage) else {
            serverLogger.debug("WS: malformed subscription envelope")
            sendWSClose(on: connection, code: .protocolCode(.protocolError))
            return
        }
        // Auth.
        guard pairingTokens.validate(envelope.token) else {
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
                NotificationCenter.default.post(
                    name: Notification.Name("clawdmeter.workspace.composeDraftIncoming"),
                    object: nil,
                    userInfo: ["draft": payload]
                )
                serverLogger.info("compose-draft received: text length=\(payload.text.count, privacy: .public), repo=\(payload.repoKey ?? "-", privacy: .public)")
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
        let op: String           // "terminal" | "events" | "compose-draft"
        let token: String
        let sessionId: String?   // required for "terminal"
        let since: UInt64?       // optional for "events"
        /// G12: target a specific pane (multi-terminal tab strip). When nil,
        /// the server falls back to the session's primary pane.
        let paneId: String?
        /// X1: compose-draft single-shot payload. Only populated when
        /// `op == "compose-draft"`. The Mac UI consumes via NotificationCenter.
        let draft: ComposeDraft?
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
        guard let auth = request.headers["authorization"],
              auth.hasPrefix("Bearer "),
              pairingTokens.validate(String(auth.dropFirst("Bearer ".count)))
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
        t.register(method: "POST", pattern: "/sessions/:id/interrupt") { [weak self] _, conn, params in
            await self?.handleInterrupt(sessionId: params["id"] ?? "", connection: conn)
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
        guard let paneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            sendResponse(.internalError, on: connection); return
        }
        guard RateLimiter.shared.tryAcquireSend(sessionId: uuid) else {
            sendResponse(.tooManyRequestsSend, on: connection); return
        }
        do {
            let data = Data(bytes)
            if req.asFollowUp || bytes.count > 256 || req.text.contains("\n") {
                try await tmux.pasteBytes(paneId: paneId, bytes: data)
            } else {
                try await tmux.sendKeys(paneId: paneId, bytes: data)
            }
            let peer = Self.endpointString(connection.endpoint)
            await AuditLog.shared.recordSend(sessionId: uuid, sourcePeer: peer, text: req.text)
            sendJSON(["ok": true], on: connection)
        } catch {
            serverLogger.error("send-prompt failed: \(error.localizedDescription, privacy: .public)")
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
        AutopilotState.shared.setEnabled(req.enabled, sessionId: uuid)
        let peer = Self.endpointString(connection.endpoint)
        await AuditLog.shared.recordAutopilotToggle(
            sessionId: uuid, sourcePeer: peer,
            enabled: req.enabled, repoKey: session.repoKey
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
        let cwd = session.worktreePath ?? session.repoKey
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
        let cwd = session.worktreePath ?? session.repoKey
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
        let cwd = session.worktreePath ?? session.repoKey
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
        let repoCwd = session.worktreePath ?? session.repoKey
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
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              let size = attrs[.size] as? Int,
              size <= 50_000_000 else {
            sendResponse(.notFound, on: connection); return
        }
        guard let data = try? Data(contentsOf: url) else {
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
                cwd: session.worktreePath ?? session.repoKey,
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
        let cwd = session.worktreePath ?? session.repoKey
        let url: URL?
        if session.agent == .claude {
            url = SessionChatStore.resolveSessionFileURL(repoCwd: cwd)
        } else {
            url = newestCodexJSONL()
        }
        let messages = url.map { TranscriptLoader.load(from: $0, maxMessages: 500) } ?? []
        var builder = ChatItemBuilder()
        for message in messages {
            builder.ingest(message)
        }
        builder.flushPending()
        let snapshot = WireChatSnapshot(
            sessionId: session.id,
            items: builder.items,
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 0,
            totalOutputTokens: 0,
            lastEventAt: session.lastEventAt,
            updateCounter: session.lastEventSeq
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
        let payload = UsageEnvelope(
            claude: claudeModel?.usage,
            codex: codexModel?.usage,
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
        let messages = TranscriptLoader.load(from: url, maxMessages: maxMessages)
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
        var cwd = req.repoKey  // assume repoKey is an absolute path
        var worktreePath: String? = nil
        if req.useWorktree {
            let slug = WorktreeManager.slug(goal: req.goal, sessionId: UUID())
            do {
                worktreePath = try await WorktreeManager.shared.add(
                    repoRoot: req.repoKey,
                    slug: slug,
                    baseBranch: req.baseBranch
                )
                cwd = worktreePath!
            } catch {
                serverLogger.error("worktree add failed: \(error.localizedDescription, privacy: .public)")
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
        }
        guard let replacementArgv = argv else {
            serverLogger.error("approve-plan: missing CLI binary for \(session.agent.rawValue, privacy: .public)")
            sendResponse(.internalError, on: connection)
            return
        }
        do {
            try await tmux.killWindow(windowId)
            let cwd = session.worktreePath ?? session.repoKey
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

    private func handleDeleteSession(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection)
            return
        }
        // Kill the tmux window.
        if let windowId = session.tmuxWindowId {
            do {
                try await tmux.killWindow(windowId)
            } catch {
                serverLogger.warning("kill-window \(windowId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Schedule worktree GC if applicable (24h grace per D12; for v1
        // we synchronously attempt delete and surface skip-reasons).
        if let worktreePath = session.worktreePath {
            do {
                let result = try await WorktreeManager.shared.delete(
                    repoRoot: session.repoKey,
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
    private static let maxBodyBytes = 1_000_000

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
