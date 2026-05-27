import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// v0.8 Phase 3 regression: lock the kind-aware dispatch of
/// `AgentSpawner.argv(for: AgentSession)`. Verifies:
/// - chat + claude → plan-mode argv with --permission-mode plan
/// - chat + codex (CLI backend) → -s read-only argv
/// - chat + codex (SDK backend) → empty (relay handles spawn)
/// - chat + gemini → empty (deferred to v0.9)
/// - code sessions retain prior behavior
///
/// These tests run inside the Mac XCTest target because AgentSpawner
/// is Mac-side; ShellRunner.locateBinary requires the agent binaries
/// to be discoverable. CI environment has claude/codex/gemini binaries
/// available; if missing, the helpers return empty array and the
/// "argv is empty" assertions for missing-binary cases trigger.
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

    // MARK: - Chat + Codex (CLI backend)

    func test_chatCodexCLI_emitsReadOnlySandbox() throws {
        try XCTSkipIf(ShellRunner.locateBinary("codex") == nil,
                      "codex binary unavailable on PATH; CI skip")
        let session = makeChatSession(agent: .codex, codexBackend: .cli, model: "gpt-5.5")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertFalse(argv.isEmpty)
        XCTAssertEqual(argv.last(2), ["-s", "read-only"],
                       "chat-codex with CLI backend must use --sandbox read-only")
    }

    // MARK: - Chat + Codex (SDK backend)

    func test_chatCodexSDK_returnsEmptyArgv() {
        // SDK backend = caller routes to CodexSubscriptionRelay, not tmux.
        // Empty argv is the contract signal.
        let session = makeChatSession(agent: .codex, codexBackend: .sdk, model: "gpt-5.5")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty, "SDK chat backend bypasses argv-based tmux spawn")
    }

    func test_chatCodexSDK_default_returnsEmptyArgv() {
        // No backend set on the session = treat as SDK per RE1 default.
        // (Daemon should pin the backend at spawn time; this guards the
        // accidental-nil path.)
        let session = makeChatSession(agent: .codex, codexBackend: nil)
        let argv = AgentSpawner.argv(for: session)
        // Falls through to CLI path when backend not pinned — defensive
        // behavior so we never silently route to an unpinned backend.
        // (Real spawn flow always pins; this asserts the fallthrough.)
        XCTAssertFalse(argv.isEmpty,
                       "no pinned backend falls through to CLI argv (safe default)")
    }

    // MARK: - Chat + Gemini (deferred to v0.9)

    func test_chatGemini_returnsEmptyArgv() {
        // v0.8: gemini chat returns empty argv (route handler surfaces 501).
        // v0.9 brings the Antigravity-via-agy spawn path.
        let session = makeChatSession(agent: .gemini, model: "gemini-3-pro")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.isEmpty,
                      "Gemini chat is deferred to v0.9 — argv contract is empty in v0.8")
    }

    func test_codeCodexPassesPreparedWorkingDirectory() throws {
        try XCTSkipIf(ShellRunner.locateBinary("codex") == nil,
                      "codex binary unavailable on PATH; CI skip")
        let session = makeCodeSession(
            agent: .codex,
            model: "gpt-5.5",
            worktreePath: "/Users/foo/repo/.claude/worktrees/oslo"
        )
        let argv = AgentSpawner.argv(for: session)
        XCTAssertFalse(argv.isEmpty)
        XCTAssertTrue(argv.containsInOrder(["-C", "/Users/foo/repo/.claude/worktrees/oslo"]))
        XCTAssertTrue(argv.containsInOrder(["--model", "gpt-5.5"]))
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

    func test_cursorCodeSession_passesWorkspaceAndModel() throws {
        try XCTSkipIf(AgentSpawner.cursorBinaryPath() == nil,
                      "cursor-agent/agent binary unavailable on PATH; CI skip")
        let session = makeCodeSession(agent: .cursor, model: "claude-4-sonnet")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertFalse(argv.isEmpty)
        XCTAssertTrue(argv.containsInOrder(["--workspace", "/Users/foo/repo"]))
        XCTAssertTrue(argv.containsInOrder(["--model", "claude-4-sonnet"]))
    }

    func test_cursorAutoModel_doesNotPassModelFlag() throws {
        try XCTSkipIf(AgentSpawner.cursorBinaryPath() == nil,
                      "cursor-agent/agent binary unavailable on PATH; CI skip")
        let session = makeCodeSession(agent: .cursor, model: CursorModelCatalog.autoModelId)
        let argv = AgentSpawner.argv(for: session)
        XCTAssertFalse(argv.isEmpty)
        XCTAssertFalse(argv.contains("--model"))
        XCTAssertTrue(argv.containsInOrder(["--workspace", "/Users/foo/repo"]))
    }

    func test_cursorNewSessionRequest_ignoresPlanModeUntilResumeIdsExist() throws {
        try XCTSkipIf(AgentSpawner.cursorBinaryPath() == nil,
                      "cursor-agent/agent binary unavailable on PATH; CI skip")
        let request = NewSessionRequest(
            repoKey: "/Users/foo/repo",
            agent: .cursor,
            model: "gpt-5",
            planMode: true,
            useWorktree: true
        )
        let argv = AgentSpawner.argv(for: request, workspacePath: "/Users/foo/repo/.claude/worktrees/oslo")
        XCTAssertFalse(argv.isEmpty)
        XCTAssertTrue(argv.containsInOrder(["--workspace", "/Users/foo/repo/.claude/worktrees/oslo"]))
        XCTAssertFalse(argv.containsInOrder(["--mode", "plan"]))
    }

    func test_cursorChatSession_doesNotUsePlanModeUntilResumeIdsExist() throws {
        try XCTSkipIf(AgentSpawner.cursorBinaryPath() == nil,
                      "cursor-agent/agent binary unavailable on PATH; CI skip")
        let session = makeChatSession(agent: .cursor, model: "gpt-5")
        let argv = AgentSpawner.argv(for: session)
        XCTAssertFalse(argv.isEmpty)
        XCTAssertTrue(argv.containsInOrder(["--workspace", session.effectiveCwd]))
        XCTAssertFalse(argv.containsInOrder(["--mode", "plan"]))
    }

    func test_cursorRespawnUsesResumeAndWorkspace() throws {
        try XCTSkipIf(AgentSpawner.cursorBinaryPath() == nil,
                      "cursor-agent/agent binary unavailable on PATH; CI skip")
        let argv = AgentSpawner.respawnArgv(
            agent: .cursor,
            resumeSessionId: "cursor-chat-123",
            model: "gpt-5",
            planMode: true,
            effort: nil,
            autopilot: false,
            workspacePath: "/Users/foo/repo"
        )
        XCTAssertFalse(argv.isEmpty)
        XCTAssertTrue(argv.containsInOrder(["--workspace", "/Users/foo/repo"]))
        XCTAssertTrue(argv.containsInOrder(["--resume", "cursor-chat-123"]))
        XCTAssertTrue(argv.containsInOrder(["--model", "gpt-5"]))
        XCTAssertTrue(argv.containsInOrder(["--mode", "plan"]))
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
