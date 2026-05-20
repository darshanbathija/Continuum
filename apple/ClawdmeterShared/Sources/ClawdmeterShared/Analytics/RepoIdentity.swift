import Foundation

/// Normalization + display helpers for the cwd-based repo keys.
///
/// Per plan A12: case-preserving, NOT lowercased.
///
/// Per user feedback after V1 ship: the displayed repo should be the actual
/// git REPOSITORY (e.g. `Defx V3`), not the branch directory inside a
/// Conductor workspace or a git worktree. So `normalize` now walks up the
/// filesystem looking for `.git` and uses the repo root as the bucket key.
///
/// Worktrees: `.git` may be a file pointing back to the main worktree's
/// `.git/worktrees/<name>` directory; we follow that pointer and bucket
/// under the MAIN worktree's path so all branches roll up to one repo.
///
/// Fallback when no `.git` exists anywhere up the chain (or the directory
/// has been deleted since the JSONL was written): use the trimmed cwd
/// as-is and let the user see the bare path.
public enum RepoIdentity {

    private static let cacheLock = NSLock()
    private static var canonicalCache: [String: String] = [:]

    /// Normalize a raw `cwd` string into a stable `RepoKey`. Strips trailing
    /// `/`, resolves `~`, then resolves to the canonical git-repo root via
    /// `.git` discovery. Returns `RepoKey.unknown` for empty input.
    public static func normalize(_ rawCwd: String) -> RepoKey {
        let trimmed = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return RepoKey.unknown }

        // Resolve `~` against the current home directory.
        let expanded = (trimmed as NSString).expandingTildeInPath

        // Strip trailing slashes but keep root `/`.
        var stripped = expanded
        while stripped.count > 1 && stripped.hasSuffix("/") {
            stripped.removeLast()
        }

