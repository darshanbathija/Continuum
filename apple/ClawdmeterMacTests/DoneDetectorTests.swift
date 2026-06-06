import XCTest
@testable import Clawdmeter

final class DoneDetectorTests: XCTestCase {

    func test_nestedToolResultClearsPendingToolCall() {
        let sessionId = UUID()
        var fired: [String] = []
        let detector = DoneDetector(sessionId: sessionId, goal: "ship phase five") { _, trigger in
            fired.append(trigger)
        }
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(detector.feed([
            "type": "assistant",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "Bash", "id": "toolu_1"]
                ]
            ]
        ], at: start))

        XCTAssertNil(detector.feed([
            "type": "user",
            "message": [
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_1",
                        "content": "command finished"
                    ]
                ]
            ]
        ], at: start.addingTimeInterval(1)))

        let trigger = detector.feed([
            "type": "assistant",
            "message": [
                "content": [
                    ["type": "text", "text": "ship phase five is done"]
                ]
            ]
        ], at: start.addingTimeInterval(2))

        XCTAssertEqual(trigger, "signal-a:goal+verb")
        XCTAssertEqual(fired, ["signal-a:goal+verb"])
    }
}
