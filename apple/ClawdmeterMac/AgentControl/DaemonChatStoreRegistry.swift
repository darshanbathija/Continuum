import Foundation
import ClawdmeterShared
import OSLog

private let registryLogger = Logger(subsystem: "com.clawdmeter.mac", category: "DaemonChatStoreRegistry")

/// Daemon-side registry of long-lived per-session `SessionChatStore`s.
///
/// Phase 0a (/plan-eng-review + Codex outside-voice P0): the Mac UI's
/// `SessionsView` already holds `chatStores: [UUID: SessionChatStore]` for
/// the dashboard, but the daemon has no equivalent. Every iPhone
/// `GET /chat-snapshot` request reparses the full JSONL via
/// `TranscriptLoader.load(maxMessages: 200)` at the legacy
/// `handleGetChatSnapshot` site. On Tailscale this means RTT + full reparse
/// every 3 seconds — the shared-pipeline bottleneck that makes iPhone *and*
/// Mac chat surfaces feel sluggish.
///
/// This registry mirrors the UI pattern at the daemon layer. It owns a
/// long-lived `SessionChatStore` per session id, keeps it warm while at
/// least one subscriber (HTTP or WS) holds a reference, and evicts after
/// an idle grace window so a flapping iPhone client (cellular handoff,
/// background → foreground) doesn't pay for a fresh reverse-tail every
/// reconnect.
///
/// Caller pattern (HTTP /chat-snapshot is the v1 user):
///   let store = registry.snapshotStore(for: session)
///   // Read store?.snapshot.items / .updateCounter directly.
///
/// Caller pattern (WS subscribe, lands in Phase 2):
///   let store = registry.acquire(for: session)
///   ... forward snapshot changes to the WS channel ...
///   registry.release(sessionId: session.id)   // on disconnect
@MainActor
public final class DaemonChatStoreRegistry {

    /// Per-entry retention book-keeping. Subscriber count drops to zero
    /// when all HTTP-snapshot or WS subscribers release; an idle sweep
    /// evicts the store after `idleEvictionInterval`.
    private struct Entry {
        let store: SessionChatStore
        var subscriberCount: Int
        var lastTouchedAt: Date
    }

    private var entries: [UUID: Entry] = [:]
    /// v0.5.3: parallel map keyed by absolute JSONL path. Used by the
    /// daemon's `/transcript` endpoint which doesn't have a session id —
    /// the path itself is the identity. Lifecycle semantics identical to
    /// the session-id-keyed map (idle eviction, max cap).
    private var pathEntries: [URL: Entry] = [:]
    private var sweepTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?

    /// Idle window after the last subscriber drops before the entry is
    /// evicted. 5 minutes balances "warm enough for tab-back" against
    /// "don't pin 50 stores in memory forever."
    public static let idleEvictionInterval: TimeInterval = 5 * 60

    /// Sweep cadence. Idle entries older than `idleEvictionInterval` are
    /// dropped on each sweep.
    public static let sweepInterval: TimeInterval = 60

    /// Hard cap on resident stores. Codex flagged unbounded growth as a
    /// risk under many parallel sessions; 20 is generous for typical
    /// passenger-seat use and well below memory concerns at ~5MB/store.
    public static let maxResidentStores: Int = 20

    /// File-URL resolver, injected. AppRuntime wires in the Phase 0b
    /// `SessionFileResolver` (with Codex respawn-lineage tracking) via a
    /// closure that delegates to it. The default fallback exists for
    /// tests and pre-Phase-0b back-compat — it mirrors the legacy
    /// `AgentControlServer.handleGetChatSnapshot` path-resolution rules.
    private let resolveURL: @MainActor (UUID, AgentSession) -> URL?

    public init(
        resolveURL: @escaping @MainActor (UUID, AgentSession) -> URL? = DaemonChatStoreRegistry.defaultResolveURL
    ) {
        self.resolveURL = resolveURL
    }

    deinit {
        // Audit P2 fix: `deinit` is implicitly non-isolated and the
        // class is `@MainActor`-isolated. Capture the task ref into a
        // local non-isolated copy so Swift 6 strict-concurrency doesn't
        // complain about accessing actor-isolated state from a non-
        // isolated context. `Task.cancel()` is itself thread-safe.
        let sweep = sweepTask
        sweep?.cancel()
        let warmup = warmupTask
        warmup?.cancel()
    }

