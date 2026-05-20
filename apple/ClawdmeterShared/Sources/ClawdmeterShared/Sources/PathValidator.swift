import Foundation

/// Shared path-safety predicates. v0.7.7 consolidation of the three
/// near-clones that lived across `AgentControlServer.isValidRepoKey`,
/// `AgentControlServer.isValidJsonlPath`, and
/// `iOSArtifactsPane.isSafeArtifactPath`. All three were doing the same
/// "reject empty / require absolute / reject control bytes / reject
/// traversal segments / optionally resolve symlinks + check prefix"
/// dance.
///
/// Design: composable predicates rather than one monolithic check, so
/// each call site picks the slice it actually needs (the iOS artifact
/// check is intentionally weaker than the daemon-side repo/jsonl check).
public enum PathValidator {

    /// Reject empty paths.
    public static func isEmpty(_ path: String) -> Bool {
        path.isEmpty
    }

    /// Reject anything that contains ASCII control bytes (C0 + DEL).
    /// These are command-injection vectors when the path is later
    /// composed into a tmux line / shell argument.
    public static func containsControlBytes(_ path: String) -> Bool {
        for scalar in path.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return true }
        }
        return false
    }

    /// Reject `..` or `.` segments. These are the traversal-attack
    /// shape `standardizingPath` would otherwise collapse silently —
    /// rejecting them at the predicate level means the caller gets a
    /// clean refusal instead of a path that quietly resolves to
    /// somewhere outside the intended sandbox.
    public static func containsTraversal(_ path: String) -> Bool {
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." || part == "." { return true }
        }
        return false
    }

    /// Resolve symlinks in the path. Returns the resolved POSIX path.
    /// `resolvingSymlinksInPath()` is a no-op for non-existent paths,
    /// which is fine — the caller's downstream prefix check still holds.
    public static func resolveSymlinks(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return URL(fileURLWithPath: standardized)
            .resolvingSymlinksInPath()
            .path
    }

    /// `true` if `path` (after symlink resolution) lives under `root` or
    /// equals `root`. Used by the daemon-side handlers to anchor a
    /// validated path under $HOME or under the session worktree.
    public static func resolvesUnder(_ path: String, root: String) -> Bool {
        let resolved = resolveSymlinks(path)
        return resolved.hasPrefix(root + "/") || resolved == root
    }

    /// `true` if `path` (after symlink resolution) lives under any of
    /// the allowlisted roots. Used by `isValidJsonlPath` to gate
    /// session-id extraction to the four known agent project directories.
    public static func resolvesUnderAny(_ path: String, roots: [String]) -> Bool {
        let resolved = resolveSymlinks(path)
        return roots.contains(where: { resolved.hasPrefix($0) })
    }

    // MARK: - High-level predicates (call-site convenience)

    /// Daemon-side: validate a repo key (a path the client claims
    /// represents the user's repo). Must be absolute, ASCII-clean, no
    /// traversal, and resolve under $HOME so a symlink-out attack fails
    /// closed. Mirrors `AgentControlServer.isValidRepoKey`.
    public static func isValidRepoKey(_ key: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        guard !isEmpty(key) else { return false }
        guard key.hasPrefix("/") else { return false }
        guard !containsControlBytes(key) else { return false }
        guard !containsTraversal(key) else { return false }
        guard !homeDirectory.isEmpty else { return true } // unit-test env
        return resolvesUnder(key, root: homeDirectory)
    }

    /// Daemon-side: validate a JSONL path (a session-id extraction
    /// target). Same shape as `isValidRepoKey` plus an explicit
    /// allowlist of agent-project roots so a malicious client can't
    /// point at an unrelated session file. Mirrors
    /// `AgentControlServer.isValidJsonlPath`.
    public static func isValidJsonlPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        guard !isEmpty(path) else { return false }
        guard path.hasPrefix("/") else { return false }
        guard !containsControlBytes(path) else { return false }
        guard !containsTraversal(path) else { return false }
        guard !homeDirectory.isEmpty else { return true } // unit-test env
        let allowed = [
            homeDirectory + "/.claude/projects/",
            homeDirectory + "/.codex/sessions/",
            homeDirectory + "/.codex/projects/",
            homeDirectory + "/.gemini/",
        ]
        return resolvesUnderAny(path, roots: allowed)
    }

    /// iOS-client-side: validate an artifact path before posting it to
    /// the daemon's `/sessions/:id/artifact?path=…` route. Weaker than
    /// the daemon-side checks because absolute paths ARE expected (the
    /// agent's `Write` tool routinely produces them); the daemon
    /// enforces the worktree-sandbox check. Mirrors
    /// `iOSArtifactsPane.isSafeArtifactPath`.
    public static func isSafeArtifactPath(_ path: String) -> Bool {
        guard !isEmpty(path) else { return false }
        return !containsTraversal(path)
    }
}
