import Foundation
import ClawdmeterShared
import CryptoKit
import OSLog

private let bridgeLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MultiHostRelay")

/// One-shot relay HTTP proxy for reaching remote execution hosts (R1 hub → VPS).
@MainActor
enum MultiHostRelayRequestBridge {

    static func makeRemoteClient(relayStore: MultiHostRelayStore = .shared) -> RemoteExecutionHostClient {
        RemoteExecutionHostClient(relayRequestHandler: { hostId, method, path, body, timeout in
            try await request(
                hostId: hostId,
                method: method,
                path: path,
                body: body,
                timeout: timeout,
                relayStore: relayStore
            )
        })
    }

    static func request(
        hostId: UUID,
        method: String,
        path: String,
        body: Data?,
        timeout: TimeInterval,
        relayStore: MultiHostRelayStore = .shared
    ) async throws -> Data {
        guard let record = relayStore.record(for: hostId),
              !record.sid.isEmpty,
              Self.isValidRelayURL(record.relayUrl),
              let token = relayStore.iosToken(for: hostId)
        else {
            throw RemoteExecutionHostClient.Error.unreachable(hostId: hostId, reason: "relay_not_configured")
        }
        let client = RelayOneShotMuxClient(
            hostId: hostId,
            sid: record.sid,
            relayUrl: record.relayUrl,
            iosToken: token,
            symmetricKey: symmetricKey(for: hostId, relayStore: relayStore)
        )
        let response = try await client.request(
            method: method,
            path: path,
            body: body,
            timeout: timeout
        )
        guard (200..<300).contains(response.status) else {
            throw RemoteExecutionHostClient.Error.httpStatus(hostId: hostId, status: response.status)
        }
        return response.body ?? Data()
    }

    private static func isValidRelayURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.host?.isEmpty == false,
              components.scheme == "ws" || components.scheme == "wss"
        else { return false }
        return true
    }

    private static func symmetricKey(for hostId: UUID, relayStore: MultiHostRelayStore) -> SymmetricKey? {
        guard let b64 = relayStore.derivedSymmetricKeyBase64URL(for: hostId),
              let keyData = RelayPairingBase64URL.decode(b64),
              keyData.count == RelayFrameCodec.keyLength
        else { return nil }
        return SymmetricKey(data: keyData)
    }
}

/// Ephemeral mux request/response over a relay WebSocket (hub as iOS peer).
@MainActor
private final class RelayOneShotMuxClient {
    private let hostId: UUID
    private let sid: String
    private let relayUrl: String
    private let iosToken: String
    private let symmetricKey: SymmetricKey?
    private var nextSeq: UInt64 = 1
    private var inboundHighSeq: UInt64 = 0

    init(hostId: UUID, sid: String, relayUrl: String, iosToken: String, symmetricKey: SymmetricKey?) {
        self.hostId = hostId
        self.sid = sid
        self.relayUrl = relayUrl
        self.iosToken = iosToken
        self.symmetricKey = symmetricKey
    }

    func request(
        method: String,
        path: String,
        body: Data?,
        timeout: TimeInterval
    ) async throws -> RelayMuxResponse {
        guard symmetricKey != nil else {
            throw RemoteExecutionHostClient.Error.unreachable(
                hostId: hostId,
                reason: "relay_key_missing"
            )
        }
        let url = connectURL()
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let requestClient = RelayMuxRequestClient { frame in
            try? await self.send(frame: frame, task: task)
        }
        return try await withThrowingTaskGroup(of: RelayMuxResponse.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await requestClient.request(method: method, path: path, body: body, timeout: timeout)
                } onCancel: {
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        if let frame = try await self.decodeRelayMessage(.string(text), task: task) {
                            requestClient.handleInbound(frame)
                        }
                    case .data(let data):
                        if let frame = try await self.decodeRelayMessage(.data(data), task: task) {
                            requestClient.handleInbound(frame)
                        }
                    @unknown default:
                        break
                    }
                }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RemoteExecutionHostClient.Error.unreachable(
                    hostId: hostId,
                    reason: "relay_mux_timeout"
                )
            }
            return result
        }
    }

    private func connectURL() -> URL {
        var base = relayUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !base.hasSuffix("/v1/relay/sessions/\(sid)/connect") {
            base += "/v1/relay/sessions/\(sid)/connect"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "token", value: iosToken)]
        return components.url!
    }

    private func send(frame: RelayMuxFrame, task: URLSessionWebSocketTask) async throws {
        guard let key = symmetricKey else {
            throw RemoteExecutionHostClient.Error.unreachable(hostId: hostId, reason: "relay_key_missing")
        }
        let muxData = try frame.encoded()
        let plaintext = RelayPlaintext(seq: nextSeq, op: RelayMux.op, data: muxData)
        nextSeq &+= 1
        let plaintextBytes = try plaintext.encodeCanonicalJSON()
        let nonce = RelayFrameCodec.randomNonce()
        let sealed = try RelayFrameCodec.seal(plaintext: plaintextBytes, key: key, nonce: nonce)
        var body = Data()
        body.append(nonce)
        body.append(sealed)
        let header = RelayEnvelopeHeader(from: .ios, type: .ciphertext)
        try await task.send(.string(String(decoding: header.encodeCanonicalJSON(), as: UTF8.self)))
        try await task.send(.data(body))
    }

    private func decodeRelayMessage(
        _ message: URLSessionWebSocketTask.Message,
        task: URLSessionWebSocketTask
    ) async throws -> RelayMuxFrame? {
        let headerData: Data
        switch message {
        case .string(let text):
            headerData = Data(text.utf8)
        case .data(let data):
            headerData = data
        @unknown default:
            return nil
        }
        guard let header = RelayEnvelopeHeader.decode(headerData) else {
            return nil
        }
        switch header.type {
        case .control, .handshake:
            return nil
        case .ciphertext:
            let bodyMessage = try await task.receive()
            guard case .data(let body) = bodyMessage else { return nil }
            return try decodeCiphertextBody(body)
        }
    }

    private func decodeCiphertextBody(_ body: Data) throws -> RelayMuxFrame? {
        guard let key = symmetricKey else {
            throw RemoteExecutionHostClient.Error.unreachable(hostId: hostId, reason: "relay_key_missing")
        }
        guard body.count > RelayFrameCodec.nonceLength + RelayFrameCodec.tagLength else {
            return nil
        }
        let nonce = body.prefix(RelayFrameCodec.nonceLength)
        let sealed = body.suffix(from: body.startIndex + RelayFrameCodec.nonceLength)
        let plaintextBytes = try RelayFrameCodec.open(
            sealed: Data(sealed),
            key: key,
            nonce: Data(nonce)
        )
        guard let plaintext = RelayPlaintext.decode(plaintextBytes),
              plaintext.op == RelayMux.op,
              plaintext.seq > inboundHighSeq
        else { return nil }
        inboundHighSeq = plaintext.seq
        return RelayMuxFrame.decode(plaintext.data)
    }
}
