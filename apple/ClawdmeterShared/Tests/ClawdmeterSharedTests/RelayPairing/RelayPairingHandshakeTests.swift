// E7: integration assertion-only test simulating the Mac ↔ iPhone
// handshake end-to-end (no real cameras, no real relay round-trip).
//
// The acceptance criterion from the E7 task: "launch both apps in
// simulators, drive through pairing end-to-end, verify the derived
// shared keys match (write an assertion-only integration test that
// doesn't require real cameras)." This test does exactly that — we
// drive both halves of the handshake via the shared types and assert
// the symmetric keys come out byte-identical.

import XCTest
@testable import ClawdmeterShared

final class RelayPairingHandshakeTests: XCTestCase {

    // MARK: - Crypto round-trip

    /// Single-peer key generation produces a 32-byte public key + a
    /// stable base64url encoding.
    func testKeyPairProducesValidPublicKey() throws {
        let pair = RelayPairingKeyPair()
        let raw = pair.publicKey.rawRepresentation
        XCTAssertEqual(raw.count, 32, "X25519 public keys are 32 bytes")

        let b64 = pair.publicKeyBase64URL
        XCTAssertEqual(b64.count, 43, "32 bytes base64url-no-padding = 43 chars")
        XCTAssertNotNil(RelayPairingBundle.isValidECDHPublicKey(b64) ? () : nil)

        // Round-trips through base64url decoder.
        let decoded = RelayPairingBase64URL.decode(b64)
        XCTAssertEqual(decoded, raw)
    }

    /// E7 acceptance: a Mac peer + iPhone peer who exchange public keys
    /// over our wire derive byte-identical symmetric keys via HKDF.
    /// This is THE crypto invariant — if it fails, E3/E4 cannot encrypt.
    func testMacAndPhoneDeriveSameSymmetricKey() throws {
        // Mac side bootstrap (mirrors RelayPairingService.beginPairing):
        let macPair = RelayPairingKeyPair()
        let sid = RelayPairingMint.randomBase64URLToken()
        let macTok = RelayPairingMint.randomBase64URLToken()
        let iosTok = RelayPairingMint.randomBase64URLToken()
        let ttl = UInt64(Date().timeIntervalSince1970) + 900
        let relayUrl = RelayEnvironment.staging.baseURL

        let bundle = RelayPairingBundle(
            sid: sid,
            macTok: macTok,
            iosTok: iosTok,
            ecdhPub: macPair.publicKeyBase64URL,
            ttl: ttl,
            relayUrl: relayUrl
        )

        // iPhone side: parses the bundle, generates its own keypair,
        // derives K from (its priv, Mac's pub, sid).
        let phonePair = RelayPairingKeyPair()
        let phoneDerivedK = try phonePair.deriveSharedKey(
            theirPublicKeyBase64URL: bundle.ecdhPub,
            sessionId: bundle.sid
        )

        // Mac side: in E3/E4 the Mac receives the iPhone's pubkey as
        // the first relay frame. For the E7 test we simulate that by
        // computing the Mac-side derivation directly. The invariant:
        // both halves of the X25519 + HKDF agree.
        let macDerivedK = try macPair.deriveSharedKey(
            theirPublicKeyBase64URL: phonePair.publicKeyBase64URL,
            sessionId: bundle.sid
        )

        XCTAssertEqual(macDerivedK.count, 32, "HKDF outputs 32-byte SymmetricKey")
        XCTAssertEqual(phoneDerivedK.count, 32)
        XCTAssertEqual(
            macDerivedK, phoneDerivedK,
            "Mac and iPhone MUST derive the same symmetric key from the same (pub, priv, sid) tuple"
        )
    }

    /// A different `sid` MUST yield a different K, even if the
    /// underlying ECDH pubkeys are the same. This is the §5b binding
    /// that makes the salt load-bearing: a captured QR can't be replayed
    /// against a different session.
    func testDifferentSidsDeriveDifferentKeys() throws {
        let macPair = RelayPairingKeyPair()
        let phonePair = RelayPairingKeyPair()
        let sidA = RelayPairingMint.randomBase64URLToken()
        let sidB = RelayPairingMint.randomBase64URLToken()

        let kA = try macPair.deriveSharedKey(
            theirPublicKeyBase64URL: phonePair.publicKeyBase64URL,
            sessionId: sidA
        )
        let kB = try macPair.deriveSharedKey(
            theirPublicKeyBase64URL: phonePair.publicKeyBase64URL,
            sessionId: sidB
        )
        XCTAssertNotEqual(kA, kB)
    }

