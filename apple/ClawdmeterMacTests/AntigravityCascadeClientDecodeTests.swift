import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Unit tests for `AntigravityCascadeClient.decodeStep` — the pure protobuf →
/// `AntigravityCascadeStep` seam. No live gRPC channel is needed: we build
/// generated `Exa_LanguageServerPb_CascadeStep` values directly and assert the
/// decode maps each `step_payload` oneof case to the right transport-neutral
/// step. This is the one piece of the Phase-7 gRPC driver that's deterministically
/// testable offline (the drive loop itself needs a live Antigravity install).
final class AntigravityCascadeClientDecodeTests: XCTestCase {

    func testAssistantTextStep() {
        var s = Exa_LanguageServerPb_CascadeStep()
        s.assistantText = "hello from gemini"
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .assistantText("hello from gemini"))
    }

    func testThinkingStep() {
        var s = Exa_LanguageServerPb_CascadeStep()
        s.thinking = "considering the diff"
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .thinking("considering the diff"))
    }

    func testToolCallStep_inProgress() {
        var tc = Exa_LanguageServerPb_CascadeToolCall()
        tc.toolCallID = "call-1"
        tc.toolName = "run_command"
        tc.toolCallJson = #"{"cmd":"ls"}"#
        tc.status = .inProgress
        var s = Exa_LanguageServerPb_CascadeStep()
        s.toolCall = tc
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .toolCall(id: "call-1", title: "run_command", kind: nil, status: .inProgress))
    }

    func testToolCallStep_emptyNameYieldsNilTitle() {
        var tc = Exa_LanguageServerPb_CascadeToolCall()
        tc.toolCallID = "call-2"
        tc.status = .completed
        var s = Exa_LanguageServerPb_CascadeStep()
        s.toolCall = tc
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .toolCall(id: "call-2", title: nil, kind: nil, status: .completed))
    }

    func testToolCallStatusMapping() {
        // Every generated status maps to the right HarnessToolCall.Status.
        let cases: [(Exa_LanguageServerPb_CascadeToolCallStatus, HarnessToolCall.Status)] = [
            (.pending, .pending),
            (.inProgress, .inProgress),
            (.completed, .completed),
            (.failed, .failed),
            (.unspecified, .unknown),
        ]
        for (pb, expected) in cases {
            var tc = Exa_LanguageServerPb_CascadeToolCall()
            tc.toolCallID = "x"
            tc.status = pb
            var s = Exa_LanguageServerPb_CascadeStep()
            s.toolCall = tc
            XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                           .toolCall(id: "x", title: nil, kind: nil, status: expected),
                           "status \(pb) should map to \(expected)")
        }
    }

    func testFileDiffStep() {
        var fd = Exa_LanguageServerPb_CascadeFileDiff()
        fd.filePath = "src/main.swift"
        fd.unifiedDiff = "@@ -1 +1 @@\n-old\n+new"
        var s = Exa_LanguageServerPb_CascadeStep()
        s.fileDiff = fd
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .fileDiff(path: "src/main.swift", unifiedDiff: "@@ -1 +1 @@\n-old\n+new"))
    }

    func testFileDiffStep_emptyDiffYieldsNil() {
        var fd = Exa_LanguageServerPb_CascadeFileDiff()
        fd.filePath = "src/empty.swift"
        var s = Exa_LanguageServerPb_CascadeStep()
        s.fileDiff = fd
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .fileDiff(path: "src/empty.swift", unifiedDiff: nil))
    }

    func testPermissionStep_carriesIdAndProposals() {
        var p = Exa_LanguageServerPb_CascadePermission()
        p.isPermission = true
        p.permissionID = "perm-42"
        p.proposalToolCalls = ["delete_file", "run_command"]
        var s = Exa_LanguageServerPb_CascadeStep()
        s.permission = p
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .permission(permissionId: "perm-42", title: nil,
                                   proposalToolCalls: ["delete_file", "run_command"]))
    }

    func testErrorStep() {
        var e = Exa_LanguageServerPb_CascadeStepError()
        e.message = "quota exceeded"
        var s = Exa_LanguageServerPb_CascadeStep()
        s.error = e
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .error(message: "quota exceeded"))
    }

    func testCompletionOutcomeMapping() {
        let cases: [(Exa_LanguageServerPb_CascadeTurnOutcome, AntigravityTurnOutcome)] = [
            (.completed, .completed),
            (.cancelled, .cancelled),
            (.failed, .failed),
            (.unspecified, .failed),   // unspecified must NOT claim a clean end
        ]
        for (pb, expected) in cases {
            var comp = Exa_LanguageServerPb_CascadeStepCompletion()
            comp.outcome = pb
            var s = Exa_LanguageServerPb_CascadeStep()
            s.completion = comp
            XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                           .turnFinished(expected),
                           "outcome \(pb) should map to \(expected)")
        }
    }

    func testEmptyPayloadIsUnknown() {
        // A step with no payload set must be preserved as `.unknown`, never dropped.
        let s = Exa_LanguageServerPb_CascadeStep()
        XCTAssertEqual(AntigravityCascadeClient.decodeStep(s),
                       .unknown(kind: "empty_step_payload"))
    }

    /// End-to-end seam: a decoded permission step flows through the SAME
    /// `AntigravityCascadeMapper` the driver uses, producing a `.permissionRequest`
    /// whose `requestId` carries the Cascade permission id (so the driver's
    /// `respondToPermission` can answer the approval RPC).
    func testDecodedPermissionMapsToHarnessPermissionRequest() {
        var p = Exa_LanguageServerPb_CascadePermission()
        p.isPermission = true
        p.permissionID = "perm-99"
        p.proposalToolCalls = ["write_file"]
        var s = Exa_LanguageServerPb_CascadeStep()
        s.permission = p

        let step = AntigravityCascadeClient.decodeStep(s)
        let event = AntigravityCascadeMapper().map(step, sessionId: "cascade-1")
        guard case .permissionRequest(let req)? = event else {
            return XCTFail("expected .permissionRequest, got \(String(describing: event))")
        }
        XCTAssertEqual(req.requestId, .string("perm-99"))
        XCTAssertEqual(req.sessionId, "cascade-1")
        XCTAssertEqual(req.options.map(\.optionId), ["allow_once", "reject_once"])
    }
}