    // MARK: - Public API

    /// Get or create the store for a session AND increment subscriber count.
    /// Use for long-lived subscribers (WS in Phase 2). Pair with
    /// `release(sessionId:)` on disconnect.
    public func acquire(for session: AgentSession) -> SessionChatStore? {
        startSweepIfNeeded()
        // Audit P0 #4 (plan-approval rollover): pre-fix, this path
        // returned the cached store WITHOUT checking whether the
        // tailed JSONL is still the right one. After a Codex plan
        // approval, the rollout flips from the read-only one to a
        // workspace-write one — long-lived WS subscribers (chat-
        // subscribe) kept tailing the old file and the chat froze on
        // the plan. Run the same file-swap logic the one-shot
        // snapshotStore() path uses so WS and HTTP paths converge on
        // the live rollout.
        rolloverChatJSONLIfNeeded(session: session)
        if var entry = entries[session.id] {
            entry.subscriberCount += 1
            entry.lastTouchedAt = Date()
            entries[session.id] = entry
            return entry.store
        }
        guard let store = createStore(for: session) else { return nil }
        let entry = Entry(
            store: store,
            subscriberCount: 1,
            lastTouchedAt: Date()
        )
        entries[session.id] = entry
        enforceMaxResidentStores()
        registryLogger.info("acquire session=\(session.id.uuidString, privacy: .public) resident=\(self.entries.count)")
        return store
    }

    /// Get or create the store for a snapshot read WITHOUT counting as a
    /// long-lived subscriber. Used by one-shot HTTP `/chat-snapshot`
    /// handlers. The store is still retained through the idle window, so
    /// a burst of HTTP polls in a row reuses parsed state.
    public func snapshotStore(for session: AgentSession) -> SessionChatStore? {
        startSweepIfNeeded()
        // Merged from PR #69 (audit P1: .code rollover) + this branch
        // (V2 audit P0 #4: hoist into a helper so `acquire()` runs the
        // same check). The helper handles BOTH `.chat` and `.code`
        // sessions now — see `rolloverChatJSONLIfNeeded` below.
        rolloverChatJSONLIfNeeded(session: session)
        if var entry = entries[session.id] {
            entry.lastTouchedAt = Date()
            entries[session.id] = entry
            return entry.store
        }
        guard let store = createStore(for: session) else { return nil }
        let entry = Entry(
            store: store,
            subscriberCount: 0,
            lastTouchedAt: Date()
        )
        entries[session.id] = entry
        enforceMaxResidentStores()
        registryLogger.info("snapshot-cache session=\(session.id.uuidString, privacy: .public) resident=\(self.entries.count)")
        return store
    }

