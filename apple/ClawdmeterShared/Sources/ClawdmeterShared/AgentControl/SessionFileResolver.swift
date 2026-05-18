import Foundation

/// Resolves an `AgentSession` to its on-disk JSONL file. Two jobs:
///
/// 1. **Claude path resolution** — delegated via the `resolveClaudeURL`
///    closure injected at construction time so this type can live in
///    `ClawdmeterShared` and stay testable. The Mac daemon plugs in
///    `SessionChatStore.resolveSessionFileURL(repoCwd:)`.
///
/// 2. **Codex respawn-lineage tracking** — when the daemon's
///    `approve-plan` handler kills the plan-mode Codex pane and respawns
///    a new rollout, the new rollout writes to a NEW JSONL file with a
///    NEW Codex session id. Clawdmeter's `AgentSession.id` (UUID) stays
///    stable across the respawn; the underlying Codex rollout file does
///    not. Without lineage tracking, `/chat-snapshot` requests for that
///    session id would resolve to the dead pre-approve rollout (no live
///    updates).
///
///    The resolver maintains `[AgentSession.id: URL]` links keyed by our
///    stable session UUID. Mac-side spawn paths can `record(...)` a known
///    rollout URL after a fresh spawn. On `approve-plan` the daemon calls
///    `invalidate(sessionId:)` and the next `resolve(...)` call rescans
///    `~/.codex/sessions/` for the newly-created rollout whose
///    modification time falls within the session's activity window.
///
/// Phase 0a of the WhatsApp-smooth pipeline used a simpler fallback
/// (`DaemonChatStoreRegistry.newestCodexJSONL()` — global newest). Phase
/// 0b replaces that with this resolver so Codex sessions keep continuity
/// across `approve-plan` boundaries.
public final class SessionFileResolver: @unchecked Sendable {

    private let codexSessionsRoot: URL
    private let resolveClaudeURL: @Sendable (AgentSession) -> URL?
    private var codexLinks: [UUID: URL] = [:]
    /// Activity-window grace after `session.lastEventAt`. Rollouts modified
    /// more than this far past `lastEventAt` are not considered candidates
    /// for the session (likely belong to a different session entirely).
    private let activityGrace: TimeInterval
    private let lock = NSLock()

    public init(
        codexSessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        activityGrace: TimeInterval = 5 * 60,
        resolveClaudeURL: @escaping @Sendable (AgentSession) -> URL?
    ) {
        self.codexSessionsRoot = codexSessionsRoot
        self.activityGrace = activityGrace
        self.resolveClaudeURL = resolveClaudeURL
    }

    // MARK: - Public API

    public func resolve(session: AgentSession) -> URL? {
        if session.agent == .claude {
            return resolveClaudeURL(session)
        }
        return resolveCodex(session: session)
    }

    /// Record a known-good rollout URL for a session id. Called by the
    /// daemon's spawn path after a fresh Codex pane comes up — both at
    /// initial spawn and after `approve-plan` respawn.
    public func record(sessionId: UUID, rolloutURL: URL) {
        lock.lock()
        codexLinks[sessionId] = rolloutURL
        lock.unlock()
    }

    /// Forget the cached rollout URL for a session id. The daemon calls
    /// this on `approve-plan` so the next `resolve(...)` call rescans for
    /// the new rollout file.
    public func invalidate(sessionId: UUID) {
        lock.lock()
        codexLinks.removeValue(forKey: sessionId)
        lock.unlock()
    }

    /// Test + observability hook.
    public func recordedURL(for sessionId: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return codexLinks[sessionId]
    }

    /// Public fallback for synthetic preview sessions (the Mac UI's
    /// outside-Clawdmeter JSONL viewer + `/chat-snapshot` requests against
    /// sessions whose identity can't be established). Returns the newest
    /// `.jsonl` under `codexSessionsRoot`. Mirrors the pre-Phase-0b
    /// `AgentControlServer.newestCodexJSONL()` behavior.
    public func findNewestCodexRollout() -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: codexSessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date > newestDate {
                newestDate = date
                newest = url
            }
        }
        return newest
    }

    // MARK: - Internals

    private func resolveCodex(session: AgentSession) -> URL? {
        lock.lock()
        let cached = codexLinks[session.id]
        lock.unlock()

        if let cached, FileManager.default.fileExists(atPath: cached.path) {
            // Cached link is still on disk. Sanity-check that no newer
            // rollout exists within the session's activity window — if a
            // respawn happened and `invalidate(...)` wasn't called, the
            // cache would silently strand on the dead pre-approve rollout.
            let cachedMtime = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let newer = findCodexRollout(for: session, modifiedAfter: cachedMtime),
               newer != cached {
                lock.lock()
                codexLinks[session.id] = newer
                lock.unlock()
                return newer
            }
            return cached
        }

        // Cache miss (or cached file vanished). Scan for a rollout modified
        // within this session's activity window.
        if let found = findCodexRollout(for: session, modifiedAfter: nil) {
            lock.lock()
            codexLinks[session.id] = found
            lock.unlock()
            return found
        }

        // Fallback: newest rollout in dir (legacy behavior for synthetic
        // preview sessions whose AgentSession identity doesn't map cleanly
        // to a rollout file).
        return findNewestCodexRollout()
    }

    /// Find the newest `.jsonl` in `codexSessionsRoot` whose modification
    /// time falls within this session's activity window
    /// (`session.createdAt` → `lastEventAt + activityGrace`), optionally
    /// filtered to files modified strictly after `modifiedAfter` (used to
    /// detect a respawn-newer rollout for an already-cached session).
    private func findCodexRollout(for session: AgentSession, modifiedAfter: Date?) -> URL? {
        let windowStart = session.createdAt
        let windowEnd = session.lastEventAt.addingTimeInterval(activityGrace)
        guard let enumerator = FileManager.default.enumerator(
            at: codexSessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard date >= windowStart, date <= windowEnd else { continue }
            if let after = modifiedAfter, date <= after { continue }
            if date > newestDate {
                newestDate = date
                newest = url
            }
        }
        return newest
    }
}
