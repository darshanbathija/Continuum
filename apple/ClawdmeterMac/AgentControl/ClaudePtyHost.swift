import Foundation
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import ClawdmeterShared

private let ptyLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ClaudePtyHost")

/// One interactive `claude` process on its own PTY (Track A).
///
/// Replaces Claude's slice of the shared tmux `-CC` server: a wedged tmux
/// server used to take down EVERY Claude session at once (the repeated 504s).
/// Each session now owns an isolated `PseudoTerminal` + `claude` child, so one
/// stuck session can't sink the others. tmux STAYS for the Terminal tab,
/// multi-pane, scheduler, Stop, swap, and Frontier — this only owns Claude's
/// session-drive.
///
/// ```
/// start() -> PseudoTerminal(120x40) -> posix_spawn claude (sanitized env, cwd)
///   |                                        |
///   |  Task.detached blocking read(masterFD) |  DispatchSourceProcess(.exit)
///   v                                        v
/// ring buffer (last 64KB) <-- bytes      waitpid + onExit(id,status) -> .degraded
///   |
///   v  recentOutput() = AnsiStrip.plain(tail)   (readiness + auth detection)
///
/// submitPrompt(text) -> SubmitToTmux.ptyWrites -> write(clear) write(payload)
///                       sleep(settle) write(CR)
/// ```
///
/// Subscription-billing invariant: the child env is ALWAYS
/// `ClaudeSpawnEnv.sanitized()` (never nil), so a stray `ANTHROPIC_API_KEY`
/// can't switch `claude` to pay-per-token.
actor ClaudePtyHost {

    let sessionId: UUID
    private let argv: [String]
    private let cwd: String?
    private let cols: UInt16
    private let rows: UInt16
    private let ringCapacity: Int
    private let submitSettle: UInt64   // ns between paste and the submit CR

    private var pty: PseudoTerminal?
    private var childPid: pid_t = 0
    private var ring = Data()
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private(set) var isRunning = false
    private(set) var lastUsedAt = Date()

    /// Invoked once when the child exits unexpectedly (crash / external kill).
    /// The registry forwards this to the daemon to mark the session `.degraded`
    /// + offer Resume. Not called on an explicit `kill()`.
    var onUnexpectedExit: (@Sendable (UUID, Int32) -> Void)?

    /// - Parameters:
    ///   - argv: full argv from `AgentSpawner.claudeArgv` (argv[0] = binary).
    ///   - cwd: worktree/repo dir the session runs in.
    init(
        sessionId: UUID,
        argv: [String],
        cwd: String?,
        cols: UInt16 = 120,
        rows: UInt16 = 40,
        ringCapacity: Int = 64 * 1024,
        submitSettleNanos: UInt64 = 280_000_000
    ) {
        self.sessionId = sessionId
        self.argv = argv
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.ringCapacity = ringCapacity
        self.submitSettle = submitSettleNanos
    }

    func setOnUnexpectedExit(_ handler: @escaping @Sendable (UUID, Int32) -> Void) {
        self.onUnexpectedExit = handler
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() throws -> pid_t {
        guard !isRunning else { return childPid }
        guard let executable = argv.first else {
            throw NSError(domain: "ClaudePtyHost", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty argv"])
        }
        let pty = try PseudoTerminal(cols: cols, rows: rows)
        self.pty = pty
        let pid = try pty.spawn(
            executable: executable,
            arguments: Array(argv.dropFirst()),
            environment: ClaudeSpawnEnv.sanitized(),   // NEVER nil — billing rail
            cwd: cwd
        )
        self.childPid = pid
        self.isRunning = true
        self.lastUsedAt = Date()
        // HarnessProcessReaper is @MainActor; record fire-and-forget so we
        // don't make start() async / block the spawn on a main-actor hop.
        let sid = sessionId
        Task { @MainActor in HarnessProcessReaper.shared.record(sessionId: sid, pid: pid, binary: "claude") }
        startReadLoop(masterFD: pty.masterFD)
        startExitWatcher(pid: pid)
        ptyLogger.info("ClaudePtyHost started pid=\(pid) session=\(self.sessionId.uuidString, privacy: .public)")
        return pid
    }

    /// Explicit teardown (idle-suspend, delete-session, LRU evict). Does NOT
    /// fire `onUnexpectedExit` — it's intentional.
    func kill() {
        guard isRunning || pty != nil else { return }
        isRunning = false
        exitSource?.cancel()
        exitSource = nil
        readSource?.cancel()
        readSource = nil
        if childPid > 0 {
            #if canImport(Darwin)
            Darwin.kill(childPid, SIGTERM)
            #endif
        }
        pty?.closeMaster()
        pty = nil
        let sid = sessionId
        Task { @MainActor in HarnessProcessReaper.shared.remove(sessionId: sid) }
    }

    // MARK: - Submit

    /// Write the user's prompt to the PTY: clear (chat) → payload → settle → CR.
    func submitPrompt(_ text: String, isChat: Bool, isFollowUp: Bool = false) async {
        guard isRunning, let pty, pty.masterFD >= 0 else { return }
        lastUsedAt = Date()
        let w = SubmitToTmux.ptyWrites(forText: text, isFollowUp: isFollowUp, isChat: isChat)
        let fd = pty.masterFD
        if let clear = w.clear { Self.writeAll(fd: fd, data: clear) }
        Self.writeAll(fd: fd, data: w.payload)
        // Let Ink's render loop commit the paste before the submit Enter
        // (mirrors the tmux path's 300ms gap + the Ink \r quirk #15553).
        try? await Task.sleep(nanoseconds: submitSettle)
        Self.writeAll(fd: fd, data: w.submit)
    }

    /// Raw write (used by the trust-folder warmup port in T6 too).
    func writeBytes(_ data: Data) {
        guard isRunning, let pty, pty.masterFD >= 0 else { return }
        Self.writeAll(fd: pty.masterFD, data: data)
    }

    // MARK: - Output

    /// ANSI-stripped tail of recent output. Consumers: spawn-readiness +
    /// auth/update detection (substring matches only).
    func recentOutput() -> String {
        AnsiStrip.plain(String(decoding: ring, as: UTF8.self))
    }

    func touch() { lastUsedAt = Date() }

    // MARK: - Internals

    private func appendOutput(_ bytes: [UInt8]) {
        ring.append(contentsOf: bytes)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
    }

    private func startReadLoop(masterFD: Int32) {
        // Event-driven read via DispatchSourceRead — NOT a blocking read() on a
        // Task.detached. With up to `maxLiveHosts` concurrent sessions, a
        // blocking-read-per-host would pin one Swift cooperative-pool thread
        // each (the pool is ~core-count) and starve the registry actor's
        // continuations → deadlock. A read source is poll-driven and holds no
        // thread while idle. (TmuxControlClient can afford the blocking loop —
        // it's a singleton; per-session hosts cannot.)
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global())
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(masterFD, &buf, buf.count)
            guard n > 0 else { return }   // EOF/EAGAIN → exit watcher owns state
            let chunk = Array(buf[0..<n])
            Task { await self?.appendOutput(chunk) }
        }
        src.resume()
        readSource = src
    }

    private func startExitWatcher(pid: pid_t) {
        #if canImport(Darwin)
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        src.setEventHandler { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)   // reap the zombie
            Task { await self?.handleChildExit(status: status) }
        }
        src.resume()
        self.exitSource = src
        #endif
    }

    private func handleChildExit(status: Int32) {
        guard isRunning else { return }   // explicit kill() already tore down
        isRunning = false
        exitSource?.cancel()
        exitSource = nil
        readSource?.cancel()
        readSource = nil
        pty?.closeMaster()
        pty = nil
        let sid = sessionId
        Task { @MainActor in HarnessProcessReaper.shared.remove(sessionId: sid) }
        ptyLogger.warning("ClaudePtyHost child exited unexpectedly status=\(status) session=\(self.sessionId.uuidString, privacy: .public)")
        onUnexpectedExit?(sessionId, status)
    }

    private static func writeAll(fd: Int32, data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            let total = raw.count
            while off < total {
                let n = write(fd, base + off, total - off)
                if n <= 0 { break }
                off += n
            }
        }
    }
}
