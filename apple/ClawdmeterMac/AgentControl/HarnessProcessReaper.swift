import Foundation
import OSLog
import ClawdmeterShared

private let reaperLogger = Logger(subsystem: "com.clawdmeter.mac", category: "HarnessReaper")

/// Records live harness child PIDs to `~/.clawdmeter/harness-pids.json` and, on
/// daemon start, kills stale orphans a previous (crashed) daemon left behind —
/// e.g. a `codex app-server` / grok / cursor-agent child that outlived its
/// in-memory `AcpHarnessBridge`. Recording happens at the single
/// `HarnessSessionRegistry.register` / `.remove` chokepoint, so there is one
/// place to keep the file in sync.
///
/// Safety (the reaper kills processes, so it is deliberately conservative):
///   1. Only reaps a recorded pid whose live executable basename still matches
///      the recorded binary (PID-reuse guard — a recycled pid is spared).
///   2. Only reaps when the spawning daemon (ownerPid) is dead — a live daemon
///      (a second Continuum instance, a test host) still owns its children.
///   3. Only signals processes this user can signal (`kill(pid, 0) == 0`).
/// Transport-owning (Antigravity gRPC) bridges have no child and are not recorded.
@MainActor
final class HarnessProcessReaper {
    static let shared = HarnessProcessReaper()

    private let fileURL: URL
    private var records: [UUID: HarnessPidRecord] = [:]
    private let ownerPid: Int32

    init(fileURL: URL? = nil, ownerPid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.ownerPid = ownerPid
        self.fileURL = fileURL ?? ClawdmeterRealHome.url()
            .appendingPathComponent(".clawdmeter", isDirectory: true)
            .appendingPathComponent("harness-pids.json")
    }

    /// Record a freshly-spawned harness child (called from register()).
    func record(sessionId: UUID, pid: Int32, binary: String) {
        records[sessionId] = HarnessPidRecord(
            sessionId: sessionId, pid: pid, binary: binary,
            ownerPid: ownerPid, startedAt: Date()
        )
        persist()
    }

    /// Forget a child after clean teardown (called from remove()).
    func remove(sessionId: UUID) {
        guard records.removeValue(forKey: sessionId) != nil else { return }
        persist()
    }

    /// On daemon start: reap orphans left by a previous daemon, then reset the
    /// file to this daemon's (empty) state. Call exactly once at boot, BEFORE any
    /// spawn (this daemon's children re-register themselves afterward).
    func reapOrphans() {
        let prior = loadFromDisk()
        var reaped: [HarnessPidRecord] = []
        for rec in prior.values {
            guard Self.processAlive(rec.pid) else { continue }
            let ownerAlive = Self.processAlive(rec.ownerPid)
            guard HarnessOrphanReaper.shouldReap(record: rec, liveComm: Self.liveComm(rec.pid), ownerAlive: ownerAlive) else { continue }
            reaperLogger.warning("reaping orphan harness child pid=\(rec.pid, privacy: .public) binary=\(rec.binary, privacy: .public) session=\(rec.sessionId.uuidString, privacy: .public)")
            kill(rec.pid, SIGTERM)
            reaped.append(rec)
        }
        if !reaped.isEmpty {
            // SIGKILL survivors after a short grace — but RE-VERIFY first. The OS
            // can recycle a pid during the grace window, so re-run the full guard
            // (owner dead + live comm STILL matches the recorded binary) before
            // escalating, so we never SIGKILL a freshly-recycled, unrelated process.
            let toEscalate = reaped
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                for rec in toEscalate where Self.processAlive(rec.pid) {
                    let ownerAlive = Self.processAlive(rec.ownerPid)
                    if HarnessOrphanReaper.shouldReap(record: rec, liveComm: Self.liveComm(rec.pid), ownerAlive: ownerAlive) {
                        kill(rec.pid, SIGKILL)
                    }
                }
            }
            reaperLogger.info("reaped \(reaped.count, privacy: .public) orphan harness child(ren)")
        }
        // Fresh slate for this daemon; its children re-register as they spawn.
        records = [:]
        persist()
    }

    // MARK: - I/O

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(Array(records.values)).write(to: fileURL, options: .atomic)
        } catch {
            reaperLogger.error("persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFromDisk() -> [UUID: HarnessPidRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([HarnessPidRecord].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Process probes

    /// Alive AND signalable by this user. EPERM (exists but not ours) returns
    /// false on purpose — we never touch a process we don't own.
    static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// Executable path currently running as `pid`, via `ps -p <pid> -o comm=`.
    static func liveComm(_ pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "comm="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }
}
