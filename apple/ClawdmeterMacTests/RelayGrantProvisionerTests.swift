import XCTest
@testable import Clawdmeter
import ClawdmeterShared

final class RelayGrantProvisionerTests: XCTestCase {

    func testProvisionURLMapsWSSRelayToHTTPSProvisionEndpoint() {
        let url = RelayGrantProvisioner.provisionURL(
            relayURL: "wss://clawdmeter-relay.continuumai.workers.dev"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://clawdmeter-relay.continuumai.workers.dev/v1/relay/provision/grant-token"
        )
    }

    func testSignProvisionRequestIsDeterministic() {
        let key = Data(base64Encoded: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")!
        let installId = "11111111-1111-4111-8111-111111111111"
        let issuedAt: UInt64 = 1_700_000_000
        let first = RelayGrantProvisioner.signProvisionRequest(
            installId: installId,
            issuedAtSeconds: issuedAt,
            provisioningKey: key
        )
        let second = RelayGrantProvisioner.signProvisionRequest(
            installId: installId,
            issuedAtSeconds: issuedAt,
            provisioningKey: key
        )
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("+"))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains("="))
    }

    func testRelayClientProvisioningKeyFallsBackToBundledDevKey() {
        let key = RelayClientProvisioningKey.resolved(processEnv: [:])
        XCTAssertNotNil(key)
        XCTAssertGreaterThanOrEqual(key?.count ?? 0, 32)
    }

    func testMintLocalDeviceGrantTokenMatchesServerAlgorithm() {
        let key = Data(base64Encoded: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")!
        let installId = "11111111-1111-4111-8111-111111111111"
        let token = RelayGrantProvisioner.mintLocalDeviceGrantToken(
            installId: installId,
            provisioningKey: key
        )
        XCTAssertTrue(token.hasPrefix("\(installId)."))
        XCTAssertEqual(
            token,
            "11111111-1111-4111-8111-111111111111.L8OeZbMU2WAZMleiolFa_abtU5LLI_bprHf-yLwRXfE"
        )
    }
}
