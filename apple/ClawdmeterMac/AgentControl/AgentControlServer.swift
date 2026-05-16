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
        case "terminal":
            guard let sessionIdString = envelope.sessionId,
                  let sessionId = UUID(uuidString: sessionIdString),
                  let session = registry.session(id: sessionId)
            else {
                sendWSClose(on: connection, code: .protocolCode(.unsupportedData))
                return
            }
            // G12: envelope can target a specific pane within the session
            // (multi-terminal tab strip). Falls back to the session's
            // primary pane / window for the single-terminal case.
            let paneId: String? = {
                if let explicit = envelope.paneId, !explicit.isEmpty {
                    return explicit
                }
                return session.tmuxPaneId ?? session.tmuxWindowId
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
        let op: String           // "terminal" | "events"
        let token: String
        let sessionId: String?   // required for "terminal"
        let since: UInt64?       // optional for "events"
        /// G12: target a specific pane (multi-terminal tab strip). When nil,
        /// the server falls back to the session's primary pane.
        let paneId: String?
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
                if let request = buffer.tryParse() {
                    Task { @MainActor in
                        await self?.dispatch(request: request, connection: connection)
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

        switch (request.method, request.path) {
        case ("GET", "/repos"):
            await handleGetRepos(connection: connection)
        case ("GET", "/sessions"):
            handleGetSessions(connection: connection)
        case ("POST", "/sessions"):
            await handlePostSession(request: request, connection: connection)
        case ("GET", let path) where path.hasPrefix("/sessions/") && !path.hasSuffix("/needs-attention"):
            // GET /sessions/<uuid>
            let sessionId = String(path.dropFirst("/sessions/".count))
            handleGetOneSession(sessionId: sessionId, connection: connection)
        case ("DELETE", let path) where path.hasPrefix("/sessions/"):
            let sessionId = String(path.dropFirst("/sessions/".count))
            await handleDeleteSession(sessionId: sessionId, connection: connection)
        case ("POST", let path) where path.hasSuffix("/approve-plan") && path.hasPrefix("/sessions/"):
            // /sessions/<uuid>/approve-plan
            let withoutPrefix = String(path.dropFirst("/sessions/".count))
            let sessionIdRaw = String(withoutPrefix.dropLast("/approve-plan".count))
            await handleApprovePlan(sessionId: sessionIdRaw, connection: connection)
        case ("GET", "/sessions/needs-attention"):
            await handleGetNeedsAttention(connection: connection)
        case ("GET", "/health"):
            sendJSON(["ok": true], on: connection)
        default:
            sendResponse(.notFound, on: connection)
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

        // Spawn into a new tmux window.
        do {
            try await tmux.start()  // idempotent
            let windowId = try await tmux.newWindow(cwd: cwd, child: argv)
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
                tmuxWindowId: windowId,
                tmuxPaneId: nil,
                planMode: req.planMode
            )
            // Wire up JSONL tail + done-detector + plan-watcher for this
            // session (Phase 4). Best-effort: find the agent's JSONL file
            // under ~/.claude/projects/<encoded-cwd>/.
            if req.agent == .claude {
                attachClaudeWiring(for: session, cwd: cwd)
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
                    registry: self.registry
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

    private func handleApprovePlan(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId),
              let session = registry.session(id: uuid),
              let windowId = session.tmuxWindowId else {
            sendResponse(.notFound, on: connection)
            return
        }
        // Per D13: kill the plan-mode pane, spawn a fresh acceptEdits pane
        // in the same window. Overlay covers the swap UI-side.
        do {
            try await tmux.killWindow(windowId)
            // Spawn replacement.
            let argv = [
                "/Users/darshanbathija_1/.local/bin/claude",
                "--permission-mode", "acceptEdits",
            ]
            let cwd = session.worktreePath ?? session.repoKey
            let newWindow = try await tmux.newWindow(cwd: cwd, child: argv)
            // Update registry.
            registry.updateStatus(id: uuid, status: .running)
            // (Plan card no longer applies; clear if needed in future.)
            AgentEventStream.recordEvent(
                sessionId: uuid,
                kind: .statusChanged,
                payload: ["status": "running", "newWindowId": newWindow]
            )
            sendResponse(.ok(contentType: "application/json", body: Data(#"{"ok":true}"#.utf8)), on: connection)
        } catch {
            serverLogger.error("approve-plan failed: \(error.localizedDescription, privacy: .public)")
            sendResponse(.internalError, on: connection)
        }
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
        // Phase 1: empty queue. NotificationDispatcher (Phase 4) fills this in.
        let response = NeedsAttentionResponse(events: [], serverTime: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(response) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    // MARK: - Response sending

    private enum HTTPResponse {
        case ok(contentType: String, body: Data)
        case badRequest
        case notFound
        case unauthorized
        case internalError
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let bytes: Data
        switch response {
        case .ok(let contentType, let body):
            bytes = httpResponseBytes(status: 200, statusText: "OK",
                                      contentType: contentType, body: body)
        case .badRequest:
            bytes = httpResponseBytes(status: 400, statusText: "Bad Request",
                                      contentType: "text/plain", body: Data("Bad Request\n".utf8))
        case .notFound:
            bytes = httpResponseBytes(status: 404, statusText: "Not Found",
                                      contentType: "text/plain", body: Data("Not Found\n".utf8))
        case .unauthorized:
            bytes = httpResponseBytes(status: 401, statusText: "Unauthorized",
                                      contentType: "text/plain", body: Data("Unauthorized\n".utf8))
        case .internalError:
            bytes = httpResponseBytes(status: 500, statusText: "Internal Server Error",
                                      contentType: "text/plain", body: Data("Internal Server Error\n".utf8))
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
        body: Data
    ) -> Data {
        var out = Data()
        out.append(Data("HTTP/1.1 \(status) \(statusText)\r\n".utf8))
        out.append(Data("Content-Type: \(contentType)\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n".utf8))
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }
}

// MARK: - HTTP request parsing helpers

private struct HTTPRequest {
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
    var data = Data()

    func append(_ chunk: Data) {
        data.append(chunk)
    }

    /// Attempt to extract a complete HTTP request. Returns nil if more bytes
    /// are needed.
    func tryParse() -> HTTPRequest? {
        // Find headers/body boundary.
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerBytes = data[..<headerEndRange.lowerBound]
        let headerText = String(decoding: headerBytes, as: UTF8.self)
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { return nil }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEndRange.upperBound
        let availableBody = data.count - bodyStart
        if availableBody < contentLength {
            return nil  // need more bytes
        }

        let body = data[bodyStart..<(bodyStart + contentLength)]
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }
}
