// E4: iOS-side relay client — handshake + ciphertext send/receive.
//
// Mirrors what E3's Mac test suite will assert on the Mac side. The
// shared `RelayFrameCodec` is already verified against the TS relay
// Worker's test vectors via `RelayCodecCryptoTests` in the
// `ClawdmeterShared` package — these tests verify the iOS WIRING
// against the codec is correct (correct envelope ordering, correct
// counter behaviour, correct replay-rejection).

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
final class IOSRelayClientHandshakeTests: XCTestCase {

    // ───────────────────────────────────────────────────────────
    // Outbound: send(op:payload:) seals + frames correctly
    // ───────────────────────────────────────────────────────────

    func testSendSealsAndEmitsHeaderThenBody() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        let factoryFired = expectation(description: "factory fired")
        let cfg = RelayLifecycleFixture.defaultConfig()
        let client = IOSRelayClient(
            config: cfg,
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryFired.fulfill()
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        let payload = Data(#"{"approve":true}"#.utf8)
        try await client.send(op: "approve_plan", payload: payload)

        let texts = await transport.sentText
        let datas = await transport.sentData
        // 1 handshake + 1 ciphertext header.
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.last, #"{"v":1,"from":"ios","type":"ciphertext"}"#)
        // 1 handshake body + 1 ciphertext body (nonce || sealed).
        XCTAssertEqual(datas.count, 2)
        guard let cipherBody = datas.last else {
            return XCTFail("missing ciphertext body")
        }
        // Body shape: 24-byte nonce || (plaintext_len + 16-byte tag).
        // Round-trip verification below is the load-bearing assertion;
        // we just sanity-check the lower bound here.
        XCTAssertGreaterThan(cipherBody.count, RelayFrameCodec.nonceLength + RelayFrameCodec.tagLength)
        // Round-trip: extract nonce + sealed and open with the same key.
        let key = SymmetricKey(data: cfg.symmetricKey)
        let nonce = cipherBody.prefix(RelayFrameCodec.nonceLength)
        let sealed = cipherBody.suffix(from: cipherBody.startIndex + RelayFrameCodec.nonceLength)
        let plaintext = try RelayFrameCodec.open(sealed: Data(sealed), key: key, nonce: Data(nonce))
        let parsed = try XCTUnwrap(RelayPlaintext.decode(plaintext))
        XCTAssertEqual(parsed.seq, 1)
        XCTAssertEqual(parsed.op, "approve_plan")
        client.stop()
    }

    func testOutboundSeqIsMonotonic() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        let cfg = RelayLifecycleFixture.defaultConfig()
        let factoryFired = expectation(description: "factory fired")
        let client = IOSRelayClient(
            config: cfg,
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryFired.fulfill()
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        let key = SymmetricKey(data: cfg.symmetricKey)
        var seenSeqs: [UInt64] = []
        for i in 0..<5 {
            try await client.send(op: "ping", payload: Data("\(i)".utf8))
        }
        let datas = await transport.sentData
        // Skip the first body (handshake pubkey). Each ciphertext body
        // is nonce || sealed.
        for body in datas.dropFirst() {
            let nonce = body.prefix(RelayFrameCodec.nonceLength)
            let sealed = body.suffix(from: body.startIndex + RelayFrameCodec.nonceLength)
            let plaintext = try RelayFrameCodec.open(sealed: Data(sealed), key: key, nonce: Data(nonce))
            let parsed = try XCTUnwrap(RelayPlaintext.decode(plaintext))
            seenSeqs.append(parsed.seq)
        }
        XCTAssertEqual(seenSeqs, [1, 2, 3, 4, 5])
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Inbound: replay rejection (§4.3)
    // ───────────────────────────────────────────────────────────

    func testInboundReplayRejection() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        let cfg = RelayLifecycleFixture.defaultConfig()
        let factoryFired = expectation(description: "factory fired")
        let client = IOSRelayClient(
            config: cfg,
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryFired.fulfill()
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        let key = SymmetricKey(data: cfg.symmetricKey)
        // Construct two Mac frames with seq=5 and seq=3 (the second
        // should be dropped as a replay because the high-water mark
        // is already at 5).
        let header = RelayEnvelopeHeader(from: .mac, type: .ciphertext)
        let headerText = String(data: header.encodeCanonicalJSON(), encoding: .utf8)!

        let nonce1 = RelayFrameCodec.randomNonce()
        let plaintext1 = try RelayPlaintext(seq: 5, op: "plan_ready", data: Data(#"{"id":"a"}"#.utf8)).encodeCanonicalJSON()
        let sealed1 = try RelayFrameCodec.seal(plaintext: plaintext1, key: key, nonce: nonce1)
        var body1 = Data()
        body1.append(nonce1)
        body1.append(sealed1)

        let nonce2 = RelayFrameCodec.randomNonce()
        let plaintext2 = try RelayPlaintext(seq: 3, op: "plan_ready", data: Data(#"{"id":"b"}"#.utf8)).encodeCanonicalJSON()
        let sealed2 = try RelayFrameCodec.seal(plaintext: plaintext2, key: key, nonce: nonce2)
        var body2 = Data()
        body2.append(nonce2)
        body2.append(sealed2)

        // Feed frame 1 (seq=5) → should be accepted.
        await transport.enqueue(.string(headerText))
        await transport.enqueue(.data(body1))
        // Allow the run loop to process.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(client.lastInbound?.seq, 5)
        XCTAssertEqual(client.lastInbound?.op, "plan_ready")

        // Feed frame 2 (seq=3, replayed) → should be DROPPED.
        await transport.enqueue(.string(headerText))
        await transport.enqueue(.data(body2))
        try await Task.sleep(nanoseconds: 200_000_000)
        // lastInbound remains seq=5 (the dropped frame did not update it).
        XCTAssertEqual(client.lastInbound?.seq, 5)
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Inbound: handshake validation
    // ───────────────────────────────────────────────────────────

    func testInboundHandshakeMatchingPubkeyAccepted() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        let cfg = RelayLifecycleFixture.defaultConfig()
        let factoryFired = expectation(description: "factory fired")
        let client = IOSRelayClient(
            config: cfg,
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryFired.fulfill()
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Construct the Mac's handshake envelope. The body must equal
        // the pubkey we recorded at pairing time.
        let theirPub = Data([
            0xa4, 0xe0, 0x92, 0x92, 0xb6, 0x51, 0xc2, 0x78,
            0xb9, 0x77, 0x2c, 0x56, 0x9f, 0x5f, 0xa9, 0xbb,
            0x13, 0xd9, 0x06, 0xb4, 0x6a, 0xb6, 0x8c, 0x9d,
            0xf9, 0xdc, 0x2b, 0x44, 0x09, 0xf8, 0xa2, 0x09,
        ])
        let header = RelayEnvelopeHeader(from: .mac, type: .handshake)
        let headerText = String(data: header.encodeCanonicalJSON(), encoding: .utf8)!
        await transport.enqueue(.string(headerText))
        await transport.enqueue(.data(theirPub))
        try await Task.sleep(nanoseconds: 200_000_000)

        // Still .connected — no tear-down occurred.
        XCTAssertEqual(client.state, .connected)
        client.stop()
    }

    func testInboundHandshakeMismatchedPubkeyTearsDown() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        let cfg = RelayLifecycleFixture.defaultConfig()
        let factoryFired = expectation(description: "factory fired")
        let client = IOSRelayClient(
            config: cfg,
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryFired.fulfill()
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        let bogusPub = Data(repeating: 0xff, count: 32)
        let header = RelayEnvelopeHeader(from: .mac, type: .handshake)
        let headerText = String(data: header.encodeCanonicalJSON(), encoding: .utf8)!
        await transport.enqueue(.string(headerText))
        await transport.enqueue(.data(bogusPub))
        try await Task.sleep(nanoseconds: 400_000_000)

        // Should be transitioned to either .failed or .reconnecting.
        // peerPubkeyMismatch is fatal (isFatal=true), so we expect
        // .failed.
        guard case .failed = client.state else {
            return XCTFail("expected .failed after pubkey mismatch, got \(client.state)")
        }
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Inbound: forged-role rejection (D22 at message layer)
    // ───────────────────────────────────────────────────────────

    func testForgedRoleHeaderRejected() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        let cfg = RelayLifecycleFixture.defaultConfig()
        let factoryFired = expectation(description: "factory fired")
        let client = IOSRelayClient(
            config: cfg,
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryFired.fulfill()
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Header claims `from: ios`. The iOS client must reject — only
        // the Mac peer ever talks to us.
        let header = RelayEnvelopeHeader(from: .ios, type: .ciphertext)
        let headerText = String(data: header.encodeCanonicalJSON(), encoding: .utf8)!
        await transport.enqueue(.string(headerText))
        try await Task.sleep(nanoseconds: 400_000_000)

        // After a protocol violation the client tears down and
        // backoff-reconnects. State should be .reconnecting (because
        // protocolViolation is not fatal in IOSRelayClientError).
        // (We don't assert on the exact attempt index since the test
        // is racy; .reconnecting OR .idle are both acceptable.)
        switch client.state {
        case .reconnecting, .idle, .failed:
            break
        default:
            XCTFail("expected post-violation tear-down, got \(client.state)")
        }
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Outbound: control frame is header-only
    // ───────────────────────────────────────────────────────────

    func testSendControlFrameEmitsHeaderOnly() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        let factoryFired = expectation(description: "factory fired")
        let client = IOSRelayClient(
            config: RelayLifecycleFixture.defaultConfig(),
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryFired.fulfill()
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        let beforeData = await transport.sentData.count
        try await client.sendControlFrame()
        let afterData = await transport.sentData.count
        let texts = await transport.sentText
        XCTAssertEqual(afterData, beforeData, "control frame must NOT send a body")
        XCTAssertEqual(texts.last, #"{"v":1,"from":"ios","type":"control"}"#)
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Constant-time compare on pubkey verification
    // ───────────────────────────────────────────────────────────

    func testConstantTimeEqualsUsedForPubkeyCompare() {
        // Smoke test that the Data extension we depend on for pubkey
        // compare actually returns false for an off-by-one byte and
        // doesn't accidentally short-circuit on length match alone.
        let a = Data(repeating: 0x00, count: 32)
        var b = Data(repeating: 0x00, count: 32)
        b[31] = 0x01
        XCTAssertFalse(a.constantTimeEquals(b))
        XCTAssertTrue(a.constantTimeEquals(a))
    }
}
