import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Verifies DaemonChatStoreRegistry's default URL resolver stays conservative:
/// Claude may use its cwd-scoped project-dir resolver, while providers without
/// a proven session path do not fall back to global provider history.
@MainActor
final class DaemonChatStoreRegistryRoutingTests: XCTestCase {

    private func makeSession(
        agent: AgentKind
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: "/Users/test/Repo",
            repoDisplayName: "Repo",
            agent: agent,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .local
        )
    }

    func test_defaultResolveURL_geminiFailsClosedWithoutOwnedPath() {
        let session = makeSession(agent: .gemini)
        XCTAssertNil(DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session))
    }

    func test_defaultResolveURL_claudeSessionsUnchangedByAGYBranching() {
        let session = makeSession(agent: .claude)
        // Claude path still goes through SessionChatStore.resolveSessionFileURL
        // — no regression from the agentapi branch.
        _ = DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session)
    }

    // MARK: - v0.23.2 T8: opencode branch routing

    func test_defaultResolveURL_opencodeFailsClosedWithoutOwnedPath() {
        // OpenCode sessions have no JSONL rollout file — the registry's
        // createStore branch instantiates an sdkOnly SessionChatStore and
        // never asks defaultResolveURL for a path.
        let session = makeSession(agent: .opencode)
        XCTAssertNil(DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session))
    }
}
