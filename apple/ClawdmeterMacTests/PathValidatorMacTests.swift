import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// v0.7.7 regression suite for the daemon-side path safety predicates.
/// These guard the trust boundary between paired clients and tmux —
/// a regression that re-accepts traversal, control bytes, or symlinks
/// outside the allowlist re-opens the v0.5.x P1-Mac-7 / codex-7 family
/// of vulnerabilities, and nothing in the ClawdmeterShared swift-test
/// suite would catch it (those helpers test the shared `PathValidator`
/// itself; these tests cover the Mac-side delegation site).
///
/// `@MainActor` because the delegates live on `AgentControlServer`
/// which is MainActor-isolated.
@MainActor
final class PathValidatorMacTests: XCTestCase {

    // MARK: - isValidRepoKey

    func test_isValidRepoKey_rejectsEmpty() {
        XCTAssertFalse(AgentControlServer.isValidRepoKey(""))
    }

    func test_isValidRepoKey_rejectsRelativePath() {
        XCTAssertFalse(AgentControlServer.isValidRepoKey("relative/path"))
        XCTAssertFalse(AgentControlServer.isValidRepoKey("./foo"))
        XCTAssertFalse(AgentControlServer.isValidRepoKey("../foo"))
    }

    func test_isValidRepoKey_rejectsTraversalSegments() {
        let home = NSHomeDirectory()
        XCTAssertFalse(AgentControlServer.isValidRepoKey(home + "/foo/../etc"))
        XCTAssertFalse(AgentControlServer.isValidRepoKey(home + "/foo/./bar"))
    }

    func test_isValidRepoKey_rejectsControlBytes() {
        let home = NSHomeDirectory()
        XCTAssertFalse(AgentControlServer.isValidRepoKey(home + "/foo\n/bar"))
        XCTAssertFalse(AgentControlServer.isValidRepoKey(home + "/foo\u{00}/bar"))
        XCTAssertFalse(AgentControlServer.isValidRepoKey(home + "/foo\u{7F}/bar"))
        XCTAssertFalse(AgentControlServer.isValidRepoKey(home + "/foo\r"))
    }

    func test_isValidRepoKey_rejectsPathsOutsideHome() {
        XCTAssertFalse(AgentControlServer.isValidRepoKey("/etc/passwd"))
        XCTAssertFalse(AgentControlServer.isValidRepoKey("/tmp/escape"))
    }

    func test_isValidRepoKey_acceptsValidHomePath() {
        let home = NSHomeDirectory()
        XCTAssertTrue(AgentControlServer.isValidRepoKey(home + "/Development/repo"))
    }

    func test_isValidRepoKey_resolvesSymlinkEscape() throws {
        // Codex-7 regression: a symlink under $HOME pointing outside
        // $HOME must fail closed after symlink resolution.
        let home = NSHomeDirectory()
        let link = home + "/.clawdmeter-test-symlink-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: "/etc"
        )
        defer { try? FileManager.default.removeItem(atPath: link) }
        XCTAssertFalse(
            AgentControlServer.isValidRepoKey(link),
            "Symlink resolving to /etc must be rejected by the home-prefix check."
        )
    }

    func test_safeNewChildPath_rejectsSymlinkParentEscape() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathValidatorMacTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let safeParent = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: safeParent, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        XCTAssertTrue(PathValidator.isSafeNewChildPath(
            safeParent.appendingPathComponent("new.env").path,
            root: root.path
        ))
        XCTAssertFalse(PathValidator.isSafeNewChildPath(
            link.appendingPathComponent("new.env").path,
            root: root.path
        ))
    }

    // MARK: - isValidJsonlPath

    func test_isValidJsonlPath_rejectsRelativeAndTraversal() {
        XCTAssertFalse(AgentControlServer.isValidJsonlPath(""))
        XCTAssertFalse(AgentControlServer.isValidJsonlPath("relative/path.jsonl"))
        let home = NSHomeDirectory()
        XCTAssertFalse(AgentControlServer.isValidJsonlPath(home + "/.claude/projects/../../etc/passwd"))
        XCTAssertFalse(AgentControlServer.isValidJsonlPath(home + "/.claude/projects/./x.jsonl"))
    }

    func test_isValidJsonlPath_rejectsControlBytes() {
        let home = NSHomeDirectory()
        XCTAssertFalse(AgentControlServer.isValidJsonlPath(home + "/.claude/projects/x\n.jsonl"))
        XCTAssertFalse(AgentControlServer.isValidJsonlPath(home + "/.claude/projects/x\u{00}.jsonl"))
        XCTAssertFalse(AgentControlServer.isValidJsonlPath(home + "/.claude/projects/x\u{7F}.jsonl"))
    }

    func test_isValidJsonlPath_rejectsNonAllowlistedRoots() {
        let home = NSHomeDirectory()
        XCTAssertFalse(AgentControlServer.isValidJsonlPath("/etc/passwd"))
        XCTAssertFalse(AgentControlServer.isValidJsonlPath(home + "/Documents/x.jsonl"))
        XCTAssertFalse(AgentControlServer.isValidJsonlPath(home + "/Development/x.jsonl"))
    }

    func test_isValidJsonlPath_acceptsAllowlistedRoots() {
        let home = NSHomeDirectory()
        XCTAssertTrue(AgentControlServer.isValidJsonlPath(home + "/.claude/projects/abc/session.jsonl"))
        XCTAssertTrue(AgentControlServer.isValidJsonlPath(home + "/.codex/sessions/2026/01/x.jsonl"))
        XCTAssertTrue(AgentControlServer.isValidJsonlPath(home + "/.codex/projects/abc/x.jsonl"))
        XCTAssertTrue(AgentControlServer.isValidJsonlPath(home + "/.gemini/sessions/x.jsonl"))
    }
}
