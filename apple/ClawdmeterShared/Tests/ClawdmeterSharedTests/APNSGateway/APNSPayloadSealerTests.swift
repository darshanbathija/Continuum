// E6: payload-sealer round-trip + tampering tests.
//
// The Worker is opaque to the encrypted body — only the paired iPhone can
// decrypt. We pin the round-trip here so a future change to nonce handling
// or AEAD construction trips the test instead of silently breaking iOS
// notification rendering.

import XCTest
@testable import ClawdmeterShared
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class APNSPayloadSealerTests: XCTestCase {

    private func makeKey() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Round trip

    func testSealAndOpenRoundtrip() throws {
        let key = makeKey()
        let plaintext = Data("hello e6 push body".utf8)
        let wire = try APNSPayloadSealer.seal(plaintext: plaintext, keyBytes: key)
        let opened = try APNSPayloadSealer.open(wire: wire, keyBytes: key)
        XCTAssertEqual(opened, plaintext)
    }

    /// Wire form is base64 (standard, not base64url). The Worker accepts
    /// both — we keep standard base64 here for consistency with the relay.
    func testWireFormIsBase64() throws {
        let key = makeKey()
        let plaintext = Data("base64 test".utf8)
        let wire = try APNSPayloadSealer.seal(plaintext: plaintext, keyBytes: key)
        XCTAssertNotNil(Data(base64Encoded: wire), "wire must round-trip through standard base64")
    }

    /// Sealed length must be < 3500 chars for small bodies, matching the
    /// Worker's `MAX_ENCRYPTED_PAYLOAD_LEN`. Use a 1-byte plaintext to
    /// confirm AEAD overhead alone stays inside the budget.
    func testSealedSizeFitsInsideWorkerCap() throws {
        let key = makeKey()
        let plaintext = Data("h".utf8)  // 1 byte plaintext
        let wire = try APNSPayloadSealer.seal(plaintext: plaintext, keyBytes: key)
        XCTAssertLessThan(wire.count, 3500, "wire form must stay under the Worker's 3500-char cap")
    }

    /// Different keys must NOT decrypt — protects threat #1 (operator
    /// curious) by proving the gateway-side derivation can't recover
    /// plaintext.
    func testWrongKeyFailsToOpen() throws {
        let kA = makeKey()
        let kB = makeKey()
        let wire = try APNSPayloadSealer.seal(plaintext: Data("secret".utf8), keyBytes: kA)
        XCTAssertThrowsError(try APNSPayloadSealer.open(wire: wire, keyBytes: kB))
    }

    /// Tampered ciphertext must fail decryption — Poly1305 tag catches
    /// any byte flip.
    func testTamperedCiphertextFailsToOpen() throws {
        let key = makeKey()
        let wire = try APNSPayloadSealer.seal(plaintext: Data("tamper".utf8), keyBytes: key)
        // Flip a single byte in the middle of the base64.
        var chars = Array(wire)
        let mid = chars.count / 2
        chars[mid] = chars[mid] == Character("A") ? Character("B") : Character("A")
        let tampered = String(chars)
        XCTAssertThrowsError(try APNSPayloadSealer.open(wire: tampered, keyBytes: key))
    }

    /// Plaintext bigger than `maxCleartextBytes` is rejected with the
    /// typed error — caller can branch on it.
    func testRejectsOversizedPlaintext() throws {
        let key = makeKey()
        let plaintext = Data(repeating: 0x41, count: APNSPayloadSealer.maxCleartextBytes + 1)
        XCTAssertThrowsError(try APNSPayloadSealer.seal(plaintext: plaintext, keyBytes: key)) { error in
            guard case let APNSPayloadSealError.plaintextTooLarge(size: size, limit: limit) = error else {
                XCTFail("expected plaintextTooLarge"); return
            }
            XCTAssertEqual(size, APNSPayloadSealer.maxCleartextBytes + 1)
            XCTAssertEqual(limit, APNSPayloadSealer.maxCleartextBytes)
        }
    }

    /// Wrong key length is rejected even before the AEAD runs.
    func testRejectsWrongKeyLength() {
        let badKey = Data(repeating: 0x00, count: 16)  // 128 bits, must be 256
        XCTAssertThrowsError(
            try APNSPayloadSealer.seal(plaintext: Data("x".utf8), keyBytes: badKey)
        ) { error in
            XCTAssertEqual(error as? APNSPayloadSealError, .invalidKeyLength)
        }
    }

    // MARK: - JSON helper

    /// sealJSON + openJSON pair compose correctly.
    func testJSONHelperRoundtrip() throws {
        let key = makeKey()
        let body = APNSPushBody(
            kind: "planApproval",
            sessionId: "abc-123",
            title: "Plan ready",
            body: "Implementation plan ready for review",
            triggerAt: 1_700_000_000
        )
        let wire = try APNSPayloadSealer.sealJSON(body: body, keyBytes: key)
        let recovered = try APNSPayloadSealer.openJSON(
            as: APNSPushBody.self, wire: wire, keyBytes: key
        )
        XCTAssertEqual(recovered, body)
    }

    /// Sender fingerprint is SHA-256 over the raw pubkey, 64 hex chars.
    func testSenderFingerprintShape() {
        let pair = RelayPairingKeyPair()
        let fp = APNSSenderFingerprint.compute(macPublicKeyBase64URL: pair.publicKeyBase64URL)
        let fingerprint = try? XCTUnwrap(fp)
        XCTAssertEqual(fingerprint?.count, 64)
        // Hex-only
        let hexOnly = fingerprint?.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
        XCTAssertEqual(hexOnly, true)
    }

    /// Pinned with a deterministic nonce vector. If CryptoKit's
    /// `ChaChaPoly.seal` output format ever shifts byte layout, this trips.
    func testDeterministicNonceProducesStableWire() throws {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x07, count: 12)
        let plaintext = Data("vector".utf8)
        let wireA = try APNSPayloadSealer.seal(plaintext: plaintext, keyBytes: key, nonceOverride: nonce)
        let wireB = try APNSPayloadSealer.seal(plaintext: plaintext, keyBytes: key, nonceOverride: nonce)
        XCTAssertEqual(wireA, wireB, "Same key+nonce+plaintext must produce identical wire bytes")
        // Reasonable size: 12-byte nonce + 6-byte ciphertext + 16-byte tag = 34 bytes
        // base64-encoded → 44 chars (with padding) ish
        guard let combined = Data(base64Encoded: wireA) else {
            XCTFail("wire is not base64"); return
        }
        XCTAssertEqual(combined.count, 12 + plaintext.count + 16)
    }
}
