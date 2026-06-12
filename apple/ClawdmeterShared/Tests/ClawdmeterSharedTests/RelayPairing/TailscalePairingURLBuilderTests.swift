import XCTest
@testable import ClawdmeterShared

final class TailscalePairingURLBuilderTests: XCTestCase {

    func testBuildsPlainHTTPURL() {
        let url = TailscalePairingURLBuilder.buildURL(
            host: "macbook.tail87a721.ts.net",
            httpPort: 21_731,
            wsPort: 21_732,
            token: "abc123-_"
        )
        XCTAssertEqual(
            url,
            "clawdmeter://macbook.tail87a721.ts.net:21731?token=abc123-_&ws=21732"
        )
    }

    func testBuildsTLSPreferredURL() {
        let url = TailscalePairingURLBuilder.buildURL(
            host: "100.64.0.2",
            httpPort: 21_731,
            wsPort: 21_732,
            token: "tok",
            preferTLS: true
        )
        XCTAssertEqual(
            url,
            "clawdmeters://100.64.0.2:21731?token=tok&ws=21732"
        )
    }

    func testBracketedIPv6HostIsEmbeddedVerbatim() {
        let url = TailscalePairingURLBuilder.buildURL(
            host: "[fd7a:115c:a1e0::2]",
            httpPort: 21_731,
            wsPort: 21_732,
            token: "tok"
        )
        XCTAssertEqual(
            url,
            "clawdmeter://[fd7a:115c:a1e0::2]:21731?token=tok&ws=21732"
        )
    }
}
