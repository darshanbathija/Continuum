import XCTest
@testable import ClawdmeterShared

/// Tests the codex `app-server` event → HarnessEvent mapping (Phase 6). The
/// mapper output flows through the same `AcpHarnessProjection` the ACP agents
/// use, so these lock the contract the JSON-RPC decode layer in
/// `CodexAppServerDriver` must produce. Mirrors `AntigravityCascadeMapperTests`.
final class CodexAppServerMapperTests: XCTestCase {
    private let mapper = CodexAppServerMapper()
    private let sid = "thread-1"

    func testTextAndReasoning() {
        XCTAssertEqual(mapper.map(.agentMessageDelta("hi"), sessionId: sid), .agentMessageDelta("hi"))
        XCTAssertEqual(mapper.map(.reasoningDelta("hmm"), sessionId: sid), .agentThoughtDelta("hmm"))
    }

    func testCompletedAgentMessageFlowsAsDelta() {
        // A whole `item/completed` agentMessage maps to a message delta so the
        // projection buffers + flushes it at turn end (no separate row).
        XCTAssertEqual(mapper.map(.agentMessage("PONG"), sessionId: sid), .agentMessageDelta("PONG"))
    }

    func testToolCall() {
        let ev = mapper.map(.toolCall(id: "i1", title: "ls -la", kind: "commandExecution", status: .inProgress), sessionId: sid)
        XCTAssertEqual(ev, .toolCall(HarnessToolCall(toolCallId: "i1", title: "ls -la", kind: "commandExecution", status: .inProgress)))
    }

    func testFileDiff() {
        let ev = mapper.map(.fileDiff(path: "a/b.swift", unifiedDiff: "@@ -1 +1 @@"), sessionId: sid)
        XCTAssertEqual(ev, .diff(HarnessDiff(path: "a/b.swift", oldText: nil, newText: "@@ -1 +1 @@")))
    }

    func testPlanMapsToEntries() {
        let steps = [CodexPlanStep(step: "build", status: "completed"),
                     CodexPlanStep(step: "test", status: "in_progress")]
        let ev = mapper.map(.plan(steps), sessionId: sid)
        XCTAssertEqual(ev, .plan([
            ACPPlanEntry(content: "build", status: "completed"),
            ACPPlanEntry(content: "test", status: "in_progress"),
        ]))
    }

    func testUsage() {
        let usage = HarnessUsage(inputTokens: 10, outputTokens: 20, totalTokens: 30)
        XCTAssertEqual(mapper.map(.usage(usage), sessionId: sid), .usage(usage))
    }

    func testApprovalSynthesizesApproveDeclineAndCarriesNumericId() {
        // Codex server-request ids are numeric JSON-RPC ids; the mapper must
        // carry the RpcId through verbatim so the driver answers the right id.
        let ev = mapper.map(
            .approval(requestId: .number(7), kind: .commandExecution, title: "Run command?", detail: "rm -rf build"),
            sessionId: sid)
        guard case .permissionRequest(let req) = ev else { return XCTFail("expected permissionRequest") }
        XCTAssertEqual(req.requestId, .number(7))
        XCTAssertEqual(req.sessionId, sid)
        XCTAssertEqual(req.options.map(\.optionId), ["allow_once", "reject_once"])
        XCTAssertEqual(req.options.map(\.kind), ["allow_once", "reject_once"])
        XCTAssertTrue(req.title?.contains("Run command?") == true)
        XCTAssertTrue(req.title?.contains("rm -rf build") == true, "detail enriches the title")
    }

    func testApprovalDefaultTitleAndStringId() {
        let ev = mapper.map(
            .approval(requestId: .string("req-abc"), kind: .fileChange, title: nil, detail: nil),
            sessionId: sid)
        guard case .permissionRequest(let req) = ev else { return XCTFail("expected permissionRequest") }
        XCTAssertEqual(req.requestId, .string("req-abc"))
        XCTAssertTrue(req.title?.contains("Codex is requesting approval") == true)
        XCTAssertFalse(req.title?.contains("(") == true, "no detail → no parenthetical suffix")
    }

    func testTurnOutcomes() {
        XCTAssertEqual(mapper.map(.turnFinished(.completed), sessionId: sid), .turnEnded(.endTurn))
        XCTAssertEqual(mapper.map(.turnFinished(.interrupted), sessionId: sid), .turnEnded(.cancelled))
        XCTAssertEqual(mapper.map(.turnFinished(.failed), sessionId: sid), .turnEnded(.unknown))
        XCTAssertEqual(mapper.map(.turnFinished(.unknown), sessionId: sid), .turnEnded(.unknown))
    }

    func testTurnStatusFromRawString() {
        XCTAssertEqual(CodexTurnStatus(rawCodexStatus: "completed"), .completed)
        XCTAssertEqual(CodexTurnStatus(rawCodexStatus: "interrupted"), .interrupted)
        XCTAssertEqual(CodexTurnStatus(rawCodexStatus: "failed"), .failed)
        XCTAssertEqual(CodexTurnStatus(rawCodexStatus: "inProgress"), .unknown, "non-terminal status is not a finish")
        XCTAssertEqual(CodexTurnStatus(rawCodexStatus: "brand_new"), .unknown)
    }

    func testErrorAndUnknown() {
        XCTAssertEqual(mapper.map(.error(message: "boom"), sessionId: sid), .error(code: "codex", message: "boom"))
        XCTAssertEqual(mapper.map(.unknown(kind: "thread/realtime/sdp"), sessionId: sid), .unknownUpdate(kind: "thread/realtime/sdp"))
    }

    func testMapStreamCompactsAndPreservesOrder() {
        let events: [CodexAppServerEvent] = [
            .agentMessageDelta("a"),
            .toolCall(id: "i", title: nil, kind: nil, status: .completed),
            .turnFinished(.completed),
        ]
        let mapped = mapper.map(events: events, sessionId: sid)
        XCTAssertEqual(mapped.count, 3)
        XCTAssertEqual(mapped.first, .agentMessageDelta("a"))
        XCTAssertEqual(mapped.last, .turnEnded(.endTurn))
    }
}