        return canonicalRepoPath(stripped)
    }

    /// Human-friendly short name. Last path component for absolute paths,
    /// or the original key for unknown / non-path values.
    public static func displayName(for key: RepoKey) -> String {
        if key == RepoKey.unknown { return "(unknown)" }
        if key == RepoKey.other { return "Other" }

        let url = URL(fileURLWithPath: key)
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" {
            return key
        }
        return last
    }

    // MARK: - Canonical repo resolution

    /// Walk up the filesystem from `path` looking for `.git`. When found:
    ///   - directory → that directory's parent IS the repo root
    ///   - file → parse `gitdir:` → resolve to the main worktree's parent
    /// Falls back to `path` if nothing is found within 20 levels.
    static func canonicalRepoPath(_ path: String) -> String {
        cacheLock.lock()
        if let hit = canonicalCache[path] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let resolved = resolveCanonical(path)

        cacheLock.lock()
        canonicalCache[path] = resolved
        cacheLock.unlock()
        return resolved
    }

    private static func resolveCanonical(_ path: String) -> String {
        // Pattern fallbacks first — these handle the common case where the
        // .git walker can't reach a repo root because the worktree was
        // deleted from disk (e.g. abandoned Conductor branches).
        if let conductor = matchConductorWorkspace(path) { return conductor }
        if let claude = matchClaudeWorktree(path) { return claude }

        let fm = FileManager.default
        var current = path
        var hops = 0
        while hops < 20 && current.count > 1 && current != "/" {
            hops += 1
            let gitPath = (current as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    return current
                } else {
                    if let main = resolveWorktreeMain(gitFile: gitPath) {
                        return main
                    }
                    return current
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        // No `.git` walking up. Try walking DOWN one level — if `path` has
        // exactly ONE child that IS a git repo, collapse to that child.
        // Catches the common case where the user started Claude from the
        // parent of a single-repo directory (e.g. `~/Downloads/CC Watch`
        // wraps `Clawdmeter/`; both cwds should bucket as `Clawdmeter`).
        if let descended = tryDescendToSoleGitChild(path) {
            return descended
        }
        // Path isn't a git repo and we can't auto-discover one. Bucket it
        // under the single "(other)" row so the UI doesn't show random
        // UUIDs, ambient folders (Downloads, home dir), and dead Paperclip
        // workspace IDs as if they were repos. The user explicitly asked
        // for this cleanup after V1 ship.
        return RepoKey.other
    }

    /// If `dir` has exactly one subdirectory that contains a `.git`, return
    /// that subdirectory. Multiple git children (or none) → nil.
    private static func tryDescendToSoleGitChild(_ dir: String) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var gitChildren: [String] = []
        for entry in entries {
            if entry.hasPrefix(".") { continue }
            let childPath = (dir as NSString).appendingPathComponent(entry)
            let childGit = (childPath as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: childGit, isDirectory: nil) {
                gitChildren.append(childPath)
                if gitChildren.count > 1 { return nil }  // ambiguous
            }
        }
        return gitChildren.first
    }

    /// Conductor pattern: `<...>/conductor/workspaces/<repo>/<branch>/...`
    /// We try to resolve to the UNDERLYING main repo by reading a live
    /// branch's `.git` pointer (typically points to `~/Downloads/<repo>` or
    /// similar). That way Conductor branches and the user's own checkout of
    /// the same repo share one bucket. Falls back to a stable
    /// `<...>/conductor/workspaces/<repo>` key when no live branch exists.
    private static func matchConductorWorkspace(_ path: String) -> String? {
        let marker = "/conductor/workspaces/"
        guard let range = path.range(of: marker) else { return nil }
        let prefix = String(path[..<range.lowerBound])
        let suffix = String(path[range.upperBound...])
        let firstSlash = suffix.firstIndex(of: "/") ?? suffix.endIndex
        let repo = String(suffix[..<firstSlash])
        guard !repo.isEmpty else { return nil }

        let workspacesDir = prefix + marker + repo

        // Try to find an alive branch under this workspaces dir and read its
        // `.git` pointer to discover the main worktree.
        if let main = discoverConductorMainRepo(workspacesDir: workspacesDir) {
            return main
        }
        // Fallback: stable Conductor bucket. All branches of the same repo
        // (dead and alive) share this key, so they at least collapse together.
        return workspacesDir
    }

    private static func discoverConductorMainRepo(workspacesDir: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: workspacesDir) else {
            return nil
        }
        for entry in entries {
            // Skip hidden / non-branch entries (`.DS_Store`).
            if entry.hasPrefix(".") { continue }
            let gitFile = workspacesDir + "/" + entry + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitFile, isDirectory: &isDir), !isDir.boolValue {
                if let main = resolveWorktreeMain(gitFile: gitFile) {
                    return main
                }
            }
        }
        return nil
    }

    /// Claude-Code worktree pattern: `<repo>/.claude/worktrees/<branch>/...`
    /// Collapses everything below `<repo>/.claude/worktrees/` so all of one
    /// repo's worktrees share a bucket. The .git walker handles this when
    /// `<repo>/.git` exists; this fallback covers the case where the worktree
    /// was deleted.
    private static func matchClaudeWorktree(_ path: String) -> String? {
        let marker = "/.claude/worktrees/"
        guard let range = path.range(of: marker) else { return nil }
        return String(path[..<range.lowerBound])
    }

    /// Parse a worktree's `.git` file (format: `gitdir: <abs-path>`) and
    /// return the main worktree's directory (one level above the `.git`
    /// directory the gitdir points into).
    ///
    /// Example: `gitdir: /Users/x/conductor/repos/Defx V3/.git/worktrees/beirut`
    ///   → main worktree = `/Users/x/conductor/repos/Defx V3`
    private static func resolveWorktreeMain(gitFile: String) -> String? {
        guard let contents = try? String(contentsOfFile: gitFile, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir: "
        guard trimmed.hasPrefix(prefix) else { return nil }
        let rawGitdir = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // P2-Shared-1: git can write a relative `gitdir:` value (e.g.,
        // `gitdir: ../.git/worktrees/feature` when the worktree lives
        // adjacent to the main repo). The previous implementation passed
        // the raw string to URL(fileURLWithPath:) which resolves relative
        // paths against the process's working directory — wrong; they're
        // relative to the .git POINTER FILE's parent directory.
        //
        // Resolve a leading non-`/` value against the .git file's parent,
        // then standardize to collapse `..` segments. Absolute paths are
        // passed through unchanged.
        let gitFileParent = (gitFile as NSString).deletingLastPathComponent
        let gitdir: String
        if rawGitdir.hasPrefix("/") {
            gitdir = rawGitdir
        } else {
            let joined = (gitFileParent as NSString).appendingPathComponent(rawGitdir)
            gitdir = (joined as NSString).standardizingPath
        }

        // gitdir looks like /.../main/.git/worktrees/<name>
        // Walking up: `.../main/.git/worktrees/<name>` → `/.../main/.git/worktrees`
        // → `/.../main/.git` → `/.../main`
        let url = URL(fileURLWithPath: gitdir)
        let main = url
            .deletingLastPathComponent()  // worktrees
            .deletingLastPathComponent()  // .git
            .deletingLastPathComponent()  // main worktree
        let path = main.path
        guard path.count > 1 else { return nil }
        return path
    }

    // MARK: - Test hooks

    /// Reset the canonical-path cache. Intended for tests only.
    public static func _resetCacheForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        canonicalCache.removeAll()
    }
}