    /// Malformed peer pubkey is rejected with the typed error, not a
    /// crash. iOS scanner code branches on this; we exercise the
    /// failure shape here.
    func testInvalidPeerPubkeyThrows() {
        let pair = RelayPairingKeyPair()
        XCTAssertThrowsError(
            try pair.deriveSharedKey(theirPublicKeyBase64URL: "not-base64-and-too-short",
                                     sessionId: "irrelevant")
        ) { error in
            XCTAssertEqual(error as? RelayPairingCryptoError, .invalidPublicKey)
        }
    }

    // MARK: - Wire-format round-trip

    /// Encode → decode → byte-equal. Also verifies the URL form starts
    /// with `clawdmeter-pair://` so the iOS scanner can branch cleanly.
    func testBundleURLRoundTrip() throws {
        let bundle = RelayPairingBundle(
            sid: makeValidToken(),
            macTok: makeValidToken(),
            iosTok: makeValidToken(),
            ecdhPub: RelayPairingKeyPair().publicKeyBase64URL,
            ttl: UInt64(Date().timeIntervalSince1970) + 900,
            relayUrl: RelayEnvironment.staging.baseURL
        )
        let url = try bundle.encodeToURL()
        XCTAssertTrue(url.hasPrefix("clawdmeter-pair://v1/"))
        let decoded = RelayPairingBundle.decode(fromURL: url)
        XCTAssertEqual(decoded, bundle)
    }

    func testRejectsOldSchemeAndOldQRs() {
        // Old Tailscale QR — must NOT decode as a relay bundle.
        let oldQR = "clawdmeter://192.168.1.100:21731?token=abc&ws=21732"
        XCTAssertNil(RelayPairingBundle.decode(fromURL: oldQR))
    }

