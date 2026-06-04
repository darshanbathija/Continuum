import XCTest
@testable import ClawdmeterShared

/// v27 Code-tab harness migration: `NewSessionRequest` gains optional
/// `existingWorkspacePath` + `sessionId`. Verify round-trip and — critically —
/// that a v26 payload without these keys still decodes (back-compat).
final class WireV27HarnessSpawnTests: XCTestCase {
    func testWireVersionAtLeast27() {
        XCTAssertGreaterThanOrEqual(AgentControlWireVersion.current, 27)
        XCTAssertEqual(AgentControlWireVersion.harnessSpawnMinimum, 27)
    }

    func testNewFieldsRoundTrip() throws {
        let id = UUID()
        let req = NewSessionRequest(
            repoKey: "/repo",
            agent: .codex,
            useWorktree: true,
            existingWorkspacePath: "/repo/.worktrees/calm-harbor",
            sessionId: id
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(NewSessionRequest.self, from: data)
        XCTAssertEqual(decoded.existingWorkspacePath, "/repo/.worktrees/calm-harbor")
        XCTAssertEqual(decoded.sessionId, id)
        XCTAssertEqual(decoded.agent, .codex)
    }

    func testBackCompatDecodeWithoutNewKeys() throws {
        // A v26-era payload has no existingWorkspacePath / sessionId keys.
        let json = #"{"repoKey":"/repo","agent":"cursor","planMode":false,"useWorktree":true}"#
        let decoded = try JSONDecoder().decode(NewSessionRequest.self, from: Data(json.utf8))
        XCTAssertNil(decoded.existingWorkspacePath)
        XCTAssertNil(decoded.sessionId)
        XCTAssertEqual(decoded.agent, .cursor)
        XCTAssertTrue(decoded.useWorktree)
    }
}
