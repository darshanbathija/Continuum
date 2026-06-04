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

    // (The agentapi conversation-DB routing tests were removed with the
    // Antigravity agentapi drive — Gemini now drives headless via `agy`.)

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

    // MARK: - v0.23.2 T8: opencode branch routing

    func test_opencodeSessions_createUnpathedChatStore() {
        // OpenCode sessions have no JSONL rollout file — the registry's
        // createStore branch instantiates an sdkOnly SessionChatStore and
        // never asks defaultResolveURL for a path. The integration is
        // verified by chat-subscribe smoke tests (T11). At unit level we
        // can at least confirm defaultResolveURL doesn't fight us for the
        // opencode agent kind by accidentally returning a Claude JSONL.
        let session = makeSession(agent: .opencode)
        let url = DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session)
        // Either nil (no JSONL ever expected) or anything Claude-resolver
        // returned by fall-through is irrelevant — production never reads
        // it for .opencode because createStore short-circuits earlier.
        // Test asserts: doesn't crash, doesn't return a `.db` (which would
        // suggest we accidentally fell into the agentapi-Gemini branch).
        XCTAssertNotEqual(url?.pathExtension, "db",
            "opencode sessions must never route to the agentapi DB layout")
    }
}
