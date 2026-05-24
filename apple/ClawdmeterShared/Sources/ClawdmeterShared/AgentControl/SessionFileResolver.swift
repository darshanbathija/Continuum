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
    private let geminiTmpRoot: URL
    private let resolveClaudeURL: @Sendable (AgentSession) -> URL?
    private var codexLinks: [UUID: URL] = [:]
    private var geminiLinks: [UUID: URL] = [:]
    /// v0.6.0 (eng review 1C fix): LRU access order for `geminiLinks`.
    /// Bounded at 200 entries to cover active-session-count (~20) +
    /// recent history without unbounded growth. Oldest entries evicted
    /// when we cross the cap. Active sessions stay in the cache because
    /// they're touched on every poll.
    private var geminiLinkOrder: [UUID] = []
    private let geminiLinkCap: Int = 200
    /// v0.6.0 (eng review 1C fix): Antigravity brain dir cache. Maps
    /// session id → brain URL. Bounded LRU with path-exists invalidation
    /// on every read — Antigravity GC can sweep older brains under us.
    private var brainLinks: [UUID: URL] = [:]
    private var brainLinkOrder: [UUID] = []
    /// Activity-window grace after `session.lastEventAt`. Rollouts modified
    /// more than this far past `lastEventAt` are not considered candidates
    /// for the session (likely belong to a different session entirely).
    private let activityGrace: TimeInterval
    private let lock = NSLock()

    public init(
        codexSessionsRoot: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        geminiTmpRoot: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".gemini/tmp", isDirectory: true),
        activityGrace: TimeInterval = 5 * 60,
        resolveClaudeURL: @escaping @Sendable (AgentSession) -> URL?
    ) {
        self.codexSessionsRoot = codexSessionsRoot
        self.geminiTmpRoot = geminiTmpRoot
        self.activityGrace = activityGrace
        self.resolveClaudeURL = resolveClaudeURL
    }

    // MARK: - Public API

    public func resolve(session: AgentSession) -> URL? {
        switch session.agent {
        case .claude:
            return resolveClaudeURL(session)
        case .codex:
            return resolveCodex(session: session)
        case .gemini:
            return resolveGemini(session: session)
        case .opencode:
            // PR #29: OpenCode sessions don't have a JSONL transcript
            // file on disk — the conversation lives inside `opencode
            // serve`'s shared process state. OpencodeSSEAdapter pulls
            // transcript events directly off the SSE stream.
            return nil
        case .cursor:
            // Cursor CLI resume/import needs Cursor chat ids rather than a
            // Claude/Codex JSONL path. The importer will attach a Cursor
            // transcript source once it can prove those ids.
            return nil
        case .unknown:
            // X3: forward-compat unknown agent — no transcript file we
            // know how to locate. UI surfaces render as "Other agent".
            return nil
        }
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

    // MARK: - Gemini resolution

    /// Mirror of `resolveCodex` for Gemini sessions. Gemini writes per-
    /// session JSONL files at `~/.gemini/tmp/<repo-slug>/chats/session-
    /// <timestamp>-<short-uuid>.jsonl`. The `<short-uuid>` is the first 8
    /// chars of the session's UUID — so if we know our spawn passed
    /// `--session-id <uuid>` we could match by prefix, but for the simpler
    /// case we just pick the newest file whose mtime falls within the
    /// session's activity window (mirrors Codex logic).
    private func resolveGemini(session: AgentSession) -> URL? {
        // v0.6.0: Antigravity 2 stopped writing the per-session JSONL
        // files this method used to resolve. The Plan pane (via the
        // `/sessions/:id/antigravity-plan` endpoint) is the v2-native
        // surface. Disk mode reads brain dirs via `findAntigravityBrain`
        // below; this legacy method falls through to the cached path
        // for any STILL-EXISTING v0.42 sessions on disk during the
        // migration window. New sessions return nil → empty chat pane
        // (Plan pane carries the content).
        lock.lock()
        let cached = lookupBoundedCache(id: session.id, store: geminiLinks, order: &geminiLinkOrder)
        lock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        // Audit P1 fix: the geminiLinks cache had a reader but no writer
        // — every lookup missed. Scan the legacy `.gemini/tmp/<uuid>/`
        // tree once per session and record the JSONL if found, so the
        // next hot path is fast. Returns nil for v2-native sessions
        // (no legacy file on disk).
        let candidate = locateLegacyGeminiJSONL(for: session)
        if let candidate {
            lock.lock()
            insertBoundedCache(
                id: session.id,
                url: candidate,
                store: &geminiLinks,
                order: &geminiLinkOrder,
                cap: geminiLinkCap
            )
            lock.unlock()
        }
        return candidate
    }

    /// Locate the JSONL transcript for a pre-v0.6.0 Gemini session under
    /// `~/.gemini/tmp/<session-uuid>/`. Walks the dir tree once looking
    /// for any `*.jsonl` whose mtime falls within the session's activity
    /// window. Returns nil when nothing matches (the common case on
    /// Antigravity 2 installs).
    private func locateLegacyGeminiJSONL(for session: AgentSession) -> URL? {
        let dir = geminiTmpRoot.appendingPathComponent(session.id.uuidString, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        let candidates: [URL]
        do {
            candidates = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        } catch {
            return nil
        }
        return candidates
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lTime = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rTime = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lTime > rTime
            }
            .first
    }

    /// v0.6.0 (eng review 1C fix): bounded LRU helper. Touches the entry
    /// to mark it recently-used (moves it to the back of `order`).
    /// Returns nil if the id isn't in the store. Caller holds `lock`.
    private func lookupBoundedCache(
        id: UUID,
        store: [UUID: URL],
        order: inout [UUID]
    ) -> URL? {
        guard let url = store[id] else { return nil }
        if let idx = order.firstIndex(of: id) {
            order.remove(at: idx)
        }
        order.append(id)
        return url
    }

    /// v0.6.0 (eng review 1C fix): bounded LRU writer. Inserts the entry
    /// and evicts the oldest if we crossed the cap. Caller holds `lock`.
    private func insertBoundedCache(
        id: UUID,
        url: URL,
        store: inout [UUID: URL],
        order: inout [UUID],
        cap: Int
    ) {
        if store[id] != nil {
            if let idx = order.firstIndex(of: id) {
                order.remove(at: idx)
            }
        }
        store[id] = url
        order.append(id)
        while order.count > cap {
            let evicted = order.removeFirst()
            store.removeValue(forKey: evicted)
        }
    }

    /// v0.6.0 — resolves the brain dir for a Gemini session. Used by the
    /// daemon's `/sessions/:id/antigravity-plan` endpoint as a faster path
    /// than reading the index on every poll.
    ///
    /// Algorithm:
    ///   1. Look up cached brain URL. If still present on disk, return it
    ///      (and touch the LRU).
    ///   2. If cache miss OR path no longer exists (Antigravity GC'd),
    ///      fall through to the BrainSummaryIndexer lookup via cwd.
    ///   3. Cache the result + return.
    ///
    /// Returns nil when no matching brain dir can be located (fresh
    /// session before Antigravity has written anything, or pre-v2 install).
    public func findAntigravityBrain(
        for session: AgentSession,
        antigravityDataDir: URL? = nil
    ) -> URL? {
        // v0.8 schema v5: chat sessions have nil repoKey and no Antigravity
        // brain — short-circuit early so we never feed nil into URL paths.
        guard session.kind == .code, session.repoKey != nil else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let dataDir = antigravityDataDir
            ?? home.appendingPathComponent(".gemini/antigravity", isDirectory: true)

        lock.lock()
        if let cached = lookupBoundedCache(id: session.id, store: brainLinks, order: &brainLinkOrder) {
            lock.unlock()
            // Path-exists invalidation: if Antigravity GC swept this
            // brain mid-session, fall through to re-resolve. Logged
            // via OSLog so we can audit how often Antigravity GCs.
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
            lock.lock()
            brainLinks.removeValue(forKey: session.id)
            if let idx = brainLinkOrder.firstIndex(of: session.id) {
                brainLinkOrder.remove(at: idx)
            }
            lock.unlock()
        } else {
            lock.unlock()
        }

        // Tier 1: BrainSummaryIndex reverse lookup by cwd.
        let indexURL = dataDir.appendingPathComponent("agyhub_summaries_proto.pb", isDirectory: false)
        let index = BrainSummaryIndexer.read(at: indexURL)
        // Force-unwrap is safe: kind/repoKey guard at the top short-circuited
        // chat sessions and any code session with nil repoKey.
        let cwdURL = URL(fileURLWithPath: session.repoKey!)
        let candidates = BrainSummaryIndexer.lookup(cwd: cwdURL, in: index)
        guard !candidates.isEmpty else { return nil }

        // Of the candidates, pick the brain with the newest mtime that's
        // within the session's activity window.
        let brainsDir = dataDir.appendingPathComponent("brain", isDirectory: true)
        let windowStart = session.createdAt
        let windowEnd = session.lastEventAt.addingTimeInterval(activityGrace)
        var bestURL: URL?
        var bestDate = Date.distantPast
        for uuid in candidates {
            let url = brainsDir.appendingPathComponent(uuid, isDirectory: true)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            // Allow brains slightly outside the window — daemon may
            // start mid-session. Prefer windowed candidates but accept
            // out-of-window if nothing else matches.
            if mtime >= windowStart && mtime <= windowEnd && mtime > bestDate {
                bestDate = mtime
                bestURL = url
            }
        }
        if bestURL == nil {
            // Fall back to newest across all candidates.
            for uuid in candidates {
                let url = brainsDir.appendingPathComponent(uuid, isDirectory: true)
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if mtime > bestDate { bestDate = mtime; bestURL = url }
            }
        }

        guard let resolved = bestURL else { return nil }
        lock.lock()
        insertBoundedCache(
            id: session.id,
            url: resolved,
            store: &brainLinks,
            order: &brainLinkOrder,
            cap: geminiLinkCap
        )
        lock.unlock()
        return resolved
    }

    /// Newest `.jsonl` under `~/.gemini/tmp/*/chats/` whose mtime is in
    /// `session.createdAt … lastEventAt + activityGrace`.
    private func findGeminiChat(for session: AgentSession, modifiedAfter: Date?) -> URL? {
        let windowStart = session.createdAt
        let windowEnd = session.lastEventAt.addingTimeInterval(activityGrace)
        guard let enumerator = FileManager.default.enumerator(
            at: geminiTmpRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            // Belt-and-braces: only consider files under a `chats/` parent
            // dir to skip the per-repo `logs.json` user-prompt stream.
            guard url.path.contains("/chats/") else { continue }
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

    /// Newest `.jsonl` under any `~/.gemini/tmp/*/chats/` — used for the
    /// synthetic-preview fallback path on Read-only JSONL viewer.
    public func findNewestGeminiChat() -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: geminiTmpRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.path.contains("/chats/") else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date > newestDate {
                newestDate = date
                newest = url
            }
        }
        return newest
    }
}
