import XCTest
@testable import ClawdmeterShared

/// Track A schema v6: AgentSession gains optional `claudeSessionId` (the Claude
/// CLI session id for `--resume`). Verifies it round-trips AND that a v5-shape
/// sessions.json (no key) decodes cleanly to nil (back-compat).
final class AgentSessionSchemaV6Tests: XCTestCase {

    private func makeSession(claudeSessionId: String?) -> AgentSession {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        return AgentSession(
            id: UUID(),
            repoKey: "/Users/foo/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "opus",
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 0,
            mode: .local,
            customName: nil,
            claudeSessionId: claudeSessionId,
            kind: .code
        )
    }

    func test_claudeSessionId_roundTrips() throws {
        let session = makeSession(claudeSessionId: "abc-123-cli-session")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: encoder.encode(session))
        XCTAssertEqual(decoded.claudeSessionId, "abc-123-cli-session")
    }

    func test_nilClaudeSessionId_roundTrips() throws {
        let session = makeSession(claudeSessionId: nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: encoder.encode(session))
        XCTAssertNil(decoded.claudeSessionId)
    }

    /// THE back-compat gate: a v5 sessions.json (no claudeSessionId key) must
    /// decode under v6 to nil — not throw.
    func test_v5SessionJSON_withoutKey_decodesToNil() throws {
        let json = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "repoKey": "/Users/foo/repo",
          "repoDisplayName": "repo",
          "agent": "claude",
          "status": "running",
          "createdAt": "2025-01-01T00:00:00Z",
          "lastEventAt": "2025-01-01T00:00:00Z",
          "lastEventSeq": 0,
          "kind": "chat"
        }
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: json.data(using: .utf8)!)
        XCTAssertNil(decoded.claudeSessionId, "v5 sessions.json (no key) must decode to nil under v6")
        XCTAssertEqual(decoded.kind, .chat)
    }
}
