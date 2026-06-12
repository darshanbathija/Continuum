import XCTest
@testable import Clawdmeter
import ClawdmeterShared

final class PRPromptResolverTests: XCTestCase {
    func test_instructionsFileURL_prefersContextMarkdownInWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktree = root.appendingPathComponent("wt-feature", isDirectory: true)
        let contextDir = worktree.appendingPathComponent(".context", isDirectory: true)
        try FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
        let instructions = contextDir.appendingPathComponent("PR instructions.md")
        try "Create PR with gh".write(to: instructions, atomically: true, encoding: .utf8)

        let session = AgentSession(
            id: UUID(),
            repoKey: root.path,
            repoDisplayName: "demo",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: worktree.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0,
            runtimeCwd: worktree.path
        )

        XCTAssertEqual(PRPromptResolver.instructionsFileURL(for: session), instructions)
    }

    func test_instructionsFileURL_fallsBackToBundledSkillWhenWorkspaceCopyMissing() {
        let session = AgentSession(
            id: UUID(),
            repoKey: "/tmp/missing-repo",
            repoDisplayName: "demo",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: "/tmp/missing-repo/wt",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0,
            runtimeCwd: "/tmp/missing-repo/wt"
        )

        XCTAssertEqual(
            PRPromptResolver.instructionsFileURL(for: session),
            PRPromptResolver.bundledInstructionsURL()
        )
    }

    func test_bundledInstructionsURL_isPresentInAppBundle() {
        XCTAssertNotNil(PRPromptResolver.bundledInstructionsURL())
    }
}
