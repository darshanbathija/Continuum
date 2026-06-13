import XCTest
@testable import Clawdmeter

final class FnKeyStateMachineTests: XCTestCase {
    func testDoubleTapWithinThresholdStartsRecording() {
        let machine = FnKeyStateMachine(tapThresholdMs: 400)
        XCTAssertEqual(machine.fnDown(timestampMs: 1_000), .none)
        XCTAssertEqual(machine.fnUp(timestampMs: 1_100), .none)
        XCTAssertEqual(machine.fnDown(timestampMs: 1_200), .startRecording(mode: .persistent))
        XCTAssertEqual(machine.state, .persistent)
    }

    func testSecondPressInPersistentStateStopsRecording() {
        let machine = FnKeyStateMachine(tapThresholdMs: 400)
        _ = machine.fnDown(timestampMs: 1_000)
        _ = machine.fnUp(timestampMs: 1_100)
        _ = machine.fnDown(timestampMs: 1_200)
        XCTAssertEqual(machine.fnDown(timestampMs: 5_000), .stopRecording)
        XCTAssertEqual(machine.state, .idle)
    }

    func testSlowSecondTapDoesNotStartRecording() {
        let machine = FnKeyStateMachine(tapThresholdMs: 400)
        _ = machine.fnDown(timestampMs: 1_000)
        _ = machine.fnUp(timestampMs: 1_100)
        XCTAssertEqual(machine.fnDown(timestampMs: 2_000), .none)
        XCTAssertEqual(machine.state, .waitingForSecondTap)
    }

    func testEscapeCancelsPersistentRecording() {
        let machine = FnKeyStateMachine(tapThresholdMs: 400)
        _ = machine.fnDown(timestampMs: 1_000)
        _ = machine.fnUp(timestampMs: 1_100)
        _ = machine.fnDown(timestampMs: 1_200)
        XCTAssertEqual(machine.escapePressed(), .cancelRecording)
        XCTAssertEqual(machine.state, .idle)
    }

    func testHoldTimerStartsHoldToTalkRecording() {
        let machine = FnKeyStateMachine(tapThresholdMs: 400)
        _ = machine.fnDown(timestampMs: 1_000)
        XCTAssertEqual(machine.holdTimerFired(), .startRecording(mode: .holdToTalk))
        XCTAssertEqual(machine.state, .holdToTalk)
        XCTAssertEqual(machine.fnUp(timestampMs: 2_000), .stopRecording)
    }

    func testResetReturnsToIdle() {
        let machine = FnKeyStateMachine()
        _ = machine.fnDown(timestampMs: 1_000)
        _ = machine.fnUp(timestampMs: 1_100)
        _ = machine.fnDown(timestampMs: 1_200)
        machine.reset()
        XCTAssertEqual(machine.state, .idle)
    }
}

final class HotkeyGestureControllerTests: XCTestCase {
    func testDoubleTapOnlyEmitsStartAndStop() {
        let controller = HotkeyGestureController(mode: .doubleTapOnly, tapThresholdMs: 400)
        XCTAssertEqual(controller.triggerPressed(timestampMs: 1_000), [])
        XCTAssertEqual(controller.triggerReleased(timestampMs: 1_100), [.showReadyForSecondTap])
        XCTAssertTrue(controller.isCapturingFnGesture)
        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 1_200),
            [.startRecording(mode: .persistent), .cancelTimers]
        )
        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 5_000),
            [.stopRecording, .cancelTimers]
        )
    }

    func testHoldOnlyStartsAndStopsOnRelease() {
        let controller = HotkeyGestureController(mode: .holdOnly, tapThresholdMs: 400)
        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 1_000),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertTrue(controller.isCapturingFnGesture)
        XCTAssertEqual(controller.triggerReleased(timestampMs: 2_000), [.stopRecording])
        XCTAssertFalse(controller.isCapturingFnGesture)
    }

    func testSecondTapWindowExpiryResetsGesture() {
        let controller = HotkeyGestureController(mode: .doubleTapOnly, tapThresholdMs: 400)
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.triggerReleased(timestampMs: 1_100)
        XCTAssertEqual(controller.secondTapWindowExpired(), [.gestureTimedOut, .cancelTimers])
        XCTAssertFalse(controller.isCapturingFnGesture)
    }

    func testEscapeCancelsRecordingInDoubleTapMode() {
        let controller = HotkeyGestureController(mode: .doubleTapOnly, tapThresholdMs: 400)
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.triggerReleased(timestampMs: 1_100)
        _ = controller.triggerPressed(timestampMs: 1_200)
        XCTAssertEqual(controller.escapePressed(), [.cancelTimers, .cancelRecording, .cancelTimers])
    }

    func testDoubleTapAndHoldSchedulesStartupAndHoldTimers() {
        let controller = HotkeyGestureController(mode: .doubleTapAndHold, tapThresholdMs: 400, startupDebounceMs: 100)
        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 1_000),
            [.scheduleStartupDebounce(milliseconds: 100), .scheduleHoldWindow(milliseconds: 400)]
        )
    }

    func testDoubleTapAndHoldStartupDebounceStartsHoldToTalkRecording() {
        let controller = HotkeyGestureController(mode: .doubleTapAndHold, tapThresholdMs: 400, startupDebounceMs: 100)
        _ = controller.triggerPressed(timestampMs: 1_000)
        XCTAssertEqual(
            controller.startupDebounceElapsed(),
            [.startRecording(mode: .holdToTalk), .cancelTimers]
        )
    }
}
