import XCTest
@testable import Clawdmeter
@testable import ClawdmeterShared

/// Track A T8/T9: the resume mechanism. A Claude session that captured a
/// claudeSessionId must respawn with `claude --resume <id>` (continues the
/// conversation after idle-teardown / relaunch / crash); a fresh session
/// (nil id) must NOT carry --resume. This is the single point that makes
/// resume work everywhere it's needed.
final class AgentSpawnerResumeArgvTests: XCTestCase {

    private func claudeSession(claudeSessionId: String?) -> AgentSession {
        let now = Date()
        return AgentSession(
            id: UUID(),
            repoKey: "/tmp/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
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

    func test_capturedSessionId_addsResumeFlag() throws {
        let argv = AgentSpawner.argv(for: claudeSession(claudeSessionId: "sess-xyz"))
        try XCTSkipIf(argv.isEmpty, "claude not on PATH")
        guard let i = argv.firstIndex(of: "--resume") else {
            return XCTFail("argv must contain --resume when claudeSessionId is set: \(argv)")
        }
        XCTAssertEqual(argv[safe: i + 1], "sess-xyz", "--resume must be followed by the captured id")
    }

    func test_freshSession_hasNoResumeFlag() throws {
        let argv = AgentSpawner.argv(for: claudeSession(claudeSessionId: nil))
        try XCTSkipIf(argv.isEmpty, "claude not on PATH")
        XCTAssertFalse(argv.contains("--resume"), "fresh session (nil id) must NOT --resume: \(argv)")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
