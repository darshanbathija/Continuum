import XCTest
@testable import Clawdmeter

@MainActor
final class GitDiffStoreTests: XCTestCase {
    private var repoURL: URL!
    private var git: String!

    override func setUp() async throws {
        try await super.setUp()
        guard let gitPath = ShellRunner.locateBinary("git") else {
            throw XCTSkip("git is required for GitDiffStoreTests")
        }
        git = gitPath
        repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitDiffStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try await runGit(["init"])
        try await runGit(["config", "user.email", "tests@clawdmeter.local"])
        try await runGit(["config", "user.name", "Clawdmeter Tests"])
        try "baseline\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await runGit(["add", "tracked.txt"])
        try await runGit(["commit", "-m", "baseline"])
    }

    override func tearDown() async throws {
        if let repoURL {
            try? FileManager.default.removeItem(at: repoURL)
        }
        try await super.tearDown()
    }

    func test_reloadIncludesUntrackedFilesWithSyntheticPatch() async throws {
        try "one\ntwo\n".write(
            to: repoURL.appendingPathComponent("new file.txt"),
            atomically: true,
            encoding: .utf8
        )
        let store = GitDiffStore(repoCwd: repoURL.path)

        await store.reloadNowForTesting()

        let file = try XCTUnwrap(store.files.first { $0.path == "new file.txt" })
        XCTAssertTrue(file.isNewFile)
        XCTAssertTrue(file.isUntracked)
        XCTAssertEqual(file.changeState, .untracked)
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.hunks.first?.addedCount, 2)
        XCTAssertTrue(file.rawPatch.contains("new file mode 100644"))
    }

    func test_stageFileUsesGitAddForUntrackedFiles() async throws {
        try "stage me\n".write(
            to: repoURL.appendingPathComponent("untracked.swift"),
            atomically: true,
            encoding: .utf8
        )
        let store = GitDiffStore(repoCwd: repoURL.path)
        await store.reloadNowForTesting()
        let file = try XCTUnwrap(store.files.first { $0.path == "untracked.swift" })

        await store.stageFile(file)

        let cached = try await runGit(["diff", "--cached", "--name-only"]).stdoutString
        XCTAssertEqual(cached.trimmingCharacters(in: .whitespacesAndNewlines), "untracked.swift")
    }

    func test_revertFileRemovesUntrackedFiles() async throws {
        let url = repoURL.appendingPathComponent("scratch.txt")
        try "delete me\n".write(to: url, atomically: true, encoding: .utf8)
        let store = GitDiffStore(repoCwd: repoURL.path)
        await store.reloadNowForTesting()
        let file = try XCTUnwrap(store.files.first { $0.path == "scratch.txt" })

        await store.revertFile(file)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_reloadSeparatesStagedAndUnstagedDiffs() async throws {
        try "staged\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await runGit(["add", "tracked.txt"])
        try "unstaged\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let store = GitDiffStore(repoCwd: repoURL.path)

        await store.reloadNowForTesting()

        let tracked = store.files.filter { $0.path == "tracked.txt" }
        XCTAssertEqual(Set(tracked.map(\.changeState)), [.staged, .unstaged])
    }

    func test_revertStagedFileUnstagesInsteadOfHidingChange() async throws {
        try "staged\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await runGit(["add", "tracked.txt"])
        let store = GitDiffStore(repoCwd: repoURL.path)
        await store.reloadNowForTesting()
        let staged = try XCTUnwrap(store.files.first {
            $0.path == "tracked.txt" && $0.changeState == .staged
        })

        await store.revertFile(staged)

        let cached = try await runGit(["diff", "--cached", "--name-only"]).stdoutString
        let unstaged = try await runGit(["diff", "--name-only"]).stdoutString
        XCTAssertTrue(cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(unstaged.trimmingCharacters(in: .whitespacesAndNewlines), "tracked.txt")
    }

    func test_revertUnstagedFileKeepsStagedChangeVisible() async throws {
        try "staged\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await runGit(["add", "tracked.txt"])
        try "unstaged\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let store = GitDiffStore(repoCwd: repoURL.path)
        await store.reloadNowForTesting()
        let unstaged = try XCTUnwrap(store.files.first {
            $0.path == "tracked.txt" && $0.changeState == .unstaged
        })

        await store.revertFile(unstaged)
        await store.reloadNowForTesting()

        let tracked = store.files.filter { $0.path == "tracked.txt" }
        XCTAssertEqual(tracked.map(\.changeState), [.staged])
    }

    func test_gitWatchDirectoryResolvesWorktreeGitFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitDiffStoreWorktree-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        let gitdir = root.appendingPathComponent("actual.git/worktrees/memphis", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try "gitdir: ../actual.git/worktrees/memphis\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            GitDiffStore.gitWatchDirectory(repoCwd: worktree.path),
            gitdir.standardizedFileURL.path
        )
    }

    @discardableResult
    private func runGit(_ arguments: [String]) async throws -> ShellRunner.Result {
        try await ShellRunner.shared.run(
            executable: git,
            arguments: arguments,
            cwd: repoURL.path,
            environment: nil,
            timeout: 20
        )
    }
}
