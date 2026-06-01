import XCTest
@testable import Clawdmeter

/// Regression coverage for the chat-snapshot JSONL resolver's parent-walk.
///
/// The bug: `resolveSessionFileURL` climbed parent directories with no lower
/// bound. For any session whose own JSONL hadn't been written yet (brand-new
/// session, or a worktree on an unborn branch), the walk reached `$HOME` —
/// whose `~/.claude/projects/-Users-<user>/` dir almost always exists — and
/// returned that unrelated session's newest transcript. A just-spawned
/// session then showed a stranger's conversation.
final class SessionChatStoreResolveURLTests: XCTestCase {

    private func makeRoot() throws -> (home: String, projects: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cont-resolve-\(UUID().uuidString)")
        let home = base.appendingPathComponent("Users/qauser")
        let projects = home.appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return (home.path, projects)
    }

    private func writeJSONL(in projects: URL, encoded: String, name: String) throws {
        let dir = projects.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The regression: a deep session cwd with no project dir of its own must
    /// NOT resolve to `$HOME`'s project dir.
    func test_parentWalkDoesNotClimbToHome() throws {
        let (home, projects) = try makeRoot()
        try writeJSONL(in: projects, encoded: SessionChatStore.encodeCwd(home), name: "foreign.jsonl")
        let cwd = home + "/Clawdmeter/workspaces/qa-123/bergen"
        let resolved = SessionChatStore.resolveSessionFileURL(
            repoCwd: cwd, projectsRoot: projects, homePath: home
        )
        XCTAssertNil(resolved, "a deep session must not resolve to $HOME's foreign transcript")
    }

    /// The session's own cwd resolves to its own JSONL.
    func test_ownCwdResolves() throws {
        let (home, projects) = try makeRoot()
        let cwd = home + "/code/proj"
        try writeJSONL(in: projects, encoded: SessionChatStore.encodeCwd(cwd), name: "own.jsonl")
        let resolved = SessionChatStore.resolveSessionFileURL(
            repoCwd: cwd, projectsRoot: projects, homePath: home
        )
        XCTAssertEqual(resolved?.lastPathComponent, "own.jsonl")
    }

    /// The legit launch-parent case (Claude launched one level above the git
    /// repo, still strictly below home) must still resolve.
    func test_launchParentStrictlyBelowHomeResolves() throws {
        let (home, projects) = try makeRoot()
        let launchDir = home + "/Downloads/CC Watch"
        let cwd = launchDir + "/Clawdmeter"
        try writeJSONL(in: projects, encoded: SessionChatStore.encodeCwd(launchDir), name: "parent.jsonl")
        let resolved = SessionChatStore.resolveSessionFileURL(
            repoCwd: cwd, projectsRoot: projects, homePath: home
        )
        XCTAssertEqual(resolved?.lastPathComponent, "parent.jsonl",
                       "the walk into a strict-descendant launch dir must still work")
    }

    /// A session whose cwd literally IS home should still resolve to home's
    /// own project dir (the bound gates the *climbed* ancestor, not the
    /// initial match).
    func test_cwdEqualsHomeResolvesHome() throws {
        let (home, projects) = try makeRoot()
        try writeJSONL(in: projects, encoded: SessionChatStore.encodeCwd(home), name: "home.jsonl")
        let resolved = SessionChatStore.resolveSessionFileURL(
            repoCwd: home, projectsRoot: projects, homePath: home
        )
        XCTAssertEqual(resolved?.lastPathComponent, "home.jsonl")
    }
}
