import XCTest
import ClawdmeterShared
@testable import ClawdmeterLinux

/// D7 security tests — the 4 explicit gates required by Phase 3.
/// Plus extras for the actual ranges to make sure both filters work.
final class PeerFilterTests: XCTestCase {

    // MARK: - PeerFilter (IP allowlist)

    func testForbiddenIPv4_RFC1918() {
        // D7 #1: LAN IP must be rejected pre-auth.
        let decision = HummingbirdPeerFilter.decide(peerIP: "192.168.1.42")
        XCTAssertNotEqual(decision, .allowed,
            "192.168.1.42 must be rejected (not in loopback / Tailscale ranges)")
    }

    func testForbiddenIPv4_PublicInternet() {
        let decision = HummingbirdPeerFilter.decide(peerIP: "8.8.8.8")
        XCTAssertNotEqual(decision, .allowed,
            "Public IPs must be rejected")
    }

    func testLoopbackIPv4_Allowed() {
        XCTAssertEqual(HummingbirdPeerFilter.decide(peerIP: "127.0.0.1"), .allowed)
        XCTAssertEqual(HummingbirdPeerFilter.decide(peerIP: "127.255.255.254"), .allowed)
    }

    func testLoopbackIPv6_Allowed() {
        XCTAssertEqual(HummingbirdPeerFilter.decide(peerIP: "::1"), .allowed)
    }

    func testTailscaleCGNAT_Allowed() {
        XCTAssertEqual(HummingbirdPeerFilter.decide(peerIP: "100.64.0.1"), .allowed)
        XCTAssertEqual(HummingbirdPeerFilter.decide(peerIP: "100.100.50.1"), .allowed)
        XCTAssertEqual(HummingbirdPeerFilter.decide(peerIP: "100.127.255.254"), .allowed)
        // Outside CGNAT bounds
        XCTAssertNotEqual(HummingbirdPeerFilter.decide(peerIP: "100.128.0.1"), .allowed)
        XCTAssertNotEqual(HummingbirdPeerFilter.decide(peerIP: "100.63.0.1"), .allowed)
    }

    func testTailscaleULA_IPv6_Allowed() {
        XCTAssertEqual(HummingbirdPeerFilter.decide(peerIP: "fd7a:115c:a1e0::1"), .allowed)
        XCTAssertEqual(HummingbirdPeerFilter.decide(peerIP: "fd7a:115c:a1e0:1234:5678:9abc:def0:1234"), .allowed)
        // Different ULA prefix
        XCTAssertNotEqual(HummingbirdPeerFilter.decide(peerIP: "fdca:f00d::1"), .allowed)
    }

    // MARK: - BearerAuth

    final class TestStore: BearerTokenStore, @unchecked Sendable {
        private let token: String
        init(token: String) { self.token = token }
        func currentToken() -> String { token }
        func regenerate() -> String { token }
        func revoke() {}
    }

    func testMissingAuthorizationHeader_Returns401() {
        // D7 #2: missing bearer → 401
        let auth = HummingbirdBearerAuth(store: TestStore(token: "abc123"))
        XCTAssertEqual(auth.decide(authorizationHeader: nil), .missing)
    }

    func testWrongBearer_Returns401() {
        // D7 #3: wrong bearer → 401
        let auth = HummingbirdBearerAuth(store: TestStore(token: "abc123"))
        XCTAssertEqual(auth.decide(authorizationHeader: "Bearer wrong-token"), .wrongToken)
    }

    func testMalformedHeader_Returns401() {
        let auth = HummingbirdBearerAuth(store: TestStore(token: "abc123"))
        XCTAssertEqual(auth.decide(authorizationHeader: "abc123"), .malformed)
        XCTAssertEqual(auth.decide(authorizationHeader: "Basic abc"), .malformed)
    }

    func testValidBearer_Allowed() {
        // D7 #4: valid bearer + valid peer → 200
        let auth = HummingbirdBearerAuth(store: TestStore(token: "abc123"))
        XCTAssertEqual(auth.decide(authorizationHeader: "Bearer abc123"), .allowed)
    }

    func testConstantTimeProperty_SameLengthDiffersByOneByte() {
        // Sanity check that constant-time comparison still rejects.
        let auth = HummingbirdBearerAuth(store: TestStore(token: "abc12X"))
        XCTAssertEqual(auth.decide(authorizationHeader: "Bearer abc12Y"),
                       HummingbirdBearerAuth.Decision.wrongToken)
    }
}
