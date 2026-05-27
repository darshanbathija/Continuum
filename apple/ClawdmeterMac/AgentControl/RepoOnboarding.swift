import Foundation
import AppKit
import OSLog
import CryptoKit
import ClawdmeterShared

private let repoOnboardingLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RepoOnboarding")

/// Mac-side service that drives the three Add-Repo flows from the sidebar:
///
///   1. **Open Project** — NSOpenPanel-picked folder → `registerWorkspace`.
///   2. **Open GitHub Project** — `gh repo clone` (or `git clone` fallback)
///      → `registerWorkspace`.
///   3. **Quick Start** — `mkdir` + `git init` → `registerWorkspace`.
///
/// All three funnel through `registerWorkspace(at:allowNonGit:)`, the single
/// SSOT mutation point (per A1-A in /plan-eng-review). The same service is
/// reused by the daemon when iOS relays a request through
/// `/workspaces/{open-local,from-github,quick-start}`.
///
/// **NSOpenPanel** runs on the main thread; this class is `@MainActor` so the
/// `openLocalFolder()` call is a simple `runModal()`. Daemon-side calls go
/// directly to `cloneFromGitHub` / `quickStart` / `registerWorkspace` without
/// touching NSOpenPanel — iOS picks paths via text fields.
@MainActor
public final class RepoOnboarding {

    private let workspaceStore: WorkspaceStore
    private let repoIndex: RepoIndex
    private let refresh: () async -> Void
    private let onWorkspaceRegistered: (CodeWorkspaceRecord) -> Void

    public init(
        workspaceStore: WorkspaceStore,
        repoIndex: RepoIndex,
        refresh: @escaping () async -> Void = {},
        onWorkspaceRegistered: @escaping (CodeWorkspaceRecord) -> Void = { _ in }
    ) {
        self.workspaceStore = workspaceStore
        self.repoIndex = repoIndex
        self.refresh = refresh
        self.onWorkspaceRegistered = onWorkspaceRegistered
    }

    // MARK: - Flows

