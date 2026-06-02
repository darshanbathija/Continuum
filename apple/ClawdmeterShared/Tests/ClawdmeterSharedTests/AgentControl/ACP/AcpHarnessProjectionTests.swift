import XCTest
@testable import ClawdmeterShared

/// Tests the HarnessEvent -> SessionChatStore-op projection that the daemon
/// bridge applies. Verifies streaming text buffers + flushes once, plan/tool
/// mapping, permission prompt construction (with a stable id that maps back to
/// the ACP request id), and turn-state transitions.
final class AcpHarnessProjectionTests: XCTestCase {

    func testStreamingBuffersAndFlushesOnce() {
        var p = AcpHarnessProjection()
        XCTAssertEqual(p.apply(.agentMessageDelta("Hello ")), [.setTurnState(.streaming)])
        XCTAssertEqual(p.apply(.agentMessageDelta("world")), [.setTurnState(.streaming)])
        let end = p.apply(.turnEnded(.endTurn))
        XCTAssertEqual(end, [
            .appendAssistantText("Hello world"),
            .setPermissionPrompt(nil),
            .setTurnState(.completed),
        ])
        // buffer cleared — a second turnEnded emits no assistant text
        let end2 = p.apply(.turnEnded(.endTurn))
        XCTAssertEqual(end2, [.setPermissionPrompt(nil), .setTurnState(.completed)])
    }

    func testCancelledTurnIsInterrupted() {
        var p = AcpHarnessProjection()
        _ = p.apply(.agentMessageDelta("partial"))
        let end = p.apply(.turnEnded(.cancelled))
        XCTAssertEqual(end.last, .setTurnState(.interrupted))
        XCTAssertTrue(end.contains(.appendAssistantText("partial")))
    }

    func testPlanAndToolMapping() {
        var p = AcpHarnessProjection()
        let plan = p.apply(.plan([
            ACPPlanEntry(content: "First", status: "completed"),
            ACPPlanEntry(content: "Second", status: "in_progress"),
            ACPPlanEntry(content: "Third", status: "pending"),
        ]))
        XCTAssertEqual(plan, [.setPlanText("[x] First\n[~] Second\n[ ] Third")])
        let tool = p.apply(.toolCall(HarnessToolCall(toolCallId: "t", title: "run tests", kind: "execute", status: .inProgress)))
        XCTAssertEqual(tool, [.appendToolCall(title: "run tests", status: "in_progress")])
    }

    func testPermissionPromptMappingAndStableId() {
        var p = AcpHarnessProjection()
        let req = HarnessPermissionRequest(
            requestId: .number(42),
            sessionId: "s",
            title: "Write foo.txt?",
            options: [
                ACPPermissionOption(optionId: "allow_once", name: "Allow", kind: "allow_once"),
                ACPPermissionOption(optionId: "reject_once", name: "Reject", kind: "reject_once"),
            ]
        )
        let ops = p.apply(.permissionRequest(req))
        guard case .setPermissionPrompt(let prompt?) = ops.first else {
            return XCTFail("expected a permission prompt op")
        }
        XCTAssertEqual(prompt.id, "acp-perm-n42")
        XCTAssertEqual(prompt.id, AcpHarnessProjection.permissionPromptId(for: .number(42)))
        XCTAssertEqual(prompt.title, "Write foo.txt?")
        XCTAssertEqual(prompt.options.map(\.id), ["allow_once", "reject_once"])
        XCTAssertTrue(prompt.options[0].isRecommended)
        XCTAssertTrue(prompt.options[1].isDestructive)
    }

    func testPermissionHeaderReflectsAgentDisplayName() {
        var p = AcpHarnessProjection(agentDisplayName: "Cursor")
        let req = HarnessPermissionRequest(
            requestId: .string("abc"),
            sessionId: "s",
            title: "Run command?",
            options: [ACPPermissionOption(optionId: "allow_once", name: "Allow", kind: "allow_once")]
        )
        let ops = p.apply(.permissionRequest(req))
        guard case .setPermissionPrompt(let prompt?) = ops.first else {
            return XCTFail("expected a permission prompt op")
        }
        XCTAssertEqual(prompt.header, "Cursor")
        XCTAssertEqual(prompt.id, "acp-perm-sabc")
    }

    func testErrorSurfacesAndInterrupts() {
        var p = AcpHarnessProjection()
        XCTAssertEqual(p.apply(.error(code: "x", message: "boom")),
                       [.appendErrorText("boom"), .setTurnState(.interrupted)])
    }

    func testDrainBufferOnTeardown() {
        var p = AcpHarnessProjection()
        _ = p.apply(.agentMessageDelta("unflushed"))
        XCTAssertEqual(p.drainAssistantBuffer(), "unflushed")
        XCTAssertNil(p.drainAssistantBuffer())
    }
}
