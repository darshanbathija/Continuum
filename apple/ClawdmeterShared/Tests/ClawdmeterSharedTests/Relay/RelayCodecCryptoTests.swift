// Cross-implementation crypto test vectors for `RelayFrameCodec`.
//
// These tests load the same JSON fixtures that the TypeScript relay
// Worker's `test-vectors.test.ts` consumes. If either side diverges
// even by one byte, the tests here flip red — which is the gating
// contract called out in docs/design/secure-relay-apns-2026-05-26.md §8.
//
// Fixture source-of-truth lives in `infra/relay/test-vectors/`. The
// build copies them into the test bundle via the package manifest's
// `resources: [.process("Fixtures")]` directive.

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import ClawdmeterShared

final class RelayCodecCryptoTests: XCTestCase {

    // MARK: - X25519

    func testX25519ECDHSharedSecret() throws {
        let v = try loadFixture("x25519-ecdh-001")
        let macPriv = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hex(v["mac_priv_hex"] as! String)
        )
        let iosPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: hex(v["ios_pub_hex"] as! String)
        )
        let macPubExpected = hex(v["mac_pub_hex"] as! String)
        XCTAssertEqual(macPriv.publicKey.rawRepresentation, macPubExpected)
        let shared = try macPriv.sharedSecretFromKeyAgreement(with: iosPub)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        XCTAssertEqual(sharedBytes, hex(v["expected_shared_secret_hex"] as! String))
    }

    // MARK: - HKDF

    func testHKDFSHA256() throws {
        let v = try loadFixture("hkdf-sha256-001")
        let secretBytes = hex(v["shared_secret_hex"] as! String)
        let saltBytes = Data((v["salt_ascii"] as! String).utf8)
        let infoBytes = Data((v["info_ascii"] as! String).utf8)

        let outputLen = v["output_len"] as! Int

        // Use HKDF<SHA256>.deriveKey directly so we don't rely on
        // SharedSecret's wrapper having a public init from raw bytes.
        let inputKey = SymmetricKey(data: secretBytes)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: saltBytes,
            info: infoBytes,
            outputByteCount: outputLen
        )
        let derivedBytes = derived.withUnsafeBytes { Data($0) }
        XCTAssertEqual(derivedBytes, hex(v["expected_key_hex"] as! String))
    }

    // MARK: - XChaCha20-Poly1305 seal

    func testXChaCha20Poly1305Seal() throws {
        let v = try loadFixture("xchacha20-poly1305-001")
        let key = SymmetricKey(data: hex(v["key_hex"] as! String))
        let nonce = hex(v["nonce_hex"] as! String)
        let aad = Data((v["aad_ascii"] as! String).utf8)
        let plaintext = Data((v["plaintext_ascii"] as! String).utf8)

        let sealed = try RelayFrameCodec.seal(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            aad: aad
        )

        let expectedHex = v["expected_ciphertext_hex"] as! String
        XCTAssertEqual(sealed, hex(expectedHex))
        XCTAssertEqual(sealed.count, v["expected_ciphertext_len"] as! Int)
    }

    // MARK: - XChaCha20-Poly1305 open

    func testXChaCha20Poly1305Open() throws {
        let v = try loadFixture("xchacha20-poly1305-roundtrip-001")
        let key = SymmetricKey(data: hex(v["key_hex"] as! String))
        let nonce = hex(v["nonce_hex"] as! String)
        let aad = Data((v["aad_ascii"] as! String).utf8)
        let sealed = hex(v["ciphertext_hex"] as! String)

        let plaintext = try RelayFrameCodec.open(
            sealed: sealed,
            key: key,
            nonce: nonce,
            aad: aad
        )
        XCTAssertEqual(plaintext, hex(v["expected_plaintext_hex"] as! String))
    }

    // MARK: - Tamper detection

    func testTamperedCiphertextFailsAEAD() throws {
        let v = try loadFixture("tampered-ciphertext-001")
        let key = SymmetricKey(data: hex(v["key_hex"] as! String))
        let nonce = hex(v["nonce_hex"] as! String)
        let aad = Data((v["aad_ascii"] as! String).utf8)
        let tampered = hex(v["tampered_ciphertext_hex"] as! String)
        XCTAssertThrowsError(try RelayFrameCodec.open(
            sealed: tampered, key: key, nonce: nonce, aad: aad
        )) { err in
            XCTAssertEqual(err as? RelayCodecError, .aeadFailed,
                          "tampered ciphertext must surface .aeadFailed")
        }
    }

    // MARK: - Envelope header

    func testEnvelopeHeaderCanonicalSerialization() throws {
        let v = try loadFixture("envelope-header-001")
        let headerObj = v["header_object"] as! [String: Any]
        let header = RelayEnvelopeHeader(
            v: headerObj["v"] as! Int,
            from: RelayPeerRole(rawValue: headerObj["from"] as! String)!,
            type: RelayEnvelopeType(rawValue: headerObj["type"] as! String)!
        )
        let serialized = header.encodeCanonicalJSON()
        let expectedAscii = v["expected_serialized_ascii"] as! String
        XCTAssertEqual(String(data: serialized, encoding: .utf8), expectedAscii)
        XCTAssertEqual(serialized, hex(v["expected_serialized_hex"] as! String))
    }

    func testEnvelopeHeaderDecodeRoundtrip() throws {
        for from in RelayPeerRole.allCases {
            for type in RelayEnvelopeType.allCases {
                let header = RelayEnvelopeHeader(from: from, type: type)
                let bytes = header.encodeCanonicalJSON()
                let decoded = RelayEnvelopeHeader.decode(bytes)
                XCTAssertEqual(decoded, header,
                              "header roundtrip failed for from=\(from) type=\(type)")
            }
        }
    }

    func testEnvelopeHeaderRejectsBadValues() {
        // Wrong wire version
        XCTAssertNil(RelayEnvelopeHeader.decode(Data(#"{"v":2,"from":"ios","type":"ciphertext"}"#.utf8)))
        // Unknown role
        XCTAssertNil(RelayEnvelopeHeader.decode(Data(#"{"v":1,"from":"watch","type":"ciphertext"}"#.utf8)))
        // Unknown type
        XCTAssertNil(RelayEnvelopeHeader.decode(Data(#"{"v":1,"from":"ios","type":"plaintext"}"#.utf8)))
        // Not JSON
        XCTAssertNil(RelayEnvelopeHeader.decode(Data("not json".utf8)))
        // Oversize
        let oversize = String(repeating: "a", count: RelayFrameCodec.maxHeaderBytes + 1)
        XCTAssertNil(RelayEnvelopeHeader.decode(Data(oversize.utf8)))
    }

    // MARK: - Plaintext payload

    func testPlaintextRoundtrip() throws {
        let payload = RelayPlaintext(
            seq: 42,
            op: "approve_plan",
            data: Data(#"{"ok":true}"#.utf8)
        )
        let bytes = try payload.encodeCanonicalJSON()
        let asString = String(data: bytes, encoding: .utf8)
        XCTAssertEqual(asString, #"{"seq":42,"op":"approve_plan","data":{"ok":true}}"#)
        let parsed = RelayPlaintext.decode(bytes)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.seq, 42)
        XCTAssertEqual(parsed?.op, "approve_plan")
    }

    // MARK: - Constant-time compare

    func testConstantTimeEqualsLengthMismatch() {
        XCTAssertFalse(Data([1, 2, 3]).constantTimeEquals(Data([1, 2])))
    }

    func testConstantTimeEqualsValueMismatch() {
        XCTAssertFalse(Data([1, 2, 3]).constantTimeEquals(Data([1, 2, 4])))
    }

    func testConstantTimeEqualsMatch() {
        XCTAssertTrue(Data([0xff, 0x00, 0xff]).constantTimeEquals(Data([0xff, 0x00, 0xff])))
        XCTAssertTrue(Data().constantTimeEquals(Data()))
    }

    // MARK: - End-to-end: HKDF → seal → open over fixture key

    func testEndToEndSealOpenRoundtripWithRandomNonce() throws {
        let v = try loadFixture("hkdf-sha256-001")
        let key = SymmetricKey(data: hex(v["expected_key_hex"] as! String))
        let plaintext = Data("the quick brown fox jumps over the lazy dog".utf8)
        let nonce = RelayFrameCodec.randomNonce()
        XCTAssertEqual(nonce.count, RelayFrameCodec.nonceLength)
        let sealed = try RelayFrameCodec.seal(plaintext: plaintext, key: key, nonce: nonce)
        XCTAssertEqual(sealed.count, plaintext.count + RelayFrameCodec.tagLength)
        let recovered = try RelayFrameCodec.open(sealed: sealed, key: key, nonce: nonce)
        XCTAssertEqual(recovered, plaintext)
    }

    // MARK: - HChaCha20 standalone vector

    /// Standalone HChaCha20 vector from RFC draft-irtf-cfrg-xchacha-03 §2.2.1.
    /// This is the canonical fixture cited by every libsodium / NaCl
    /// implementation; we test against it directly so a regression in
    /// the pure-Swift block function is caught without needing the
    /// full XChaCha20-Poly1305 stack.
    func testHChaCha20RFCVector() throws {
        // Key:    000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
        // Nonce:  000000090000004a0000000031415927
        // Output: 82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc
        let key = SymmetricKey(data: hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        let salt = hex("000000090000004a0000000031415927")
        let expected = hex("82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc")
        let derived = HChaCha20.subkey(key: key, salt: salt)
        XCTAssertEqual(derived, expected)
    }

    // MARK: - Helpers

    private func loadFixture(_ name: String) throws -> [String: Any] {
        // `Resources/.process` flattens subdirectories into the bundle
        // root unless the manifest preserves structure with `.copy`. We
        // use `.process` here (mirrors the existing Fixtures dir), so
        // look up the JSON by base name only.
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "json"
        ), "fixture \(name).json missing from bundle")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "fixture \(name).json malformed"
        )
    }

    private func hex(_ string: String) -> Data {
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}