    /// Per-snapshot file-swap logic. Hoisted out of `snapshotStore(for:)`
    /// so the long-lived `acquire(for:)` path runs the same check.
    /// Audit fixes folded together here:
    ///
    /// - **V2 audit P0 #4 (chat path)**: a WS `chat-subscribe`
    ///   subscriber attached before a Codex plan approval kept tailing
    ///   the read-only rollout forever and the chat froze on the
    ///   plan. Calling this helper from `acquire(for:)` closes that
    ///   gap.
    /// - **PR #69 audit P1 (code path)**: Codex plan-mode
    ///   approve-plan respawns under a new rollout JSONL. Without
    ///   running the file-swap for `.code` sessions, the registry
    ///   kept tailing the stale plan-mode file and iOS chat-subscribe
    ///   WS clients saw no execution turns.
    ///
    /// Resolution rules differ by kind:
    /// - **`.chat`**: chat-specific selectors. `newestCodexJSONLMatching`
    ///   is scoped to this session's cwd + createdAt (won't pick up a
    ///   concurrent Codex run on the same machine). `chatCwdClaudeJSONL`
    ///   is the chat-mode Claude JSONL.
    /// - **`.code`**: injected `resolveURL` closure (delegates to
    ///   `SessionFileResolver` in production for respawn-lineage
    ///   tracking).
    ///
    /// CRITICAL: switches the file IN PLACE on the existing store
    /// (`switchTailedFile`) so the Mac UI's `@ObservedObject` doesn't
    /// invalidate — the chat thread would otherwise freeze on the
    /// previous turn's snapshot.
    private func rolloverChatJSONLIfNeeded(session: AgentSession) {
        guard let entry = entries[session.id] else { return }
        let desiredURL: URL?
        switch session.kind {
        case .chat:
            if session.agent == .codex, session.codexChatBackend == .cli {
                desiredURL = Self.newestCodexJSONLMatching(
                    cwd: session.effectiveCwd,
                    after: session.createdAt
                )
            } else if session.agent == .claude {
                desiredURL = Self.chatCwdClaudeJSONL(chatCwd: session.effectiveCwd)
            } else {
                desiredURL = nil
            }
        case .code:
            // v27: paneless harness Code sessions are sdkOnly (bridge-fed) —
            // never roll them over to a JSONL, or every snapshot would drop +
            // rebuild the store and lose streamed content. Only LEGACY tmux Code
            // sessions (real pane) track rollout lineage.
            if session.tmuxPaneId == nil {
                desiredURL = nil
            } else {
                // Plan-mode rollout swap on approve-plan (PR #69 audit P1).
                // resolveURL delegates to SessionFileResolver which tracks
                // Codex respawn lineage via record(sessionId:rolloutURL:).
                desiredURL = resolveURL(session.id, session)
            }
        }
        guard let desired = desiredURL, entry.store.currentFileURL != desired else { return }
        if entry.store.isSDKOnly {
            // The existing entry is an sdkOnly fallback (e.g. Codex CLI
            // chat created before its first rollout existed); switchTailedFile
            // is a no-op there. Drop the entry and let createStore rebuild.
            // This is the one place where @ObservedObject invalidation is
            // acceptable: no real chat content has streamed yet.
            entry.store.stop()
            entries.removeValue(forKey: session.id)
            return
        }
        entry.store.switchTailedFile(to: desired)
        var refreshed = entry
        refreshed.lastTouchedAt = Date()
        entries[session.id] = refreshed
        registryLogger.info("jsonl-rollover session=\(session.id.uuidString, privacy: .public) kind=\(String(describing: session.kind), privacy: .public) → \(desired.lastPathComponent, privacy: .public)")
    }

    /// Decrement the subscriber count for a long-lived subscriber. Idempotent
    /// on unknown ids. When count hits zero, the entry enters its
    /// idle-eviction grace window.
    public func release(sessionId: UUID) {
        guard var entry = entries[sessionId] else { return }
        entry.subscriberCount = max(0, entry.subscriberCount - 1)
        entry.lastTouchedAt = Date()
        entries[sessionId] = entry
    }

    /// Force-evict everything immediately. Used by tests and the daemon's
    /// shutdown path so stop() runs cleanly on each held store. Walks
    /// both the session-id-keyed and path-keyed maps.
    public func evictAll() {
        for (_, entry) in entries {
            entry.store.stop()
        }
        entries.removeAll()
        for (_, entry) in pathEntries {
            entry.store.stop()
        }
        pathEntries.removeAll()
    }

    // MARK: - Introspection (tests + observability)

    public var residentCount: Int { entries.count }

    public func isResident(_ sessionId: UUID) -> Bool {
        entries[sessionId] != nil
    }

    public func subscriberCount(for sessionId: UUID) -> Int {
        entries[sessionId]?.subscriberCount ?? 0
    }

    // MARK: - Default file-URL resolution

    /// Phase 0a default. Mirrors `AgentControlServer.handleGetChatSnapshot`'s
    /// existing path-resolution rules. Phase 0b replaces this with a real
    /// `SessionFileResolver` that tracks Codex respawn lineage so
    /// `approve-plan` doesn't break continuity.
    ///
    /// v0.8.0 agy-migration: Gemini sessions spawned via Antigravity 2's
    /// agentapi don't have JSONL files at all — chat state lives in a
    /// SQLite WAL at ~/.gemini/antigravity/conversations/<id>.db. We
    /// surface that URL here so future SessionChatStore work (v0.8.1+
    /// ingest path) can consume `AntigravityConversationDB` (T6) instead
    /// of trying to JSONL-parse a binary database.
    @MainActor
    public static func defaultResolveURL(sessionId: UUID, session: AgentSession) -> URL? {
        let cwd = session.effectiveCwd
        if session.agent == .claude {
            return SessionChatStore.resolveSessionFileURL(repoCwd: cwd)
        } else {
            return Self.newestCodexJSONL()
        }
    }