    func testRejectsExpiredTTL() throws {
        // We can't construct an "already-expired" bundle through the
        // public init without also rejecting via decode-time validation
        // — manufacture the URL directly and feed it through decode.
        let body: [String: Any] = [
            "v": 1,
            "sid": makeValidToken(),
            "macTok": makeValidToken(),
            "iosTok": makeValidToken(),
            "ecdhPub": RelayPairingKeyPair().publicKeyBase64URL,
            // 1970 — definitely expired.
            "ttl": 1,
            "relayUrl": RelayEnvironment.staging.baseURL,
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let b64 = RelayPairingBase64URL.encode(data)
        let url = "clawdmeter-pair://v1/\(b64)"
        XCTAssertNil(RelayPairingBundle.decode(fromURL: url))
    }

    func testRejectsRelayURLOutsideAllowlist() throws {
        let body: [String: Any] = [
            "v": 1,
            "sid": makeValidToken(),
            "macTok": makeValidToken(),
            "iosTok": makeValidToken(),
            "ecdhPub": RelayPairingKeyPair().publicKeyBase64URL,
            "ttl": UInt64(Date().timeIntervalSince1970) + 900,
            "relayUrl": "wss://attacker.example", // not under *.clawdmeter.dev
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let b64 = RelayPairingBase64URL.encode(data)
        let url = "clawdmeter-pair://v1/\(b64)"
        XCTAssertNil(RelayPairingBundle.decode(fromURL: url))
    }

    func testAcceptsKnownHostedWorkerRelayURL() throws {
        let bundle = RelayPairingBundle(
            sid: makeValidToken(),
            macTok: makeValidToken(),
            iosTok: makeValidToken(),
            ecdhPub: RelayPairingKeyPair().publicKeyBase64URL,
            ttl: UInt64(Date().timeIntervalSince1970) + 900,
            relayUrl: "wss://clawdmeter-relay-staging.darshan-1ba.workers.dev"
        )
        let url = try bundle.encodeToURL()
        XCTAssertEqual(RelayPairingBundle.decode(fromURL: url), bundle)
    }

    func testRejectsUnknownHostedWorkerRelayURL() throws {
        let bundle = RelayPairingBundle(
            sid: makeValidToken(),
            macTok: makeValidToken(),
            iosTok: makeValidToken(),
            ecdhPub: RelayPairingKeyPair().publicKeyBase64URL,
            ttl: UInt64(Date().timeIntervalSince1970) + 900,
            relayUrl: "wss://clawdmeter-relay-staging.attacker.workers.dev"
        )
        let url = try bundle.encodeToURL()
        XCTAssertNil(RelayPairingBundle.decode(fromURL: url))
    }

    func testRejectsBundleWhereMacAndIosTokensMatch() throws {
        let dupTok = makeValidToken()
        let body: [String: Any] = [
            "v": 1,
            "sid": makeValidToken(),
            "macTok": dupTok,
            "iosTok": dupTok,
            "ecdhPub": RelayPairingKeyPair().publicKeyBase64URL,
            "ttl": UInt64(Date().timeIntervalSince1970) + 900,
            "relayUrl": RelayEnvironment.staging.baseURL,
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let b64 = RelayPairingBase64URL.encode(data)
        let url = "clawdmeter-pair://v1/\(b64)"
        XCTAssertNil(RelayPairingBundle.decode(fromURL: url))
    }

    // MARK: - End-to-end "drive both peers through the state machine"

    /// Walks the full handshake the way IOSPairingScanView + Mac's
    /// RelayPairingService will at runtime — minus the camera + the
    /// QR-render step. Asserts the iOS-side persistence round-trips and
    /// that the derived K saved on disk matches the one in memory.
    func testPairingPersistsAndRoundTripsThroughStore() throws {
        // Make a fresh per-test store under a tmpdir so we don't poison
        // the simulator's real Application Support directory.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e7-pairing-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storeFile = tmpDir.appendingPathComponent("record.json")
        let store = RelayPairingStore(
            fileURL: storeFile,
            keychainService: "com.clawdmeter.relay.pairing.test-\(UUID())"
        )

        // --- Mac side ---
        let macPair = RelayPairingKeyPair()
        let bundle = RelayPairingBundle(
            sid: RelayPairingMint.randomBase64URLToken(),
            macTok: RelayPairingMint.randomBase64URLToken(),
            iosTok: RelayPairingMint.randomBase64URLToken(),
            ecdhPub: macPair.publicKeyBase64URL,
            ttl: UInt64(Date().timeIntervalSince1970) + 900,
            relayUrl: RelayEnvironment.staging.baseURL
        )
        let urlString = try bundle.encodeToURL()

        // --- iOS side ---
        let scanned = RelayPairingBundle.decode(fromURL: urlString)
        let parsed = try XCTUnwrap(scanned)
        let phonePair = RelayPairingKeyPair()
        let k = try phonePair.deriveSharedKey(
            theirPublicKeyBase64URL: parsed.ecdhPub,
            sessionId: parsed.sid
        )
        let record = RelayPairingRecord(
            sid: parsed.sid,
            macTok: parsed.macTok,
            iosTok: parsed.iosTok,
            theirEcdhPublicKeyBase64URL: parsed.ecdhPub,
            ourEcdhPublicKeyBase64URL: phonePair.publicKeyBase64URL,
            derivedSymmetricKeyBase64URL: RelayPairingBase64URL.encode(k),
            ttl: parsed.ttl,
            relayUrl: parsed.relayUrl,
            pairedAtUnixSeconds: UInt64(Date().timeIntervalSince1970)
        )
        try store.save(record: record, symmetricKey: k)

        // Reload as if app relaunched. Mac-side K is then computed and
        // compared against the persisted iOS K (acceptance: they match).
        let reloaded = try XCTUnwrap(store.loadRecord())
        XCTAssertEqual(reloaded.sid, bundle.sid)
        XCTAssertEqual(reloaded.macTok, bundle.macTok)
        XCTAssertEqual(reloaded.iosTok, bundle.iosTok)
        XCTAssertEqual(reloaded.derivedSymmetricKeyBase64URL,
                       RelayPairingBase64URL.encode(k))

        // Keychain check is skipped under SPM-host (no Keychain available
        // outside a code-signed test target). The presence of the json
        // record + a clean save() returning without throw is the load-
        // bearing assertion.

        // Now compute the Mac side and compare.
        let macK = try macPair.deriveSharedKey(
            theirPublicKeyBase64URL: phonePair.publicKeyBase64URL,
            sessionId: bundle.sid
        )
        XCTAssertEqual(macK, k, "Mac- and iPhone-derived keys MUST match")
    }

    // MARK: - Helpers

    private func makeValidToken() -> String {
        RelayPairingMint.randomBase64URLToken()
    }
}