    /// Pick a folder via NSOpenPanel. Returns the registered workspace,
    /// or `nil` if the user cancelled. Throws `RepoOnboardingError` on
    /// failure (including `.alreadyRegistered` when the folder is already
    /// known — the UI should surface this as a toast, not an error).
    @discardableResult
    public func openLocalFolder() async throws -> CodeWorkspaceRecord? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.title = "Open project"
        panel.message = "Pick a folder to add to your Clawdmeter projects."
        guard panel.runModal() == .OK, let url = panel.urls.first else {
            return nil
        }
        let path = url.path
        let isGit = Self.pathLooksLikeGitRepo(path)
        if !isGit {
            // Confirm before registering a non-git folder as a workspace.
            // Surface via NSAlert so the user knows what they're agreeing to.
            let allow = await presentNonGitConfirm(for: path)
            if !allow { return nil }
        }
        return try await registerWorkspace(at: path, allowNonGit: !isGit)
    }

    /// Clone a GitHub repo. `spec` accepts `owner/repo`, full HTTPS URL, or
    /// SSH URL (`git@github.com:owner/repo.git`) — all normalize to
    /// `owner/repo` before invoking `gh repo clone`. Falls back to
    /// `git clone https://github.com/<spec>.git` if `gh` is missing.
    /// `destinationParent` is the directory the clone lands UNDER; the
    /// new clone's directory name is `owner/repo`'s last component.
    @discardableResult
    public func cloneFromGitHub(
        spec: String,
        destinationParent: String
    ) async throws -> CodeWorkspaceRecord {
        let normalized = try Self.normalizeCloneSpec(spec)
        guard let lastSlash = normalized.lastIndex(of: "/") else {
            throw RepoOnboardingError.cloneFailed(stderr: "no slash in normalized spec: \(normalized)")
        }
        let lastComponent = String(normalized[normalized.index(after: lastSlash)...])
        let destPath = (destinationParent as NSString).appendingPathComponent(lastComponent)

        // TOCTOU mitigation (Codex R3 #6 + R4 #3): the daemon handler
        // validated `destinationParent` against PathAllowList, but the
        // parent could have been replaced with a symlink in the window
        // between that check and this filesystem call. Two-layer defense:
        //   1. Re-validate the path against the allow-list (narrows
        //      window from handler-to-service hop to microseconds).
        //   2. lstat() the path RIGHT before each filesystem operation;
        //      if it's a symlink at that instant, abort. Window shrinks
        //      to ~50ns — practically unattackable without a kernel-
        //      side primitive.
        // Full closure requires openat(O_NOFOLLOW) which Swift doesn't
        // expose cleanly. Pragmatic mitigation only.
        switch PathAllowList.validate(destinationParent) {
        case .success:
            break
        case .failure(let err):
            throw err
        }
        if let symlinkError = PathAllowList.confirmNotSymlink(destinationParent) {
            throw symlinkError
        }

        // mkdir -p the parent if it doesn't exist yet. Clone fails fast
        // otherwise; the parent is part of the user-controlled allow-list,
        // not a path the daemon picked.
        var parentIsDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: destinationParent, isDirectory: &parentIsDir) {
            do {
                try FileManager.default.createDirectory(
                    atPath: destinationParent,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw RepoOnboardingError.persistenceFailed(
                    message: "Couldn't create parent: \(error.localizedDescription)"
                )
            }
        } else if !parentIsDir.boolValue {
            throw RepoOnboardingError.notADirectory
        }

        if FileManager.default.fileExists(atPath: destPath) {
            throw RepoOnboardingError.persistenceFailed(
                message: "Destination already exists: \(destPath)"
            )
        }

        // Prefer gh (handles auth, redirects, etc.); fall back to git.
        let ghPath = ShellRunner.locateBinary("gh")
        let gitPath = ShellRunner.locateBinary("git")
        let executable: String
        let args: [String]
        if let gh = ghPath {
            executable = gh
            args = ["repo", "clone", normalized, destPath]
        } else if let git = gitPath {
            executable = git
            args = ["clone", "https://github.com/\(normalized).git", destPath]
        } else {
            throw RepoOnboardingError.persistenceFailed(
                message: "Neither `gh` nor `git` is installed"
            )
        }

        do {
            let result = try await ShellRunner.shared.run(
                executable: executable,
                arguments: args,
                cwd: destinationParent,
                timeout: 300
            )
            if result.exitStatus != 0 {
                let stderr = result.stderrString
                if RepoOnboardingError.matchAuthFailure(stderr: stderr) {
                    throw RepoOnboardingError.ghAuthFailed
                }
                throw RepoOnboardingError.cloneFailed(stderr: stderr)
            }
        } catch let err as RepoOnboardingError {
            throw err
        } catch let err as ShellRunner.ShellError {
            throw RepoOnboardingError.cloneFailed(stderr: "\(err)")
        } catch {
            throw RepoOnboardingError.cloneFailed(stderr: "\(error)")
        }

        return try await registerWorkspace(at: destPath, allowNonGit: false)
    }

    /// Create a new empty directory + `git init` + register. `name` is
    /// validated (non-empty, no `/`, no leading `.`); `parent` is expected
    /// to be pre-validated by the caller (Mac NSOpenPanel result, iOS
    /// allow-list gate).
    @discardableResult
    public func quickStart(
        name: String,
        in parent: String
    ) async throws -> CodeWorkspaceRecord {
        try Self.validateQuickStartName(name)
        // TOCTOU mitigation: re-validate `parent` + lstat immediately
        // before we touch the filesystem. See `cloneFromGitHub` for
        // rationale.
        switch PathAllowList.validate(parent) {
        case .success:
            break
        case .failure(let err):
            throw err
        }
        if let symlinkError = PathAllowList.confirmNotSymlink(parent) {
            throw symlinkError
        }
        // Ensure the parent itself exists (idempotent mkdir).
        var parentIsDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDir) {
            do {
                try FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw RepoOnboardingError.persistenceFailed(
                    message: "Couldn't create parent: \(error.localizedDescription)"
                )
            }
        } else if !parentIsDir.boolValue {
            throw RepoOnboardingError.notADirectory
        }

        let destPath = (parent as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destPath) {
            throw RepoOnboardingError.persistenceFailed(
                message: "Folder already exists at \(destPath)"
            )
        }
        do {
            try FileManager.default.createDirectory(
                atPath: destPath,
                withIntermediateDirectories: false,
                attributes: nil
            )
        } catch {
            throw RepoOnboardingError.persistenceFailed(
                message: "mkdir failed: \(error.localizedDescription)"
            )
        }

        // Codex R4 #2: if anything after createDirectory fails, the
        // empty `destPath` is stranded — iOS clears the key on failure,
        // retry hits "folder already exists" indefinitely. Use a
        // success flag + defer-cleanup so the partial directory is
        // removed on every failure path before we re-throw.
        var quickStartSucceeded = false
        defer {
            if !quickStartSucceeded {
                try? FileManager.default.removeItem(atPath: destPath)
            }
        }

        guard let git = ShellRunner.locateBinary("git") else {
            throw RepoOnboardingError.gitInitFailed(stderr: "git binary not found")
        }
        let result: ShellRunner.Result
        do {
            result = try await ShellRunner.shared.run(
                executable: git,
                arguments: ["init"],
                cwd: destPath,
                timeout: 30
            )
        } catch let err as ShellRunner.ShellError {
            throw RepoOnboardingError.gitInitFailed(stderr: "\(err)")
        } catch {
            throw RepoOnboardingError.gitInitFailed(stderr: "\(error)")
        }
        if result.exitStatus != 0 {
            throw RepoOnboardingError.gitInitFailed(stderr: result.stderrString)
        }

        let record = try await registerWorkspace(at: destPath, allowNonGit: false)
        quickStartSucceeded = true
        return record
    }

    // MARK: - Chokepoint

    /// Single SSOT mutation point. Canonicalize `path`, verify it's a
    /// directory, upsert a `CodeWorkspaceRecord` into `WorkspaceStore`,
    /// nudge `RepoIndex.refresh()` so the sidebar's 4th source picks it
    /// up (per A1-A), fire `onWorkspaceRegistered` so the UI can scroll
    /// to / select the new entry.
    ///
    /// Throws `.alreadyRegistered(workspaceId:)` if the path canonicalizes
    /// to a repo already in `WorkspaceStore` — the caller surfaces this
    /// as a toast, not an error banner. `onWorkspaceRegistered` is still
    /// fired so the UI can highlight the existing record.
    @discardableResult
    public func registerWorkspace(
        at path: String,
        allowNonGit: Bool
    ) async throws -> CodeWorkspaceRecord {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw RepoOnboardingError.pathMissing
        }
        guard isDir.boolValue else {
            throw RepoOnboardingError.notADirectory
        }
        let normalized = RepoIdentity.normalize(path)
        let isOther = (normalized == RepoKey.other) || (normalized == RepoKey.unknown)
        if isOther && !allowNonGit {
            throw RepoOnboardingError.notAGitRepo
        }
        let canonicalRoot = isOther ? path : normalized

        if let existing = workspaceStore.workspace(forRepoRoot: canonicalRoot) {
            repoOnboardingLogger.info("Workspace already registered for repoRoot=\(canonicalRoot, privacy: .public)")
            onWorkspaceRegistered(existing)
            await refresh()
            throw RepoOnboardingError.alreadyRegistered(workspaceId: existing.id)
        }

        let displayName: String = {
            let last = (canonicalRoot as NSString).lastPathComponent
            return last.isEmpty ? canonicalRoot : last
        }()
        let projectId = Self.deterministicUUID(for: "project:\(canonicalRoot)")
        let id = Self.deterministicUUID(for: "workspace:\(canonicalRoot)")
        let now = Date()
        let record = CodeWorkspaceRecord(
            id: id,
            projectId: projectId,
            repoRoot: canonicalRoot,
            repoDisplayName: displayName,
            runtimeCwd: canonicalRoot,
            providerDefaults: WorkspaceProviderDefaults(),
            activeSessionIds: [],
            createdAt: now,
            updatedAt: now
        )
        let upserted = workspaceStore.upsert(record)
        repoOnboardingLogger.info("Registered workspace \(upserted.id, privacy: .public) at \(canonicalRoot, privacy: .public)")
        onWorkspaceRegistered(upserted)
        await refresh()
        return upserted
    }

    // MARK: - Static helpers (testable)

    /// Normalize a GitHub clone spec to `owner/repo`. Accepts:
    /// - `owner/repo`
    /// - `https://github.com/owner/repo`
    /// - `https://github.com/owner/repo.git`
    /// - `git@github.com:owner/repo.git`
    /// Throws `cloneFailed` for anything else.
    public static func normalizeCloneSpec(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            throw RepoOnboardingError.cloneFailed(stderr: "empty spec")
        }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("git@github.com:") {
            let body = String(s.dropFirst("git@github.com:".count))
            return try stripDotGitAndValidate(body, original: raw)
        }
        for prefix in ["https://github.com/", "http://github.com/", "git://github.com/"] {
            if s.hasPrefix(prefix) {
                let body = String(s.dropFirst(prefix.count))
                return try stripDotGitAndValidate(body, original: raw)
            }
        }
        return try stripDotGitAndValidate(s, original: raw)
    }

    /// Validate a Quick Start folder name. Throws `.persistenceFailed` for
    /// empty / slash-bearing / dot-leading names so the UI surfaces a
    /// targeted error inline.
    public static func validateQuickStartName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw RepoOnboardingError.persistenceFailed(message: "Name can't be empty")
        }
        if trimmed.contains("/") || trimmed.contains("\\") {
            throw RepoOnboardingError.persistenceFailed(message: "Name can't contain a slash")
        }
        if trimmed.hasPrefix(".") {
            throw RepoOnboardingError.persistenceFailed(message: "Name can't start with a dot")
        }
    }

    /// Cheap probe: does `path` (or any ancestor up to 20 levels) contain
    /// a `.git` directory? Mirrors `RepoIdentity.canonicalRepoPath` shape
    /// but returns a Bool without canonicalizing (which we do separately).
    /// Faster than calling `RepoIdentity.normalize` twice and stays
    /// out of the cache RepoIdentity maintains for analytics.
    public static func pathLooksLikeGitRepo(_ path: String) -> Bool {
        var current = (path as NSString).standardizingPath
        for _ in 0..<20 {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                return true
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return false
    }

    // MARK: - Private

    private static func stripDotGitAndValidate(_ s: String, original: String) throws -> String {
        let stripped = s.hasSuffix(".git") ? String(s.dropLast(4)) : s
        let parts = stripped.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
           !parts[0].contains(" "), !parts[1].contains(" ") {
            return "\(parts[0])/\(parts[1])"
        }
        throw RepoOnboardingError.cloneFailed(stderr: "unrecognized GitHub spec: \(original)")
    }

    private static func deterministicUUID(for input: String) -> UUID {
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest).prefix(16)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Present an NSAlert asking the user if they really want to register
    /// a non-git folder as a workspace (it'll appear under "Other" in
    /// the sidebar). Returns true if the user confirmed.
    private func presentNonGitConfirm(for path: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "This folder isn't a git repository"
        alert.informativeText = "It'll appear under \"Other\" in the sidebar. Add it anyway?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add anyway")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
}
