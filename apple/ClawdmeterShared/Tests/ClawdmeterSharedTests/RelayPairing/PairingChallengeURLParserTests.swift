import XCTest
@testable import ClawdmeterShared

final class PairingChallengeURLParserTests: XCTestCase {

    func testRoundTripsTailscalePairingURLBuilderOutput() throws {
        let token = String(repeating: "a", count: 32)
        let url = TailscalePairingURLBuilder.buildURL(
            host: "macbook.tail87a721.ts.net",
            httpPort: 21_731,
            wsPort: 21_732,
            token: token
        )
        let challenge = try XCTUnwrap(PairingChallengeURLParser.parse(urlString: url))
        XCTAssertEqual(challenge.host, "macbook.tail87a721.ts.net")
        XCTAssertEqual(challenge.port, 21_731)
        XCTAssertEqual(challenge.wsPort, 21_732)
        XCTAssertEqual(challenge.token, token)
        XCTAssertFalse(challenge.useHTTPS)
    }

    func testParsesTLSPreferredScheme() throws {
        let token = String(repeating: "b", count: 32)
        let url = TailscalePairingURLBuilder.buildURL(
            host: "100.64.0.2",
            httpPort: 21_731,
            wsPort: 21_732,
            token: token,
            preferTLS: true
        )
        let challenge = try XCTUnwrap(PairingChallengeURLParser.parse(urlString: url))
        XCTAssertTrue(challenge.useHTTPS)
    }

    func testRejectsPublicInternetHost() {
        let token = String(repeating: "c", count: 32)
        let url = TailscalePairingURLBuilder.buildURL(
            host: "203.0.113.10",
            httpPort: 21_731,
            wsPort: 21_732,
            token: token
        )
        XCTAssertNil(PairingChallengeURLParser.parse(urlString: url))
    }
}
