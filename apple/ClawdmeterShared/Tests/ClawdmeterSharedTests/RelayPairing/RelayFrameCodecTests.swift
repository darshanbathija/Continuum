// E3: RelayFrameCodec cross-impl tests.
//
// Validates that our hand-rolled HChaCha20 + ChaCha20-Poly1305 stack
// produces byte-identical output to libsodium's
// `crypto_aead_xchacha20poly1305_ietf_encrypt`, which is what the E2
// relay's TypeScript test-vector harness uses. The fixtures live under
// `infra/relay/test-vectors/` and are read here via the embedded JSON
// strings below (we can't path-traverse to read them at test time on a
// random CI runner, so we copy the same canonical bytes into the suite).
//
// These fixtures are the cross-implementation gating contract per
// `infra/relay/test-vectors/README.md`:
//
// > Both stacks MUST produce byte-identical outputs for the same inputs,
// > or paired peers will silently fail to decrypt each other's frames.
//
// If any of these tests fail, that's a P0 — the relay's frames cannot
// cross between the Mac and the iOS app and pairing is broken.

import XCTest
@testable import ClawdmeterShared
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class RelayFrameCodecTests: XCTestCase {

    // MARK: - HKDF-SHA256 vector
    //
    // From infra/relay/test-vectors/hkdf-sha256-001.json. Already covered
    // by E7's RelayPairingHandshakeTests for the live path; replicated
    // here so the gating tests stay self-contained.

    func testHKDFMatches() throws {
        let sharedSecret = try fromHex("2ed76ab549b1e73c031eb49c9448f0798aea81b698279a0c3dc3e49fbfc4b953")
        let salt = Data("0123456789abcdef0123456789abcdef".utf8)
        let info = Data("clawdmeter.relay.v1".utf8)
        let expected = try fromHex("148e0a09ad732f51169aa362cf68db94e4226ab10b3c5039d5f8ad588e804fe8")

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        let derivedBytes = derived.withUnsafeBytes { Data($0) }
        XCTAssertEqual(
            derivedBytes, expected,
            "HKDF-SHA256 output must match the E2 test vector byte-for-byte. "
            + "Mismatch means the per-session symmetric key derives differently "
            + "on the Mac/iOS side vs the relay, which breaks the protocol."
        )
    }

    // MARK: - XChaCha20-Poly1305 encrypt vector
    //
    // From infra/relay/test-vectors/xchacha20-poly1305-001.json. THE
    // cross-impl gating fixture: if our XChaCha output differs by one
    // byte, paired peers can't decrypt each other's frames.

    func testXChaCha20Poly1305EncryptMatchesVector() throws {
        let key = try fromHex("148e0a09ad732f51169aa362cf68db94e4226ab10b3c5039d5f8ad588e804fe8")
        let nonce = try fromHex("0102030405060708090a0b0c0d0e0f101112131415161718")
        let aad = Data("clawdmeter.relay.frame.v1".utf8)
        let plaintext = try fromHex("7b22736571223a312c226f70223a22617070726f76655f706c616e222c2264617461223a7b226f6b223a747275657d7d")
        let expected = try fromHex("5af94a2905ec02b81620ec604f72df46493b79820ec28ecd492823e08007a636eb66bf4263b12a8325d1b574c0e5f536de38f68ef0e36632e3dc72eee13e86e0")

        let actual = try XChaCha20Poly1305.seal(
            plaintext: plaintext,
            key: SymmetricKey(data: key),
            nonce: nonce,
            aad: aad
        )
        XCTAssertEqual(
            actual.count, expected.count,
            "XChaCha20-Poly1305 output length (got \(actual.count)) must match the vector's expected length (\(expected.count))."
        )
        XCTAssertEqual(
            actual, expected,
            "XChaCha20-Poly1305 ciphertext+tag must match libsodium's output byte-exact. "
            + "If this fails, paired peers cannot decrypt each other's frames. P0."
        )
    }

    // MARK: - XChaCha20-Poly1305 decrypt round-trip
    //
    // From infra/relay/test-vectors/xchacha20-poly1305-roundtrip-001.json.

    func testXChaCha20Poly1305DecryptMatchesVector() throws {
        let key = try fromHex("148e0a09ad732f51169aa362cf68db94e4226ab10b3c5039d5f8ad588e804fe8")
        let nonce = try fromHex("0102030405060708090a0b0c0d0e0f101112131415161718")
        let aad = Data("clawdmeter.relay.frame.v1".utf8)
        let ciphertext = try fromHex("5af94a2905ec02b81620ec604f72df46493b79820ec28ecd492823e08007a636eb66bf4263b12a8325d1b574c0e5f536de38f68ef0e36632e3dc72eee13e86e0")
        let expectedPlaintext = try fromHex("7b22736571223a312c226f70223a22617070726f76655f706c616e222c2264617461223a7b226f6b223a747275657d7d")

        let plaintext = try XChaCha20Poly1305.open(
            ciphertextWithTag: ciphertext,
            key: SymmetricKey(data: key),
            nonce: nonce,
            aad: aad
        )
        XCTAssertEqual(plaintext, expectedPlaintext)
        // Round-trip the plaintext too — it's just the JSON-form inner
        // frame, so decoding via the public surface must work.
        let inner = try XCTUnwrap(RelayInnerFrame.decode(plaintext))
        XCTAssertEqual(inner.seq, 1)
        XCTAssertEqual(inner.op, "approve_plan")
    }

    // MARK: - Tampered ciphertext → auth failure
    //
    // From infra/relay/test-vectors/tampered-ciphertext-001.json.

    func testTamperedCiphertextFailsAuthentication() throws {
        let key = try fromHex("148e0a09ad732f51169aa362cf68db94e4226ab10b3c5039d5f8ad588e804fe8")
        let nonce = try fromHex("0102030405060708090a0b0c0d0e0f101112131415161718")
        let aad = Data("clawdmeter.relay.frame.v1".utf8)
        let tampered = try fromHex("5af94a29056c02b81620ec604f72df46493b79820ec28ecd492823e08007a636eb66bf4263b12a8325d1b574c0e5f536de38f68ef0e36632e3dc72eee13e86e0")

        XCTAssertThrowsError(
            try XChaCha20Poly1305.open(
                ciphertextWithTag: tampered,
                key: SymmetricKey(data: key),
                nonce: nonce,
                aad: aad
            )
        ) { error in
            XCTAssertEqual(error as? RelayFrameCodecError, .authenticationFailed)
        }
    }

    // MARK: - Envelope header serialization
    //
    // From infra/relay/test-vectors/envelope-header-001.json.

    func testEnvelopeHeaderSerializationMatchesVector() {
        let header = RelayEnvelopeHeader(v: 1, from: "mac", type: "ciphertext")
        let expected = "{\"v\":1,\"from\":\"mac\",\"type\":\"ciphertext\"}"
        XCTAssertEqual(header.encodeJSON(), expected)
        // Round-trip.
        let decoded = RelayEnvelopeHeader.decode(expected)
        XCTAssertEqual(decoded, header)
    }

    func testEnvelopeHeaderRejectsBadInputs() {
        XCTAssertNil(RelayEnvelopeHeader.decode("not json"))
        XCTAssertNil(RelayEnvelopeHeader.decode("{\"v\":2,\"from\":\"mac\",\"type\":\"ciphertext\"}"))
        XCTAssertNil(RelayEnvelopeHeader.decode("{\"v\":1,\"from\":\"server\",\"type\":\"ciphertext\"}"))
        XCTAssertNil(RelayEnvelopeHeader.decode("{\"v\":1,\"from\":\"mac\",\"type\":\"data\"}"))
    }

    // MARK: - Codec end-to-end (encrypt → relay-as-postal-service → decrypt)

    func testCodecEncryptDecryptRoundTrip() throws {
        // Shared key — derived in production via E7's RelayPairingCrypto.
        let key = SymmetricKey(size: .bits256)
        let macCodec = RelayFrameCodec(key: key, from: "mac")
        let iosCodec = RelayFrameCodec(key: key, from: "ios")

        // Mac sends frame; the inner payload is whatever shape iOS/Mac agree on.
        // Use a canonical JSON object so the codec's `sortedKeys`-based
        // re-serialization on decode produces byte-identical output.
        let payload = Data(#"{"planId":42,"sessionId":"abc"}"#.utf8)
        let (header, body) = try macCodec.encrypt(op: "approve_plan", data: payload)
        XCTAssertEqual(header.from, "mac")
        XCTAssertEqual(header.type, "ciphertext")

        // The relay sees only the opaque body bytes.
        // iOS side gets header + body, decrypts.
        let inner = try iosCodec.decrypt(body: body)
        XCTAssertEqual(inner.op, "approve_plan")
        XCTAssertEqual(inner.seq, 1)
        // The data round-trips. JSON re-serialization in the codec uses
        // sortedKeys, so equality holds because the payload above is
        // already in sorted-key form.
        XCTAssertEqual(
            String(data: inner.data, encoding: .utf8),
            String(data: payload, encoding: .utf8)
        )
    }

    func testCodecRejectsReplayedSequence() throws {
        let key = SymmetricKey(size: .bits256)
        let mac = RelayFrameCodec(key: key, from: "mac")
        let ios = RelayFrameCodec(key: key, from: "ios")

        let (_, body) = try mac.encrypt(op: "ping", data: Data("{}".utf8))
        // First open: accepted.
        _ = try ios.decrypt(body: body)
        // Same bytes a second time: rejected as replay.
        XCTAssertThrowsError(try ios.decrypt(body: body)) { error in
            XCTAssertEqual(error as? RelayFrameCodecError, .replayedSequence)
        }
    }

    func testCodecAdvancesSequenceMonotonically() throws {
        let key = SymmetricKey(size: .bits256)
        let mac = RelayFrameCodec(key: key, from: "mac")
        let ios = RelayFrameCodec(key: key, from: "ios")

        var seqs: [UInt64] = []
        for _ in 0..<5 {
            let (_, body) = try mac.encrypt(op: "ping", data: Data("{}".utf8))
            let inner = try ios.decrypt(body: body)
            seqs.append(inner.seq)
        }
        XCTAssertEqual(seqs, [1, 2, 3, 4, 5])
    }

    func testCodecBidirectionalSequencesAreIndependent() throws {
        // Mac → iOS counter is independent of iOS → Mac counter.
        // (Two codecs per peer in production — one for each direction.)
        let key = SymmetricKey(size: .bits256)
        let macSend = RelayFrameCodec(key: key, from: "mac")
        let iosSend = RelayFrameCodec(key: key, from: "ios")
        // Each side has its own RECEIVE-side codec too. The "receive" codec
        // is just the same struct flipped: we'll feed Mac's outbound to iOS
        // and vice versa, expecting each direction to start at seq=1.
        let iosReceiveMac = RelayFrameCodec(key: key, from: "ios")
        let macReceiveIos = RelayFrameCodec(key: key, from: "mac")

        let (_, macBody1) = try macSend.encrypt(op: "ping", data: Data("{}".utf8))
        let (_, macBody2) = try macSend.encrypt(op: "ping", data: Data("{}".utf8))
        let (_, iosBody1) = try iosSend.encrypt(op: "pong", data: Data("{}".utf8))

        let m1 = try iosReceiveMac.decrypt(body: macBody1)
        let m2 = try iosReceiveMac.decrypt(body: macBody2)
        let i1 = try macReceiveIos.decrypt(body: iosBody1)

        XCTAssertEqual(m1.seq, 1)
        XCTAssertEqual(m2.seq, 2)
        XCTAssertEqual(i1.seq, 1, "iOS-side counter must be independent of Mac-side counter")
    }

    func testCodecRejectsTooShortBody() {
        let codec = RelayFrameCodec(key: SymmetricKey(size: .bits256), from: "ios")
        XCTAssertThrowsError(try codec.decrypt(body: Data([0x00]))) { error in
            XCTAssertEqual(error as? RelayFrameCodecError, .ciphertextTooShort)
        }
    }

    func testCodecWrongKeyFailsAuth() throws {
        let mac = RelayFrameCodec(key: SymmetricKey(size: .bits256), from: "mac")
        let iosWrong = RelayFrameCodec(key: SymmetricKey(size: .bits256), from: "ios")
        let (_, body) = try mac.encrypt(op: "ping", data: Data("{}".utf8))
        XCTAssertThrowsError(try iosWrong.decrypt(body: body)) { error in
            XCTAssertEqual(error as? RelayFrameCodecError, .authenticationFailed)
        }
    }

    // MARK: - HChaCha20 unit test
    //
    // From RFC draft-irtf-cfrg-xchacha §2.2 Appendix A test vector:
    //   key   = 00010203040506070809...1f (00..1f)
    //   input = 000000090000004a0000000031415927
    //   subkey = 82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc
    //
    // We assert our pure-Swift HChaCha20 matches.
    func testHChaCha20MatchesIETFDraftVector() throws {
        let keyHex = (0..<32).map { String(format: "%02x", $0) }.joined()
        let key = try fromHex(keyHex)
        let input = try fromHex("000000090000004a0000000031415927")
        let expected = try fromHex("82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc")

        let subkey = try XChaCha20Poly1305.hchacha20(
            key: SymmetricKey(data: key),
            nonce: input
        )
        XCTAssertEqual(
            subkey, expected,
            "HChaCha20 RFC draft-irtf-cfrg-xchacha Appendix A vector must match."
        )
    }

    // MARK: - Helpers

    private func fromHex(_ hex: String) throws -> Data {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else {
                throw NSError(domain: "fromHex", code: 1)
            }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }
}
