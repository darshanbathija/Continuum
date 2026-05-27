// E3 (respin): Mac-side relay-client handshake + ciphertext send/receive.
//
// Companion to E4's `IOSRelayClientHandshakeTests`. The shared
// `RelayFrameCodec` is verified cross-impl by `RelayCodecCryptoTests`
// in `ClawdmeterShared` against the libsodium-generated test vectors
// in `infra/relay/test-vectors/` — these tests verify the MAC WIRING
// against the codec is correct (envelope ordering, replay rejection,
// X25519 handshake handoff, control frames).

import XCTest
import Combine
import ClawdmeterShared
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import Clawdmeter

@MainActor
final class MacRelayClientHandshakeTests: XCTestCase {

    // ───────────────────────────────────────────────────────────
    // Outbound: handshake-on-open
    // ───────────────────────────────────────────────────────────

    func testStartOpensTransportAndSendsHandshake() async throws {
        let transport = MacFakeRelayTransport()
        let recorder = MacFakeHandshakeRecorder()
        let factoryFired = expectation(description: "factory fired")
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in
                factoryFired.fulfill()
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        let texts = await transport.sentText
        let datas = await transport.sentData
        XCTAssertEqual(texts.count, 1, "exactly one handshake header should be sent")
        XCTAssertEqual(datas.count, 1, "exactly one handshake body should be sent")
        XCTAssertEqual(texts.first, #"{"v":1,"from":"mac","type":"handshake"}"#)
        XCTAssertEqual(datas.first, MacRelayFixture.macHandshakePubkeyBytes)
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Inbound: handshake → K derived → ciphertext flows
    // ───────────────────────────────────────────────────────────

    func testInboundHandshakeDerivesKeyAndTransitionsToConnected() async throws {
        let transport = MacFakeRelayTransport()
        let recorder = MacFakeHandshakeRecorder(
            kBytesToReturn: MacRelayFixture.testSymmetricKey
        )
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.state, .awaitingPeer)

        // iPhone sends its handshake envelope. The Mac calls into the
        // recorder, gets K back, and transitions to .connected.
        let theirPub = Data(repeating: 0x42, count: 32)
        let header = RelayEnvelopeHeader(from: .ios, type: .handshake)
        await transport.enqueue(.string(String(decoding: header.encodeCanonicalJSON(), as: UTF8.self)))
        await transport.enqueue(.data(theirPub))
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(client.state, .connected)
        // Recorder must have received the iPhone's pubkey, base64url-encoded.
        XCTAssertEqual(recorder.lastReceivedPubkeyBase64URL, MacRelayFixture.base64URLEncode(theirPub))
        client.stop()
    }

    func testInboundHandshakeFailureTearsDown() async throws {
        let transport = MacFakeRelayTransport()
        let recorder = MacFakeHandshakeRecorder(kBytesToReturn: nil) // nil = pubkey mismatch
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        let bogus = Data(repeating: 0xff, count: 32)
        let header = RelayEnvelopeHeader(from: .ios, type: .handshake)
        await transport.enqueue(.string(String(decoding: header.encodeCanonicalJSON(), as: UTF8.self)))
        await transport.enqueue(.data(bogus))
        try await Task.sleep(nanoseconds: 400_000_000)

        // `peerPubkeyMismatch` is fatal — state should be .failed.
        if case .failed = client.state { /* good */ } else {
            XCTFail("expected .failed after recorder returned nil; got \(client.state)")
        }
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Outbound: send() seals + frames correctly
    // ───────────────────────────────────────────────────────────

    func testSendSealsAndEmitsHeaderThenBody() async throws {
        let transport = MacFakeRelayTransport()
        let cfg = MacRelayFixture.defaultConfig()
        let recorder = MacFakeHandshakeRecorder(kBytesToReturn: MacRelayFixture.testSymmetricKey)
        let client = MacRelayClient(
            config: cfg,
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Drive the K-derivation handshake first.
        let theirPub = Data(repeating: 0x42, count: 32)
        let hsHeader = RelayEnvelopeHeader(from: .ios, type: .handshake)
        await transport.enqueue(.string(String(decoding: hsHeader.encodeCanonicalJSON(), as: UTF8.self)))
        await transport.enqueue(.data(theirPub))
        try await Task.sleep(nanoseconds: 200_000_000)

        let payload = Data(#"{"approve":true}"#.utf8)
        try await client.send(op: "approve_plan", payload: payload)
        try await Task.sleep(nanoseconds: 50_000_000)

        let texts = await transport.sentText
        let datas = await transport.sentData
        // 1 handshake + 1 ciphertext header.
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.last, #"{"v":1,"from":"mac","type":"ciphertext"}"#)
        // 1 handshake body + 1 ciphertext body (nonce || sealed).
        XCTAssertEqual(datas.count, 2)
        guard let cipherBody = datas.last else {
            return XCTFail("missing ciphertext body")
        }
        XCTAssertGreaterThan(cipherBody.count, RelayFrameCodec.nonceLength + RelayFrameCodec.tagLength)

        // Round-trip verify with the same K.
        let key = SymmetricKey(data: MacRelayFixture.testSymmetricKey)
        let nonce = cipherBody.prefix(RelayFrameCodec.nonceLength)
        let sealed = cipherBody.suffix(from: cipherBody.startIndex + RelayFrameCodec.nonceLength)
        let plaintext = try RelayFrameCodec.open(sealed: Data(sealed), key: key, nonce: Data(nonce))
        let parsed = try XCTUnwrap(RelayPlaintext.decode(plaintext))
        XCTAssertEqual(parsed.seq, 1)
        XCTAssertEqual(parsed.op, "approve_plan")
        client.stop()
    }

    func testSendBeforeHandshakeThrows() async throws {
        let transport = MacFakeRelayTransport()
        let recorder = MacFakeHandshakeRecorder()
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        // We're in .awaitingPeer; sending ciphertext must throw because
        // K isn't derived yet.
        do {
            try await client.send(op: "ping", payload: Data())
            XCTFail("expected send to throw before handshake")
        } catch let e as MacRelayClientError {
            XCTAssertEqual(e, .notHandshaked)
        }
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Outbound seq is monotonic
    // ───────────────────────────────────────────────────────────

    func testOutboundSeqIsMonotonic() async throws {
        let transport = MacFakeRelayTransport()
        let recorder = MacFakeHandshakeRecorder(kBytesToReturn: MacRelayFixture.testSymmetricKey)
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Drive handshake.
        let header = RelayEnvelopeHeader(from: .ios, type: .handshake)
        await transport.enqueue(.string(String(decoding: header.encodeCanonicalJSON(), as: UTF8.self)))
        await transport.enqueue(.data(Data(repeating: 0x42, count: 32)))
        try await Task.sleep(nanoseconds: 150_000_000)

        let key = SymmetricKey(data: MacRelayFixture.testSymmetricKey)
        for i in 0..<5 {
            try await client.send(op: "ping", payload: Data("\(i)".utf8))
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let datas = await transport.sentData
        // Skip the first body (handshake pubkey).
        var seqs: [UInt64] = []
        for body in datas.dropFirst() {
            let nonce = body.prefix(RelayFrameCodec.nonceLength)
            let sealed = body.suffix(from: body.startIndex + RelayFrameCodec.nonceLength)
            let plaintext = try RelayFrameCodec.open(sealed: Data(sealed), key: key, nonce: Data(nonce))
            let parsed = try XCTUnwrap(RelayPlaintext.decode(plaintext))
            seqs.append(parsed.seq)
        }
        XCTAssertEqual(seqs, [1, 2, 3, 4, 5])
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Inbound: replay rejection (§4.3)
    // ───────────────────────────────────────────────────────────

    func testInboundReplayRejection() async throws {
        let transport = MacFakeRelayTransport()
        var handlerCallCount = 0
        let recorder = MacFakeHandshakeRecorder(kBytesToReturn: MacRelayFixture.testSymmetricKey)
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in
                handlerCallCount += 1
                return nil
            },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Drive handshake.
        let hsHeader = RelayEnvelopeHeader(from: .ios, type: .handshake)
        await transport.enqueue(.string(String(decoding: hsHeader.encodeCanonicalJSON(), as: UTF8.self)))
        await transport.enqueue(.data(Data(repeating: 0x42, count: 32)))
        try await Task.sleep(nanoseconds: 150_000_000)

        let key = SymmetricKey(data: MacRelayFixture.testSymmetricKey)
        let ctxHeader = RelayEnvelopeHeader(from: .ios, type: .ciphertext)
        let headerText = String(data: ctxHeader.encodeCanonicalJSON(), encoding: .utf8)!

        // seq=5 → accepted; seq=3 → replay → dropped.
        let pt1 = try RelayPlaintext(seq: 5, op: "plan_ready", data: Data(#"{"id":"a"}"#.utf8)).encodeCanonicalJSON()
        let nonce1 = RelayFrameCodec.randomNonce()
        let sealed1 = try RelayFrameCodec.seal(plaintext: pt1, key: key, nonce: nonce1)
        var body1 = Data(); body1.append(nonce1); body1.append(sealed1)

        let pt2 = try RelayPlaintext(seq: 3, op: "plan_ready", data: Data(#"{"id":"b"}"#.utf8)).encodeCanonicalJSON()
        let nonce2 = RelayFrameCodec.randomNonce()
        let sealed2 = try RelayFrameCodec.seal(plaintext: pt2, key: key, nonce: nonce2)
        var body2 = Data(); body2.append(nonce2); body2.append(sealed2)

        await transport.enqueue(.string(headerText))
        await transport.enqueue(.data(body1))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(client.lastInbound?.seq, 5)
        XCTAssertEqual(handlerCallCount, 1)

        await transport.enqueue(.string(headerText))
        await transport.enqueue(.data(body2))
        try await Task.sleep(nanoseconds: 200_000_000)
        // lastInbound remains seq=5; handler not called again.
        XCTAssertEqual(client.lastInbound?.seq, 5)
        XCTAssertEqual(handlerCallCount, 1, "replayed frame must be dropped before invoking handler")
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Inbound: forged-role rejection (D22 at message layer)
    // ───────────────────────────────────────────────────────────

    func testForgedFromMacHeaderRejected() async throws {
        let transport = MacFakeRelayTransport()
        let recorder = MacFakeHandshakeRecorder(kBytesToReturn: MacRelayFixture.testSymmetricKey)
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Header claims `from: mac`. The Mac client must reject — only
        // the iPhone peer ever talks to us.
        let header = RelayEnvelopeHeader(from: .mac, type: .ciphertext)
        await transport.enqueue(.string(String(decoding: header.encodeCanonicalJSON(), as: UTF8.self)))
        try await Task.sleep(nanoseconds: 300_000_000)
        // After the protocol violation the client tears down + backs
        // off. `.reconnecting`, `.idle`, or `.failed` are all acceptable
        // (test is racy on which state we observe).
        switch client.state {
        case .reconnecting, .idle, .failed, .stopped:
            break
        default:
            XCTFail("expected post-violation tear-down, got \(client.state)")
        }
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Control frame is header-only
    // ───────────────────────────────────────────────────────────

    func testSendControlFrameEmitsHeaderOnly() async throws {
        let transport = MacFakeRelayTransport()
        let recorder = MacFakeHandshakeRecorder()
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeData = await transport.sentData.count
        try await client.sendControlFrame()
        let afterData = await transport.sentData.count
        let texts = await transport.sentText
        XCTAssertEqual(afterData, beforeData, "control frame must NOT send a body")
        XCTAssertEqual(texts.last, #"{"v":1,"from":"mac","type":"control"}"#)
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Ciphertext before handshake is a protocol violation
    // ───────────────────────────────────────────────────────────

    func testCiphertextBeforeHandshakeIsProtocolViolation() async throws {
        let transport = MacFakeRelayTransport()
        let recorder = MacFakeHandshakeRecorder()
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in transport }
        )
        client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Send a ciphertext frame without driving the handshake first.
        let header = RelayEnvelopeHeader(from: .ios, type: .ciphertext)
        var body = Data()
        body.append(RelayFrameCodec.randomNonce())
        body.append(Data(repeating: 0, count: RelayFrameCodec.tagLength + 1))
        await transport.enqueue(.string(String(decoding: header.encodeCanonicalJSON(), as: UTF8.self)))
        await transport.enqueue(.data(body))
        try await Task.sleep(nanoseconds: 300_000_000)
        // State should NOT be `.connected` — we tore down.
        XCTAssertNotEqual(client.state, .connected)
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // URL construction
    // ───────────────────────────────────────────────────────────

    func testBuildConnectURLStagingWithoutBundle() {
        let cfg = MacRelayFixture.defaultConfig()
        let url = MacRelayClient.buildConnectURL(config: cfg, includeBundle: false)
        XCTAssertEqual(url?.scheme, "wss")
        XCTAssertEqual(url?.host, "relay-staging.clawdmeter.dev")
        XCTAssertEqual(url?.path, "/v1/relay/sessions/\(cfg.sid)/connect")
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            comps?.queryItems?.first(where: { $0.name == "token" })?.value,
            cfg.macTok
        )
        XCTAssertNil(comps?.queryItems?.first(where: { $0.name == "bundle" }))
    }

    func testBuildConnectURLWithBundleOnFirstConnect() throws {
        let cfg = MacRelayFixture.defaultConfig()
        let url = try XCTUnwrap(MacRelayClient.buildConnectURL(config: cfg, includeBundle: true))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let bundleParam = try XCTUnwrap(
            comps?.queryItems?.first(where: { $0.name == "bundle" })?.value
        )
        let bundleData = try XCTUnwrap(Data(base64Encoded: bundleParam))
        let bundle = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bundleData) as? [String: Any]
        )
        XCTAssertEqual(bundle["macTokenHash"] as? String, cfg.macTokHashHex)
        XCTAssertEqual(bundle["iosTokenHash"] as? String, cfg.iosTokHashHex)
        XCTAssertEqual((bundle["ttlSeconds"] as? UInt64), cfg.ttl)
    }

    func testBuildConnectURLLocalhostDev() {
        let cfg = MacRelayFixture.defaultConfig(relayUrl: "ws://localhost:8787")
        let url = MacRelayClient.buildConnectURL(config: cfg, includeBundle: false)
        XCTAssertEqual(url?.scheme, "ws")
        XCTAssertEqual(url?.host, "localhost")
        XCTAssertEqual(url?.port, 8787)
        XCTAssertEqual(url?.path, "/v1/relay/sessions/\(cfg.sid)/connect")
    }

    func testBuildConnectURLRejectsHTTPScheme() {
        let cfg = MacRelayFixture.defaultConfig(relayUrl: "http://example.com")
        XCTAssertNil(MacRelayClient.buildConnectURL(config: cfg, includeBundle: false))
    }

    // ───────────────────────────────────────────────────────────
    // SHA-256 hex helper
    // ───────────────────────────────────────────────────────────

    func testSha256HexLowercaseAndCorrect() {
        let h = MacRelayClientConfig.sha256Hex("hello")
        // Reference SHA-256 of "hello": 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        XCTAssertEqual(h, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}

// MARK: - Fakes + fixtures

@MainActor
final class MacFakeHandshakeRecorder: MacRelayPairingHandshakeRecorder, @unchecked Sendable {
    let kBytesToReturn: Data?
    private(set) var lastReceivedPubkeyBase64URL: String?
    private(set) var callCount: Int = 0
    init(kBytesToReturn: Data? = MacRelayFixture.testSymmetricKey) {
        self.kBytesToReturn = kBytesToReturn
    }
    func recordPeerHandshake(iPhoneEcdhPublicKeyBase64URL: String) -> Data? {
        lastReceivedPubkeyBase64URL = iPhoneEcdhPublicKeyBase64URL
        callCount += 1
        return kBytesToReturn
    }
}

/// Faked WebSocket transport for unit tests. Records send calls and
/// feeds canned receive responses. Same actor pattern as the iOS
/// `FakeTransport` (E4) — deliberately mirrors so the test patterns
/// look identical across the two suites.
actor MacFakeRelayTransport: MacRelayWebSocketTransport {
    nonisolated let id = UUID()
    private(set) var sentText: [String] = []
    private(set) var sentData: [Data] = []
    private(set) var cancelled: Bool = false

    private var receiveQueue: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var pendingError: Error?

    func enqueue(_ message: URLSessionWebSocketTask.Message) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            receiveQueue.append(message)
        }
    }

    func enqueueError(_ error: Error) {
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        } else {
            pendingError = error
        }
    }

    func send(text: String) async throws {
        sentText.append(text)
    }
    func send(data: Data) async throws {
        sentData.append(data)
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !receiveQueue.isEmpty {
            return receiveQueue.removeFirst()
        }
        if let pendingError {
            self.pendingError = nil
            throw pendingError
        }
        return try await withCheckedThrowingContinuation { cont in
            self.waiter = cont
        }
    }

    nonisolated func cancel() {
        Task { await self.markCancelled() }
    }
    private func markCancelled() {
        cancelled = true
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: CancellationError())
        }
    }

    var wasCancelled: Bool { cancelled }
}

enum MacRelayFixture {

    /// 32-byte symmetric key from the HKDF test vector (same one the
    /// iOS fixture uses, so a cross-impl regression flips red here too).
    static let testSymmetricKey = Data([
        0x14, 0x8e, 0x0a, 0x09, 0xad, 0x73, 0x2f, 0x51,
        0x16, 0x9a, 0xa3, 0x62, 0xcf, 0x68, 0xdb, 0x94,
        0xe4, 0x22, 0x6a, 0xb1, 0x0b, 0x3c, 0x50, 0x39,
        0xd5, 0xf8, 0xad, 0x58, 0x8e, 0x80, 0x4f, 0xe8,
    ])

    /// 32 bytes of the Mac's handshake pubkey. Distinct from the iOS
    /// fixture's `iosHandshakePubkeyBytes` so the right one shows up
    /// on the wire.
    static let macHandshakePubkeyBytes: Data = Data(repeating: 0x55, count: 32)

    static func defaultConfig(
        sid: String = "test-session-123456789abcdef",
        macTok: String = "mac-tok-1234567890abcdef1234",
        iosTok: String = "ios-tok-1234567890abcdef1234",
        relayUrl: String = "wss://relay-staging.clawdmeter.dev",
        ttl: UInt64? = nil
    ) -> MacRelayClientConfig {
        let now = UInt64(Date().timeIntervalSince1970)
        return MacRelayClientConfig(
            sid: sid,
            macTok: macTok,
            macTokHashHex: MacRelayClientConfig.sha256Hex(macTok),
            iosTokHashHex: MacRelayClientConfig.sha256Hex(iosTok),
            relayUrl: relayUrl,
            ttl: ttl ?? (now + 900),
            ourPublicKeyBytes: macHandshakePubkeyBytes
        )
    }

    static func base64URLEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
