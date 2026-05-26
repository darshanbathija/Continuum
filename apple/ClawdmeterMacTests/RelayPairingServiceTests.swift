import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// E7 Mac-side state-machine + bundle-gen tests for the relay pairing
/// service. Validates that:
///   1. Initial phase is `.unpaired`
///   2. `beginPairing()` transitions to `.readyButNotConnected` and
///      surfaces a valid bundle + URL
///   3. The URL round-trips through `RelayPairingBundle.decode(fromURL:)`
///   4. The iOS-side derivation against the Mac's keypair yields the
///      same symmetric key as the Mac-side derivation (cross-platform
///      acceptance — same invariant as RelayPairingHandshakeTests but
///      driven through the Mac service)
///   5. `reset()` returns to `.unpaired` + drops the keypair
@MainActor
final class RelayPairingServiceTests: XCTestCase {

    func testInitialPhaseIsUnpaired() {
        let service = RelayPairingService()
        XCTAssertEqual(service.phase, .unpaired)
        XCTAssertNil(service.bundle)
        XCTAssertNil(service.bundleURL)
    }

    func testBeginPairingProducesValidBundle() throws {
        let service = RelayPairingService()
        service.beginPairing()

        XCTAssertEqual(service.phase, .readyButNotConnected)
        let bundle = try XCTUnwrap(service.bundle)
        let urlString = try XCTUnwrap(service.bundleURL)

        // Bundle fields validate.
        XCTAssertNotNil(bundle.validated())
        XCTAssertTrue(urlString.hasPrefix("clawdmeter-pair://v1/"))

        // The URL parses cleanly back into an equal bundle.
        let decoded = try XCTUnwrap(RelayPairingBundle.decode(fromURL: urlString))
        XCTAssertEqual(decoded, bundle)

        // The session ID + tokens are 32-byte base64url (43 chars).
        XCTAssertEqual(bundle.sid.count, 43)
        XCTAssertEqual(bundle.macTok.count, 43)
        XCTAssertEqual(bundle.iosTok.count, 43)
        XCTAssertNotEqual(bundle.macTok, bundle.iosTok)

        // The TTL is in the future and ≤ 15 minutes out.
        let now = UInt64(Date().timeIntervalSince1970)
        XCTAssertGreaterThan(bundle.ttl, now)
        XCTAssertLessThanOrEqual(bundle.ttl, now + 900 + 5) // 5s slack

        // The relay URL defaults to staging (no env override).
        XCTAssertEqual(bundle.relayUrl, RelayEnvironment.staging.baseURL)
    }

    func testIPhoneCanDeriveMatchingSymmetricKey() throws {
        let service = RelayPairingService()
        service.beginPairing()

        let macKeypair = try XCTUnwrap(service.keypairForTesting)
        let bundle = try XCTUnwrap(service.bundle)

        // Simulate the iPhone side: parse the bundle from URL, generate
        // an iPhone keypair, derive K, then compute the Mac-side K
        // independently and verify byte equality.
        let urlString = try XCTUnwrap(service.bundleURL)
        let parsed = try XCTUnwrap(RelayPairingBundle.decode(fromURL: urlString))
        XCTAssertEqual(parsed.sid, bundle.sid)
        XCTAssertEqual(parsed.ecdhPub, bundle.ecdhPub)

        let phoneKeypair = RelayPairingKeyPair()
        let phoneK = try phoneKeypair.deriveSharedKey(
            theirPublicKeyBase64URL: parsed.ecdhPub,
            sessionId: parsed.sid
        )
        let macK = try macKeypair.deriveSharedKey(
            theirPublicKeyBase64URL: phoneKeypair.publicKeyBase64URL,
            sessionId: parsed.sid
        )
        XCTAssertEqual(macK, phoneK)
        XCTAssertEqual(macK.count, 32)
    }

    func testResetReturnsToUnpaired() throws {
        let service = RelayPairingService()
        service.beginPairing()
        XCTAssertEqual(service.phase, .readyButNotConnected)

        service.reset()
        XCTAssertEqual(service.phase, .unpaired)
        XCTAssertNil(service.bundle)
        XCTAssertNil(service.bundleURL)
        XCTAssertNil(service.keypairForTesting)
    }

    func testRegeneratingProducesFreshBundle() throws {
        let service = RelayPairingService()
        service.beginPairing()
        let first = try XCTUnwrap(service.bundle)
        let firstKey = try XCTUnwrap(service.keypairForTesting).publicKeyBase64URL

        service.beginPairing()
        let second = try XCTUnwrap(service.bundle)
        let secondKey = try XCTUnwrap(service.keypairForTesting).publicKeyBase64URL

        // Fresh sid, fresh tokens, fresh keypair.
        XCTAssertNotEqual(first.sid, second.sid)
        XCTAssertNotEqual(first.macTok, second.macTok)
        XCTAssertNotEqual(first.iosTok, second.iosTok)
        XCTAssertNotEqual(firstKey, secondKey)
    }
}
