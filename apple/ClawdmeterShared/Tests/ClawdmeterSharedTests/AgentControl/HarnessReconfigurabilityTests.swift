import XCTest
@testable import ClawdmeterShared

/// The routing gate for in-place harness reconfigure (model / effort /
/// approval). This is the decision point the daemon's handleChangeModel /
/// handleChangeEffort / handleSetAutopilot and the Mac composer chips branch on:
/// a `true` session respawns its bridge; a `false` session keeps its existing
/// SessionConfigChanger (Claude PTY) or 410 (retired / OpenCode) path.
final class HarnessReconfigurabilityTests: XCTestCase {

    private func session(
        agent: AgentKind,
        kind: SessionKind = .code,
        tmuxPaneId: String? = nil,
        tmuxWindowId: String? = nil
    ) -> AgentSession {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        return AgentSession(
            id: UUID(),
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: agent,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: tmuxWindowId,
            tmuxPaneId: tmuxPaneId,
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 0,
            mode: .local,
            customName: nil,
            claudeSessionId: nil,
            kind: kind
        )
    }

    func test_agentKind_reconfigurableHarnessSet() {
        XCTAssertTrue(AgentKind.cursor.isReconfigurableHarness)
        XCTAssertTrue(AgentKind.codex.isReconfigurableHarness)
        XCTAssertTrue(AgentKind.grok.isReconfigurableHarness)
        XCTAssertTrue(AgentKind.gemini.isReconfigurableHarness)
        // Claude = direct PTY, OpenCode = SSE, unknown = none.
        XCTAssertFalse(AgentKind.claude.isReconfigurableHarness)
        XCTAssertFalse(AgentKind.opencode.isReconfigurableHarness)
        XCTAssertFalse(AgentKind.unknown.isReconfigurableHarness)
    }

    func test_managedHarnessCodeSessions_areReconfigurable() {
        for agent: AgentKind in [.cursor, .codex, .grok, .gemini] {
            XCTAssertTrue(session(agent: agent).isReconfigurableHarnessCodeSession,
                          "\(agent.rawValue) code session should reconfigure in place")
        }
    }

    func test_claudeAndOpencodeCodeSessions_areNotReconfigurable() {
        XCTAssertFalse(session(agent: .claude).isReconfigurableHarnessCodeSession,
                       "Claude is a direct PTY — SessionConfigChanger, not the harness path")
        XCTAssertFalse(session(agent: .opencode).isReconfigurableHarnessCodeSession,
                       "OpenCode has its own SSE path")
    }

    func test_legacyPaneBackedHarnessSession_isNotReconfigurable() {
        // A harness-kind agent with stale tmux pane metadata is a retired
        // pre-v0.31.6 session → must NOT route to the new reconfigure (keeps 410).
        let legacy = session(agent: .codex, tmuxPaneId: "%legacy", tmuxWindowId: "@legacy")
        XCTAssertFalse(legacy.isReconfigurableHarnessCodeSession)
    }

    func test_chatSession_isNotReconfigurable() {
        // Chat harness sessions run read-only; reconfigure is a Code-tab concept.
        XCTAssertFalse(session(agent: .codex, kind: .chat).isReconfigurableHarnessCodeSession)
    }
}
