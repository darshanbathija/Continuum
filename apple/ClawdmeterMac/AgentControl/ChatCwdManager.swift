import Foundation
import ClawdmeterShared

/// Per-session chat-cwd directory management for v0.8 Chat tab.
///
/// Chat sessions execute in `~/Library/Application Support/Clawdmeter/chat-sessions/<sessionId>/`
/// — a fresh, empty directory per chat. No `.git`, no `.claude/`, no
/// `.codex/` — the CLI runs in plan-mode against an empty workspace so
/// the user gets pure conversational behavior with zero risk of
/// filesystem mutation, shell execution, or write attempts.
///
/// The chat-cwd path is stored in `AgentSession.worktreePath` so the
/// existing `session.worktreePath ?? session.repoKey` dispatch (now
/// `session.effectiveCwd`) resolves to it without daemon-wide changes.
public enum ChatCwdManager {

    /// Root directory under Application Support where per-session chat
    /// cwds live. Created lazily by `ensure(for:)`. Tests override via
    /// `chatSessionsRoot(overriddenBy:)`.
    public static var chatSessionsRoot: URL {
        // Mac sandbox / non-sandbox both honor
        // `applicationSupportDirectory` (the system creates the
        // bundle-id subdir automatically when sandboxed).
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("chat-sessions", isDirectory: true)
    }

    /// The absolute path string for a session's chat-cwd. Use this when
    /// storing the path in `AgentSession.worktreePath`.
    public static func chatCwdPath(for sessionId: UUID) -> String {
        cwdURL(for: sessionId).path
    }

    /// The chat-cwd URL for a session. Does NOT create the directory —
    /// use `ensure(for:)` for that.
    public static func cwdURL(for sessionId: UUID) -> URL {
        chatSessionsRoot.appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    /// Ensure the per-session chat-cwd exists on disk. Idempotent;
    /// throws only if the FileManager call fails (disk full, permission
    /// denied). Returns the URL of the created (or already-existing)
    /// directory.
    @discardableResult
    public static func ensure(for sessionId: UUID) throws -> URL {
        let url = cwdURL(for: sessionId)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Pre-accept Claude Code's first-run "Quick safety check / trust this
    /// folder" dialog for `path` by writing `hasTrustDialogAccepted = true` into
    /// `~/.claude.json`'s per-project map BEFORE the CLI launches.
    ///
    /// Why: a chat-cwd is a brand-new empty dir, so Claude blocks at the trust
    /// prompt on first launch. The TUI then swallows the first /send into the
    /// dialog and the client times out (the in-pane warmup poll dismisses it,
    /// but that adds ~9s — longer than the mobile send timeout). Pre-trusting
    /// means Claude boots straight to the composer, so the warmup poll breaks
    /// early on "Welcome back" and the first send is fast.
    ///
    /// Best-effort + non-throwing: a missing/unparseable `~/.claude.json` or a
    /// write failure just falls back to the in-pane warmup poll.
    ///
    /// Concurrency: `~/.claude.json` is shared with a live Claude Code process,
    /// so the whole read-modify-write runs under an exclusive `flock(2)` and
    /// writes IN PLACE (not atomic-rename — a rename would swap the inode the
    /// lock is held on, defeating it). This serializes our own concurrent
    /// chat-session creates and mutually excludes any flock-respecting writer,
    /// so we can't clobber another writer's keys with stale data. We also skip
    /// the write entirely when the dir is already trusted (the common case).
    public static func markTrustedForClaude(path: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { _ = flock(fd, LOCK_UN) }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var root: [String: Any] = [:]
        if let data = try? handle.readToEnd(), !data.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[path] as? [String: Any] ?? [:]
        // Already trusted → nothing to write, leave the file (and Claude's other
        // edits) untouched.
        if (entry["hasTrustDialogAccepted"] as? Bool) == true,
           (entry["hasCompletedProjectOnboarding"] as? Bool) == true {
            return
        }
        entry["hasTrustDialogAccepted"] = true
        entry["hasCompletedProjectOnboarding"] = true
        projects[path] = entry
        root["projects"] = projects
        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: out)
        try? handle.truncate(atOffset: UInt64(out.count))
    }

    /// Remove the per-session chat-cwd. Called by ChatCwdCleaner (Phase 4)
    /// from the DELETE /sessions/:id handler. PathValidator guard in the
    /// cleaner enforces that the path is under `chatSessionsRoot` before
    /// invoking this — defense in depth against a malicious worktreePath
    /// stored on a session entry (e.g., from a corrupted sessions.json).
    public static func remove(for sessionId: UUID) throws {
        let url = cwdURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