    /// Same logic as `AgentControlServer.newestCodexJSONL()` — kept here so
    /// the registry's default resolver doesn't reach across the server's
    /// private API. Phase 0b replaces this entirely.
    nonisolated public static func newestCodexJSONL() -> URL? {
        let sessionsDir = ClawdmeterRealHome.url()
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
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

    /// v0.8 QA F1: find the newest Codex rollout whose `session_meta.cwd`
    /// matches `cwd` AND whose mtime is >= `after`. This isolates a
    /// chat-mode Codex CLI session's rollout from any other Codex
    /// activity on the machine — without this, `newestCodexJSONL()`
    /// surfaces ANY codex run's transcript (concurrent chat, another
    /// worktree, manual `codex` in Terminal). Returns nil when no
    /// rollout for this session exists yet (e.g. before the user's first
    /// prompt processes).
    nonisolated public static func newestCodexJSONLMatching(cwd: String, after: Date) -> URL? {
        let sessionsDir = ClawdmeterRealHome.url()
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        // Gather candidates sorted by mtime desc so we can early-exit
        // on the first cwd match.
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            // Skip rollouts that predate session creation — those are
            // from prior runs, can't belong to this session.
            guard date >= after else { continue }
            candidates.append((url, date))
        }
        candidates.sort { $0.1 > $1.1 }
        let targetCwd = (cwd as NSString).standardizingPath
        for (url, _) in candidates {
            if let metaCwd = readSessionMetaCwd(from: url),
               (metaCwd as NSString).standardizingPath == targetCwd {
                return url
            }
        }
        return nil
    }

