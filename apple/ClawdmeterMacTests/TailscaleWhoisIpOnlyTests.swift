import XCTest
import Network
@testable import Clawdmeter

/// v0.7.7 regression suite for `TailscaleWhois.ipOnly`. The textbook
/// case for a regression test: a previous patch (P2-Mac-4) shipped a
/// numeric-tail heuristic that silently truncated `fd7a:115c:a1e0::1`
/// to `fd7a:115c:a1e0::`, breaking whois lookups for every Tailscale
/// peer with a numeric final hextet. The rollback (codex-4) is what
/// these tests guard.
final class TailscaleWhoisIpOnlyTests: XCTestCase {

    // MARK: - Bracketed IPv6

    func test_bracketedIPv6_stripsPort() {
        XCTAssertEqual(TailscaleWhois.ipOnly("[fd7a:115c:a1e0::1]:443"), "fd7a:115c:a1e0::1")
        XCTAssertEqual(TailscaleWhois.ipOnly("[::1]:80"), "::1")
        XCTAssertEqual(TailscaleWhois.ipOnly("[2001:db8::1]:9000"), "2001:db8::1")
    }

    @MainActor
    func test_endpointStringBracketsIPv6HostPortForWhois() throws {
        let address = try XCTUnwrap(IPv6Address("fd7a:115c:a1e0::1"))
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 443))
        let endpoint = NWEndpoint.hostPort(host: .ipv6(address), port: port)
        XCTAssertEqual(AgentControlServer.endpointString(endpoint), "[fd7a:115c:a1e0::1]:443")
    }

    // MARK: - IPv4

    func test_IPv4_stripsPort() {
        XCTAssertEqual(TailscaleWhois.ipOnly("100.64.0.1:443"), "100.64.0.1")
        XCTAssertEqual(TailscaleWhois.ipOnly("127.0.0.1:21731"), "127.0.0.1")
    }

    func test_bareIPv4_unchanged() {
        XCTAssertEqual(TailscaleWhois.ipOnly("100.64.0.1"), "100.64.0.1")
        XCTAssertEqual(TailscaleWhois.ipOnly("127.0.0.1"), "127.0.0.1")
    }

    // MARK: - Bare IPv6 (load-bearing regression assertion)

    /// THE regression: prior P2-Mac-4 truncated this to `fd7a:115c:a1e0::`.
    /// A re-introduction of the numeric-tail heuristic would fail here.
    func test_bareIPv6_roundTripsUnchanged() {
        XCTAssertEqual(TailscaleWhois.ipOnly("fd7a:115c:a1e0::1"),
                       "fd7a:115c:a1e0::1")
        XCTAssertEqual(TailscaleWhois.ipOnly("fd7a:115c:a1e0:ab12:cd34:ef56:7890:1234"),
                       "fd7a:115c:a1e0:ab12:cd34:ef56:7890:1234")
        XCTAssertEqual(TailscaleWhois.ipOnly("::1"), "::1")
    }
}
