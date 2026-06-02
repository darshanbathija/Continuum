import XCTest
@testable import ClawdmeterShared

/// Tests the Antigravity Cascade step → HarnessEvent mapping (Phase 7). The
/// mapper output flows through the same AcpHarnessProjection the ACP agents use,
/// so these lock the contract the gRPC decode layer must produce.
final class AntigravityCascadeMapperTests: XCTestCase {
    private let mapper = AntigravityCascadeMapper()
    private let sid = "cascade-1"

    func testTextAndThinking() {
        XCTAssertEqual(mapper.map(.assistantText("hi"), sessionId: sid), .agentMessageDelta("hi"))
        XCTAssertEqual(mapper.map(.thinking("hmm"), sessionId: sid), .agentThoughtDelta("hmm"))
    }

    func testToolCall() {
        let ev = mapper.map(.toolCall(id: "t1", title: "run tests", kind: "execute", status: .inProgress), sessionId: sid)
        XCTAssertEqual(ev, .toolCall(HarnessToolCall(toolCallId: "t1", title: "run tests", kind: "execute", status: .inProgress)))
    }

    func testFileDiff() {
        let ev = mapper.map(.fileDiff(path: "a/b.swift", unifiedDiff: "@@ -1 +1 @@"), sessionId: sid)
        XCTAssertEqual(ev, .diff(HarnessDiff(path: "a/b.swift", oldText: nil, newText: "@@ -1 +1 @@")))
    }

    func testPermissionSynthesizesApproveRejectAndCarriesId() {
        let ev = mapper.map(.permission(permissionId: "perm-9", title: "Edit file?", proposalToolCalls: ["x", "y"]), sessionId: sid)
        guard case .permissionRequest(let req) = ev else { return XCTFail("expected permissionRequest") }
        XCTAssertEqual(req.requestId, .string("perm-9"))
        XCTAssertEqual(req.sessionId, sid)
        XCTAssertEqual(req.options.map(\.optionId), ["allow_once", "reject_once"])
        XCTAssertEqual(req.options.map(\.kind), ["allow_once", "reject_once"])
        XCTAssertTrue(req.title?.contains("Edit file?") == true)
        XCTAssertTrue(req.title?.contains("2 proposed actions") == true, "proposal count enriches the title")
    }

    func testPermissionDefaultTitleAndSingularCount() {
        let ev = mapper.map(.permission(permissionId: "p", title: nil, proposalToolCalls: ["only"]), sessionId: sid)
        guard case .permissionRequest(let req) = ev else { return XCTFail("expected permissionRequest") }
        XCTAssertTrue(req.title?.contains("Antigravity is requesting approval") == true)
        XCTAssertTrue(req.title?.contains("1 proposed action") == true)
        XCTAssertFalse(req.title?.contains("actions") == true, "singular, not plural")
    }

    func testTurnOutcomes() {
        XCTAssertEqual(mapper.map(.turnFinished(.completed), sessionId: sid), .turnEnded(.endTurn))
        XCTAssertEqual(mapper.map(.turnFinished(.cancelled), sessionId: sid), .turnEnded(.cancelled))
        XCTAssertEqual(mapper.map(.turnFinished(.failed), sessionId: sid), .turnEnded(.unknown))
    }

    func testErrorAndUnknown() {
        XCTAssertEqual(mapper.map(.error(message: "boom"), sessionId: sid), .error(code: "antigravity", message: "boom"))
        XCTAssertEqual(mapper.map(.unknown(kind: "weird_step"), sessionId: sid), .unknownUpdate(kind: "weird_step"))
    }

    func testMapStreamCompactsAndPreservesOrder() {
        let steps: [AntigravityCascadeStep] = [
            .assistantText("a"),
            .toolCall(id: "t", title: nil, kind: nil, status: .completed),
            .turnFinished(.completed),
        ]
        let events = mapper.map(steps: steps, sessionId: sid)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.first, .agentMessageDelta("a"))
        XCTAssertEqual(events.last, .turnEnded(.endTurn))
    }
}