    /// Peek the first line of a Codex rollout JSONL and return its
    /// `session_meta.cwd` value, or nil if the file is empty / malformed /
    /// not yet a session_meta record.
    nonisolated private static func readSessionMetaCwd(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        // First line only — session_meta is always the first record.
        guard let newlineIdx = data.firstIndex(of: 0x0a) else { return nil }
        let firstLine = data.prefix(newlineIdx)
        guard let json = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any] else {
            return nil
        }
        guard (json["type"] as? String) == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String else {
            return nil
        }
        return cwd
    }

    // MARK: - Internals

    private func createStore(for session: AgentSession) -> SessionChatStore? {
        // v0.8 chat sessions: route by backend.
        //
        // - Codex SDK chat → sdkOnly store, populated by CodexSDKEventIngestor.
        //   No JSONLTail (the SDK doesn't write JSONL).
        // - Claude chat (CLI) → JSONLTail at exact encoded chat-cwd path. The
        //   chat-cwd is `<AppSupport>/chat-sessions/<sessionUUID>/`, unique per
        //   session, so the encoded `~/.claude/projects/-Users-..-chat-sessions-<UUID>/`
        //   directory contains only this chat's JSONLs — no fuzzy parent walk
        //   needed and no risk of surfacing unrelated transcripts.
        // - Codex CLI chat → newest rollout JSONL via the legacy default
        //   resolver (good enough for v0.8; the CLI writes to
        //   `~/.codex/sessions/<date>/rollout-...jsonl` keyed by date/uuid).
        if session.kind == .chat {
            // Codex SDK: sdkOnly (no JSONL exists). v0.9.x.1 replays the
            // disk-backed SDK transcript mirror so chat history survives
            // idle-eviction — without this, every 5-min idle wipes the
            // visible thread even though the SDK server-side thread is
            // still resumable via op:"resume" with the persisted threadId.
            if session.agent == .codex && session.codexChatBackend == .sdk {
                let store = SessionChatStore(sessionId: session.id, sdkOnly: true)
                store.start()
                SDKChatTranscriptMirror.replay(sessionId: session.id, into: store)
                return store
            }
            // Claude chat (CLI): point JSONLTail at the encoded chat-cwd dir.
            // The dir-name encoding mirrors Claude's `/` → `-`, `_` → `-`,
            // ` ` → `-` rule (see SessionChatStore.encodeCwd). Picking the
            // newest .jsonl in that dir is safe because the dir is unique
            // per session (chat-cwd contains the session UUID).
            if session.agent == .claude {
                if let url = Self.chatCwdClaudeJSONL(chatCwd: session.effectiveCwd) {
                    let store = SessionChatStore(sessionId: session.id, sessionFileURL: url)
                    store.start()
                    return store
                }
                // No JSONL yet — fall through to sdkOnly. The session will
                // remain empty until the CLI writes its first turn; the next
                // snapshotStore() call after that point will see the file.
                // (For v0.8 the store stays sdkOnly forever; v0.8.x can wire
                // a directory-watch retry. Acceptable trade — empty thread
                // beats wrong thread.) v0.9.x.1: replay the transcript
                // mirror in case the user opened the chat post-evict.
                let store = SessionChatStore(sessionId: session.id, sdkOnly: true)
                store.start()
                SDKChatTranscriptMirror.replay(sessionId: session.id, into: store)
                return store
            }
            // Codex CLI chat: bind to the rollout whose session_meta.cwd
            // matches this session's chat-cwd. Without the cwd gate, any
            // concurrent codex run on the machine (another chat, another
            // worktree, manual `codex` in Terminal) would surface its
            // transcript inside THIS chat's UI. After-gate excludes
            // pre-existing rollouts. Falls through to sdkOnly when the
            // user hasn't sent their first prompt yet (no rollout
            // written) — snapshotStore upgrades the store later via the
            // file-swap path when the matching rollout appears.
            if session.agent == .codex && session.codexChatBackend == .cli {
                if let url = Self.newestCodexJSONLMatching(
                    cwd: session.effectiveCwd,
                    after: session.createdAt
                ) {
                    let store = SessionChatStore(sessionId: session.id, sessionFileURL: url)
                    store.start()
                    return store
                }
            }
            // v0.23.2 OpenCode chat — same shape as the agentapi branch
            // below. No JSONL on disk; messages arrive via the opencode
            // SSE `/event` stream and `OpencodeSSEAdapter` routes
            // `message.added` events into this store via
            // `appendSDKMessages`. The chat-subscribe WS reads
            // uniformly. The store stays sdkOnly so SDKChatTranscriptMirror
            // persists messages across idle-eviction.
            if session.agent == .opencode {
                let store = SessionChatStore(sessionId: session.id, sdkOnly: true)
                store.start()
                SDKChatTranscriptMirror.replay(sessionId: session.id, into: store)
                return store
            }
            // Default chat fallback: sdkOnly store. v0.9.x.1 also replays
            // the transcript mirror for the rare case where a chat session
            // landed here via the "unknown agent" fall-through.
            let store = SessionChatStore(sessionId: session.id, sdkOnly: true)
            store.start()
            SDKChatTranscriptMirror.replay(sessionId: session.id, into: store)
            return store
        }
        // v27 Code-tab harness migration: paneless harness-driven Code sessions
        // (cursor/grok always; gemini always — headless `agy` by default, gRPC
        // Cascade when its flag is on; codex via app-server when its flag is on)
        // are fed by the AcpHarnessBridge through `appendSDKMessages` — there is
        // NO JSONL to tail. Use an sdkOnly store. Distinguished from a LEGACY tmux
        // Code session (real pane + JSONL) by the absence of a tmux pane, so old
        // tmux codex/cursor sessions keep resolving their JSONL below. Gemini has
        // no tmux spawn path at all, so paneless gemini is always harness-driven.
        if session.tmuxPaneId == nil,
           session.agent == .cursor
             || session.agent == .grok
             || session.agent == .gemini
             || (session.agent == .codex && AgentControlServer.codexAppServerEnabled) {
            let store = SessionChatStore(sessionId: session.id, sdkOnly: true)
            store.start()
            SDKChatTranscriptMirror.replay(sessionId: session.id, into: store)
            return store
        }
        guard let url = resolveURL(session.id, session) else {
            registryLogger.warning("could not resolve JSONL for session \(session.id.uuidString, privacy: .public)")
            return nil
        }
        let store = SessionChatStore(sessionId: session.id, sessionFileURL: url)
        store.start()
        return store
    }

    /// Resolve `~/.claude/projects/<encoded-chat-cwd>/<newest>.jsonl` for a
    /// chat-mode Claude session. The encoded dir name is deterministic per
    /// session UUID, so we can target it directly without the parent-walk
    /// fuzzy-match that ISSUE-003 fixed for unrelated paths.
    private static func chatCwdClaudeJSONL(chatCwd: String) -> URL? {
        let home = ClawdmeterRealHome.url()
        let projects = home.appendingPathComponent(".claude/projects")
        let encoded = SessionChatStore.encodeCwd((chatCwd as NSString).standardizingPath)
        let dir = projects.appendingPathComponent(encoded)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let jsonls = contents.filter { $0.pathExtension == "jsonl" }
        return jsonls.max { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad < bd
        }
    }

    private func startSweepIfNeeded() {
        guard sweepTask == nil else { return }
        let interval = Self.sweepInterval
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                await MainActor.run { self.sweep() }
            }
        }
    }

    /// Evict entries whose subscriber count is zero AND whose
    /// lastTouchedAt is older than the idle window. Subscribers always
    /// touch the timestamp on access so a busy WS subscriber never
    /// becomes eligible for eviction. Walks BOTH the session-id-keyed
    /// and path-keyed maps so /transcript path entries also evict
    /// after the idle grace.
    private func sweep() {
        let cutoff = Date().addingTimeInterval(-Self.idleEvictionInterval)
        let evictableIds = entries.compactMap { (id, entry) -> UUID? in
            guard entry.subscriberCount == 0, entry.lastTouchedAt < cutoff else { return nil }
            // F1 guard: an awaiting permission prompt means a daemon-side
            // continuation is parked waiting for the user. Evicting would
            // wipe the @Published prompt state, the UI would disappear,
            // and the next prompt or send would hang forever on the
            // un-resumed continuation. Keep the store resident.
            guard entry.store.pendingPermissionPrompt == nil else { return nil }
            return id
        }
        for id in evictableIds {
            evict(sessionId: id)
        }
        let evictablePaths = pathEntries.compactMap { (url, entry) -> URL? in
            guard entry.subscriberCount == 0, entry.lastTouchedAt < cutoff else { return nil }
            guard entry.store.pendingPermissionPrompt == nil else { return nil }
            return url
        }
        for url in evictablePaths {
            evictPath(url)
        }
    }

    /// Cap-driven eviction: when (session + path) residentCount exceeds
    /// the hard limit, drop the least-recently-touched entries with zero
    /// subscribers until we're back under the cap. Active-subscriber
    /// entries (live WS subscribers, etc.) never evict. Both maps share
    /// the same cap because both reference SessionChatStores of the same
    /// memory weight.
    private func enforceMaxResidentStores() {
        var totalResident = entries.count + pathEntries.count
        guard totalResident > Self.maxResidentStores else { return }
        // Build a unified eviction list across both maps, sorted by
        // lastTouchedAt ascending. We use an enum to keep type-safety
        // when calling the matching evictor.
        enum Key {
            case session(UUID)
            case path(URL)
        }
        var idleSorted: [(Key, Date)] = []
        for (id, entry) in entries where entry.subscriberCount == 0 && entry.store.pendingPermissionPrompt == nil {
            idleSorted.append((.session(id), entry.lastTouchedAt))
        }
        for (url, entry) in pathEntries where entry.subscriberCount == 0 && entry.store.pendingPermissionPrompt == nil {
            idleSorted.append((.path(url), entry.lastTouchedAt))
        }
        idleSorted.sort { $0.1 < $1.1 }
        for (key, _) in idleSorted {
            if totalResident <= Self.maxResidentStores { break }
            switch key {
            case .session(let id):
                evict(sessionId: id)
            case .path(let url):
                evictPath(url)
            }
            totalResident -= 1
        }
    }

    private func evictPath(_ url: URL) {
        guard let entry = pathEntries[url] else { return }
        entry.store.stop()
        pathEntries.removeValue(forKey: url)
        registryLogger.info("evicted path=\(url.path, privacy: .public) pathResident=\(self.pathEntries.count)")
    }

    /// Force-evict a single session entry. v0.8 F3: handleDeleteSession
    /// calls this so the registry doesn't keep a stale store around after
    /// the session is gone — without the explicit call, the entry only
    /// drops on the next 60s sweep, and any path-keyed sibling lingers
    /// until idle eviction. Idempotent.
    public func evict(sessionId: UUID) {
        guard let entry = entries[sessionId] else { return }
        entry.store.stop()
        entries.removeValue(forKey: sessionId)
        registryLogger.info("evicted session=\(sessionId.uuidString, privacy: .public) resident=\(self.entries.count)")
    }

    // MARK: - v0.5.3: by-path lookup for /transcript

    /// Get or create a path-keyed store for the daemon's `/transcript`
    /// endpoint. Mirrors `snapshotStore(for: AgentSession)` but uses the
    /// JSONL URL as the identity — `/transcript` doesn't have a session
    /// id, the path itself is the key. The store's internal `sessionId`
    /// is synthesized deterministically from the path so log lines and
    /// signposts have a stable identifier.
    ///
    /// Same idle eviction + max-cap semantics as the session-id-keyed
    /// stores. A burst of `/transcript` polls in a row reuses the same
    /// parsed state instead of reparsing the 500-message JSONL on
    /// every request.
    public func snapshotStore(forJSONLPath url: URL) -> SessionChatStore? {
        startSweepIfNeeded()
        let canonical = url.standardizedFileURL
        if var entry = pathEntries[canonical] {
            entry.lastTouchedAt = Date()
            pathEntries[canonical] = entry
            return entry.store
        }
        // Synthesize a deterministic UUID from the path so logs/signposts
        // remain stable across daemon restarts for the same JSONL.
        let synthSessionId = Self.uuidForPath(canonical.path)
        let store = SessionChatStore(sessionId: synthSessionId, sessionFileURL: canonical)
        store.start()
        let entry = Entry(
            store: store,
            subscriberCount: 0,
            lastTouchedAt: Date()
        )
        pathEntries[canonical] = entry
        enforceMaxResidentStores()
        registryLogger.info("path-cache new path=\(canonical.path, privacy: .public) resident=\(self.entries.count) pathResident=\(self.pathEntries.count)")
        return store
    }

    public var pathResidentCount: Int { pathEntries.count }

    public func isPathResident(_ url: URL) -> Bool {
        pathEntries[url.standardizedFileURL] != nil
    }

    // MARK: - v0.5.3: warmup on daemon startup

    /// Pre-warm the registry with the N most-recently-modified JSONLs
    /// under `~/.claude/projects/` and `~/.codex/sessions/`. Each store
    /// kicks off a background reverse-tail parse; by the time the iPhone
    /// hits its first `/chat-snapshot` or `/transcript` after Mac
    /// startup, the snapshot is already populated. Eliminates the cold-
    /// cache slowness the user reported on 2026-05-19.
    ///
    /// Safe to call from `AgentControlServer.start()` post-listener-bind.
    /// Runs async on a detached Task so it doesn't block startup.
    public func warm(recentLimit: Int = 5) {
        guard warmupTask == nil else { return }
        let limit = recentLimit
        warmupTask = Task.detached(priority: .utility) { [weak self] in
            let recents = Self.scanForRecentJSONLs(limit: limit)
            await MainActor.run {
                guard let self else { return }
                for url in recents {
                    _ = self.snapshotStore(forJSONLPath: url)
                }
                // Audit P2 fix: clear the slot so a later force-rewarm
                // (e.g. after the user adds a new repo) can run instead
                // of short-circuiting on the lingering completed task.
                self.warmupTask = nil
                registryLogger.info("warmup complete: \(recents.count) JSONLs preloaded")
            }
        }
    }

    /// Walk `~/.claude/projects/` and `~/.codex/sessions/` for the `limit`
    /// most-recently-modified `.jsonl` files. `nonisolated` so the
    /// background `Task.detached` in `warm()` can call it off-main.
    nonisolated private static func scanForRecentJSONLs(limit: Int) -> [URL] {
        let home = ClawdmeterRealHome.url()
        let roots = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
        ]
        var candidates: [(URL, Date)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((url.standardizedFileURL, mtime))
            }
        }
        candidates.sort { $0.1 > $1.1 }
        return candidates.prefix(limit).map(\.0)
    }

    /// Deterministic UUID derived from a path. We use the same SHA-256-
    /// based scheme as `Foundation.UUID(uuidString:)` accepts, but
    /// constructed from the path bytes so the same file always produces
    /// the same id. Cheap to compute, cheap to compare in logs.
    nonisolated private static func uuidForPath(_ path: String) -> UUID {
        // SHA-256(path) → first 16 bytes → UUID. SHA-256 from CryptoKit
        // would import a framework just for this; rolling a tiny FNV-1a
        // hash twice (mixed) is plenty here — the id only matters for
        // observability, NOT security.
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x84222325cbf29ce4
        for byte in path.utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
            h2 = (h2 ^ UInt64(byte ^ 0xA5)) &* 0x100000001b3
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i]     = UInt8((h1 >> (i * 8)) & 0xFF) }
        for i in 0..<8 { bytes[i + 8] = UInt8((h2 >> (i * 8)) & 0xFF) }
        // Set version (4) + variant bits so the UUID is well-formed.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
