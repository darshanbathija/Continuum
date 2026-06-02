import Foundation

/// A byte channel to the agent process: write bytes to stdin, and feed inbound
/// stdout bytes into the connection. Kept transport-neutral so the connection
/// is unit-testable with an in-memory channel (FakeAcpAgent) and reused by the
/// Codex app-server driver (different dialect, same framing).
public protocol AcpByteWriter: Sendable {
    func write(_ data: Data) async throws
}

/// Transport-neutral NDJSON JSON-RPC 2.0 engine.
///
/// - One JSON object per line (`\n`-delimited); buffers partial trailing lines
///   so split reads and split UTF-8 are safe (`\n` is ASCII, never a UTF-8
///   continuation byte, so complete-line decoding can't tear a codepoint).
/// - Correlates responses to our requests by id; routes agent→client requests
///   to `onClientRequest` (the handler answers later via `respond`/`respondError`,
///   which lets slow flows like permission prompts defer); routes notifications
///   (`session/update`, …) to `onNotification`.
/// - Strips `_meta` from inbound results/params at the edge.
public actor NdjsonRpcConnection {
    private let writer: AcpByteWriter
    private var buffer = Data()
    private var nextId: Int64 = 1
    private var pending: [RpcId: CheckedContinuation<ACPJSONValue, Error>] = [:]
    private var closed = false

    /// agent→client request. The handler must eventually call `respond` /
    /// `respondError` with the same id (immediately for fs/terminal, later for
    /// permission prompts).
    public var onClientRequest: (@Sendable (_ method: String, _ id: RpcId, _ params: ACPJSONValue) async -> Void)?
    /// agent→client notification (no id), e.g. `session/update`.
    public var onNotification: (@Sendable (_ method: String, _ params: ACPJSONValue) async -> Void)?

    public init(writer: AcpByteWriter) { self.writer = writer }

    public func setOnClientRequest(_ h: @escaping @Sendable (String, RpcId, ACPJSONValue) async -> Void) {
        onClientRequest = h
    }
    public func setOnNotification(_ h: @escaping @Sendable (String, ACPJSONValue) async -> Void) {
        onNotification = h
    }

    // MARK: outbound

    /// Send a request and await the agent's result (or throw on its error).
    @discardableResult
    public func request(_ method: String, params: ACPJSONValue) async throws -> ACPJSONValue {
        if closed { throw ACPError.processExited(code: nil) }
        let id = RpcId.number(nextId); nextId += 1
        let frame = ACPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(idNumber(id)),
            "method": .string(method),
            "params": params,
        ])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ACPJSONValue, Error>) in
            pending[id] = cont
            Task {
                do { try await writeFrame(frame) }
                catch { resume(id: id, with: .failure(error)) }
            }
        }
    }

    /// Send a notification (no response expected), e.g. `session/cancel`.
    public func notify(_ method: String, params: ACPJSONValue) async throws {
        let frame = ACPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        try await writeFrame(frame)
    }

    /// Answer an agent→client request with a result.
    public func respond(to id: RpcId, result: ACPJSONValue) async throws {
        let frame = ACPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": idValue(id),
            "result": result,
        ])
        try await writeFrame(frame)
    }

    /// Answer an agent→client request with an error.
    public func respondError(to id: RpcId, code: Int, message: String) async throws {
        let frame = ACPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": idValue(id),
            "error": .object(["code": .int(Int64(code)), "message": .string(message)]),
        ])
        try await writeFrame(frame)
    }

    // MARK: inbound

    /// Feed raw stdout bytes. Splits complete lines, routes each.
    public func feed(_ data: Data) async {
        buffer.append(data)
        let newline: UInt8 = 0x0A
        while let idx = buffer.firstIndex(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            guard !lineData.isEmpty else { continue }
            await route(lineData)
        }
    }

    /// The agent process ended; fail any in-flight requests.
    public func close(code: Int32? = nil) {
        closed = true
        let conts = pending
        pending.removeAll()
        for (_, cont) in conts { cont.resume(throwing: ACPError.processExited(code: code)) }
    }

    // MARK: internals

    private func route(_ lineData: Data) async {
        guard let value = try? JSONDecoder().decode(ACPJSONValue.self, from: lineData),
              case .object(let obj) = value else {
            return // ignore non-JSON noise (some agents print banners)
        }
        let hasMethod = obj["method"] != nil
        let hasId = obj["id"] != nil
        if hasMethod, hasId, let method = obj["method"]?.stringValue, let id = decodeId(obj["id"]) {
            // agent → client request
            let params = (obj["params"] ?? .object([:])).strippingMeta()
            await onClientRequest?(method, id, params)
        } else if hasMethod, let method = obj["method"]?.stringValue {
            // notification
            let params = (obj["params"] ?? .object([:])).strippingMeta()
            await onNotification?(method, params)
        } else if hasId, let id = decodeId(obj["id"]) {
            // response to one of our requests
            if let err = obj["error"], case .object(let e) = err {
                let code = e["code"]?.intValue ?? ACP.ErrorCode.internalError
                let msg = e["message"]?.stringValue ?? "agent error"
                resume(id: id, with: .failure(ACPError.rpc(code: code, message: msg)))
            } else {
                let result = (obj["result"] ?? .object([:])).strippingMeta()
                resume(id: id, with: .success(result))
            }
        }
        // else: malformed; drop.
    }

    private func resume(id: RpcId, with outcome: Result<ACPJSONValue, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(with: outcome)
    }

    private func writeFrame(_ frame: ACPJSONValue) async throws {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        try await writer.write(data)
    }

    private func idNumber(_ id: RpcId) -> Int64 {
        if case .number(let n) = id { return n }
        return 0
    }
    private func idValue(_ id: RpcId) -> ACPJSONValue {
        switch id {
        case .number(let n): return .int(n)
        case .string(let s): return .string(s)
        }
    }
    /// Decode an id from an inbound frame. Distinguishes `id: 0` from absent
    /// (absent never reaches here — caller checks `hasId`).
    private func decodeId(_ v: ACPJSONValue?) -> RpcId? {
        switch v {
        case .int(let n): return .number(n)
        case .double(let d): return .number(Int64(d))
        case .string(let s): return .string(s)
        default: return nil
        }
    }
}
