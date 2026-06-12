import XCTest
@testable import ClawdmeterShared

final class PairingModeTests: XCTestCase {

    func testStorageKeyIsStable() {
        XCTAssertEqual(PairingMode.storageKey, "clawdmeter.pairing.mode")
    }

    func testAllCasesRoundTripRawValues() {
        XCTAssertEqual(PairingMode.allCases.map(\.rawValue), ["cloud", "tailscale"])
        for mode in PairingMode.allCases {
            XCTAssertEqual(PairingMode(rawValue: mode.rawValue), mode)
        }
    }

    func testDisplayNamesAreUserFacing() {
        XCTAssertEqual(PairingMode.cloud.displayName, "Continuum Cloud")
        XCTAssertEqual(PairingMode.tailscale.displayName, "Tailscale")
    }

    func testTransportPreferenceMatchesPairingMode() {
        XCTAssertTrue(PairingMode.cloud.prefersRelayTransport)
        XCTAssertFalse(PairingMode.tailscale.prefersRelayTransport)
    }
}
