import XCTest
@testable import Clawdmeter

final class DoneDetectorTests: XCTestCase {

    func test_nestedToolResultClearsPendingToolCall() {
        let sessionId = UUID()
        let fired = LockedTestBox<[String]>([])
        let detector = DoneDetector(sessionId: sessionId, goal: "ship phase five") { _, trigger in
            fired.update { $0.append(trigger) }
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
        XCTAssertEqual(fired.snapshot, ["signal-a:goal+verb"])
    }
}

private final class LockedTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var snapshot: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}
