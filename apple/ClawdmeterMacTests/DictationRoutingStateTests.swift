import XCTest
@testable import Clawdmeter

@MainActor
final class DictationRoutingStateTests: XCTestCase {
    override func tearDown() {
        DictationRouting.shared.setGlobalSession(active: false)
        DictationRouting.shared.setChatComposerReadOnly(false)
        super.tearDown()
    }

    func testGlobalSessionEndClearsActiveRecordingWithoutTarget() {
        let routing = DictationRouting.shared
        routing.setGlobalSession(active: true, target: .code)

        XCTAssertEqual(routing.activeRecordingTarget, .code)

        routing.setGlobalSession(active: false)

        XCTAssertNil(routing.activeRecordingTarget)
        XCTAssertNil(routing.globalSessionTarget)
        XCTAssertFalse(routing.globalSessionActive)
    }

    func testStopDeliveryResolutionCanIgnoreActiveRecordingTarget() {
        let routing = DictationRouting.shared
        routing.setGlobalSession(active: true, target: .code)

        let activeResolution = routing.resolve(
            currentTab: "chat",
            lastDictationTab: .code
        )
        let stopResolution = routing.resolve(
            currentTab: "chat",
            lastDictationTab: .code,
            includeActiveRecording: false
        )

        XCTAssertEqual(activeResolution, .route(.code))
        XCTAssertEqual(stopResolution, .route(.chat))
    }
}
