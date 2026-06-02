import Foundation

/// One harness child process recorded for the orphan reaper. Persisted (by the
/// Mac daemon) to `~/.clawdmeter/harness-pids.json` so a daemon that crashed
/// without tearing down its ACP / `codex app-server` children can have those
/// stale agents reaped on the next start instead of lingering forever.
///
/// Transport-owning drivers (Antigravity gRPC) have no child process, so they
/// are never recorded here.
public struct HarnessPidRecord: Codable, Hashable, Sendable {
    /// The Clawdmeter session that owns the child.
    public let sessionId: UUID
    /// The agent child process id.
    public let pid: Int32
    /// The spawn binary name (e.g. "codex", "grok", "cursor-agent"). Matched
    /// against the live process's executable basename as the PID-reuse guard.
    public let binary: String
    /// The daemon process that spawned the child. A still-running owner means a
    /// live daemon still manages this child — it must NOT be reaped (handles the
    /// two-daemon / test-host case).
    public let ownerPid: Int32
    public let startedAt: Date

    public init(sessionId: UUID, pid: Int32, binary: String, ownerPid: Int32, startedAt: Date) {
        self.sessionId = sessionId
        self.pid = pid
        self.binary = binary
        self.ownerPid = ownerPid
        self.startedAt = startedAt
    }
}

/// Pure decision logic for the harness orphan reaper. The Mac daemon supplies
/// the live facts (is the owner daemon alive? what binary is the pid running
/// now?) and performs the actual kill; keeping the decision here makes it
/// swift-testable without process management.
public enum HarnessOrphanReaper {
    /// Whether the recorded child should be killed as an orphan.
    ///
    /// - Parameters:
    ///   - record: the persisted child record.
    ///   - liveComm: the executable path/name currently running as `record.pid`,
    ///     or nil if the pid is dead / unreadable. A recycled pid running a
    ///     *different* binary is spared (the PID-reuse fail-safe).
    ///   - ownerAlive: whether the spawning daemon (`record.ownerPid`) is still
    ///     running. If so, that daemon owns the child — never reap.
    /// - Returns: true only when the owner is gone AND the live process's
    ///   basename still matches the recorded binary.
    public static func shouldReap(record: HarnessPidRecord, liveComm: String?, ownerAlive: Bool) -> Bool {
        if ownerAlive { return false }
        guard let liveComm, !liveComm.isEmpty else { return false }
        let recordedBase = lastComponent(record.binary)
        let liveBase = lastComponent(liveComm)
        guard !recordedBase.isEmpty, !liveBase.isEmpty else { return false }
        // Exact basename match, with a prefix fallback for `comm` truncation.
        return liveBase == recordedBase
            || liveBase.hasPrefix(recordedBase)
            || recordedBase.hasPrefix(liveBase)
    }

    /// Basename of a path-or-name, dropping any trailing argument that a `comm`
    /// readout might include.
    public static func lastComponent(_ path: String) -> String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return base.split(separator: " ").first.map(String.init) ?? base
    }
}
