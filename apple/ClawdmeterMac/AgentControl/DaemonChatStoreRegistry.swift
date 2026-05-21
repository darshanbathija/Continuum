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
/// `TranscriptLoader.load(maxMessages: 500)` at the legacy
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
        sweepTask?.cancel()
    }

    // MARK: - Public API

    /// Get or create the store for a session AND increment subscriber count.
    /// Use for long-lived subscribers (WS in Phase 2). Pair with
    /// `release(sessionId:)` on disconnect.
    public func acquire(for session: AgentSession) -> SessionChatStore? {
        startSweepIfNeeded()
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
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
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
            // Codex SDK: sdkOnly (no JSONL exists).
            if session.agent == .codex && session.codexChatBackend == .sdk {
                let store = SessionChatStore(sessionId: session.id, sdkOnly: true)
                store.start()
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
                // beats wrong thread.)
                let store = SessionChatStore(sessionId: session.id, sdkOnly: true)
                store.start()
                return store
            }
            // Codex CLI chat: use the legacy newest-rollout resolver. Safe
            // because Codex CLI rollouts are per-process; the freshly-spawned
            // chat session's rollout will be the newest one in `~/.codex/sessions/`.
            if session.agent == .codex && session.codexChatBackend == .cli {
                if let url = Self.newestCodexJSONL() {
                    let store = SessionChatStore(sessionId: session.id, sessionFileURL: url)
                    store.start()
                    return store
                }
            }
            // Default chat fallback: sdkOnly store. Keeps the rendering empty
            // but never wrong — better than surfacing unrelated transcripts.
            let store = SessionChatStore(sessionId: session.id, sdkOnly: true)
            store.start()
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
        let home = FileManager.default.homeDirectoryForCurrentUser
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
            return id
        }
        for id in evictableIds {
            evict(sessionId: id)
        }
        let evictablePaths = pathEntries.compactMap { (url, entry) -> URL? in
            guard entry.subscriberCount == 0, entry.lastTouchedAt < cutoff else { return nil }
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
        for (id, entry) in entries where entry.subscriberCount == 0 {
            idleSorted.append((.session(id), entry.lastTouchedAt))
        }
        for (url, entry) in pathEntries where entry.subscriberCount == 0 {
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

    private func evict(sessionId: UUID) {
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
                registryLogger.info("warmup complete: \(recents.count) JSONLs preloaded")
            }
        }
    }

    /// Walk `~/.claude/projects/` and `~/.codex/sessions/` for the `limit`
    /// most-recently-modified `.jsonl` files. `nonisolated` so the
    /// background `Task.detached` in `warm()` can call it off-main.
    nonisolated private static func scanForRecentJSONLs(limit: Int) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
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
