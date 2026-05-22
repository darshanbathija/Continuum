import XCTest
@testable import ClawdmeterShared

/// Exercises the wire v10 → v11 bump (v0.9 — chat-via-agentapi):
///   - AgentControlWireVersion.current bumped to 12 (X3 unknown hardening)
///   - antigravityChatMinimum stays at 11 (now reachable: daemon ships
///     handlePostGeminiChatSession lifting the v0.8 501 stub)
///   - All v0.8 + v0.8.1 minimums unchanged (composeDraftMinimum,
///     chatSubscribeMinimum, geminiMinimum, antigravityMinimum,
///     codexSDKMinimum, chatMinimum, frontierMinimum,
///     codexChatBackendMinimum, agentapiMinimum)
///   - AgentSession schema gains optional `antigravityProjectId: String?`
///     with decoder tolerance for all prior schema versions
final class WireV11Tests: XCTestCase {

    // MARK: - Wire version constants

    func test_currentWireVersionIsFourteen() {
        // v14 (2026-05-23, Chat V2): explicit per-turn lifecycle on the
        // snapshot wire (`WireChatSnapshot.currentTurnState: TurnState`),
        // deepResearch toggle on chat requests + AgentSession, and the
        // new `GET /chat-sessions/search?q=` endpoint. All additive +
        // decodeIfPresent — v13 clients still decode v14 payloads
        // cleanly with default values.
        XCTAssertEqual(AgentControlWireVersion.current, 14)
    }

    func test_opencodeMinimumIsThirteen() {
        XCTAssertEqual(AgentControlWireVersion.opencodeMinimum, 13)
    }

    func test_antigravityChatMinimumIsEleven() {
        XCTAssertEqual(AgentControlWireVersion.antigravityChatMinimum, 11)
    }

    func test_supportsAntigravityChat_trueAtCurrentVersion() {
        XCTAssertTrue(
            AgentControlWireVersion.supportsAntigravityChat(
                serverWireVersion: AgentControlWireVersion.current
            )
        )
    }

    func test_supportsAntigravityChat_falseBelowEleven() {
        for v in 1...10 {
            XCTAssertFalse(
                AgentControlWireVersion.supportsAntigravityChat(serverWireVersion: v),
                "v\(v) Mac should not advertise agentapi chat support"
            )
        }
        XCTAssertFalse(AgentControlWireVersion.supportsAntigravityChat(serverWireVersion: nil))
    }

    func test_priorMinimumsUnchanged() {
        // v11 must not drift earlier gates.
        XCTAssertEqual(AgentControlWireVersion.composeDraftMinimum, 4)
        XCTAssertEqual(AgentControlWireVersion.chatSubscribeMinimum, 5)
        XCTAssertEqual(AgentControlWireVersion.geminiMinimum, 6)
        XCTAssertEqual(AgentControlWireVersion.antigravityMinimum, 7)
        XCTAssertEqual(AgentControlWireVersion.codexSDKMinimum, 8)
        XCTAssertEqual(AgentControlWireVersion.chatMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.frontierMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.codexChatBackendMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.agentapiMinimum, 10)
    }

    // MARK: - AgentSession schema — antigravityProjectId

    func test_session_round_trip_with_antigravityProjectId() throws {
        let projectId = UUID().uuidString
        let session = AgentSession(
            id: UUID(),
            repoKey: nil,
            repoDisplayName: "Chat — Gemini",
            agent: .gemini,
            model: "gemini-3-pro",
            goal: nil,
            worktreePath: "/tmp/clawdmeter-chat/abc",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .local,
            kind: .chat,
            geminiBackend: .agentapi,
            antigravityConversationId: UUID(),
            antigravityProjectId: projectId
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.antigravityProjectId, projectId)
        XCTAssertEqual(decoded.geminiBackend, .agentapi)
        XCTAssertEqual(decoded.kind, .chat)
    }

    func test_session_decodes_without_antigravityProjectId() throws {
        // v0.8.1 sessions.json files don't carry antigravityProjectId.
        // The decoder must treat its absence as nil — not throw.
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "repoKey": "/Users/test/repo",
            "repoDisplayName": "Test",
            "agent": "claude",
            "status": "running",
            "createdAt": 0,
            "lastEventAt": 0,
            "lastEventSeq": 1
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AgentSession.self, from: data)
        XCTAssertNil(decoded.antigravityProjectId)
        XCTAssertNil(decoded.geminiBackend)
        XCTAssertNil(decoded.antigravityConversationId)
    }
}
