import XCTest
@testable import ClawdmeterShared

/// Sessions v2 T16 — end-to-end wire round-trip. Walks the full create
/// → swap → effort → mode → approve → diff → merge cycle through the
/// Codable DTOs, asserting at each step that the wire shape stays
/// stable.
///
/// The plan's "drives the daemon over loopback" version requires a Mac
/// test target that doesn't exist yet. This shared version catches the
/// regression class /ship cares about most — protocol drift between
/// iOS and Mac — without needing a real daemon. When the Mac test
/// target arrives (T27 fastlane brings it in), a parallel integration
/// test driving `Network.framework` over `127.0.0.1` slots in as a
/// strict superset.
final class SessionsV2E2ETests: XCTestCase {

    /// Helper: encode + decode through JSON to mimic the daemon
    /// boundary. Any Codable bug in either direction surfaces here.
    private func roundTrip<T: Codable>(_ value: T, as type: T.Type) throws -> T {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: data)
    }

    // MARK: - Create session

    func test_e2e_step1_create_session_request_roundtrip() throws {
        let req = NewSessionRequest(
            repoKey: "/Users/darshan/Code/axtior-platform",
            agent: .claude,
            model: "claude-opus-4-7",
            planMode: true,
            goal: "Fix the redis connection timeout in auth middleware",
            useWorktree: true,
            baseBranch: "main",
            effort: .high,
            abPair: nil
        )
        let decoded = try roundTrip(req, as: NewSessionRequest.self)
        XCTAssertEqual(decoded.repoKey, req.repoKey)
        XCTAssertEqual(decoded.agent, .claude)
        XCTAssertEqual(decoded.model, "claude-opus-4-7")
        XCTAssertTrue(decoded.planMode)
        XCTAssertEqual(decoded.goal, req.goal)
        XCTAssertTrue(decoded.useWorktree)
        XCTAssertEqual(decoded.effort, .high)
        XCTAssertNil(decoded.abPair)
    }

    func test_e2e_step1b_create_ab_pair_request() throws {
        let req = NewSessionRequest(
            repoKey: "/repo",
            agent: .claude,
            model: "claude-opus-4-7",
            planMode: false,
            goal: "Refactor auth",
            useWorktree: true,
            baseBranch: "main",
            effort: .medium,
            abPair: .codex
        )
        let decoded = try roundTrip(req, as: NewSessionRequest.self)
        XCTAssertEqual(decoded.abPair, .codex)
    }

    // MARK: - AgentSession back from daemon (schema v3)

    func test_e2e_step2_session_response_includes_v3_fields() throws {
        let id = UUID()
        let pairId = UUID()
        let now = Date()
        let session = AgentSession(
            id: id,
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "claude-opus-4-7",
            goal: "Test",
            worktreePath: "/repo/.claude/worktrees/test-abc",
            tmuxWindowId: "@5",
            tmuxPaneId: "%7",
            status: AgentSessionStatus.running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 1,
            mode: SessionMode.worktree,
            archivedAt: nil,
            terminalPanes: [],
            scheduledFollowUps: [],
            parentSessionId: nil,
            effort: ReasoningEffort.high,
            abPairSessionId: pairId,
            abPairDecidedAt: nil
        )
        let decoded = try roundTrip(session, as: AgentSession.self)
        XCTAssertEqual(decoded.effort, ReasoningEffort.high)
        XCTAssertEqual(decoded.abPairSessionId, pairId)
        XCTAssertNil(decoded.abPairDecidedAt)
        XCTAssertEqual(decoded.mode, SessionMode.worktree)
    }

    // MARK: - Mid-session swaps

    func test_e2e_step3_change_model_to_sonnet() throws {
        let req = ChangeModelRequest(model: "claude-sonnet-4-6", effort: .medium)
        let decoded = try roundTrip(req, as: ChangeModelRequest.self)
        XCTAssertEqual(decoded.model, "claude-sonnet-4-6")
        XCTAssertEqual(decoded.effort, .medium)
    }

    func test_e2e_step4_change_effort_to_xhigh() throws {
        let req = ChangeEffortRequest(effort: .xhigh)
        let decoded = try roundTrip(req, as: ChangeEffortRequest.self)
        XCTAssertEqual(decoded.effort, .xhigh)
    }

    func test_e2e_step5_change_mode_to_local_with_plan_off() throws {
        let req = ChangeModeRequest(mode: .local, planMode: false)
        let decoded = try roundTrip(req, as: ChangeModeRequest.self)
        XCTAssertEqual(decoded.mode, .local)
        XCTAssertEqual(decoded.planMode, false)
    }

    // MARK: - Send prompt

    func test_e2e_step6_send_prompt_round_trip() throws {
        let req = SendPromptRequest(
            text: "Run the tests and fix any failures.",
            asFollowUp: true
        )
        let decoded = try roundTrip(req, as: SendPromptRequest.self)
        XCTAssertEqual(decoded.text, req.text)
        XCTAssertTrue(decoded.asFollowUp)
    }

    // MARK: - Approve plan triggers a respawn (no DTO, but planText flips)

    func test_e2e_step7_session_after_approve_plan() throws {
        // Approve flips status → running and clears planText. Verify the
        // session shape still decodes after that mutation.
        let id = UUID()
        let now = Date()
        let postApprove = AgentSession(
            id: id,
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "Test",
            worktreePath: "/repo/.claude/worktrees/test-abc",
            tmuxWindowId: "@9",
            tmuxPaneId: "%11",
            status: AgentSessionStatus.running,
            planText: "",   // cleared
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 5,
            mode: SessionMode.worktree,
            archivedAt: nil,
            terminalPanes: [],
            scheduledFollowUps: [],
            parentSessionId: nil,
            effort: ReasoningEffort.medium,
            abPairSessionId: nil,
            abPairDecidedAt: nil
        )
        let decoded = try roundTrip(postApprove, as: AgentSession.self)
        XCTAssertEqual(decoded.status, AgentSessionStatus.running)
        XCTAssertEqual(decoded.planText, "")
    }

    // MARK: - Diff fetch

    func test_e2e_step8_diff_response_round_trip() throws {
        let file = GitDiffFile(
            path: "src/auth.ts",
            status: "M",
            additions: 12,
            deletions: 3,
            hunks: [
                GitDiffHunk(
                    header: "@@ -10,3 +10,12 @@",
                    lines: [
                        .init(kind: .context, text: " function authenticate() {"),
                        .init(kind: .deletion, text: "-  return token;"),
                        .init(kind: .addition, text: "+  if (token == null) {"),
                        .init(kind: .addition, text: "+    return null;"),
                        .init(kind: .addition, text: "+  }"),
                        .init(kind: .addition, text: "+  return token;"),
                    ]
                )
            ],
            truncated: false
        )
        let decoded = try roundTrip([file], as: [GitDiffFile].self)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].path, "src/auth.ts")
        XCTAssertEqual(decoded[0].additions, 12)
        XCTAssertEqual(decoded[0].deletions, 3)
        XCTAssertEqual(decoded[0].hunks.count, 1)
        XCTAssertEqual(decoded[0].hunks[0].lines.count, 6)
    }

    func test_e2e_step8b_truncated_large_diff() throws {
        // Large diff returns truncated=true with empty hunks. iOS should
        // render the "diff too large" overlay.
        let file = GitDiffFile(
            path: "vendor/big.gen.ts",
            status: "M",
            additions: 50000,
            deletions: 0,
            hunks: [],
            truncated: true
        )
        let decoded = try roundTrip(file, as: GitDiffFile.self)
        XCTAssertTrue(decoded.truncated)
        XCTAssertTrue(decoded.hunks.isEmpty)
    }

    // MARK: - PR status + merge

    func test_e2e_step9_pr_status_after_create() throws {
        let pr = PRStatus(
            url: "https://github.com/foo/axtior-platform/pull/142",
            number: 142,
            title: "Fix redis connection timeout in auth middleware",
            body: "## Summary\nAdds nil-check before token read.",
            state: PRStatus.State.open,
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            reviewDecision: nil,
            checksRollup: "pending"
        )
        let decoded = try roundTrip(pr, as: PRStatus.self)
        XCTAssertEqual(decoded.number, 142)
        XCTAssertEqual(decoded.state, PRStatus.State.open)
        XCTAssertEqual(decoded.checksRollup, "pending")
    }

    func test_e2e_step10_pr_status_after_merge() throws {
        let pr = PRStatus(
            url: "https://github.com/foo/axtior-platform/pull/142",
            number: 142,
            title: "Fix redis connection timeout",
            body: "Merged.",
            state: PRStatus.State.merged,
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            reviewDecision: "APPROVED",
            checksRollup: "success"
        )
        let decoded = try roundTrip(pr, as: PRStatus.self)
        XCTAssertEqual(decoded.state, PRStatus.State.merged)
        XCTAssertEqual(decoded.reviewDecision, "APPROVED")
        XCTAssertEqual(decoded.checksRollup, "success")
    }

    // MARK: - HealthResponse + wireVersion handshake (E8)

    func test_e2e_step11_health_carries_wire_version() throws {
        let health = HealthResponse(
            ok: true,
            serverVersion: "0.2.0",
            wireVersion: AgentControlWireVersion.current
        )
        let decoded = try roundTrip(health, as: HealthResponse.self)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.serverVersion, "0.2.0")
        XCTAssertEqual(decoded.wireVersion, AgentControlWireVersion.current)
    }

    func test_e2e_step11b_wire_version_mismatch_detection() throws {
        // Simulate a Mac on an older daemon. The iOS client should flag
        // mismatch when current != served.
        let oldHealth = HealthResponse(ok: true, serverVersion: "0.1.9", wireVersion: 2)
        let decoded = try roundTrip(oldHealth, as: HealthResponse.self)
        XCTAssertNotEqual(decoded.wireVersion, AgentControlWireVersion.current)
    }

    // MARK: - Preflight (Phase 8 cost banner)

    func test_e2e_step12_preflight_query_to_response() throws {
        let q = PreflightQuery(
            repoKey: "/repo",
            agent: .claude,
            model: "claude-opus-4-7",
            effort: .high,
            goalLength: 200
        )
        _ = try roundTrip(q, as: PreflightQuery.self)
        let r = PreflightResponse(
            estimatedCostUSD: 1.47,
            weeklyCapPct: 0.32,
            wouldCap: false,
            suggestedSwap: nil,
            staleData: false
        )
        let decoded = try roundTrip(r, as: PreflightResponse.self)
        XCTAssertEqual(decoded.estimatedCostUSD, 1.47)
        XCTAssertEqual(decoded.weeklyCapPct, 0.32)
        XCTAssertFalse(decoded.wouldCap)
    }

    func test_e2e_step12b_preflight_response_with_swap_cta() throws {
        // High projection → wouldCap → suggestedSwap to a cheaper model.
        let r = PreflightResponse(
            estimatedCostUSD: 5.21,
            weeklyCapPct: 0.97,
            wouldCap: true,
            suggestedSwap: "claude-sonnet-4-6",
            staleData: false
        )
        let decoded = try roundTrip(r, as: PreflightResponse.self)
        XCTAssertTrue(decoded.wouldCap)
        XCTAssertEqual(decoded.suggestedSwap, "claude-sonnet-4-6")
    }

    // MARK: - A/B pair winner-pick atomic CAS (E3)

    func test_e2e_step13_pick_winner_decided() throws {
        let req = PickWinnerRequest(winnerSessionId: UUID())
        let decoded = try roundTrip(req, as: PickWinnerRequest.self)
        XCTAssertEqual(decoded.winnerSessionId, req.winnerSessionId)
    }

    func test_e2e_step13b_pick_winner_conflict_response() throws {
        let winner = UUID()
        let conflict = PickWinnerConflictResponse(
            winnerSessionId: winner,
            decidedAt: Date()
        )
        let decoded = try roundTrip(conflict, as: PickWinnerConflictResponse.self)
        XCTAssertTrue(decoded.alreadyDecided)
        XCTAssertEqual(decoded.winnerSessionId, winner)
    }

    // MARK: - Autopilot

    func test_e2e_step14_autopilot_toggle() throws {
        let on = AutopilotRequest(enabled: true)
        let off = AutopilotRequest(enabled: false)
        XCTAssertTrue(try roundTrip(on, as: AutopilotRequest.self).enabled)
        XCTAssertFalse(try roundTrip(off, as: AutopilotRequest.self).enabled)
    }
}
