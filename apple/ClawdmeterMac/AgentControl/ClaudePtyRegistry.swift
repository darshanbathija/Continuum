import Foundation
import OSLog
import ClawdmeterShared

private let registryLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ClaudePtyRegistry")

/// Owns the live `ClaudePtyHost`s, one per Claude session (Track A).
///
/// Three responsibilities the eng review made load-bearing:
///
/// 1. **Single-flight resume.** A dormant session can be woken from several
///    triggers at once — a mobile send, app-relaunch auto-resume, the next
///    local send. Without a guard each would `claude --resume <same-id>` →
///    double subscription burn + a JSONL both processes corrupt. `resumeOrSpawn`
///    joins concurrent callers onto ONE in-flight `Task`.
///
/// 2. **Hard cap + LRU-suspend.** Each `claude` is ~300MB; the prod box has
///    OOM-crashed twice. A burst of sessions inside the 5-min idle window can
///    pile up, so we bound concurrent live hosts and evict the
///    least-recently-used (keeping its `claudeSessionId` → resumable) before
///    spawning a new one. The IdleSessionSweeper (T8) is the slow path; this
///    is the hard backstop.
///
/// 3. **Crash forwarding.** A host whose child exits unexpectedly calls back
///    here; we drop it from the map and forward `(id, status)` to the daemon
///    so the session goes `.degraded` + offers Resume.
actor ClaudePtyRegistry {

    /// Process-wide shared instance. There is one daemon per app process, so a
    /// single registry owns all Claude PTY hosts. Sharing it (rather than
    /// threading it through every consumer's init) lets the daemon,
    /// SessionScheduler, and SessionConfigChanger all reach the same hosts.
    /// Tests construct their own instances directly.
    static let shared = ClaudePtyRegistry()


    /// Per-session spawn closure: returns full argv (argv[0] = binary) + cwd,
    /// or nil if the session can't be spawned (e.g. claude not found). The
    /// daemon supplies this so the registry stays free of AgentSession/argv
    /// policy.
    struct SpawnPlan: Sendable {
        let argv: [String]
        let cwd: String?
        /// Explicit child environment (already sanitized of the billing-breaking
        /// keys by the caller). Carries the enriched login PATH + repo env so a
        /// PTY `claude` finds node/rg/hooks. The host re-sanitizes defensively,
        /// so the billing rail holds regardless.
        let env: [String: String]
        init(argv: [String], cwd: String?, env: [String: String] = ClaudeSpawnEnv.sanitized()) {
            self.argv = argv
            self.cwd = cwd
            self.env = env
        }
    }

    private var hosts: [UUID: ClaudePtyHost] = [:]
    private var inflight: [UUID: Task<ClaudePtyHost, Error>] = [:]
    private var lastUsed: [UUID: Date] = [:]
    private let maxLiveHosts: Int

    /// Forwarded to the daemon when a host's child exits unexpectedly.
    private var onUnexpectedExit: (@Sendable (UUID, Int32) -> Void)?

    init(maxLiveHosts: Int = 12) {
        self.maxLiveHosts = maxLiveHosts
    }

    func setOnUnexpectedExit(_ handler: @escaping @Sendable (UUID, Int32) -> Void) {
        self.onUnexpectedExit = handler
    }

    /// The live host for a session, if any. Used by send/submit paths and by
    /// `needsResume` ("no live host" ⇒ idle-swept/never-started).
    func host(for id: UUID) -> ClaudePtyHost? { hosts[id] }

    func hasLiveHost(_ id: UUID) -> Bool { hosts[id] != nil }

    func touch(_ id: UUID) {
        lastUsed[id] = Date()
        if let h = hosts[id] { Task { await h.touch() } }
    }

    /// Single-flight spawn-or-return. Concurrent callers for the same id join
    /// the same Task. `plan()` builds the argv lazily so a no-op (already-live)
    /// path doesn't pay for it.
    func resumeOrSpawn(id: UUID, plan: @Sendable @escaping () -> SpawnPlan?) async throws -> ClaudePtyHost {
        if let existing = hosts[id] {
            lastUsed[id] = Date()
            return existing
        }
        if let pending = inflight[id] {
            return try await pending.value   // join the in-flight spawn
        }
        let task = Task<ClaudePtyHost, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            guard let p = plan() else {
                throw NSError(domain: "ClaudePtyRegistry", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "no spawn plan (claude not found?)"])
            }
            await self.enforceCapBeforeSpawn()
            let host = ClaudePtyHost(sessionId: id, argv: p.argv, cwd: p.cwd, env: p.env)
            let forward = await self.exitForwarder()
            await host.setOnUnexpectedExit(forward)
            try await host.start()
            // A suspend()/delete() may have raced in while host.start() awaited.
            // store() refuses (returns false) if this id was suspended mid-spawn;
            // we then tear the just-started host down instead of leaking a live
            // `claude` for a session the daemon already deleted.
            guard await self.store(id: id, host: host) else {
                await host.kill()
                throw CancellationError()
            }
            // Cold-spawn only: block until the Ink TUI is actually accepting
            // input before handing the host back. The caller (send / approve-
            // plan) submits the first prompt immediately, and writing it before
            // the TUI enters raw mode gets it swallowed (blank chat, no turn).
            await host.waitUntilReady()
            return host
        }
        inflight[id] = task
        defer { inflight[id] = nil }
        return try await task.value
    }

    /// Explicit suspend (idle-sweep / delete). Kills the PTY, drops the host;
    /// the session + claudeSessionId stay on disk (caller's concern) so it's
    /// resumable. Keeps `lastUsed` cleared so it isn't LRU-considered.
    func suspend(_ id: UUID) async {
        // Cancel an in-flight spawn FIRST and clear its inflight slot. The spawn
        // Task's `store(id:)` checks `inflight[id] != nil` and bails when it's
        // gone, so a spawn that's mid-`host.start()` won't resurrect this id
        // after we've suspended it. (Without this, a delete during spawn left an
        // orphan live `claude` for a deleted session.)
        if let pending = inflight.removeValue(forKey: id) {
            pending.cancel()
        }
        if let host = hosts.removeValue(forKey: id) {
            await host.kill()
        }
        lastUsed[id] = nil
    }

    func liveCount() -> Int { hosts.count }

    // MARK: - Internals

    /// Insert a freshly-started host UNLESS a suspend/delete cancelled this
    /// spawn while it was in flight (which clears `inflight[id]`). Returns false
    /// in that case so the caller tears the orphan host down. Runs on the actor,
    /// so the check + insert are atomic against suspend().
    @discardableResult
    private func store(id: UUID, host: ClaudePtyHost) -> Bool {
        guard inflight[id] != nil else { return false }
        hosts[id] = host
        lastUsed[id] = Date()
        return true
    }

    private func exitForwarder() -> (@Sendable (UUID, Int32) -> Void) {
        let outer = onUnexpectedExit
        return { [weak self] sid, status in
            outer?(sid, status)
            Task { await self?.dropExited(sid) }
        }
    }

    private func dropExited(_ id: UUID) {
        hosts[id] = nil
        lastUsed[id] = nil
    }

    /// Evict the least-recently-used live host until under the cap, so the new
    /// spawn keeps total memory bounded.
    private func enforceCapBeforeSpawn() async {
        while hosts.count >= maxLiveHosts {
            // Oldest lastUsed among live hosts; fall back to any host.
            let victim = hosts.keys.min { (a, b) in
                (lastUsed[a] ?? .distantPast) < (lastUsed[b] ?? .distantPast)
            }
            guard let victim else { break }
            registryLogger.info("LRU-suspend \(victim.uuidString, privacy: .public) (cap \(self.maxLiveHosts))")
            await suspend(victim)
        }
    }
}
