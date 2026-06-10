import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// v0.8 Phase 3 regression: lock the kind-aware dispatch of
/// `AgentSpawner.argv(for: AgentSession)`. Verifies:
/// - chat + claude → plan-mode argv with --permission-mode plan
/// - non-Claude providers → empty argv because managed adapters own transport
/// - code sessions retain Claude direct-runtime argv behavior
///
/// These tests run inside the Mac XCTest target because AgentSpawner
/// is Mac-side; only Claude requires a CLI binary for these argv contracts.
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
        // Verify the `--permission-mode plan` pair is present (in order) rather
        // than pinning it to the tail — chat sessions append `--strict-mcp-config`
        // after it, so it's no longer the last flag.
        guard let pmIndex = argv.firstIndex(of: "--permission-mode"), pmIndex + 1 < argv.count else {
            return XCTFail("chat session must force plan mode regardless of stored flags")
        }
        XCTAssertEqual(argv[pmIndex + 1], "plan",
                       "chat session must force plan mode regardless of stored flags")
    }

    // MARK: - Managed non-Claude transports

    func test_nonClaudeChatSessions_returnEmptyArgvForManagedAdapters() {
        let cases: [(AgentKind, CodexChatBackend?, String?)] = [
            (.codex, nil, "gpt-5.5"),
            (.codex, .sdk, "gpt-5.5"),
            (.codex, .cli, "gpt-5.5"),
            (.gemini, nil, "gemini-3-pro"),
            (.cursor, nil, CursorModelCatalog.autoModelId),
            (.opencode, nil, "anthropic/claude-sonnet-4.6"),
            (.grok, nil, "grok-code-fast-1")
        ]
        for (agent, backend, model) in cases {
            let session = makeChatSession(agent: agent, codexBackend: backend, model: model)
            XCTAssertTrue(
                AgentSpawner.argv(for: session).isEmpty,
                "\(agent.rawValue) chat should be routed through its managed adapter, not direct argv"
            )
        }
    }

    func test_nonClaudeCodeSessions_returnEmptyArgvForManagedAdapters() {
        let cases: [(AgentKind, String?)] = [
            (.codex, "gpt-5.5"),
            (.gemini, "gemini-3-pro"),
            (.cursor, CursorModelCatalog.autoModelId),
            (.opencode, "anthropic/claude-sonnet-4.6"),
            (.grok, "grok-code-fast-1")
        ]
        for (agent, model) in cases {
            let session = makeCodeSession(
                agent: agent,
                model: model,
                worktreePath: "/Users/foo/repo/.claude/worktrees/oslo"
            )
            XCTAssertTrue(
                AgentSpawner.argv(for: session).isEmpty,
                "\(agent.rawValue) code should be routed through its managed adapter, not direct argv"
            )
        }
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

    func test_nonClaudeNewSessionRequests_returnEmptyArgvForManagedAdapters() {
        let agents: [AgentKind] = [.codex, .gemini, .cursor, .opencode, .grok]
        for agent in agents {
            let request = NewSessionRequest(
                repoKey: "/Users/foo/repo",
                agent: agent,
                model: nil,
                planMode: true,
                useWorktree: true
            )
            let argv = AgentSpawner.argv(for: request, workspacePath: "/Users/foo/repo/.claude/worktrees/oslo")
            XCTAssertTrue(
                argv.isEmpty,
                "\(agent.rawValue) new sessions should be routed through their managed adapter, not direct argv"
            )
        }
    }

    func test_codeSessionTransportPolicy_routesManagedAdaptersPastArgvPreflight() {
        let cases: [(AgentKind, Bool, AgentTransportPolicy, String)] = [
            (.claude, false, .directPtyArgv, ""),
            (.codex, false, .codexAppServer, "codex-app-server-session"),
            (.gemini, false, .transportOwningHarness, "transport-owning-harness-session"),
            (.grok, false, .transportOwningHarness, "transport-owning-harness-session"),
            (.opencode, false, .opencodeServe, "opencode-managed-session"),
            (.cursor, true, .acpHarness, "acp-managed-session"),
            (.cursor, false, .unsupported, "")
        ]
        for (agent, acpSupported, expected, token) in cases {
            let policy = AgentTransportPolicy.codeSessionTransport(for: agent, acpSupported: acpSupported)
            XCTAssertEqual(policy, expected, "\(agent.rawValue) should route through the expected code-session transport")
            XCTAssertEqual(policy.managedPreflightToken, token)
            XCTAssertEqual(policy.requiresArgvPreflight, expected == .directPtyArgv)
        }
    }

    func test_nonClaudeRespawn_returnsEmptyArgvForManagedAdapters() {
        let agents: [AgentKind] = [.codex, .gemini, .cursor, .opencode, .grok]
        for agent in agents {
            let argv = AgentSpawner.respawnArgv(
                agent: agent,
                resumeSessionId: "\(agent.rawValue)-session-123",
                model: nil,
                planMode: true,
                effort: nil,
                autopilot: false,
                workspacePath: "/Users/foo/repo"
            )
            XCTAssertTrue(
                argv.isEmpty,
                "\(agent.rawValue) respawn should rebuild its managed adapter, not direct argv"
            )
        }
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
