import XCTest
@testable import ClawdmeterShared

/// Verifies the typed WatchPlanBridge.Payload encoder + decoder matches
/// the runtime dict shape that legacy v5/v6 receivers expect, and that
/// the SendGate's diff-before-send skips identical payloads.
final class WatchPlanBridgePayloadTests: XCTestCase {

    // MARK: - Dict round-trip

    func test_encodedAsDict_includesOnlyNonNilFields() {
        let payload = WatchPlanBridge.Payload(
            planWaitingCount: 3,
            latestGoal: "ship v0.6.0"
        )
        let dict = payload.encodedAsDict()
        XCTAssertEqual(dict["planWaitingCount"] as? Int, 3)
        XCTAssertEqual(dict["latestGoal"] as? String, "ship v0.6.0")
        XCTAssertNil(dict["latestPlanSummary"], "nil fields must be omitted from dict (legacy receivers see no surprise keys)")
        XCTAssertNil(dict["currentTaskHeadline"])
    }

    func test_decode_handlesV5DictShape() {
        // v5/v6 dict shape: planWaitingCount + latestGoal + sessions snapshot.
        let v5dict: [String: Any] = [
            "planWaitingCount": 7,
            "latestGoal": "Sessions list",
            "sessionsSummaryJSON": "[]",
        ]
        let payload = WatchPlanBridge.Payload.decode(from: v5dict)
        XCTAssertEqual(payload.planWaitingCount, 7)
        XCTAssertEqual(payload.latestGoal, "Sessions list")
        XCTAssertEqual(payload.sessionsSummaryJSON, "[]")
        XCTAssertNil(payload.currentTaskHeadline, "v5 dict has no currentTaskHeadline — decoder returns nil cleanly")
    }

    func test_decode_handlesV7DictWithCurrentTaskHeadline() {
        let v7dict: [String: Any] = [
            "planWaitingCount": 1,
            "currentTaskHeadline": "Build feat/antigravity-v2",
        ]
        let payload = WatchPlanBridge.Payload.decode(from: v7dict)
        XCTAssertEqual(payload.currentTaskHeadline, "Build feat/antigravity-v2")
    }

    func test_roundTrip_throughDict_preservesAllFields() {
        let original = WatchPlanBridge.Payload(
            planWaitingCount: 2,
            latestGoal: "g",
            latestPlanSummary: "s",
            latestSessionId: UUID().uuidString,
            sessionsSummaryJSON: "[]",
            currentTaskHeadline: "task"
        )
        let dict = original.encodedAsDict()
        let decoded = WatchPlanBridge.Payload.decode(from: dict)
        // sentAt is approximate (ISO8601 round-trip drops sub-second)
        XCTAssertEqual(decoded.planWaitingCount, original.planWaitingCount)
        XCTAssertEqual(decoded.latestGoal, original.latestGoal)
        XCTAssertEqual(decoded.latestPlanSummary, original.latestPlanSummary)
        XCTAssertEqual(decoded.latestSessionId, original.latestSessionId)
        XCTAssertEqual(decoded.sessionsSummaryJSON, original.sessionsSummaryJSON)
        XCTAssertEqual(decoded.currentTaskHeadline, original.currentTaskHeadline)
    }

    // MARK: - Diff-before-send (eng review 4B)

    func test_sendGate_firstSendReturnsTrue() {
        let gate = WatchPlanBridge.SendGate()
        let payload = WatchPlanBridge.Payload(planWaitingCount: 1)
        XCTAssertTrue(gate.shouldSend(payload))
    }

    func test_sendGate_identicalSecondSendReturnsFalse() {
        let gate = WatchPlanBridge.SendGate()
        let payload = WatchPlanBridge.Payload(planWaitingCount: 1, currentTaskHeadline: "stable")
        XCTAssertTrue(gate.shouldSend(payload))
        // Same content, different sentAt — must skip.
        var second = payload
        second.sentAt = Date().addingTimeInterval(60)
        XCTAssertFalse(gate.shouldSend(second), "Content-equivalent payload (timestamp-only change) should NOT re-send")
    }

    func test_sendGate_contentChangeReturnsTrueAgain() {
        let gate = WatchPlanBridge.SendGate()
        let original = WatchPlanBridge.Payload(planWaitingCount: 1, currentTaskHeadline: "first")
        XCTAssertTrue(gate.shouldSend(original))
        let changed = WatchPlanBridge.Payload(planWaitingCount: 1, currentTaskHeadline: "second")
        XCTAssertTrue(gate.shouldSend(changed))
    }

    func test_sendGate_resetClearsCache() {
        let gate = WatchPlanBridge.SendGate()
        let payload = WatchPlanBridge.Payload(currentTaskHeadline: "t")
        XCTAssertTrue(gate.shouldSend(payload))
        XCTAssertFalse(gate.shouldSend(payload))
        gate.reset()
        XCTAssertTrue(gate.shouldSend(payload), "After reset, the next send should succeed even with identical content")
    }
}
