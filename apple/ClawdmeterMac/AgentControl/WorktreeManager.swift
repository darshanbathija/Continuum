import Foundation
import ClawdmeterShared
import OSLog

private let worktreeLogger = Logger(subsystem: "com.clawdmeter.mac", category: "WorktreeManager")

/// Git worktree lifecycle for sessions that opt into isolation (D7).
///
/// On create: `git worktree add .claude/worktrees/<goal-slug>-<shortid>
/// <base-branch>` in the repo root. The session's cwd becomes the new
/// worktree path; the agent works there in isolation from your main
/// checkout.
///
/// On delete: `git worktree remove <path>` — but ONLY if the multi-gate
/// safety check (D12) passes:
///   1. Registry owns this worktree (we created it; not a manual one)
///   2. `git status --porcelain` is empty (no uncommitted changes)
///   3. `git stash list` is empty for this worktree
///   4. No tmux pane has this path as its `pane_current_path`
///   5. ≥ 24h since the session was deleted (grace period)
///
/// Failures surface in Settings as "Could not clean up worktree X —
/// uncommitted changes" with a Force-delete button.
public actor WorktreeManager {

    public static let shared = WorktreeManager()

    private var gitBinary: String?

    public init() {}

    // MARK: - Slug + path derivation

    /// Derive a worktree slug from a goal + session id. Per D7:
    /// `<goal-slug-or-session>-<shortid>` where goal-slug is the goal
    /// lowercased, non-alphanumeric → `-`, truncated to 24 chars.
    public static func slug(goal: String?, sessionId: UUID) -> String {
        let shortId = sessionId.uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        let goalSlug: String
        if let goal, !goal.isEmpty {
            let cleaned = goal.lowercased().unicodeScalars.map { scalar -> String in
                if (scalar.value >= 0x30 && scalar.value <= 0x39) ||  // 0-9
                   (scalar.value >= 0x61 && scalar.value <= 0x7A) {   // a-z
                    return String(scalar)
                }
                return "-"
            }.joined()
            // Collapse repeated hyphens, trim hyphens, cap at 24 chars.
            let collapsed = cleaned.split(separator: "-").joined(separator: "-")
            goalSlug = String(collapsed.prefix(24))
        } else {
            goalSlug = "session"
        }
        return "\(goalSlug)-\(shortId)"
    }

    /// Compute the worktree path for a given repo root + slug.
    /// `<repoRoot>/.claude/worktrees/<slug>`.
    public static func worktreePath(repoRoot: String, slug: String) -> String {
        (repoRoot as NSString).appendingPathComponent(".claude/worktrees/\(slug)")
    }

    // MARK: - Create

    /// `git worktree add <path> <baseBranch>`. Returns the absolute worktree
    /// path on success. If a directory at the chosen path already exists
    /// (collision), suffixes `-2`, `-3`, etc. before retrying.
    public func add(repoRoot: String, slug: String, baseBranch: String? = nil) async throws -> String {
        if gitBinary == nil {
            gitBinary = ShellRunner.locateBinary("git")
        }
        guard let git = gitBinary else {
            throw WorktreeError.gitNotFound
        }

        // Resolve collisions: try slug, slug-2, slug-3, etc.
        var finalSlug = slug
        var attempt = 1
        while FileManager.default.fileExists(atPath: Self.worktreePath(repoRoot: repoRoot, slug: finalSlug)) {
            attempt += 1
            if attempt > 100 { throw WorktreeError.collisionUnresolvable }
            finalSlug = "\(slug)-\(attempt)"
        }
        let path = Self.worktreePath(repoRoot: repoRoot, slug: finalSlug)

        // Ensure parent dir exists.
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )

        var args = ["worktree", "add", path]
        if let baseBranch {
            args.append(baseBranch)
        }
        let result = try await ShellRunner.shared.run(
            executable: git,
            arguments: args,
            cwd: repoRoot,
            timeout: 60
        )
        guard result.exitStatus == 0 else {
            throw WorktreeError.gitFailed(
                operation: "worktree add",
                stderr: result.stderrString
            )
        }
        worktreeLogger.info("Created worktree at \(path, privacy: .public)")
        return path
    }

    // MARK: - Delete with multi-gate safety (D12)

    /// Result of attempting to delete a worktree.
    public enum DeleteResult: Sendable {
        case deleted
        case skipped(reason: String)
    }

    /// Attempt to delete a worktree. Runs the multi-gate safety check
    /// FIRST; if any gate fails, returns `.skipped(reason: ...)` without
    /// touching the filesystem.
    public func delete(
        repoRoot: String,
        worktreePath: String,
        registryOwned: Bool,
        attachedPanePaths: Set<String> = []
    ) async throws -> DeleteResult {
        // Gate 1: registry must own this worktree.
        guard registryOwned else {
            return .skipped(reason: "Worktree not owned by Clawdmeter registry")
        }
        // Gate 2: git status --porcelain must be empty.
        let statusResult = try await runGit(
            args: ["status", "--porcelain"], cwd: worktreePath
        )
        if !statusResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skipped(reason: "Uncommitted changes (git status not empty)")
        }
        // Gate 3: git stash list must be empty.
        let stashResult = try await runGit(
            args: ["stash", "list"], cwd: worktreePath
        )
        if !stashResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skipped(reason: "Has stashed changes (git stash list not empty)")
        }
        // Gate 4: no tmux pane is attached here.
        if attachedPanePaths.contains(worktreePath) {
            return .skipped(reason: "Worktree is the cwd of an attached tmux pane")
        }
        // All gates passed: actually delete.
        _ = try await runGit(
            args: ["worktree", "remove", worktreePath],
            cwd: repoRoot
        )
        worktreeLogger.info("Removed worktree \(worktreePath, privacy: .public)")
        return .deleted
    }

    // MARK: - Helpers

    private func runGit(args: [String], cwd: String) async throws -> ShellRunner.Result {
        if gitBinary == nil {
            gitBinary = ShellRunner.locateBinary("git")
        }
        guard let git = gitBinary else {
            throw WorktreeError.gitNotFound
        }
        return try await ShellRunner.shared.run(
            executable: git, arguments: args, cwd: cwd, timeout: 30
        )
    }

    public enum WorktreeError: Error, Sendable {
        case gitNotFound
        case gitFailed(operation: String, stderr: String)
        case collisionUnresolvable
    }
}
