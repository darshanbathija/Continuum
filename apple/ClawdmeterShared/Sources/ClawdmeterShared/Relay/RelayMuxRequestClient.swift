import Foundation

/// Track B — B1.7: request/response over the relay multiplex.
///
/// `RelayMuxClient` only handles long-lived subscriptions; one-shot HTTP-style
/// requests have no scaffolding (its `handleInbound` ignores `.request`/
/// `.response`). This client adds the missing correlator: it ships a `.request`
/// frame, parks on a per-opId continuation, and resolves it when the matching
/// `.response` arrives — with chunk reassembly (large response bodies cross the
/// 64 KiB cap), a timeout, and disconnect cancellation.
///
/// The wire envelopes mirror the existing `RelayRequestDispatcher` shape on the
/// Mac (`{method}.{path}` → `{status, body}`), so the Mac side can reuse that
/// tested dispatcher to service relayed requests.

/// A relayed request: the method + path + optional body.
public struct RelayMuxRequest: Codable, Sendable {
    public let method: String
    public let path: String
    public let body: Data?
    public init(method: String, path: String, body: Data?) {
        self.method = method
        self.path = path
        self.body = body
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ d: Data) -> RelayMuxRequest? { try? JSONDecoder().decode(RelayMuxRequest.self, from: d) }
}

/// A relayed response: the HTTP status + optional body bytes.
public struct RelayMuxResponse: Codable, Sendable {
    public let status: Int
    public let body: Data?
    public init(status: Int, body: Data?) {
        self.status = status
        self.body = body
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ d: Data) -> RelayMuxResponse? { try? JSONDecoder().decode(RelayMuxResponse.self, from: d) }
}

@MainActor
public final class RelayMuxRequestClient {

    public typealias SendMux = @MainActor (RelayMuxFrame) async -> Void

    public enum RequestError: Error, Equatable {
        case timeout
        case disconnected
        case malformedResponse
        case remoteError(String)
    }

    private let send: SendMux
    private let makeOpId: @MainActor () -> String
    private let makeMessageId: @MainActor () -> String
    private let timeout: TimeInterval
    private let maxRawPayloadBytes: Int

    private var continuations: [String: CheckedContinuation<RelayMuxResponse, Error>] = [:]
    private var reassemblers: [String: RelayChunkReassembler] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    public init(
        send: @escaping SendMux,
        makeOpId: @escaping @MainActor () -> String = { UUID().uuidString },
        makeMessageId: @escaping @MainActor () -> String = { UUID().uuidString },
        timeout: TimeInterval = 30,
        maxRawPayloadBytes: Int = RelayMux.maxRawPayloadBytes
    ) {
        self.send = send
        self.makeOpId = makeOpId
        self.makeMessageId = makeMessageId
        self.timeout = timeout
        self.maxRawPayloadBytes = maxRawPayloadBytes
    }

    public var inFlightCount: Int { continuations.count }

    /// Send a request and await its response. Throws `RequestError` on timeout /
    /// disconnect / malformed reply.
    public func request(
        method: String,
        path: String,
        body: Data?,
        timeout: TimeInterval? = nil
    ) async throws -> RelayMuxResponse {
        let opId = makeOpId()
        let payload = try RelayMuxRequest(method: method, path: path, body: body).encoded()
        let messageId = makeMessageId()
        let timeoutSeconds = timeout ?? self.timeout
        return try await withCheckedThrowingContinuation { cont in
            continuations[opId] = cont
            reassemblers[opId] = RelayChunkReassembler()
            timeoutTasks[opId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if !Task.isCancelled { self?.resolve(opId, .failure(RequestError.timeout)) }
            }
            // Ship the (possibly chunked) request frames.
            Task { [weak self] in
                guard let self else { return }
                let frames = RelayChunker.split(
                    opId: opId, kind: .request, payload: payload,
                    messageId: messageId, maxRawPayloadBytes: self.maxRawPayloadBytes
                )
                for f in frames { await self.send(f) }
            }
        }
    }

    /// Route an inbound `.response`/`.error` frame to its pending request.
    public func handleInbound(_ frame: RelayMuxFrame) {
        guard continuations[frame.opId] != nil else { return }   // unknown / already-resolved
        switch frame.kind {
        case .response:
            guard let reassembler = reassemblers[frame.opId] else { return }
            do {
                guard let full = try reassembler.accept(frame) else { return }   // more chunks pending
                guard let resp = RelayMuxResponse.decode(full) else {
                    resolve(frame.opId, .failure(RequestError.malformedResponse)); return
                }
                resolve(frame.opId, .success(resp))
            } catch {
                resolve(frame.opId, .failure(RequestError.malformedResponse))
            }
        case .error:
            let msg = frame.payload.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }?["error"] as? String
            resolve(frame.opId, .failure(RequestError.remoteError(msg ?? "relay request error")))
        default:
            break
        }
    }

    /// Fail every in-flight request — called when the relay disconnects so
    /// callers can fall back / retry rather than hang until timeout.
    public func failAll(_ error: RequestError = .disconnected) {
        for opId in Array(continuations.keys) { resolve(opId, .failure(error)) }
    }

    private func resolve(_ opId: String, _ result: Result<RelayMuxResponse, Error>) {
        guard let cont = continuations.removeValue(forKey: opId) else { return }
        timeoutTasks.removeValue(forKey: opId)?.cancel()
        reassemblers.removeValue(forKey: opId)
        cont.resume(with: result)
    }
}
