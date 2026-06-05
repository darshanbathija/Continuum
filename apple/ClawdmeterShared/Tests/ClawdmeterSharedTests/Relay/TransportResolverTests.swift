import XCTest
@testable import ClawdmeterShared

/// Track B — B3: the transport-selection decision.
final class TransportResolverTests: XCTestCase {

    func test_flagOff_alwaysTailscale() {
        XCTAssertEqual(TransportResolver.resolve(relayDefaultEnabled: false, lanReachable: true, lanFingerprintVerified: true), .tailscaleDirect)
        XCTAssertEqual(TransportResolver.resolve(relayDefaultEnabled: false, lanReachable: false, lanFingerprintVerified: false), .tailscaleDirect)
    }

    func test_flagOn_verifiedLan_picksLanDirect() {
        XCTAssertEqual(TransportResolver.resolve(relayDefaultEnabled: true, lanReachable: true, lanFingerprintVerified: true), .lanDirect)
    }

    func test_flagOn_unverifiedLan_fallsBackToRelay_neverLan() {
        // SECURITY: an impostor LAN host (fingerprint not matched) must NEVER be
        // chosen — fall back to the relay.
        XCTAssertEqual(TransportResolver.resolve(relayDefaultEnabled: true, lanReachable: true, lanFingerprintVerified: false), .relay)
    }

    func test_flagOn_noLan_picksRelay() {
        XCTAssertEqual(TransportResolver.resolve(relayDefaultEnabled: true, lanReachable: false, lanFingerprintVerified: false), .relay)
        // Verified-but-unreachable (stale discovery) → relay too.
        XCTAssertEqual(TransportResolver.resolve(relayDefaultEnabled: true, lanReachable: false, lanFingerprintVerified: true), .relay)
    }
}
