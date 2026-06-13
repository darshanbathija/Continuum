import Foundation
import ClawdmeterShared
import OSLog
import Darwin

private let worktreeLogger = Logger(subsystem: "com.clawdmeter.mac", category: "WorktreeManager")

private final class WorktreeDataBox: @unchecked Sendable {
    var data = Data()
}

/// Git worktree lifecycle for sessions that opt into isolation (D7).
///
/// On create: `git worktree add ~/Clawdmeter/workspaces/<project>/<city>
/// <base-branch>`. The session's cwd becomes the new worktree path; the
/// agent works there in isolation from your main checkout.
///
/// On delete: `git worktree remove <path>` — but ONLY if the multi-gate
/// safety check (D12) passes:
///   1. Registry owns this worktree (we created it; not a manual one)
///   2. `git status --porcelain` is empty (no uncommitted changes)
///   3. `git stash list` is empty for this worktree
    ///   4. No attached terminal/process is using this path as cwd
///   5. ≥ 24h since the session was deleted (grace period)
///
/// Failures surface in Settings as "Could not clean up worktree X —
/// uncommitted changes" with a Force-delete button.
public actor WorktreeManager {

    public static let shared = WorktreeManager()

    private var gitBinary: String?
    private let workspaceStorageRoot: String

    public struct ProvisionedWorktree: Sendable {
        public let path: String
        public let branchName: String?
        public let metadata: WorktreeProvisioningMetadata
    }

    public struct WorktreeLayout: Sendable, Equatable {
        public let storageRoot: String
        public let projectSlug: String
        public let workspaceSlug: String
        public let projectRoot: String
        public let path: String
        public let branchAliasPath: String?
    }

    /// Result of renaming a worktree's display folder and git branch together.
    public struct RenamedWorktree: Sendable {
        public let oldPath: String
        public let newPath: String
        public let oldBranchName: String?
        public let newBranchName: String?
        public let workspaceSlug: String
        public let branchAliasPath: String?
    }

    private struct AddedWorktree: Sendable {
        let path: String
        let branchName: String?
        let layout: WorktreeLayout
    }

    private struct OwnershipMarker: Codable {
        let version: Int
        let markerId: String
        let repoRoot: String
        let worktreePath: String
        let branchName: String?
        let storageRoot: String?
        let projectSlug: String?
        let workspaceSlug: String?
        let branchAliasPath: String?
        let createdAt: Date
    }

    private struct CopyManifest: Codable {
        struct Skipped: Codable {
            let path: String
            let reason: String
        }

        struct Entry: Codable {
            enum Kind: String, Codable {
                case file
                case directory
            }

            let path: String
            let kind: Kind
            let size: Int64?
            let modificationTime: TimeInterval?

            var copiedPath: String {
                kind == .directory ? path + "/" : path
            }
        }

        let version: Int
        let markerId: String
        let repoRoot: String
        let worktreePath: String
        let source: WorktreeFileCopyPatternSource
        let mode: WorkspaceFilesToCopyMode?
        let patterns: [String]
        let copied: [String]
        let entries: [Entry]
        let skipped: [Skipped]
        let copiedBytes: Int64
        let createdAt: Date

        init(
            version: Int,
            markerId: String,
            repoRoot: String,
            worktreePath: String,
            source: WorktreeFileCopyPatternSource,
            mode: WorkspaceFilesToCopyMode?,
            patterns: [String],
            entries: [Entry],
            skipped: [Skipped],
            copiedBytes: Int64,
            createdAt: Date
        ) {
            self.version = version
            self.markerId = markerId
            self.repoRoot = repoRoot
            self.worktreePath = worktreePath
            self.source = source
            self.mode = mode
            self.patterns = patterns
            self.entries = entries
            self.copied = entries.map(\.copiedPath)
            self.skipped = skipped
            self.copiedBytes = copiedBytes
            self.createdAt = createdAt
        }

        private enum CodingKeys: String, CodingKey {
            case version, markerId, repoRoot, worktreePath, source, mode, patterns
            case copied, entries, skipped, copiedBytes, createdAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            markerId = try c.decode(String.self, forKey: .markerId)
            repoRoot = try c.decode(String.self, forKey: .repoRoot)
            worktreePath = try c.decode(String.self, forKey: .worktreePath)
            source = try c.decode(WorktreeFileCopyPatternSource.self, forKey: .source)
            mode = try c.decodeIfPresent(WorkspaceFilesToCopyMode.self, forKey: .mode)
            patterns = try c.decode([String].self, forKey: .patterns)
            let decodedCopied = try c.decodeIfPresent([String].self, forKey: .copied) ?? []
            entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? decodedCopied.map { raw in
                let normalized = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
                return Entry(
                    path: normalized,
                    kind: raw.hasSuffix("/") ? .directory : .file,
                    size: nil,
                    modificationTime: nil
                )
            }
            copied = decodedCopied.isEmpty ? entries.map(\.copiedPath) : decodedCopied
            skipped = try c.decode([Skipped].self, forKey: .skipped)
            copiedBytes = try c.decode(Int64.self, forKey: .copiedBytes)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
        }
    }

    private struct ResolvedCopyPlan {
        let source: WorktreeFileCopyPatternSource
        let mode: WorkspaceFilesToCopyMode
        let patterns: [String]
    }

    private struct CopyCandidate {
        enum Kind { case file, directory }
        let relativePath: String
        let kind: Kind
        let size: Int64
        let fingerprint: SourceFingerprint?
    }

    private struct SourceFingerprint: Equatable {
        let size: Int64
        let modificationTime: TimeInterval?
    }

    private struct SQLiteGroupSnapshot: Equatable {
        let paths: Set<String>
        let fingerprints: [String: SourceFingerprint]
    }

    private static let markerFileName = "clawdmeter-worktree.json"
    private static let manifestFileName = "clawdmeter-files-to-copy-manifest.json"

    public init(workspaceStorageRoot: String? = nil) {
        self.workspaceStorageRoot = workspaceStorageRoot ?? Self.defaultWorkspaceStorageRoot()
    }

    // MARK: - Slug + path derivation

    /// v0.7.9: derive a worktree slug from a city name (assigned via
    /// `CityNamer.shared.cityName(for:)`). Multi-word cities collapse
    /// to kebab-case: "Cape Town" → "cape-town", "São Paulo" → "sao-paulo".
    /// Stable, unique per session because CityNamer guarantees uniqueness
    /// across live assignments.
    public static func slug(city: String) -> String {
        // Lowercase + map non-[a-z0-9] to '-' so both worktree path and
        // git branch name are filesystem- and ref-safe. Diacritics get
        // folded via `String.applyingTransform(.stripDiacritics)` first.
        let folded = city
            .applyingTransform(.stripDiacritics, reverse: false) ?? city
        let cleaned = folded.lowercased().unicodeScalars.map { scalar -> String in
            if (scalar.value >= 0x30 && scalar.value <= 0x39) ||  // 0-9
               (scalar.value >= 0x61 && scalar.value <= 0x7A) {   // a-z
                return String(scalar)
            }
            return "-"
        }.joined()
        let collapsed = cleaned.split(separator: "-").joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "session" : trimmed
    }

    /// Legacy slug derivation (goal + session-id-shortid). Kept for
    /// back-compat with code paths that haven't been migrated to the
    /// city-named worktrees yet; new spawns should call `slug(city:)`.
    /// Derive a git-safe branch name from a user-supplied rename label.
    /// Preserves an existing slash prefix (`user/feature` → `user/new-name`).
    public static func renamedBranchName(currentBranch: String?, newDisplayName: String) -> String {
        let slug = slug(city: newDisplayName)
        guard let current = currentBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty
        else { return slug }
        if let slash = current.lastIndex(of: "/") {
            let prefix = String(current[..<slash])
            return "\(prefix)/\(slug)"
        }
        return slug
    }

    /// Replace the last path component with a slug derived from `newDisplayName`.
    public static func renamedWorktreePath(currentPath: String, newDisplayName: String) -> String {
        let slug = slug(city: newDisplayName)
        let parent = (currentPath as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent(slug)
    }

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
    /// `~/Clawdmeter/workspaces/<project>/<slug>`.
    public static func worktreePath(
        repoRoot: String,
        slug: String,
        storageRoot: String? = nil
    ) -> String {
        let root = storageRoot ?? defaultWorkspaceStorageRoot()
        let project = projectFolderSlug(fromRepoRoot: repoRoot)
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .path
    }

    public static func defaultWorkspaceStorageRoot(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
            .path
    }

    public static func projectFolderSlug(fromRepoRoot repoRoot: String) -> String {
        let last = (repoRoot as NSString).lastPathComponent
        return folderSlug(last.isEmpty ? "Project" : last)
    }

    private static func layout(
        storageRoot: String,
        projectSlug: String,
        workspaceSlug: String,
        branchName: String?
    ) -> WorktreeLayout {
        let projectRoot = URL(fileURLWithPath: storageRoot, isDirectory: true)
            .appendingPathComponent(projectSlug, isDirectory: true)
            .path
        let path = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(workspaceSlug, isDirectory: true)
            .path
        let aliasName = branchName.map(branchAliasName)
        let aliasPath = aliasName.flatMap { name -> String? in
            guard name != workspaceSlug else { return nil }
            return URL(fileURLWithPath: projectRoot, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
        }
        return WorktreeLayout(
            storageRoot: storageRoot,
            projectSlug: projectSlug,
            workspaceSlug: workspaceSlug,
            projectRoot: projectRoot,
            path: path,
            branchAliasPath: aliasPath
        )
    }

    private static func folderSlug(_ value: String) -> String {
        let folded = value.applyingTransform(.stripDiacritics, reverse: false) ?? value
        let cleaned = folded.unicodeScalars.map { scalar -> String in
            let v = scalar.value
            if (v >= 0x30 && v <= 0x39) ||
               (v >= 0x41 && v <= 0x5A) ||
               (v >= 0x61 && v <= 0x7A) ||
               scalar == "-" || scalar == "_" || scalar == "." {
                return String(scalar)
            }
            return "-"
        }.joined()
        let collapsed = cleaned.split(separator: "-").joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "Project" : String(trimmed.prefix(80))
    }

    private static func branchAliasName(_ branchName: String) -> String {
        folderSlug(branchName.replacingOccurrences(of: "/", with: "-"))
    }

    // MARK: - Create

    /// `git worktree add <path> [<baseBranch>]` — or, when `branchName`
    /// is supplied, `git worktree add -b <branchName> <path> [<baseBranch>]`
    /// to create a new branch off the base. Returns the absolute
    /// worktree path on success. If a directory at the chosen path
    /// already exists (collision), suffixes `-2`, `-3`, etc. before
    /// retrying.
    ///
    /// v0.7.9: callers pass `branchName` so the worktree's branch is
    /// named after the session's assigned city (e.g. `cape-town`)
    /// instead of `HEAD-detached-at-<sha>`. Branch shows up in
    /// `git branch` output + on the PR creation path.
    public func add(
        repoRoot: String,
        slug: String,
        branchName: String? = nil,
        baseBranch: String? = nil
    ) async throws -> String {
        try await addWithLayout(
            repoRoot: repoRoot,
            slug: slug,
            branchName: branchName,
            baseBranch: baseBranch
        ).path
    }

    private func addWithLayout(
        repoRoot: String,
        slug: String,
        branchName: String? = nil,
        baseBranch: String? = nil
    ) async throws -> AddedWorktree {
        if gitBinary == nil {
            gitBinary = ShellRunner.locateBinary("git")
        }
        guard let git = gitBinary else {
            throw WorktreeError.gitNotFound
        }

        let projectSlug = try await resolveProjectSlug(repoRoot: repoRoot)
        let projectRoot = URL(fileURLWithPath: workspaceStorageRoot, isDirectory: true)
            .appendingPathComponent(projectSlug, isDirectory: true)
            .path

        // Resolve path and branch collisions together: try slug, slug-2, etc.
        var attempt = 1
        var finalSlug = slug
        var finalBranchName = branchName
        while true {
            let path = Self.layout(
                storageRoot: workspaceStorageRoot,
                projectSlug: projectSlug,
                workspaceSlug: finalSlug,
                branchName: finalBranchName
            ).path
            let pathExists = FileManager.default.fileExists(atPath: path)
            let branchExists: Bool
            if let bn = finalBranchName {
                let listResult = try await ShellRunner.shared.run(
                    executable: git,
                    arguments: ["branch", "--list", bn],
                    cwd: repoRoot,
                    timeout: 10
                )
                branchExists = !listResult.stdoutString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            } else {
                branchExists = false
            }
            if !pathExists && !branchExists { break }
            attempt += 1
            if attempt > 100 { throw WorktreeError.collisionUnresolvable }
            finalSlug = "\(slug)-\(attempt)"
            if let branchName {
                finalBranchName = "\(branchName)-\(attempt)"
            }
        }
        let layout = Self.layout(
            storageRoot: workspaceStorageRoot,
            projectSlug: projectSlug,
            workspaceSlug: finalSlug,
            branchName: finalBranchName
        )
        let path = layout.path

        // Ensure parent dir exists.
        try FileManager.default.createDirectory(
            atPath: projectRoot, withIntermediateDirectories: true
        )

        var args: [String] = ["worktree", "add"]
        if let bn = finalBranchName {
            args.append(contentsOf: ["-b", bn])
        }
        args.append(path)
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
        worktreeLogger.info("Created worktree at \(path, privacy: .public) branch=\(finalBranchName ?? "(checked-out)", privacy: .public)")
        let alias = createBranchAlias(layout: layout, worktreePath: path)
        let recordedLayout = WorktreeLayout(
            storageRoot: layout.storageRoot,
            projectSlug: layout.projectSlug,
            workspaceSlug: layout.workspaceSlug,
            projectRoot: layout.projectRoot,
            path: layout.path,
            branchAliasPath: alias
        )
        return AddedWorktree(path: path, branchName: finalBranchName, layout: recordedLayout)
    }

    /// Create an owned worktree and apply Conductor-style "Files to copy"
    /// before any provider runtime starts inside it.
    /// Real provisioning milestones, emitted at each step boundary so the UI can
    /// render a live "Setup Trail" that confirms each stage with a fact (branch
    /// name, files-copied count, setup ran). Observability only — never affects
    /// provisioning correctness.
    public enum ProvisionPhase: Sendable {
        case worktreeReady(branch: String)
        case copyingFiles
        case filesCopied(count: Int, noop: Bool)
        case runningSetup
        case setupFinished
        case setupSkipped
    }

    public func provision(
        repoRoot: String,
        slug: String,
        branchName: String? = nil,
        baseBranch: String? = nil,
        filesToCopy: WorkspaceFilesToCopySettings = WorkspaceFilesToCopySettings(),
        setupScript: String? = nil,
        onPhase: (@Sendable (ProvisionPhase) -> Void)? = nil
    ) async throws -> ProvisionedWorktree {
        let added = try await addWithLayout(
            repoRoot: repoRoot,
            slug: slug,
            branchName: branchName,
            baseBranch: baseBranch
        )
        let path = added.path
        let markerId = UUID().uuidString
        do {
            let branch = try await currentBranch(cwd: path)
            onPhase?(.worktreeReady(branch: branch ?? slug))
            let gitDir = try await absoluteGitDir(cwd: path)
            try writeOwnershipMarker(
                gitDir: gitDir,
                marker: OwnershipMarker(
                    version: 1,
                    markerId: markerId,
                    repoRoot: repoRoot,
                    worktreePath: path,
                    branchName: branch,
                    storageRoot: added.layout.storageRoot,
                    projectSlug: added.layout.projectSlug,
                    workspaceSlug: added.layout.workspaceSlug,
                    branchAliasPath: added.layout.branchAliasPath,
                    createdAt: Date()
                )
            )
            // Files-to-copy is a best-effort convenience (Conductor's "Files
            // to copy"), NOT a precondition for the session. A repo with a huge
            // gitignored tree (node_modules, .next, …) trips the copy cap and
            // throws — which previously failed the ENTIRE spawn, the symptom
            // users hit as "the + button creates a branch but never starts a
            // session." Degrade gracefully: log, record the failure in the
            // summary, and keep the worktree + agent. The worktree + ownership
            // marker are already written above, so cleanup still works later.
            let summary: WorktreeFileCopySummary
            onPhase?(.copyingFiles)
            do {
                summary = try await copyConfiguredFiles(
                    repoRoot: repoRoot,
                    worktreePath: path,
                    gitDir: gitDir,
                    markerId: markerId,
                    settings: filesToCopy
                )
            } catch {
                worktreeLogger.error("files-to-copy skipped (non-fatal) for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                summary = WorktreeFileCopySummary(
                    source: .disabled,
                    mode: filesToCopy.mode,
                    patterns: [],
                    failureSummary: "Skipped — \(error.localizedDescription)"
                )
            }
            onPhase?(.filesCopied(count: summary.copiedFileCount, noop: summary.copiedFileCount == 0))
            // Conductor parity: run the per-repo Setup Script INSIDE the fresh
            // worktree before the agent starts (e.g. `npm install`, or symlink
            // node_modules from $CONTINUUM_REPO_ROOT). Non-fatal — a failed
            // setup must never block the session; we log and proceed.
            if let setupScript,
               !setupScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onPhase?(.runningSetup)
                await runSetupScript(setupScript, worktreePath: path, repoRoot: repoRoot, branch: branch)
                onPhase?(.setupFinished)
            } else {
                onPhase?(.setupSkipped)
            }
            let metadata = WorktreeProvisioningMetadata(
                ownershipMarkerId: markerId,
                branchName: branch,
                worktreePath: path,
                storageRoot: added.layout.storageRoot,
                projectSlug: added.layout.projectSlug,
                workspaceSlug: added.layout.workspaceSlug,
                branchAliasPath: added.layout.branchAliasPath,
                filesToCopy: summary
            )
            return ProvisionedWorktree(path: path, branchName: branch, metadata: metadata)
        } catch {
            _ = try? await cleanupProvisionedWorktree(
                repoRoot: repoRoot,
                worktreePath: path,
                expectedMarkerId: markerId,
                attachedPanePaths: []
            )
            throw error
        }
    }

    /// Run the per-repo Setup Script in a freshly-provisioned worktree.
    /// NEVER throws — setup is a convenience, not a precondition for the
    /// session. Runs under a login zsh (real PATH via SpawnPathResolver) with
    /// the worktree as cwd and CONTINUUM_WORKTREE / CONTINUUM_REPO_ROOT /
    /// CONTINUUM_BRANCH exported, so the script can install deps or symlink
    /// caches (e.g. `ln -s "$CONTINUUM_REPO_ROOT/node_modules" node_modules`).
    private func runSetupScript(
        _ script: String,
        worktreePath: String,
        repoRoot: String,
        branch: String?
    ) async {
        worktreeLogger.info("Running setup script in \(worktreePath, privacy: .public)")
        // Seed from the app's real environment (HOME, USER, SHELL, TMPDIR,
        // LANG, …) BEFORE enriching PATH. ShellRunner REPLACES the child env
        // with this dict, so a bare [CONTINUUM_*] would strip $HOME and break
        // npm/pnpm cache + config, `~` expansion, and ~/.zshrc shims
        // (nvm / asdf / rbenv) — i.e. the whole point of a setup script.
        // CONTINUUM_* override last.
        var env = SpawnPathResolver.merged(into: ProcessInfo.processInfo.environment)
        env["CONTINUUM_WORKTREE"] = worktreePath
        env["CONTINUUM_REPO_ROOT"] = repoRoot
        env["CONTINUUM_BRANCH"] = branch ?? ""
        do {
            // 10-minute ceiling: long enough for a cold `npm install`, bounded
            // so a hung setup doesn't strand the session forever.
            let result = try await ShellRunner.shared.run(
                executable: "/bin/zsh",
                arguments: ["-lc", script],
                cwd: worktreePath,
                environment: env,
                timeout: 600
            )
            if result.exitStatus == 0 {
                worktreeLogger.info("Setup script completed for \(worktreePath, privacy: .public)")
            } else {
                let tail = String(result.stderrString.suffix(500))
                worktreeLogger.error("Setup script exited \(result.exitStatus, privacy: .public) for \(worktreePath, privacy: .public): \(tail, privacy: .public)")
            }
        } catch {
            worktreeLogger.error("Setup script failed (non-fatal) for \(worktreePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
        let marker = try? readOwnershipMarker(worktreePath: worktreePath)
        // Gate 2: git status --porcelain --ignored must be empty after
        // manifest-owned files are removed. This preserves unrelated
        // untracked or ignored files a user created inside the worktree.
        try? cleanupCopiedFiles(worktreePath: worktreePath, expectedMarkerId: nil)
        let statusResult = try await runGit(
            args: ["status", "--porcelain", "--ignored"], cwd: worktreePath
        )
        if !statusResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skipped(reason: "Uncommitted or untracked files (git status not empty)")
        }
        // Gate 3: git stash list must be empty.
        let stashResult = try await runGit(
            args: ["stash", "list"], cwd: worktreePath
        )
        if !stashResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skipped(reason: "Has stashed changes (git stash list not empty)")
        }
        // Gate 4: no attached terminal/process is using this path.
        if attachedPanePaths.contains(worktreePath) {
            return .skipped(reason: "Worktree is the cwd of an attached terminal")
        }
        // All gates passed: actually delete.
        let removeResult = try await runGit(
            args: ["worktree", "remove", worktreePath],
            cwd: repoRoot
        )
        if let reason = Self.worktreeRemoveFailureReason(removeResult) {
            return .skipped(reason: reason)
        }
        removeBranchAliasIfOwned(marker: marker, worktreePath: worktreePath)
        worktreeLogger.info("Removed worktree \(worktreePath, privacy: .public)")
        return .deleted
    }

    public func cleanupProvisionedWorktree(
        repoRoot: String,
        worktreePath: String,
        expectedMarkerId: String?,
        attachedPanePaths: Set<String> = []
    ) async throws -> DeleteResult {
        if let expectedMarkerId {
            try cleanupCopiedFiles(worktreePath: worktreePath, expectedMarkerId: expectedMarkerId)
        } else {
            try? cleanupCopiedFiles(worktreePath: worktreePath, expectedMarkerId: nil)
        }
        return try await delete(
            repoRoot: repoRoot,
            worktreePath: worktreePath,
            registryOwned: true,
            attachedPanePaths: attachedPanePaths
        )
    }

    public func hasOwnershipMarker(worktreePath: String, markerId: String) async -> Bool {
        do {
            let marker = try readOwnershipMarker(worktreePath: worktreePath)
            return marker.markerId == markerId && marker.worktreePath == worktreePath
        } catch {
            return false
        }
    }

    /// Move a worktree's checkout to the macOS Trash (recoverable) and prune
    /// git's now-stale worktree entry. Used by Archive to reclaim disk.
    ///
    /// Differs from `delete` on purpose: NO clean-tree gate (the user opted into
    /// "trash as-is" — Trash keeps it recoverable), and the BRANCH is left fully
    /// intact, so committed work survives in the main repo's object store and
    /// `reprovision` can re-check-it-out on unarchive. Best-effort; a Trash
    /// failure leaves the worktree in place rather than throwing.
    @discardableResult
    public func trashWorktree(repoRoot: String, worktreePath: String) async -> DeleteResult {
        // Guard against trashing the main repo or a path outside our managed
        // workspace root — only ever Trash Clawdmeter-provisioned worktrees.
        guard worktreePath.contains("/Clawdmeter/workspaces/"),
              worktreePath != repoRoot else {
            return .skipped(reason: "Path is not a Clawdmeter-managed worktree")
        }
        if FileManager.default.fileExists(atPath: worktreePath) {
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: worktreePath), resultingItemURL: &trashed
                )
            } catch {
                worktreeLogger.warning("trashItem failed \(worktreePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .skipped(reason: "Could not move worktree to Trash: \(error.localizedDescription)")
            }
        }
        // `.git/worktrees/<name>` now points at a missing dir; prune so the
        // branch can be re-checked-out later without "already checked out".
        _ = try? await runGit(args: ["worktree", "prune"], cwd: repoRoot)
        worktreeLogger.info("Trashed worktree \(worktreePath, privacy: .public)")
        return .deleted
    }

    /// Rename a worktree's sidebar label folder and its checked-out git branch.
    /// Clawdmeter-managed worktrees move under `~/Clawdmeter/workspaces/…`;
    /// Conductor-style paths (`…/conductor/workspaces/<repo>/<slug>`) swap the
    /// last folder component. Ownership markers + branch alias symlinks are
    /// updated when present.
    public func renameWorktree(
        repoRoot: String,
        worktreePath: String,
        newDisplayName: String
    ) async throws -> RenamedWorktree {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorktreeError.invalidName
        }

        let oldPath = WorkspaceKey.canonicalPath(worktreePath)
        let currentBranch = try await currentBranch(cwd: oldPath)
        let newBranchName = Self.renamedBranchName(
            currentBranch: currentBranch,
            newDisplayName: trimmed
        )
        let marker = try? readOwnershipMarker(worktreePath: oldPath)

        let newPath: String
        if let marker,
           let storageRoot = marker.storageRoot,
           let projectSlug = marker.projectSlug {
            let workspaceSlug = Self.slug(city: trimmed)
            newPath = Self.layout(
                storageRoot: storageRoot,
                projectSlug: projectSlug,
                workspaceSlug: workspaceSlug,
                branchName: newBranchName
            ).path
        } else {
            newPath = WorkspaceKey.canonicalPath(
                Self.renamedWorktreePath(currentPath: oldPath, newDisplayName: trimmed)
            )
        }

        if newPath == oldPath && newBranchName == currentBranch {
            return RenamedWorktree(
                oldPath: oldPath,
                newPath: oldPath,
                oldBranchName: currentBranch,
                newBranchName: currentBranch,
                workspaceSlug: (oldPath as NSString).lastPathComponent,
                branchAliasPath: marker?.branchAliasPath
            )
        }

        if newPath != oldPath && FileManager.default.fileExists(atPath: newPath) {
            throw WorktreeError.collisionUnresolvable
        }
        if newBranchName != currentBranch {
            let listResult = try await runGit(args: ["branch", "--list", newBranchName], cwd: repoRoot)
            let listed = listResult.stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !listed.isEmpty {
                throw WorktreeError.collisionUnresolvable
            }
        }

        if newBranchName != currentBranch {
            let branchResult = try await runGit(args: ["branch", "-m", newBranchName], cwd: oldPath)
            guard branchResult.exitStatus == 0 else {
                throw WorktreeError.gitFailed(operation: "branch -m", stderr: branchResult.stderrString)
            }
        }

        if marker != nil {
            removeBranchAliasIfOwned(marker: marker, worktreePath: oldPath)
        }

        if newPath != oldPath {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: newPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let moveResult = try await runGit(args: ["worktree", "move", oldPath, newPath], cwd: repoRoot)
            guard moveResult.exitStatus == 0 else {
                throw WorktreeError.gitFailed(operation: "worktree move", stderr: moveResult.stderrString)
            }
        }

        var branchAliasPath: String? = marker?.branchAliasPath
        let workspaceSlug = (newPath as NSString).lastPathComponent
        if let marker {
            let layout = Self.layout(
                storageRoot: marker.storageRoot ?? workspaceStorageRoot,
                projectSlug: marker.projectSlug ?? Self.projectFolderSlug(fromRepoRoot: repoRoot),
                workspaceSlug: workspaceSlug,
                branchName: newBranchName
            )
            let alias = createBranchAlias(layout: layout, worktreePath: newPath)
            let recordedLayout = WorktreeLayout(
                storageRoot: layout.storageRoot,
                projectSlug: layout.projectSlug,
                workspaceSlug: layout.workspaceSlug,
                projectRoot: layout.projectRoot,
                path: layout.path,
                branchAliasPath: alias
            )
            branchAliasPath = recordedLayout.branchAliasPath
            let gitDir = try await absoluteGitDir(cwd: newPath)
            try writeOwnershipMarker(
                gitDir: gitDir,
                marker: OwnershipMarker(
                    version: marker.version,
                    markerId: marker.markerId,
                    repoRoot: marker.repoRoot,
                    worktreePath: newPath,
                    branchName: newBranchName,
                    storageRoot: recordedLayout.storageRoot,
                    projectSlug: recordedLayout.projectSlug,
                    workspaceSlug: recordedLayout.workspaceSlug,
                    branchAliasPath: recordedLayout.branchAliasPath,
                    createdAt: marker.createdAt
                )
            )
        }

        worktreeLogger.info(
            "Renamed worktree \(oldPath, privacy: .public) → \(newPath, privacy: .public) branch=\(newBranchName, privacy: .public)"
        )
        return RenamedWorktree(
            oldPath: oldPath,
            newPath: newPath,
            oldBranchName: currentBranch,
            newBranchName: newBranchName,
            workspaceSlug: workspaceSlug,
            branchAliasPath: branchAliasPath
        )
    }

    /// Re-check-out a previously-trashed worktree at its original path from its
    /// (still-present) branch — the unarchive counterpart to `trashWorktree`.
    /// Returns true on success. No-op success if the path already exists.
    public func reprovision(repoRoot: String, worktreePath: String, branchName: String) async -> Bool {
        if FileManager.default.fileExists(atPath: worktreePath) { return true }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: worktreePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Belt-and-suspenders: prune any stale entry so `add` won't refuse.
        _ = try? await runGit(args: ["worktree", "prune"], cwd: repoRoot)
        let result = try? await runGit(
            args: ["worktree", "add", worktreePath, branchName], cwd: repoRoot
        )
        let ok = (result?.exitStatus == 0)
        if !ok {
            worktreeLogger.warning("reprovision failed \(worktreePath, privacy: .public): \(result?.stderrString.prefix(200) ?? "", privacy: .public)")
        }
        return ok
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

    internal nonisolated static func worktreeRemoveFailureReason(_ result: ShellRunner.Result) -> String? {
        guard result.exitStatus != 0 else { return nil }
        let detail = result.stderrString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(300)
        if detail.isEmpty {
            return "git worktree remove failed with exit status \(result.exitStatus)"
        }
        return "git worktree remove failed: \(detail)"
    }

    private func currentBranch(cwd: String) async throws -> String? {
        let result = try await runGit(args: ["branch", "--show-current"], cwd: cwd)
        guard result.exitStatus == 0 else { return nil }
        let branch = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    private func resolveProjectSlug(repoRoot: String) async throws -> String {
        let result = try await runGit(args: ["rev-parse", "--git-common-dir"], cwd: repoRoot)
        if result.exitStatus == 0 {
            let raw = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                let commonDir: String
                if raw.hasPrefix("/") {
                    commonDir = raw
                } else {
                    commonDir = URL(fileURLWithPath: repoRoot, isDirectory: true)
                        .appendingPathComponent(raw, isDirectory: true)
                        .standardizedFileURL
                        .path
                }
                let commonURL = URL(fileURLWithPath: commonDir, isDirectory: true)
                let projectURL: URL
                if commonURL.lastPathComponent == ".git" {
                    projectURL = commonURL.deletingLastPathComponent()
                } else {
                    projectURL = commonURL
                }
                let name = projectURL.lastPathComponent
                if !name.isEmpty {
                    return Self.folderSlug(name)
                }
            }
        }
        return Self.projectFolderSlug(fromRepoRoot: repoRoot)
    }

    private func absoluteGitDir(cwd: String) async throws -> String {
        let result = try await runGit(args: ["rev-parse", "--absolute-git-dir"], cwd: cwd)
        guard result.exitStatus == 0 else {
            throw WorktreeError.gitFailed(operation: "rev-parse --absolute-git-dir", stderr: result.stderrString)
        }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw WorktreeError.gitFailed(operation: "rev-parse --absolute-git-dir", stderr: "empty git dir")
        }
        return path
    }

    private func createBranchAlias(layout: WorktreeLayout, worktreePath: String) -> String? {
        guard let initial = layout.branchAliasPath else { return nil }
        let fm = FileManager.default
        let base = (initial as NSString).lastPathComponent
        let projectRoot = (initial as NSString).deletingLastPathComponent
        for attempt in 1...100 {
            let aliasPath = attempt == 1
                ? initial
                : URL(fileURLWithPath: projectRoot, isDirectory: true)
                    .appendingPathComponent("\(base)-\(attempt)", isDirectory: false)
                    .path
            if let existingTarget = try? fm.destinationOfSymbolicLink(atPath: aliasPath) {
                let resolved = URL(fileURLWithPath: existingTarget, relativeTo: URL(fileURLWithPath: projectRoot, isDirectory: true))
                    .standardizedFileURL
                    .path
                if resolved == worktreePath { return aliasPath }
                continue
            }
            guard !fm.fileExists(atPath: aliasPath) else { continue }
            do {
                try fm.createSymbolicLink(atPath: aliasPath, withDestinationPath: worktreePath)
                return aliasPath
            } catch {
                worktreeLogger.warning("Failed to create branch alias \(aliasPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    private func removeBranchAliasIfOwned(marker: OwnershipMarker?, worktreePath: String) {
        guard let aliasPath = marker?.branchAliasPath else { return }
        let projectRoot = (aliasPath as NSString).deletingLastPathComponent
        guard let existingTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: aliasPath) else { return }
        let resolved = URL(fileURLWithPath: existingTarget, relativeTo: URL(fileURLWithPath: projectRoot, isDirectory: true))
            .standardizedFileURL
            .path
        guard resolved == worktreePath else { return }
        try? FileManager.default.removeItem(atPath: aliasPath)
    }

    private func markerURL(gitDir: String) -> URL {
        URL(fileURLWithPath: gitDir, isDirectory: true).appendingPathComponent(Self.markerFileName)
    }

    private func manifestURL(gitDir: String) -> URL {
        URL(fileURLWithPath: gitDir, isDirectory: true).appendingPathComponent(Self.manifestFileName)
    }

    private func writeOwnershipMarker(gitDir: String, marker: OwnershipMarker) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: markerURL(gitDir: gitDir), options: [.atomic])
    }

    private func readOwnershipMarker(worktreePath: String) throws -> OwnershipMarker {
        let gitDir = try blockingAbsoluteGitDir(cwd: worktreePath)
        let data = try Data(contentsOf: markerURL(gitDir: gitDir))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OwnershipMarker.self, from: data)
    }

    private func blockingAbsoluteGitDir(cwd: String) throws -> String {
        guard let git = gitBinary ?? ShellRunner.locateBinary("git") else {
            throw WorktreeError.gitNotFound
        }
        gitBinary = git
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["rev-parse", "--absolute-git-dir"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw WorktreeError.gitFailed(operation: "rev-parse --absolute-git-dir", stderr: err)
        }
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw WorktreeError.gitFailed(operation: "rev-parse --absolute-git-dir", stderr: "empty git dir")
        }
        return path
    }

    private func copyConfiguredFiles(
        repoRoot: String,
        worktreePath: String,
        gitDir: String,
        markerId: String,
        settings: WorkspaceFilesToCopySettings
    ) async throws -> WorktreeFileCopySummary {
        let resolved = try resolveCopyPlan(
            repoRoot: repoRoot,
            worktreePath: worktreePath,
            settings: settings
        )
        guard settings.enabled else {
            let manifest = CopyManifest(
                version: 1,
                markerId: markerId,
                repoRoot: repoRoot,
                worktreePath: worktreePath,
                source: resolved.source,
                mode: resolved.mode,
                patterns: resolved.patterns,
                entries: [],
                skipped: [],
                copiedBytes: 0,
                createdAt: Date()
            )
            try writeManifest(gitDir: gitDir, manifest: manifest)
            return WorktreeFileCopySummary(
                source: resolved.source,
                mode: resolved.mode,
                patterns: resolved.patterns,
                manifestPath: manifestURL(gitDir: gitDir).path
            )
        }

        if resolved.mode == .patterns, resolved.patterns.isEmpty {
            let manifest = CopyManifest(
                version: 1,
                markerId: markerId,
                repoRoot: repoRoot,
                worktreePath: worktreePath,
                source: resolved.source,
                mode: resolved.mode,
                patterns: resolved.patterns,
                entries: [],
                skipped: [],
                copiedBytes: 0,
                createdAt: Date()
            )
            try writeManifest(gitDir: gitDir, manifest: manifest)
            return WorktreeFileCopySummary(
                source: resolved.source,
                mode: resolved.mode,
                patterns: resolved.patterns,
                manifestPath: manifestURL(gitDir: gitDir).path
            )
        }

        let planned = try await copyCandidates(
            repoRoot: repoRoot,
            worktreePath: worktreePath,
            resolved: resolved,
            settings: settings
        )
        let candidates = planned.candidates
        let skipped = planned.skipped
        let totalBytes = try preflightCopyCandidates(candidates, settings: settings)
        let sqliteGroupsBefore = try sqliteGroupSnapshots(candidates: candidates, repoRoot: repoRoot)

        var copiedEntries: [CopyManifest.Entry] = []
        var copiedFiles = 0
        var copiedDirectories = 0
        do {
            for candidate in orderedForCopy(candidates) {
                let rel = candidate.relativePath
                guard isSafeRelativePath(rel) else {
                    throw WorktreeError.fileCopyFailed("Unsafe relative path: \(rel)")
                }
                let source = URL(fileURLWithPath: repoRoot, isDirectory: true).appendingPathComponent(rel)
                let destination = URL(fileURLWithPath: worktreePath, isDirectory: true).appendingPathComponent(rel)
                guard PathValidator.isSafeNewChildPath(destination.path, root: worktreePath) else {
                    throw WorktreeError.fileCopyFailed("Destination escapes worktree: \(rel)")
                }
                switch candidate.kind {
                case .directory:
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
                       !isDirectory.boolValue {
                        throw WorktreeError.fileCopyFailed("Destination already exists: \(rel)")
                    }
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    copiedEntries.append(.init(path: rel, kind: .directory, size: nil, modificationTime: nil))
                    copiedDirectories += 1
                case .file:
                    if FileManager.default.fileExists(atPath: destination.path) {
                        throw WorktreeError.fileCopyFailed("Destination already exists: \(rel)")
                    }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try cloneOrCopyItem(source: source, destination: destination)
                    if let before = candidate.fingerprint {
                        let after = try sourceFingerprint(url: source)
                        guard before == after else {
                            throw WorktreeError.fileCopyFailed("Source changed during copy: \(rel)")
                        }
                    }
                    let copiedFingerprint = try sourceFingerprint(url: destination)
                    copiedEntries.append(.init(
                        path: rel,
                        kind: .file,
                        size: copiedFingerprint.size,
                        modificationTime: copiedFingerprint.modificationTime
                    ))
                    copiedFiles += 1
                }
            }
            try verifySQLiteGroupsStable(
                before: sqliteGroupsBefore,
                candidates: candidates,
                repoRoot: repoRoot
            )
            let manifest = CopyManifest(
                version: 2,
                markerId: markerId,
                repoRoot: repoRoot,
                worktreePath: worktreePath,
                source: resolved.source,
                mode: resolved.mode,
                patterns: resolved.patterns,
                entries: copiedEntries,
                skipped: skipped,
                copiedBytes: totalBytes,
                createdAt: Date()
            )
            try writeManifest(gitDir: gitDir, manifest: manifest)
        } catch {
            cleanupCopiedEntries(copiedEntries, worktreePath: worktreePath)
            throw error
        }

        return WorktreeFileCopySummary(
            source: resolved.source,
            mode: resolved.mode,
            patterns: resolved.patterns,
            copiedFileCount: copiedFiles,
            copiedDirectoryCount: copiedDirectories,
            skippedFileCount: skipped.count,
            copiedBytes: totalBytes,
            manifestPath: manifestURL(gitDir: gitDir).path
        )
    }

    private func resolveCopyPlan(
        repoRoot: String,
        worktreePath: String,
        settings: WorkspaceFilesToCopySettings
    ) throws -> ResolvedCopyPlan {
        guard settings.enabled else {
            return ResolvedCopyPlan(source: .disabled, mode: settings.mode, patterns: [])
        }
        let worktreeInclude = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".worktreeinclude")
        let rootInclude = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(".worktreeinclude")
        for url in [worktreeInclude, rootInclude] where FileManager.default.fileExists(atPath: url.path) {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return ResolvedCopyPlan(
                source: .worktreeinclude,
                mode: .patterns,
                patterns: contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            )
        }
        let usesDefault = settings.mode == .patterns
            && settings.patterns == WorkspaceFilesToCopySettings.defaultPatterns
            && settings.maxFiles == WorkspaceFilesToCopySettings.defaultMaxFiles
            && settings.maxBytesPerFile == WorkspaceFilesToCopySettings.defaultMaxBytesPerFile
            && settings.maxTotalBytes == WorkspaceFilesToCopySettings.defaultMaxTotalBytes
            && settings.allowDirectories == true
        return ResolvedCopyPlan(
            source: usesDefault ? .defaultPatterns : .settings,
            mode: settings.mode,
            patterns: settings.mode == .patterns ? settings.patterns : []
        )
    }

    private func copyCandidates(
        repoRoot: String,
        worktreePath: String,
        resolved: ResolvedCopyPlan,
        settings: WorkspaceFilesToCopySettings
    ) async throws -> (candidates: [CopyCandidate], skipped: [CopyManifest.Skipped]) {
        switch resolved.mode {
        case .patterns:
            let matches = try await matchedIgnoredFiles(repoRoot: repoRoot, patterns: resolved.patterns)
            return try candidatesFromRelativePaths(
                repoRoot: repoRoot,
                relativePaths: matches,
                allowDirectories: settings.allowDirectories
            )
        case .allIgnored:
            return try await allIgnoredCandidates(
                repoRoot: repoRoot,
                worktreePath: worktreePath,
                allowDirectories: settings.allowDirectories
            )
        }
    }

    private func preflightCopyCandidates(
        _ candidates: [CopyCandidate],
        settings: WorkspaceFilesToCopySettings
    ) throws -> Int64 {
        if candidates.count > settings.maxFiles {
            throw WorktreeError.fileCopyFailed("Matched \(candidates.count) ignored items, over cap \(settings.maxFiles)")
        }
        var totalBytes: Int64 = 0
        for candidate in candidates where candidate.kind == .file {
            if candidate.size > settings.maxBytesPerFile {
                throw WorktreeError.fileCopyFailed("\(candidate.relativePath) is \(candidate.size) bytes, over per-file cap \(settings.maxBytesPerFile)")
            }
            if totalBytes + candidate.size > settings.maxTotalBytes {
                throw WorktreeError.fileCopyFailed("Files to copy exceed total byte cap \(settings.maxTotalBytes)")
            }
            totalBytes += candidate.size
        }
        return totalBytes
    }

    private func orderedForCopy(_ candidates: [CopyCandidate]) -> [CopyCandidate] {
        candidates.sorted { lhs, rhs in
            switch (lhs.kind, rhs.kind) {
            case (.directory, .file): return true
            case (.file, .directory): return false
            case (.directory, .directory):
                let lDepth = lhs.relativePath.split(separator: "/").count
                let rDepth = rhs.relativePath.split(separator: "/").count
                if lDepth != rDepth { return lDepth < rDepth }
                return lhs.relativePath < rhs.relativePath
            case (.file, .file):
                return lhs.relativePath < rhs.relativePath
            }
        }
    }

    private func candidatesFromRelativePaths(
        repoRoot: String,
        relativePaths: Set<String>,
        allowDirectories: Bool
    ) throws -> (candidates: [CopyCandidate], skipped: [CopyManifest.Skipped]) {
        var candidates: [CopyCandidate] = []
        var skipped: [CopyManifest.Skipped] = []
        var seen: Set<String> = []
        for rel in relativePaths.map(normalizedRelativePath).sorted() {
            guard seen.insert(rel).inserted else { continue }
            guard isSafeRelativePath(rel), !isExcludedCopyRelativePath(rel) else {
                throw WorktreeError.fileCopyFailed("Unsafe relative path: \(rel)")
            }
            let source = URL(fileURLWithPath: repoRoot, isDirectory: true).appendingPathComponent(rel)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true {
                skipped.append(.init(path: rel, reason: "symlink"))
                continue
            }
            if values.isDirectory == true {
                if allowDirectories {
                    candidates.append(.init(relativePath: rel, kind: .directory, size: 0, fingerprint: nil))
                } else {
                    skipped.append(.init(path: rel, reason: "directory"))
                }
                continue
            }
            guard values.isRegularFile == true else {
                skipped.append(.init(path: rel, reason: "special-file"))
                continue
            }
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                throw WorktreeError.fileCopyFailed("Source is not readable: \(rel)")
            }
            let fingerprint = SourceFingerprint(
                size: Int64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSinceReferenceDate
            )
            candidates.append(.init(
                relativePath: rel,
                kind: .file,
                size: fingerprint.size,
                fingerprint: fingerprint
            ))
        }
        return (candidates, skipped)
    }

    private func allIgnoredCandidates(
        repoRoot: String,
        worktreePath: String,
        allowDirectories: Bool
    ) async throws -> (candidates: [CopyCandidate], skipped: [CopyManifest.Skipped]) {
        let items = try enumerateRepoItems(repoRoot: repoRoot, worktreePath: worktreePath)
        let checkInputs = items.map { item in item.isDirectory ? item.relativePath + "/" : item.relativePath }
        let ignored = try await checkIgnored(repoRoot: repoRoot, relativePaths: checkInputs)
        let ignoredRels = Set(ignored.map(normalizedRelativePath))
        let rels = Set(items.compactMap { ignoredRels.contains($0.relativePath) ? $0.relativePath : nil })
        return try candidatesFromRelativePaths(
            repoRoot: repoRoot,
            relativePaths: rels,
            allowDirectories: allowDirectories
        )
    }

    private struct EnumeratedRepoItem {
        let relativePath: String
        let isDirectory: Bool
    }

    private func enumerateRepoItems(repoRoot: String, worktreePath: String) throws -> [EnumeratedRepoItem] {
        let rootURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
        let rootPath = rootURL.standardizedFileURL.path
        let worktreeStandardized = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                worktreeLogger.error("Failed to enumerate ignored copy source: \(error.localizedDescription, privacy: .public)")
                return false
            }
        ) else { return [] }

        var items: [EnumeratedRepoItem] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path != worktreeStandardized else {
                enumerator.skipDescendants()
                continue
            }
            guard path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(path.dropFirst(rootPath.count + 1))
            guard !rel.isEmpty else { continue }
            let normalized = normalizedRelativePath(rel)
            if isExcludedCopyRelativePath(normalized) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            items.append(.init(relativePath: normalized, isDirectory: values.isDirectory == true))
        }
        return items
    }

    private func checkIgnored(repoRoot: String, relativePaths: [String]) async throws -> Set<String> {
        guard !relativePaths.isEmpty else { return [] }
        var ignored = Set<String>()
        let batchSize = 200
        var index = 0
        while index < relativePaths.count {
            let batch = Array(relativePaths[index..<min(index + batchSize, relativePaths.count)])
            index += batchSize
            let input = batch.joined(separator: "\0").appending("\0")
            let result = try await runGitWithInput(
                args: ["check-ignore", "-z", "--stdin"],
                cwd: repoRoot,
                input: Data(input.utf8)
            )
            guard result.exitStatus == 0 || result.exitStatus == 1 else {
                throw WorktreeError.gitFailed(operation: "check-ignore", stderr: result.stderrString)
            }
            ignored.formUnion(Self.nulSeparated(result.stdoutString))
        }
        return ignored
    }

    private func matchedIgnoredFiles(repoRoot: String, patterns: [String]) async throws -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-worktreeinclude-\(UUID().uuidString)")
        try patterns.joined(separator: "\n").appending("\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ignored = try await runGit(args: ["ls-files", "-o", "-i", "--exclude-standard", "-z"], cwd: repoRoot)
        guard ignored.exitStatus == 0 else {
            throw WorktreeError.gitFailed(operation: "ls-files ignored", stderr: ignored.stderrString)
        }
        let patternMatches = try await runGit(args: ["ls-files", "-o", "-i", "-z", "-X", tmp.path], cwd: repoRoot)
        guard patternMatches.exitStatus == 0 else {
            throw WorktreeError.gitFailed(operation: "ls-files files-to-copy", stderr: patternMatches.stderrString)
        }
        let ignoredSet = Set(Self.nulSeparated(ignored.stdoutString))
        let patternSet = Set(Self.nulSeparated(patternMatches.stdoutString))
        return ignoredSet.intersection(patternSet)
    }

    private func runGitWithInput(args: [String], cwd: String, input: Data) async throws -> ShellRunner.Result {
        if gitBinary == nil {
            gitBinary = ShellRunner.locateBinary("git")
        }
        guard let git = gitBinary else {
            throw WorktreeError.gitNotFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let queue = DispatchQueue(label: "WorktreeManager.git-stdin")
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let outBox = WorktreeDataBox()
        let errBox = WorktreeDataBox()
        queue.async {
            outBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
            outDone.signal()
        }
        queue.async {
            errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }

        try process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        await Task.detached(priority: .utility) {
            Self.waitForProcessAndReaders(process: process, outDone: outDone, errDone: errDone)
        }.value
        return ShellRunner.Result(
            exitStatus: process.terminationStatus,
            stdout: outBox.data,
            stderr: errBox.data
        )
    }

    private nonisolated static func waitForProcessAndReaders(
        process: Process,
        outDone: DispatchSemaphore,
        errDone: DispatchSemaphore
    ) {
        process.waitUntilExit()
        outDone.wait()
        errDone.wait()
    }

    private func cloneOrCopyItem(source: URL, destination: URL) throws {
        var cloned = false
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                if let sourcePath, let destinationPath, clonefile(sourcePath, destinationPath, 0) == 0 {
                    cloned = true
                }
            }
        }
        if !cloned {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func sourceFingerprint(url: URL) throws -> SourceFingerprint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SourceFingerprint(
            size: Int64(values.fileSize ?? 0),
            modificationTime: values.contentModificationDate?.timeIntervalSinceReferenceDate
        )
    }

    private func sqliteGroupSnapshots(
        candidates: [CopyCandidate],
        repoRoot: String
    ) throws -> [String: SQLiteGroupSnapshot] {
        let candidateFiles = Set(candidates.compactMap { candidate -> String? in
            candidate.kind == .file ? candidate.relativePath : nil
        })
        let groupBases = Set(candidateFiles.compactMap { sqliteGroupBase(for: $0) })
        guard !groupBases.isEmpty else { return [:] }

        var snapshots: [String: SQLiteGroupSnapshot] = [:]
        for base in groupBases {
            var paths = Set<String>()
            var fingerprints: [String: SourceFingerprint] = [:]
            for rel in sqliteCompanionPaths(for: base) {
                let source = URL(fileURLWithPath: repoRoot, isDirectory: true).appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isDirectory != true, values.isSymbolicLink != true else {
                    throw WorktreeError.fileCopyFailed("SQLite group member is not a regular file: \(rel)")
                }
                paths.insert(rel)
                fingerprints[rel] = try sourceFingerprint(url: source)
            }
            guard paths.isSubset(of: candidateFiles) else {
                let missing = paths.subtracting(candidateFiles).sorted().joined(separator: ", ")
                throw WorktreeError.fileCopyFailed("SQLite group has uncopied companion files: \(missing)")
            }
            snapshots[base] = SQLiteGroupSnapshot(paths: paths, fingerprints: fingerprints)
        }
        return snapshots
    }

    private func verifySQLiteGroupsStable(
        before: [String: SQLiteGroupSnapshot],
        candidates: [CopyCandidate],
        repoRoot: String
    ) throws {
        guard !before.isEmpty else { return }
        let after = try sqliteGroupSnapshots(candidates: candidates, repoRoot: repoRoot)
        guard before == after else {
            throw WorktreeError.fileCopyFailed("SQLite group changed during copy")
        }
    }

    private func sqliteGroupBase(for relativePath: String) -> String? {
        let suffixes = ["-wal", "-shm"]
        let lower = relativePath.lowercased()
        for suffix in suffixes where lower.hasSuffix(suffix) {
            let base = String(relativePath.dropLast(suffix.count))
            return sqliteBaseIfRecognized(base)
        }
        return sqliteBaseIfRecognized(relativePath)
    }

    private func sqliteBaseIfRecognized(_ relativePath: String) -> String? {
        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        switch ext {
        case "db", "sqlite", "sqlite3":
            return relativePath
        default:
            return nil
        }
    }

    private func sqliteCompanionPaths(for base: String) -> [String] {
        [base, base + "-wal", base + "-shm"]
    }

    private func normalizedRelativePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func writeManifest(gitDir: String, manifest: CopyManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(gitDir: gitDir), options: [.atomic])
    }

    private func cleanupCopiedFiles(worktreePath: String, expectedMarkerId: String?) throws {
        let gitDir = try blockingAbsoluteGitDir(cwd: worktreePath)
        if let expectedMarkerId {
            let markerData = try Data(contentsOf: markerURL(gitDir: gitDir))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let marker = try decoder.decode(OwnershipMarker.self, from: markerData)
            guard marker.markerId == expectedMarkerId else {
                throw WorktreeError.fileCopyFailed("Ownership marker mismatch")
            }
        }
        let url = manifestURL(gitDir: gitDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CopyManifest.self, from: data)
        cleanupCopiedEntries(manifest.entries, worktreePath: worktreePath)
    }

    private func cleanupCopiedEntries(
        _ entries: [CopyManifest.Entry],
        worktreePath: String
    ) {
        let root = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let fm = FileManager.default
        for entry in entries.reversed() {
            let normalized = normalizedRelativePath(entry.path)
            guard isSafeRelativePath(normalized) else { continue }
            let target = root.appendingPathComponent(normalized)
            guard PathValidator.isSafeNewChildPath(target.path, root: worktreePath) else { continue }

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else { continue }

            switch entry.kind {
            case .file:
                guard !isDirectory.boolValue else { continue }
                guard copiedFileStillMatches(entry: entry, url: target) else { continue }
                try? fm.removeItem(at: target)
                removeEmptyParents(from: target.deletingLastPathComponent(), root: root)
            case .directory:
                guard isDirectory.boolValue else { continue }
                guard let contents = try? fm.contentsOfDirectory(atPath: target.path), contents.isEmpty else {
                    continue
                }
                try? fm.removeItem(at: target)
                removeEmptyParents(from: target.deletingLastPathComponent(), root: root)
            }
        }
    }

    private func copiedFileStillMatches(entry: CopyManifest.Entry, url: URL) -> Bool {
        guard entry.kind == .file, let copiedSize = entry.size else { return false }
        guard let current = try? sourceFingerprint(url: url) else { return false }
        return current.size == copiedSize && current.modificationTime == entry.modificationTime
    }

    private func removeEmptyParents(from start: URL, root: URL) {
        let fm = FileManager.default
        var current = start
        let rootPath = (root.path as NSString).standardizingPath
        while current.path != rootPath && current.path.hasPrefix(rootPath + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path), contents.isEmpty else {
                return
            }
            try? fm.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        guard !PathValidator.containsControlBytes(path), !PathValidator.containsTraversal(path) else {
            return false
        }
        return true
    }

    private func isExcludedCopyRelativePath(_ path: String) -> Bool {
        let rel = normalizedRelativePath(path)
        guard !rel.isEmpty else { return true }
        let excludedExact = [
            ".git",
            "Clawdmeter/workspaces",
            "conductor/workspaces",
        ]
        if excludedExact.contains(rel) { return true }
        let excludedPrefixes = [
            ".git/",
            ".claude/worktrees/",
            ".codex/worktrees/",
            "Clawdmeter/workspaces/",
            "conductor/workspaces/",
        ]
        return excludedPrefixes.contains { rel.hasPrefix($0) }
    }

    private static func nulSeparated(_ string: String) -> [String] {
        string.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    public enum WorktreeError: Error, Sendable, LocalizedError {
        case gitNotFound
        case gitFailed(operation: String, stderr: String)
        case collisionUnresolvable
        case fileCopyFailed(String)
        case invalidName

        public var errorDescription: String? {
            switch self {
            case .gitNotFound:
                return "git binary not found"
            case .gitFailed(let operation, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "\(operation) failed" : "\(operation) failed: \(detail)"
            case .collisionUnresolvable:
                return "That name is already in use by another branch or workspace folder"
            case .fileCopyFailed(let message):
                return message
            case .invalidName:
                return "Name cannot be empty"
            }
        }
    }
}
