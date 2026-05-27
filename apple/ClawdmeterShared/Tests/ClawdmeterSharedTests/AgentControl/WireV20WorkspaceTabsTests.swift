import XCTest
@testable import ClawdmeterShared

final class WireV20WorkspaceTabsTests: XCTestCase {

    func test_wireVersionAndGateExposeTabContext() {
        XCTAssertEqual(AgentControlWireVersion.current, 22)
        XCTAssertEqual(AgentControlWireVersion.tabContextMinimum, 22)
        XCTAssertFalse(AgentControlWireVersion.supportsTabContext(serverWireVersion: 21))
        XCTAssertTrue(AgentControlWireVersion.supportsTabContext(serverWireVersion: 22))
    }

    func test_agentSessionRoundTripsInheritedContextSources() throws {
        let sourceA = UUID()
        let sourceB = UUID()
        let session = AgentSession(
            id: UUID(),
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "continue",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            status: .running,
            planText: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            lastEventAt: Date(timeIntervalSince1970: 20),
            lastEventSeq: 3,
            mode: .worktree,
            runtimeCwd: "/repo/.claude/worktrees/kolkata",
            inheritedContextSourceIds: [sourceA, sourceB],
            ownsWorktree: true
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)

        XCTAssertEqual(decoded.inheritedContextSourceIds, [sourceA, sourceB])
        XCTAssertTrue(decoded.ownsWorktree)
    }

    func test_legacyAgentSessionDefaultsInheritedContextToNil() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "repoKey": "/repo",
          "repoDisplayName": "repo",
          "agent": "claude",
          "model": null,
          "goal": null,
          "worktreePath": null,
          "tmuxWindowId": null,
          "tmuxPaneId": null,
          "status": "running",
          "planText": null,
          "createdAt": "2026-05-26T00:00:00Z",
          "lastEventAt": "2026-05-26T00:00:00Z",
          "lastEventSeq": 1
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(AgentSession.self, from: json)

        XCTAssertNil(decoded.inheritedContextSourceIds)
        XCTAssertFalse(decoded.ownsWorktree)
    }
}
