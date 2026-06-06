import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// v0.8 Phase 3 regression: lock the kind-aware dispatch of
/// `AgentSpawner.argv(for: AgentSession)`. Verifies:
/// - chat + claude → plan-mode argv with --permission-mode plan
/// - non-Claude chat/code/new-session/respawn paths → empty tmux argv
///   because the daemon routes them through the paneless ACP harness.
///
/// These tests run inside the Mac XCTest target because AgentSpawner
/// is Mac-side.
final class AgentSpawnerChatArgvTests: XCTestCase {

    // MARK: - Helpers

    private func makeChatSession(
        agent: AgentKind,
        codexBackend: CodexChatBackend? = nil,
        model: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: nil,
            repoDisplayName: "Chat — \(agent.rawValue)",
            agent: agent,
            model: model,
            goal: nil,
            worktreePath: "/tmp/chat-sessions/\(UUID().uuidString)",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0,
            mode: .local,
            kind: .chat,
            codexChatBackend: codexBackend
        )
    }

    private func makeCodeSession(
        agent: AgentKind,
        model: String? = nil,
        worktreePath: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: "/Users/foo/repo",
            repoDisplayName: "repo",
            agent: agent,
            model: model,
            goal: nil,
            worktreePath: worktreePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0,
            mode: .local,
            kind: .code
        )
    }

    // MARK: - Chat + Claude

    func test_chatClaude_emitsPlanModeArgv() throws {
        try XCTSkipIf(ShellRunner.locateBinary("claude") == nil,
                      "claude binary unavailable on PATH; CI skip")
        let session = makeChatSession(agent: .claude, model: "opus")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertFalse(argv.isEmpty)
        XCTAssertEqual(argv.last(2), ["--permission-mode", "plan"],
                       "chat session must force plan mode regardless of stored flags")
    }

    // MARK: - Chat + Codex

    func test_chatCodexCLI_returnsEmptyForHarness() {
        let session = makeChatSession(agent: .codex, codexBackend: .cli, model: "gpt-5.5")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "Codex chat is ACP/app-server driven, not tmux argv")
    }

    func test_chatCodexSDK_returnsEmptyArgv() {
        // SDK backend is now a legacy, decode-only shape. Empty argv is the
        // contract signal that command routes retire it instead of spawning.
        let session = makeChatSession(agent: .codex, codexBackend: .sdk, model: "gpt-5.5")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "SDK chat backend bypasses argv-based spawn")
    }

    func test_chatCodexSDK_default_returnsEmptyArgv() {
        // No backend set on the session still stays paneless; the daemon pins
        // the concrete runtime before attaching a bridge.
        let session = makeChatSession(agent: .codex, codexBackend: nil)
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "unpinned Codex chat still bypasses argv-based tmux spawn")
    }

    // MARK: - Chat + Gemini

    func test_chatGemini_returnsEmptyArgv() {
        // Gemini chat is harness-driven via headless agy/Cascade, not tmux.
        let session = makeChatSession(agent: .gemini, model: "gemini-3-pro")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "Gemini chat bypasses argv-based tmux spawn")
    }

    func test_codeCodexReturnsEmptyForHarness() {
        let session = makeCodeSession(
            agent: .codex,
            model: "gpt-5.5",
            worktreePath: "/Users/foo/repo/.claude/worktrees/oslo"
        )
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "Codex code sessions are ACP/app-server driven, not tmux argv")
    }

    // MARK: - Code sessions unchanged

    func test_codeClaude_doesNotForcePlanMode_whenNotPlanning() throws {
        try XCTSkipIf(ShellRunner.locateBinary("claude") == nil,
                      "claude binary unavailable on PATH; CI skip")
        let session = makeCodeSession(agent: .claude, model: "opus")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertFalse(argv.isEmpty)
        // Should NOT contain --permission-mode plan when status is .running
        XCTAssertFalse(argv.contains("--permission-mode"),
                       "code session in .running status should not force plan-mode flag")
    }

    // MARK: - Cursor

    func test_cursorCodeSession_returnsEmptyForHarness() {
        let session = makeCodeSession(agent: .cursor, model: "claude-4-sonnet")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "Cursor code sessions are ACP-harness driven, not tmux argv")
    }

    func test_cursorAutoModel_returnsEmptyForHarness() {
        let session = makeCodeSession(agent: .cursor, model: CursorModelCatalog.autoModelId)
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "Cursor auto-model code sessions bypass argv-based tmux spawn")
    }

    func test_cursorNewSessionRequest_returnsEmptyForHarness() {
        let request = NewSessionRequest(
            repoKey: "/Users/foo/repo",
            agent: .cursor,
            model: "gpt-5",
            planMode: true,
            useWorktree: true
        )
        let argv = AgentSpawner.argv(for: request, workspacePath: "/Users/foo/repo/.claude/worktrees/oslo")
        XCTAssertTrue(argv.isEmpty, "Cursor new sessions are routed to the ACP harness, not tmux argv")
    }

    func test_cursorChatSession_returnsEmptyForHarness() {
        let session = makeChatSession(agent: .cursor, model: "gpt-5")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "Cursor chat sessions bypass argv-based tmux spawn")
    }

    func test_cursorRespawnReturnsEmptyForHarness() {
        let argv = AgentSpawner.respawnArgv(
            agent: .cursor,
            resumeSessionId: "cursor-chat-123",
            model: "gpt-5",
            planMode: true,
            effort: nil,
            autopilot: false,
            workspacePath: "/Users/foo/repo"
        )
        XCTAssertTrue(argv.isEmpty, "Cursor respawn rebuilds the ACP bridge, not tmux argv")
    }
}

// MARK: - Helper

private extension Array {
    /// Returns the last `n` elements, or the full array if smaller.
    func last(_ n: Int) -> [Element] {
        guard count >= n else { return self }
        return Array(suffix(n))
    }
}

private extension Array where Element: Equatable {
    func containsInOrder(_ needle: [Element]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in indices {
            let end = index(start, offsetBy: needle.count, limitedBy: endIndex)
            guard let end, end <= endIndex else { continue }
            if Array(self[start..<end]) == needle { return true }
        }
        return false
    }
}
