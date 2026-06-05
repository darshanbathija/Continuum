import XCTest
@testable import ClawdmeterShared

/// Track B — CB-P1g: the persisted pairing record must NEVER serialize the
/// bearer tokens or the derived key to disk; those are Keychain-only. A legacy
/// file that still carries them must remain decodable so the store can migrate.
final class RelayPairingRecordRedactionTests: XCTestCase {

    private func sample() -> RelayPairingRecord {
        RelayPairingRecord(
            sid: "sid-123", macTok: "MAC-SECRET-TOKEN", iosTok: "IOS-SECRET-TOKEN",
            theirEcdhPublicKeyBase64URL: "their-pub", ourEcdhPublicKeyBase64URL: "our-pub",
            derivedSymmetricKeyBase64URL: "DERIVED-KEY-SECRET",
            ttl: 1_800_000_000, relayUrl: "wss://relay.example", pairedAtUnixSeconds: 1_700_000_000
        )
    }

    func test_encode_omitsAllSecrets() throws {
        let data = try JSONEncoder().encode(sample())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("MAC-SECRET-TOKEN"), "macTok must not be on disk")
        XCTAssertFalse(json.contains("IOS-SECRET-TOKEN"), "iosTok must not be on disk")
        XCTAssertFalse(json.contains("DERIVED-KEY-SECRET"), "derived key must not be on disk")
        XCTAssertFalse(json.contains("macTok"))
        XCTAssertFalse(json.contains("iosTok"))
        XCTAssertFalse(json.contains("derivedSymmetricKeyBase64URL"))
        // Non-secret fields stay (slashes may be JSON-escaped, so match the
        // host fragment + key names rather than the full URL).
        XCTAssertTrue(json.contains("sid-123"))
        XCTAssertTrue(json.contains("relayUrl"))
        XCTAssertTrue(json.contains("relay.example"))
    }

    func test_encodeDecode_roundTripsNonSecretsAndBlanksSecrets() throws {
        let back = try JSONDecoder().decode(RelayPairingRecord.self, from: try JSONEncoder().encode(sample()))
        XCTAssertEqual(back.sid, "sid-123")
        XCTAssertEqual(back.relayUrl, "wss://relay.example")
        XCTAssertEqual(back.ttl, 1_800_000_000)
        // Secrets are NOT recoverable from the redacted JSON.
        XCTAssertEqual(back.macTok, "")
        XCTAssertEqual(back.iosTok, "")
        XCTAssertNil(back.derivedSymmetricKeyBase64URL)
        XCTAssertFalse(back.hasInlineSecrets)
    }

    func test_legacyFileWithInlineSecrets_stillDecodes_forMigration() throws {
        // A pre-CB-P1g file: secrets are inline. Decode must read them so the
        // store can migrate them into the Keychain.
        let legacy = """
        {"sid":"sid-9","macTok":"OLD-MAC","iosTok":"OLD-IOS","ourEcdhPublicKeyBase64URL":"p",\
        "derivedSymmetricKeyBase64URL":"OLD-K","ttl":123,"relayUrl":"wss://r","pairedAtUnixSeconds":7}
        """
        let rec = try JSONDecoder().decode(RelayPairingRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(rec.macTok, "OLD-MAC")
        XCTAssertEqual(rec.iosTok, "OLD-IOS")
        XCTAssertEqual(rec.derivedSymmetricKeyBase64URL, "OLD-K")
        XCTAssertTrue(rec.hasInlineSecrets, "a legacy file must be flagged for migration")
    }

    func test_withSecrets_rehydrates() {
        let redacted = RelayPairingRecord(
            sid: "s", macTok: "", iosTok: "", theirEcdhPublicKeyBase64URL: nil,
            ourEcdhPublicKeyBase64URL: "p", derivedSymmetricKeyBase64URL: nil,
            ttl: 1, relayUrl: "r", pairedAtUnixSeconds: 2
        )
        let full = redacted.withSecrets(macTok: "M", iosTok: "I", derivedSymmetricKeyBase64URL: "K")
        XCTAssertEqual(full.iosTok, "I")
        XCTAssertEqual(full.macTok, "M")
        XCTAssertEqual(full.sid, "s")
    }
}
