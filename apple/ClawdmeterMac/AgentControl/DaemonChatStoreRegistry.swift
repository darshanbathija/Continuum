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
    private var sweepTask: Task<Void, Never>?

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
    /// shutdown path so stop() runs cleanly on each held store.
    public func evictAll() {
        for (_, entry) in entries {
            entry.store.stop()
        }
        entries.removeAll()
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
        let cwd = session.worktreePath ?? session.repoKey
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
        guard let url = resolveURL(session.id, session) else {
            registryLogger.warning("could not resolve JSONL for session \(session.id.uuidString, privacy: .public)")
            return nil
        }
        let store = SessionChatStore(sessionId: session.id, sessionFileURL: url)
        store.start()
        return store
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
    /// becomes eligible for eviction.
    private func sweep() {
        let cutoff = Date().addingTimeInterval(-Self.idleEvictionInterval)
        let evictable = entries.compactMap { (id, entry) -> UUID? in
            guard entry.subscriberCount == 0, entry.lastTouchedAt < cutoff else { return nil }
            return id
        }
        for id in evictable {
            evict(sessionId: id)
        }
    }

    /// Cap-driven eviction: when residentCount exceeds the hard limit,
    /// drop the least-recently-touched entries that have zero subscribers
    /// until we're back under the cap. Active-subscriber entries never
    /// evict.
    private func enforceMaxResidentStores() {
        guard entries.count > Self.maxResidentStores else { return }
        let idleSorted = entries
            .filter { $0.value.subscriberCount == 0 }
            .sorted { $0.value.lastTouchedAt < $1.value.lastTouchedAt }
        for (id, _) in idleSorted {
            if entries.count <= Self.maxResidentStores { break }
            evict(sessionId: id)
        }
    }

    private func evict(sessionId: UUID) {
        guard let entry = entries[sessionId] else { return }
        entry.store.stop()
        entries.removeValue(forKey: sessionId)
        registryLogger.info("evicted session=\(sessionId.uuidString, privacy: .public) resident=\(self.entries.count)")
    }
}
