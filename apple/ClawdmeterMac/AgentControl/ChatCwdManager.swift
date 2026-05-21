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
