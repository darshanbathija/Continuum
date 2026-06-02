import Foundation

/// The unified harness driver. Every backend (ACP agents, Codex app-server,
/// Antigravity agentapi, the kept Claude/tmux path) conforms so the daemon
/// drives one object regardless of transport. The ACP implementation is below;
/// other backends land in later phases.
public protocol AgentDriver: Actor {
    /// Live harness events. Consume on a background task; the daemon marshals
    /// to its (off-main) sinks.
    nonisolated var events: AsyncStream<HarnessEvent> { get }

    /// Two-phase failure contract: spawn + handshake + auth + session creation.
    /// Throws synchronously on any setup failure (so the daemon's create route
    /// returns a real error). Returns the external session id (for revive).
    func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String

    /// Begin a turn. Returns once the turn is *accepted*; completion arrives as
    /// a `.turnEnded` event. Runtime failures stream as `.error` + `.turnEnded`.
    func prompt(_ text: String) async

    /// Cancel the in-flight turn.
    func cancel() async

    /// Answer a `.permissionRequest`. `optionId == nil` means cancelled.
    func respondToPermission(requestId: RpcId, optionId: String?) async

    /// Tear down the session/process.
    func close() async
}

/// ACP driver — drives any ACP-speaking agent (Grok, Cursor, the ecosystem)
/// over an `NdjsonRpcConnection`. Transport (process spawn vs in-memory test
/// channel) is injected, so this is unit-testable end to end with a fake agent.
public actor AcpAgentDriver: AgentDriver {
    public nonisolated let events: AsyncStream<HarnessEvent>
    private let eventCont: AsyncStream<HarnessEvent>.Continuation

    private let connection: NdjsonRpcConnection
    private let support: AcpAgentSupport
    private let clientInfo: ACPClientInfo
    /// fs/terminal client capabilities. `terminal` stays off (Phase 6 follow-up).
    /// `fs` (read/write) is advertised + served ONLY when a `trustGate` is
    /// injected — i.e. the session's repo is autopilot-trusted. Every fs request
    /// is validated through the gate (repo-root binding, symlink/`..`/TOCTOU
    /// resolution) before any disk I/O.
    private let advertiseFsTerminal: Bool
    private let trustGate: RepoTrustGate?
    /// Hash-only audit hook for fs ops (the daemon wires it to its audit log;
    /// the gate itself is Mac/transport-agnostic so it can't log directly).
    private let onFileAccess: (@Sendable (_ op: String, _ path: String, _ allowed: Bool) async -> Void)?

    private var sessionId: String?
    private var toolTitles: [String: String] = [:]
    private var turnTask: Task<Void, Never>?

    public init(
        connection: NdjsonRpcConnection,
        support: AcpAgentSupport,
        clientInfo: ACPClientInfo,
        advertiseFsTerminal: Bool = false,
        trustGate: RepoTrustGate? = nil,
        onFileAccess: (@Sendable (String, String, Bool) async -> Void)? = nil
    ) {
        self.connection = connection
        self.support = support
        self.clientInfo = clientInfo
        self.advertiseFsTerminal = advertiseFsTerminal
        self.trustGate = trustGate
        self.onFileAccess = onFileAccess
        var cont: AsyncStream<HarnessEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.eventCont = cont
    }

    // MARK: start (two-phase: throws synchronously)

    public func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String {
        await wireHandlers()

        // initialize
        let initReq = ACPInitializeRequest(
            clientCapabilities: ACPClientCapabilities(
                // fs advertised only when a trust gate is present (repo trusted);
                // terminal stays off this phase.
                fs: .init(readTextFile: trustGate != nil, writeTextFile: trustGate != nil),
                terminal: advertiseFsTerminal
            ),
            clientInfo: clientInfo
        )
        let initRaw: ACPJSONValue
        do {
            initRaw = try await connection.request(ACP.AgentMethod.initialize, params: try encodeValue(initReq))
        } catch {
            throw ACPError.startFailed("initialize failed: \(error)")
        }
        let initResult = try decodeValue(ACPInitializeResult.self, from: initRaw)
        guard initResult.protocolVersion == ACP.protocolVersion else {
            throw ACPError.startFailed("unsupported ACP protocolVersion \(initResult.protocolVersion)")
        }

        // session/new — try first; authenticate + retry only if the agent
        // demands it (cached-auth agents skip the auth round-trip entirely).
        let newReq = ACPNewSessionRequest(cwd: cwd)
        let newRaw: ACPJSONValue
        do {
            newRaw = try await connection.request(ACP.AgentMethod.sessionNew, params: try encodeValue(newReq))
        } catch let ACPError.rpc(code, _) where code == ACP.ErrorCode.authRequired {
            guard let methodId = support.resolveAuthMethod(offered: initResult.authMethods) else {
                throw ACPError.noUsableAuthMethod(offered: initResult.authMethods.map(\.id))
            }
            do {
                _ = try await connection.request(ACP.AgentMethod.authenticate, params: .object(["methodId": .string(methodId)]))
            } catch {
                throw ACPError.startFailed("authenticate(\(methodId)) failed: \(error). Sign in to \(support.binaryName) first.")
            }
            do {
                newRaw = try await connection.request(ACP.AgentMethod.sessionNew, params: try encodeValue(newReq))
            } catch {
                throw ACPError.startFailed("session/new failed after auth: \(error)")
            }
        } catch {
            throw ACPError.startFailed("session/new failed: \(error)")
        }
        let newResult = try decodeValue(ACPNewSessionResult.self, from: newRaw)
        sessionId = newResult.sessionId
        return newResult.sessionId
    }

    // MARK: turn loop

    public func prompt(_ text: String) async {
        guard let sid = sessionId else {
            eventCont.yield(.error(code: "no_session", message: "prompt before start"))
            eventCont.yield(.turnEnded(.unknown))
            return
        }
        let req = ACPPromptRequest(sessionId: sid, prompt: [.text(text)])
        // Fire-and-accept: the request resolves at turn end; completion is the
        // `.turnEnded` event. session/update notifications stream meanwhile.
        turnTask = Task { [connection, eventCont] in
            do {
                let raw = try await connection.request(ACP.AgentMethod.sessionPrompt, params: try Self.encodeValueStatic(req))
                let resp = (try? Self.decodeValueStatic(ACPPromptResponse.self, from: raw)) ?? ACPPromptResponse(stopReason: .unknown)
                eventCont.yield(.turnEnded(resp.stopReason))
            } catch let ACPError.processExited(code) {
                eventCont.yield(.error(code: "process_exited", message: "agent exited (code \(code.map(String.init) ?? "?"))"))
                eventCont.yield(.turnEnded(.unknown))
            } catch {
                eventCont.yield(.error(code: "prompt_failed", message: "\(error)"))
                eventCont.yield(.turnEnded(.unknown))
            }
        }
    }

    public func cancel() async {
        guard let sid = sessionId else { return }
        try? await connection.notify(ACP.AgentMethod.sessionCancel, params: .object(["sessionId": .string(sid)]))
        turnTask?.cancel()
    }

    public func respondToPermission(requestId: RpcId, optionId: String?) async {
        let outcome: ACPJSONValue
        if let optionId {
            outcome = .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionId)])])
        } else {
            outcome = .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        try? await connection.respond(to: requestId, result: outcome)
    }

    public func close() async {
        turnTask?.cancel()
        await connection.close()
        eventCont.finish()
    }

    // MARK: handlers

    private func wireHandlers() async {
        await connection.setOnNotification { [weak self] method, params in
            guard method == ACP.ClientMethod.sessionUpdate else { return }
            await self?.handleSessionUpdate(params)
        }
        await connection.setOnClientRequest { [weak self] method, id, params in
            await self?.handleClientRequest(method: method, id: id, params: params)
        }
    }

    private func handleSessionUpdate(_ params: ACPJSONValue) async {
        guard let data = try? JSONEncoder().encode(params),
              let note = try? JSONDecoder().decode(ACPSessionNotification.self, from: data) else { return }
        let evs = ACPEventMapper.map(note, toolTitles: &toolTitles)
        for e in evs { eventCont.yield(e) }
    }

    private func handleClientRequest(method: String, id: RpcId, params: ACPJSONValue) async {
        switch method {
        case ACP.ClientMethod.sessionRequestPermission:
            let req = (try? decodeValue(ACPRequestPermissionRequest.self, from: params))
            let title = params["toolCall"]?["title"]?.stringValue
            eventCont.yield(.permissionRequest(HarnessPermissionRequest(
                requestId: id,
                sessionId: req?.sessionId ?? sessionId ?? "",
                title: title,
                options: req?.options ?? []
            )))
            // Deferred: the daemon answers later via respondToPermission(id:).
        case ACP.ClientMethod.fsReadTextFile:
            await handleFsRead(id: id, params: params)
        case ACP.ClientMethod.fsWriteTextFile:
            await handleFsWrite(id: id, params: params)
        case ACP.ClientMethod.terminalCreate,
             ACP.ClientMethod.terminalOutput,
             ACP.ClientMethod.terminalWaitForExit,
             ACP.ClientMethod.terminalKill,
             ACP.ClientMethod.terminalRelease:
            // Terminal capability not advertised this phase → refuse cleanly.
            try? await connection.respondError(to: id, code: ACP.ErrorCode.methodNotFound,
                                               message: "\(method) not enabled")
        default:
            try? await connection.respondError(to: id, code: ACP.ErrorCode.methodNotFound,
                                               message: "unknown client method \(method)")
        }
    }

    // MARK: fs client requests (Phase 6 — gated by RepoTrustGate)

    /// `fs/read_text_file` — validate the path through the trust gate, then read
    /// (capped) and return `{content}`. Denials become invalidParams errors so
    /// the agent learns the path is out of bounds rather than silently failing.
    private func handleFsRead(id: RpcId, params: ACPJSONValue) async {
        guard let gate = trustGate, let path = params["path"]?.stringValue else {
            try? await connection.respondError(to: id, code: ACP.ErrorCode.methodNotFound,
                                               message: "fs/read_text_file not enabled"); return
        }
        switch gate.authorizeRead(path: path) {
        case .deny(let reason):
            await onFileAccess?("read", path, false)
            try? await connection.respondError(to: id, code: ACP.ErrorCode.invalidParams,
                                               message: "fs read denied: \(reason)")
        case .allow(let resolved):
            do {
                let (capped, _) = gate.cap(try Data(contentsOf: URL(fileURLWithPath: resolved)))
                await onFileAccess?("read", resolved, true)
                try? await connection.respond(to: id, result: .object([
                    "content": .string(String(decoding: capped, as: UTF8.self))
                ]))
            } catch {
                try? await connection.respondError(to: id, code: ACP.ErrorCode.internalError,
                                                   message: "fs read failed")
            }
        }
    }

    /// `fs/write_text_file` — validate through the gate (a symlinked/`..` parent
    /// can't escape the root), create intermediate dirs under the root, write.
    private func handleFsWrite(id: RpcId, params: ACPJSONValue) async {
        guard let gate = trustGate, let path = params["path"]?.stringValue else {
            try? await connection.respondError(to: id, code: ACP.ErrorCode.methodNotFound,
                                               message: "fs/write_text_file not enabled"); return
        }
        let content = params["content"]?.stringValue ?? ""
        switch gate.authorizeWrite(path: path) {
        case .deny(let reason):
            await onFileAccess?("write", path, false)
            try? await connection.respondError(to: id, code: ACP.ErrorCode.invalidParams,
                                               message: "fs write denied: \(reason)")
        case .allow(let resolved):
            do {
                let url = URL(fileURLWithPath: resolved)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url)
                await onFileAccess?("write", resolved, true)
                try? await connection.respond(to: id, result: .null)
            } catch {
                try? await connection.respondError(to: id, code: ACP.ErrorCode.internalError,
                                                   message: "fs write failed")
            }
        }
    }

    // MARK: encode/decode helpers (ACPJSONValue <-> Codable)

    private func encodeValue<T: Encodable>(_ v: T) throws -> ACPJSONValue { try Self.encodeValueStatic(v) }
    private func decodeValue<T: Decodable>(_ t: T.Type, from v: ACPJSONValue) throws -> T { try Self.decodeValueStatic(t, from: v) }

    static func encodeValueStatic<T: Encodable>(_ v: T) throws -> ACPJSONValue {
        let data = try JSONEncoder().encode(v)
        return try JSONDecoder().decode(ACPJSONValue.self, from: data)
    }
    static func decodeValueStatic<T: Decodable>(_ t: T.Type, from v: ACPJSONValue) throws -> T {
        let data = try JSONEncoder().encode(v)
        return try JSONDecoder().decode(t, from: data)
    }
}
