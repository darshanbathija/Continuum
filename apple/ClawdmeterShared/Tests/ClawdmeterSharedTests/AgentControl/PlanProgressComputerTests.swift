import XCTest
@testable import ClawdmeterShared

/// Daemon-side completion heuristic. The critical regression test
/// is `testPostApprovalMessageReferencingStep3` — guards the bug
/// Codex caught during plan review where feeding `approvedPlanText`
/// to the existing `computePlanStepsIncremental` heuristic would peg
/// the bar at N/N immediately because every step's needle is a
/// substring of the plan it came from.
final class PlanProgressComputerTests: XCTestCase {

    private let approvedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func msg(
        _ kind: ChatMessage.Kind,
        _ body: String,
        offset seconds: TimeInterval,
        detail: String? = nil,
        id: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id ?? UUID().uuidString,
            kind: kind,
            title: "test",
            body: body,
            detail: detail,
            at: approvedAt.addingTimeInterval(seconds),
            isError: false
        )
    }

    // MARK: - 1. Prose plan → nil

    func testEmptyPlan_returnsNil() {
        XCTAssertNil(PlanProgressComputer.compute(
            approvedPlanText: "",
            messagesSinceApproval: [],
            approvedAt: approvedAt
        ))
    }

    func testProseOnlyPlan_returnsNil() {
        // Plan with no list markers: TahoePlanParser.steps treats each
        // newline-split chunk as a candidate, so a multi-line prose
        // plan does produce candidates. Single-line prose has exactly
        // one "step" — also valid input. The "nil" path only fires
        // for a plan that produces zero candidates after parsing,
        // which `TahoePlanParser.steps` only does on whitespace-only
        // input.
        XCTAssertNil(PlanProgressComputer.compute(
            approvedPlanText: "   \n   \n\n",
            messagesSinceApproval: [],
            approvedAt: approvedAt
        ))
    }

    // MARK: - 2. Parsed steps but no post-approval messages

    func testParsedSteps_noPostApprovalMessages_returnsZeroOfN() {
        let plan = """
        1. Add the PlanProgress struct to the shared module.
        2. Wire it into the daemon's session registry.
        3. Render a thin bar in the Mac sidebar row.
        """
        let progress = PlanProgressComputer.compute(
            approvedPlanText: plan,
            messagesSinceApproval: [],
            approvedAt: approvedAt
        )
        XCTAssertEqual(progress?.total, 3)
        XCTAssertEqual(progress?.completed, 0)
    }

    // MARK: - 3. **REGRESSION**: post-approval message must mark step complete

    func testPostApprovalMessageReferencingStep3_returnsOneOfN() {
        // Three-step plan; one assistant message after approval that
        // references step 3's text. Expectation: 1/3, NOT 3/3.
        // The auto-complete bug Codex caught would produce 3/3 because
        // every step's first-30 chars are substrings of the plan text
        // itself. The fix is the post-approval timestamp filter, which
        // means the plan-emission message (at approvedAt or before)
        // is filtered out and the plan text is never directly scanned.
        let plan = """
        1. Add the PlanProgress struct to the shared module.
        2. Wire it into the daemon's session registry.
        3. Render a thin bar in the Mac sidebar row.
        """
        let postApprovalMessage = msg(
            .assistantText,
            "Done. Render a thin bar in the Mac sidebar row is now wired up.",
            offset: 60
        )
        let progress = PlanProgressComputer.compute(
            approvedPlanText: plan,
            messagesSinceApproval: [postApprovalMessage],
            approvedAt: approvedAt
        )
        XCTAssertEqual(progress?.total, 3)
        XCTAssertEqual(progress?.completed, 1,
            "Only step 3 should be complete. Steps 1 and 2 must NOT auto-complete from the plan text — that's the auto-complete bug.")
    }

    // MARK: - 4. Pre-approval messages don't count

    func testPreApprovalMessages_doNotCount() {
        // A message stamped *before* the approval timestamp must not
        // count, even if it references step text. This guards the
        // case where the plan-emission assistant message itself
        // contains every step verbatim — without the filter, that
        // single message would self-complete the whole plan.
        let plan = """
        1. Add the PlanProgress struct to the shared module.
        2. Wire it into the daemon's session registry.
        """
        // Same text as step 1, but stamped 10s BEFORE approval.
        let preApprovalMessage = msg(
            .assistantText,
            "Add the PlanProgress struct to the shared module.",
            offset: -10
        )
        let progress = PlanProgressComputer.compute(
            approvedPlanText: plan,
            messagesSinceApproval: [preApprovalMessage],
            approvedAt: approvedAt
        )
        XCTAssertEqual(progress?.total, 2)
        XCTAssertEqual(progress?.completed, 0,
            "Pre-approval messages must not count toward step completion.")
    }

    // MARK: - 5. Self-match guard

    func testSelfMatchGuard_quotedStepDoesNotSelfComplete() {
        // A post-approval message whose body is exactly the step text
        // repeated back (or very close to it — within needleLen+4)
        // should NOT count as completion. This catches cases like the
        // agent narrating "Step 3: render a thin bar in the Mac sidebar"
        // verbatim without actually doing the work.
        let plan = """
        1. Add the PlanProgress struct to the shared module.
        2. Render a thin bar in the Mac sidebar row.
        """
        // Body is just step 2's text, no surrounding work claim.
        let echoMessage = msg(
            .assistantText,
            "render a thin bar in the m",  // ≤ needleLen + 4 = 34
            offset: 5
        )
        let progress = PlanProgressComputer.compute(
            approvedPlanText: plan,
            messagesSinceApproval: [echoMessage],
            approvedAt: approvedAt
        )
        XCTAssertEqual(progress?.total, 2)
        XCTAssertEqual(progress?.completed, 0,
            "Self-match (body that's only the needle, no real work claim) must not count.")
    }

    // MARK: - 6. ToolCall + toolResult bodies also count

    func testToolCallBodyCountsTowardCompletion() {
        let plan = """
        1. Edit Protocol.swift to add the new wire field.
        2. Edit SessionWorkspaceView.swift to render the bar.
        """
        // Tool-call message describing the agent's actual file edit
        // (body is typically the file path / command line).
        let toolMessage = msg(
            .toolCall,
            "Edited Protocol.swift +12 -0",
            offset: 30,
            detail: "edit Protocol.swift to add the new wire field"
        )
        let progress = PlanProgressComputer.compute(
            approvedPlanText: plan,
            messagesSinceApproval: [toolMessage],
            approvedAt: approvedAt
        )
        XCTAssertEqual(progress?.total, 2)
        XCTAssertEqual(progress?.completed, 1,
            "Tool-call detail/body should count when it references a step's text.")
    }
}
