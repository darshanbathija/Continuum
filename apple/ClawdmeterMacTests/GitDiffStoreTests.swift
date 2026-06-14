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

    func test_stageAndUnstageHunkUseCorrectGitDomains() async throws {
        try "changed\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let store = GitDiffStore(repoCwd: repoURL.path)
        await store.reloadNowForTesting()
        let unstaged = try XCTUnwrap(store.files.first {
            $0.path == "tracked.txt" && $0.changeState == .unstaged
        })
        let unstagedHunk = try XCTUnwrap(unstaged.hunks.first)

        await store.stage(unstagedHunk)

        let cached = try await runGit(["diff", "--cached", "--name-only"]).stdoutString
        let worktree = try await runGit(["diff", "--name-only"]).stdoutString
        XCTAssertEqual(cached.trimmingCharacters(in: .whitespacesAndNewlines), "tracked.txt")
        XCTAssertTrue(worktree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        await store.reloadNowForTesting()
        let staged = try XCTUnwrap(store.files.first {
            $0.path == "tracked.txt" && $0.changeState == .staged
        })
        let stagedHunk = try XCTUnwrap(staged.hunks.first)

        await store.revert(stagedHunk)

        let cachedAfterUnstage = try await runGit(["diff", "--cached", "--name-only"]).stdoutString
        let worktreeAfterUnstage = try await runGit(["diff", "--name-only"]).stdoutString
        XCTAssertTrue(cachedAfterUnstage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(worktreeAfterUnstage.trimmingCharacters(in: .whitespacesAndNewlines), "tracked.txt")
    }

    func test_worktreeDiffFormattingUsesCompactThousands() {
        XCTAssertEqual(WorktreeDiffFormatting.compactCount(18), "18")
        XCTAssertEqual(WorktreeDiffFormatting.compactCount(11000), "11k")
        XCTAssertEqual(WorktreeDiffFormatting.compactCount(1680), "1.7k")
    }

    func test_worktreeDiffTrackerIncludesUncommittedTrackedChanges() async throws {
        let git = try XCTUnwrap(git)
        try "baseline\nlocal fix\n".write(
            to: repoURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tracker = WorktreeDiffTracker(gitLocator: { git })

        await tracker.refresh(paths: [repoURL.path])

        let stat = try XCTUnwrap(tracker.stat(for: repoURL.path))
        // Exactly one added line on top of HEAD — staged and unstaged numstats
        // must not double-count the same change.
        XCTAssertEqual(stat.additions, 1)
        XCTAssertEqual(stat.deletions, 0)
    }

    func test_worktreeDiffTrackerSumsStagedAndUnstagedWithoutOverlap() async throws {
        let git = try XCTUnwrap(git)
        // Stage one new line, then add a second uncommitted line on top.
        try "baseline\nstaged line\n".write(
            to: repoURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await runGit(["add", "tracked.txt"])
        try "baseline\nstaged line\nunstaged line\n".write(
            to: repoURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tracker = WorktreeDiffTracker(gitLocator: { git })

        await tracker.refresh(paths: [repoURL.path])

        let stat = try XCTUnwrap(tracker.stat(for: repoURL.path))
        // Two distinct added lines (one staged, one unstaged) — total 2, not 3+.
        XCTAssertEqual(stat.additions, 2)
        XCTAssertEqual(stat.deletions, 0)
    }

    func test_gitDiffPaneActionDescriptorsExposeStableTargets() {
        let unstagedFile = GitDiffPane.fileActionDescriptors(for: .unstaged)
        XCTAssertEqual(GitDiffPane.FileActionDescriptors.rowAccessibilityIdentifier, "code.diff.git.file.row")
        XCTAssertEqual(GitDiffPane.FileActionDescriptors.toggleAccessibilityIdentifier, "code.diff.git.file.toggle")
        XCTAssertEqual(unstagedFile.stage?.accessibilityIdentifier, "code.diff.git.file.stage")
        XCTAssertEqual(unstagedFile.revert?.accessibilityIdentifier, "code.diff.git.file.revert")
        XCTAssertNil(unstagedFile.unstage)
        XCTAssertNil(unstagedFile.trash)

        let stagedFile = GitDiffPane.fileActionDescriptors(for: .staged)
        XCTAssertEqual(stagedFile.unstage?.title, "Unstage")
        XCTAssertEqual(stagedFile.unstage?.accessibilityIdentifier, "code.diff.git.file.unstage")

        let untrackedFile = GitDiffPane.fileActionDescriptors(for: .untracked)
        XCTAssertEqual(untrackedFile.stage?.accessibilityIdentifier, "code.diff.git.file.stage")
        XCTAssertEqual(untrackedFile.trash?.accessibilityIdentifier, "code.diff.git.file.trash")

        let unstagedHunk = GitDiffPane.hunkActionDescriptors(for: .unstaged)
        XCTAssertEqual(GitDiffPane.HunkActionDescriptors.rowAccessibilityIdentifier, "code.diff.git.hunk.row")
        XCTAssertEqual(unstagedHunk.stage?.accessibilityIdentifier, "code.diff.git.hunk.stage")
        XCTAssertEqual(unstagedHunk.revert?.accessibilityIdentifier, "code.diff.git.hunk.revert")

        let stagedHunk = GitDiffPane.hunkActionDescriptors(for: .staged)
        XCTAssertEqual(stagedHunk.unstage?.accessibilityIdentifier, "code.diff.git.hunk.unstage")

        let emptyMessage = GitDiffPane.commitSheetDescriptor(message: "  ", isCommitting: false)
        XCTAssertEqual(GitDiffPane.CommitSheetDescriptor.openAccessibilityIdentifier, "code.diff.git.commit.open")
        XCTAssertEqual(GitDiffPane.CommitSheetDescriptor.sheetAccessibilityIdentifier, "code.diff.git.commit.sheet")
        XCTAssertEqual(GitDiffPane.CommitSheetDescriptor.messageAccessibilityIdentifier, "code.diff.git.commit.message")
        XCTAssertEqual(GitDiffPane.CommitSheetDescriptor.cancelAccessibilityIdentifier, "code.diff.git.commit.cancel")
        XCTAssertFalse(emptyMessage.submit.isEnabled)

        let ready = GitDiffPane.commitSheetDescriptor(message: "ship diff controls", isCommitting: false)
        XCTAssertEqual(ready.submit.title, "Commit")
        XCTAssertEqual(ready.submit.accessibilityIdentifier, "code.diff.git.commit.submit")
        XCTAssertTrue(ready.submit.isEnabled)

        let committing = GitDiffPane.commitSheetDescriptor(message: "ship diff controls", isCommitting: true)
        XCTAssertEqual(committing.submit.title, "Committing...")
        XCTAssertFalse(committing.submit.isEnabled)
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
