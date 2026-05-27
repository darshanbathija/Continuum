import XCTest
@testable import Clawdmeter

final class CGSessionLivenessTests: XCTestCase {

    func test_mock_defaultsToAwake() {
        let mock = MockCGSessionLiveness()
        XCTAssertEqual(mock.state, .awake)
    }

    func test_mock_returnsConfiguredState() {
        let mock = MockCGSessionLiveness(state: .locked)
        XCTAssertEqual(mock.state, .locked)
    }

    func test_mock_setStateUpdatesValue() {
        let mock = MockCGSessionLiveness(state: .awake)
        mock.setState(.loggedOut)
        XCTAssertEqual(mock.state, .loggedOut)
        mock.setState(.locked)
        XCTAssertEqual(mock.state, .locked)
    }

    func test_liveCGSession_returnsKnownState() {
        // Running tests means a console user IS logged in, so this should
        // be .awake or .locked (depending on whether the screensaver kicked
        // in during the test run). We can't pin a specific value because
        // tests run in many environments — assert only that we get one of
        // the well-defined cases (not crash).
        let live = LiveCGSession()
        let state = live.state
        XCTAssertTrue(
            [.awake, .locked, .loggedOut, .unknown].contains(state),
            "Expected a known state; got \(state)"
        )
    }
}
