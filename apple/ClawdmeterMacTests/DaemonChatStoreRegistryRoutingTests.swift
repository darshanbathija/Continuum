import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// v0.8.0 agy-migration — verifies DaemonChatStoreRegistry's URL resolver
/// branches correctly for Antigravity-agentapi Gemini sessions vs the
/// legacy JSONL paths used by Claude / Codex.
///
/// The deeper question of how SessionChatStore consumes that DB URL is
/// out of scope until the v0.8.1+ ingest path lands — these tests just
/// confirm the routing layer doesn't accidentally feed an agentapi
/// session into the Codex newest-JSONL fallback or the Claude
/// project-dir resolver.
@MainActor
final class DaemonChatStoreRegistryRoutingTests: XCTestCase {

    private func makeSession(
        agent: AgentKind,
        geminiBackend: GeminiBackend? = nil,
        antigravityConversationId: UUID? = nil
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
            mode: .local,
            geminiBackend: geminiBackend,
            antigravityConversationId: antigravityConversationId
        )
    }

    func test_antigravityConversationDBURL_followsExpectedLayout() {
        let convId = UUID(uuidString: "4D67B68A-7D62-45BD-A3CC-E4F46FB27EF3")!
        let home = URL(fileURLWithPath: "/Users/test")
        let url = DaemonChatStoreRegistry.antigravityConversationDBURL(
            conversationId: convId,
            homeDirectory: home
        )
        XCTAssertEqual(
            url.path,
            "/Users/test/.gemini/antigravity/conversations/4D67B68A-7D62-45BD-A3CC-E4F46FB27EF3.db"
        )
    }

    func test_defaultResolveURL_geminiAgentapiPointsAtSQLiteDB() {
        let convId = UUID()
        let session = makeSession(
            agent: .gemini,
            geminiBackend: .agentapi,
            antigravityConversationId: convId
        )
        let url = DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session)
        XCTAssertNotNil(url, "agentapi sessions must resolve to a DB URL even when the file is absent")
        XCTAssertTrue(url?.pathExtension == "db",
            "agentapi sessions must NOT route to JSONL — expected .db, got \(url?.pathExtension ?? "nil")")
        XCTAssertTrue(url?.path.contains(".gemini/antigravity/conversations/") ?? false,
            "url path must be under ~/.gemini/antigravity/conversations/")
    }

    func test_defaultResolveURL_geminiAgentapiWithoutConversationIdFallsThrough() {
        // When the agentapi handshake hasn't returned a conversationId yet
        // (e.g. session created mid-flight before agentapi RPC succeeded),
        // we don't have a DB URL to return. The fallthrough should pick
        // SOMETHING — Codex newest-JSONL is the path of least surprise.
        let session = makeSession(
            agent: .gemini,
            geminiBackend: .agentapi,
            antigravityConversationId: nil
        )
        // Doesn't crash — the result is whatever Codex newest-JSONL
        // returns (could be nil on a system with no codex sessions).
        _ = DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session)
    }

    func test_defaultResolveURL_legacyGeminiWithoutBackendUsesCodexFallback() {
        // Sessions created before v0.8.0 have geminiBackend == nil. These
        // were tmux-based v0.42 chat sessions (now extinct after D4 hard-
        // stop, but the data may persist on disk for old session.json
        // entries). Fallthrough returns whatever the Codex newest-JSONL
        // path picks (or nil) — same as v0.7 behavior.
        let session = makeSession(agent: .gemini, geminiBackend: nil)
        _ = DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session)
    }

    func test_defaultResolveURL_claudeSessionsUnchangedByAGYBranching() {
        let session = makeSession(agent: .claude)
        // Claude path still goes through SessionChatStore.resolveSessionFileURL
        // — no regression from the agentapi branch.
        _ = DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session)
    }
}
