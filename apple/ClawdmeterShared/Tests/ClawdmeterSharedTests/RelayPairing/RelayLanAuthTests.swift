import XCTest
import CryptoKit
@testable import ClawdmeterShared

/// Track B — B3/B4: the LAN-direct challenge-response + per-request MAC.
final class RelayLanAuthTests: XCTestCase {

    private let key = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
    private let otherKey = SymmetricKey(data: Data(repeating: 0xCD, count: 32))

    // MARK: fingerprint + challenge

    func test_fingerprint_isStableAndKeyBound() {
        let fp = RelayLanAuth.discoveryFingerprint(key: key)
        XCTAssertEqual(fp, RelayLanAuth.discoveryFingerprint(key: key), "stable per key")
        XCTAssertNotEqual(fp, RelayLanAuth.discoveryFingerprint(key: otherKey), "an impostor without K can't forge it")
        XCTAssertEqual(fp.count, 64, "hex SHA-256")
    }

    func test_challengeProof_provesKeyPossession() {
        let proof = RelayLanAuth.challengeProof(key: key, nonce: "nonce-1")
        XCTAssertTrue(RelayLanAuth.verify(proof, message: "continuum-lan-challenge-v1\u{1f}nonce-1", key: key))
        // Wrong key can't produce a verifying proof.
        XCTAssertNotEqual(proof, RelayLanAuth.challengeProof(key: otherKey, nonce: "nonce-1"))
        // Nonce is bound: a proof for one nonce doesn't verify another.
        XCTAssertNotEqual(proof, RelayLanAuth.challengeProof(key: key, nonce: "nonce-2"))
    }

    // MARK: per-request MAC + verifier

    private func mac(_ method: String, _ path: String, body: Data?, nonce: String, ts: UInt64,
                     role: RelayLanAuth.Role = .ios, session: String = "s1", endpoint: String = "lan") -> String {
        RelayLanAuth.requestMAC(key: key, role: role, sessionId: session, endpoint: endpoint,
                                method: method, path: path, body: body, nonce: nonce, timestamp: ts)
    }

    func test_validRequest_verifies() {
        let v = RelayLanAuthVerifier(key: key, window: 30)
        let ts: UInt64 = 1_000_000
        let m = mac("GET", "/sessions", body: nil, nonce: "n1", ts: ts)
        let now = Date(timeIntervalSince1970: TimeInterval(ts))
        XCTAssertNil(v.verify(role: .ios, sessionId: "s1", endpoint: "lan", method: "GET", path: "/sessions",
                              body: nil, nonce: "n1", timestamp: ts, mac: m, now: now))
    }

    func test_tamperedPathOrMethodOrBody_rejected() {
        let v = RelayLanAuthVerifier(key: key, window: 30)
        let ts: UInt64 = 1_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(ts))
        let m = mac("POST", "/sessions/x/send", body: Data("hi".utf8), nonce: "n1", ts: ts)
        // path changed
        XCTAssertEqual(v.verify(role: .ios, sessionId: "s1", endpoint: "lan", method: "POST", path: "/sessions/y/send",
                                body: Data("hi".utf8), nonce: "n1", timestamp: ts, mac: m, now: now), .badMAC)
        // body changed
        XCTAssertEqual(v.verify(role: .ios, sessionId: "s1", endpoint: "lan", method: "POST", path: "/sessions/x/send",
                                body: Data("bye".utf8), nonce: "n2", timestamp: ts, mac: m, now: now), .badMAC)
        // wrong key
        let v2 = RelayLanAuthVerifier(key: otherKey, window: 30)
        XCTAssertEqual(v2.verify(role: .ios, sessionId: "s1", endpoint: "lan", method: "POST", path: "/sessions/x/send",
                                 body: Data("hi".utf8), nonce: "n3", timestamp: ts, mac: m, now: now), .badMAC)
    }

    func test_roleBinding_rejectsCrossRoleReplay() {
        let v = RelayLanAuthVerifier(key: key, window: 30)
        let ts: UInt64 = 1_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(ts))
        let iosMAC = mac("GET", "/x", body: nil, nonce: "n1", ts: ts, role: .ios)
        // The same MAC presented as the mac role must not verify (role is bound).
        XCTAssertEqual(v.verify(role: .mac, sessionId: "s1", endpoint: "lan", method: "GET", path: "/x",
                                body: nil, nonce: "n1", timestamp: ts, mac: iosMAC, now: now), .badMAC)
    }

    func test_staleTimestamp_rejected() {
        let v = RelayLanAuthVerifier(key: key, window: 30)
        let ts: UInt64 = 1_000_000
        let m = mac("GET", "/x", body: nil, nonce: "n1", ts: ts)
        let now = Date(timeIntervalSince1970: TimeInterval(ts + 60))   // 60s > 30s window
        XCTAssertEqual(v.verify(role: .ios, sessionId: "s1", endpoint: "lan", method: "GET", path: "/x",
                                body: nil, nonce: "n1", timestamp: ts, mac: m, now: now), .staleTimestamp)
    }

    func test_replayedNonce_rejected() {
        let v = RelayLanAuthVerifier(key: key, window: 30)
        let ts: UInt64 = 1_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(ts))
        let m = mac("GET", "/x", body: nil, nonce: "dup", ts: ts)
        XCTAssertNil(v.verify(role: .ios, sessionId: "s1", endpoint: "lan", method: "GET", path: "/x",
                              body: nil, nonce: "dup", timestamp: ts, mac: m, now: now), "first use ok")
        XCTAssertEqual(v.verify(role: .ios, sessionId: "s1", endpoint: "lan", method: "GET", path: "/x",
                                body: nil, nonce: "dup", timestamp: ts, mac: m, now: now), .replayedNonce, "replay rejected")
    }

    func test_noncePruneAfterWindow() {
        let v = RelayLanAuthVerifier(key: key, window: 10)
        let ts: UInt64 = 1_000_000
        let m = mac("GET", "/x", body: nil, nonce: "n1", ts: ts)
        _ = v.verify(role: .ios, sessionId: "s1", endpoint: "lan", method: "GET", path: "/x",
                     body: nil, nonce: "n1", timestamp: ts, mac: m, now: Date(timeIntervalSince1970: TimeInterval(ts)))
        XCTAssertEqual(v.trackedNonceCount, 1)
        v.pruneExpired(now: Date(timeIntervalSince1970: TimeInterval(ts) + 11))
        XCTAssertEqual(v.trackedNonceCount, 0, "nonces age out after the window")
    }
}
