#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Unit tests for AntigravityKeychainKeys — focused on the proto
/// parser since Keychain access itself can't be exercised hermetically
/// (would require a test entitlement + per-machine ACL setup).
///
/// Fixtures are built programmatically rather than hand-written hex so
/// the byte counts are exact by construction. Real Keychain secrets
/// never appear in source — material bytes are deterministic patterns
/// (0xAA / 0xBB / 0x00 ...).
final class AntigravityKeychainKeysTests: XCTestCase {

    // MARK: - Fixture builder

    /// Encodes a uint64 as protobuf varint bytes.
    private func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v > 0
        return bytes
    }

    /// Encodes a single Key submessage as a length-delimited field 2
    /// of the outer KeyBundle.
    ///
    /// Inner shape: { id=1 varint, version=2 varint, createdAt=3 varint, material=4 bytes }.
    private func encodeKey(id: UInt64, version: UInt64, createdAt: UInt64, material: Data) -> [UInt8] {
        var inner: [UInt8] = []
        // field 1 (id): tag = (1 << 3) | 0 = 0x08
        inner.append(0x08)
        inner.append(contentsOf: varint(id))
        // field 2 (version): tag = (2 << 3) | 0 = 0x10
        inner.append(0x10)
        inner.append(contentsOf: varint(version))
        // field 3 (createdAt): tag = (3 << 3) | 0 = 0x18
        inner.append(0x18)
        inner.append(contentsOf: varint(createdAt))
        // field 4 (material bytes): tag = (4 << 3) | 2 = 0x22
        inner.append(0x22)
        inner.append(contentsOf: varint(UInt64(material.count)))
        inner.append(contentsOf: material)
        // Wrap in outer field 2 length-delimited.
        var outer: [UInt8] = [0x12]
        outer.append(contentsOf: varint(UInt64(inner.count)))
        outer.append(contentsOf: inner)
        return outer
    }

    /// Encodes a KeyBundle as a hex string ready to feed
    /// `parseGeminiKeyBundle(hex:)`.
    private func encodeBundle(activeKeyID: UInt64, keys: [(id: UInt64, version: UInt64, createdAt: UInt64, material: Data)]) -> String {
        var bytes: [UInt8] = []
        // field 1 (activeKeyID): tag = (1 << 3) | 0 = 0x08
        bytes.append(0x08)
        bytes.append(contentsOf: varint(activeKeyID))
        for k in keys {
            bytes.append(contentsOf: encodeKey(id: k.id, version: k.version, createdAt: k.createdAt, material: k.material))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Parse happy path

    func test_parseGeminiKeyBundle_extractsActiveKeyAndBothKeys() throws {
        let hex = encodeBundle(
            activeKeyID: 291,
            keys: [
                (id: 1, version: 1, createdAt: 1_700_000_000, material: Data(repeating: 0xAA, count: 32)),
                (id: 2, version: 1, createdAt: 1_710_000_000, material: Data(repeating: 0xBB, count: 32)),
            ]
        )

        guard let bundle = AntigravityKeychainKeys.parseGeminiKeyBundle(hex: hex) else {
            XCTFail("parse returned nil for a well-formed fixture")
            return
        }
        XCTAssertEqual(bundle.activeKeyID, 291, "varint active id roundtrip")
        XCTAssertEqual(bundle.keys.count, 2, "should pick up both Key submessages")

        let k1 = bundle.keys[0]
        XCTAssertEqual(k1.id, 1)
        XCTAssertEqual(k1.version, 1)
        XCTAssertEqual(k1.createdAt, 1_700_000_000)
        XCTAssertEqual(k1.material.count, 32, "AES key material should be 32 bytes")
        XCTAssertEqual(k1.material, Data(repeating: 0xAA, count: 32))

        let k2 = bundle.keys[1]
        XCTAssertEqual(k2.id, 2)
        XCTAssertEqual(k2.createdAt, 1_710_000_000)
        XCTAssertEqual(k2.material, Data(repeating: 0xBB, count: 32))
    }

    func test_geminiKeyBundle_activeProperty_returnsKeyMatchingActiveID() {
        let hex = encodeBundle(
            activeKeyID: 2,
            keys: [
                (id: 1, version: 1, createdAt: 1_700_000_000, material: Data(repeating: 0x11, count: 32)),
                (id: 2, version: 1, createdAt: 1_710_000_000, material: Data(repeating: 0x22, count: 32)),
            ]
        )
        let bundle = AntigravityKeychainKeys.parseGeminiKeyBundle(hex: hex)
        XCTAssertEqual(bundle?.active?.id, 2)
        XCTAssertEqual(bundle?.active?.material, Data(repeating: 0x22, count: 32))
    }

    // MARK: - Edge cases

    func test_parseGeminiKeyBundle_returnsNilOnMalformedHex() {
        XCTAssertNil(AntigravityKeychainKeys.parseGeminiKeyBundle(hex: "zz"), "non-hex characters rejected")
        XCTAssertNil(AntigravityKeychainKeys.parseGeminiKeyBundle(hex: "abc"), "odd-length hex rejected")
    }

    func test_parseGeminiKeyBundle_acceptsCaseInsensitiveHex() {
        let hex = encodeBundle(
            activeKeyID: 1,
            keys: [(id: 1, version: 1, createdAt: 100, material: Data(repeating: 0xAB, count: 32))]
        )
        let lower = AntigravityKeychainKeys.parseGeminiKeyBundle(hex: hex)
        let upper = AntigravityKeychainKeys.parseGeminiKeyBundle(hex: hex.uppercased())
        XCTAssertEqual(lower, upper)
    }

    func test_parseGeminiKeyBundle_emptyHexReturnsEmptyBundle() {
        // Empty payload is a valid proto encoding of an empty message
        // (active=0, no keys). Matches the protobuf wire-format spec.
        let bundle = AntigravityKeychainKeys.parseGeminiKeyBundle(hex: "")
        XCTAssertNotNil(bundle)
        XCTAssertEqual(bundle?.activeKeyID, 0)
        XCTAssertEqual(bundle?.keys.count, 0)
    }

    func test_parseGeminiKeyBundle_skipsUnknownFields() {
        // Build a bundle, then prepend an unknown future field (field
        // 99 varint, value 42) before the keys. Parser should
        // tolerate it and still emit the real fields.
        var bytes: [UInt8] = []
        // active = 1
        bytes.append(0x08)
        bytes.append(contentsOf: varint(1))
        // Unknown field 99 varint, value 42. Tag = (99 << 3) | 0 = 792.
        bytes.append(contentsOf: varint(792))
        bytes.append(contentsOf: varint(42))
        // One real key.
        bytes.append(contentsOf: encodeKey(id: 1, version: 1, createdAt: 100, material: Data(repeating: 0x33, count: 32)))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let bundle = AntigravityKeychainKeys.parseGeminiKeyBundle(hex: hex)
        XCTAssertEqual(bundle?.activeKeyID, 1)
        XCTAssertEqual(bundle?.keys.count, 1)
        XCTAssertEqual(bundle?.keys.first?.material, Data(repeating: 0x33, count: 32))
    }

    // MARK: - Surface integration (best-effort, allowed to skip)

    /// Smoke test that calls into the real Keychain. Skipped silently
    /// when Antigravity isn't installed on the test runner (CI). Not
    /// expected to pass without a per-machine "Always Allow" grant —
    /// it's here so a maintainer running tests locally on a real
    /// Antigravity machine can verify the integration end-to-end.
    func test_realKeychainReadDoesNotCrash() {
        _ = AntigravityKeychainKeys.electronSafeStorageKey()
        _ = AntigravityKeychainKeys.geminiKeyBundleRawHex()
        _ = AntigravityKeychainKeys.geminiKeyBundle()
    }
}
#endif
