import Foundation
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import ClawdmeterShared

private let ptyLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ClaudePtyHost")

/// One interactive `claude` process on its own PTY (Track A).
///
/// Each Claude session owns an isolated `PseudoTerminal` + `claude` child, so
/// one stuck session can't sink the others. Terminal tabs, scheduler delivery,
/// Stop, swap, and Frontier now route through direct PTY/harness transports.
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
/// submitPrompt(text) -> PromptPtySubmission.writes -> write(clear) write(payload)
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
    /// Explicit child env (PATH-enriched + repo env). Re-sanitized at spawn so
    /// the billing rail (no ANTHROPIC_API_KEY/AUTH_TOKEN) holds even if a caller
    /// passes an un-scrubbed base.
    private let env: [String: String]
    private let cols: UInt16
    private let rows: UInt16
    private let ringCapacity: Int
    private let submitSettle: UInt64   // ns between paste and the submit CR

    private var pty: PseudoTerminal?
    private var childPid: pid_t = 0
    /// Host-owned copy of the PTY master fd. Mirrors `pty.masterFD` while live
    /// and is set to -1 the instant teardown begins, so an in-flight
    /// `submitPrompt` (suspended at its settle `await`) re-checks and refuses to
    /// write a closed/recycled fd. The fd itself is closed by the read source's
    /// cancel handler (see `startReadLoop`).
    private var masterFD: Int32 = -1
    private var ring = Data()
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private(set) var isRunning = false
    private(set) var lastUsedAt = Date()
    private var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]

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
        env: [String: String] = ClaudeSpawnEnv.sanitized(),
        cols: UInt16 = 120,
        rows: UInt16 = 40,
        ringCapacity: Int = 64 * 1024,
        submitSettleNanos: UInt64 = 280_000_000
    ) {
        self.sessionId = sessionId
        self.argv = argv
        self.cwd = cwd
        self.env = env
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
            // Re-sanitize the (already PATH-enriched + repo) env so the billing
            // rail holds regardless of what the caller passed. NEVER nil.
            environment: ClaudeSpawnEnv.sanitized(base: env),
            cwd: cwd
        )
        self.childPid = pid
        self.masterFD = pty.masterFD
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
        masterFD = -1               // stop any in-flight submit from writing it
        exitSource?.cancel()
        exitSource = nil
        let pidToReap = childPid
        childPid = 0
        if pidToReap > 0 {
            PtyProcessTerminator.terminateProcessGroup(pid: pidToReap)
        }
        // Hand the fd to the read source's cancel handler (it owns the close),
        // so a read handler already dispatched can't touch a recycled fd. Detach
        // from PseudoTerminal so deinit won't double-close. If there's no read
        // source yet (start() failed early), close directly.
        if let rs = readSource {
            readSource = nil
            _ = pty?.detachMaster()
            rs.cancel()
        } else {
            pty?.closeMaster()
        }
        pty = nil
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        let sid = sessionId
        Task { @MainActor in HarnessProcessReaper.shared.remove(sessionId: sid) }
    }

    // MARK: - Submit

    /// Write the user's prompt to the PTY: clear (chat) → payload → settle → CR.
    @discardableResult
    func submitPrompt(_ text: String, isChat: Bool, isFollowUp: Bool = false) async -> Bool {
        guard isRunning, masterFD >= 0 else { return false }
        lastUsedAt = Date()
        let w = PromptPtySubmission.writes(forText: text, isFollowUp: isFollowUp, isChat: isChat)
        if let clear = w.clear, !Self.writeAll(fd: masterFD, data: clear) { return false }
        guard Self.writeAll(fd: masterFD, data: w.payload) else { return false }
        // Let Ink's render loop commit the paste before the submit Enter
        // (keeps the old 300ms settle and the Ink \r quirk #15553).
        try? await Task.sleep(nanoseconds: submitSettle)
        // kill() runs actor-isolated, so it can only land while we're suspended
        // at the sleep above; it sets isRunning=false + masterFD=-1. Re-check so
        // the submit CR can't write a closed/recycled fd.
        guard isRunning, masterFD >= 0 else { return false }
        return Self.writeAll(fd: masterFD, data: w.submit)
    }

    /// Raw write (used by the trust-folder warmup port in T6 too).
    @discardableResult
    func writeBytes(_ data: Data) -> Bool {
        guard isRunning, masterFD >= 0 else { return false }
        return Self.writeAll(fd: masterFD, data: data)
    }

    // MARK: - Output

    /// ANSI-stripped tail of recent output. Consumers: spawn-readiness +
    /// auth/update detection (substring matches only).
    func recentOutput() -> String {
        AnsiStrip.plain(String(decoding: ring, as: UTF8.self))
    }

    /// Raw output stream for terminal clients. The current ring is yielded
    /// first so attach-after-output clients receive useful scrollback.
    func outputStream() -> AsyncStream<Data> {
        let subscriberId = UUID()
        let snapshot = ring
        let pair = AsyncStream<Data>.makeStream(of: Data.self)
        if !snapshot.isEmpty {
            pair.continuation.yield(snapshot)
        }
        guard isRunning else {
            pair.continuation.finish()
            return pair.stream
        }
        subscribers[subscriberId] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberId) }
        }
        return pair.stream
    }

    func snapshot() -> Data {
        ring
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        _ = pty?.resize(cols: UInt16(min(cols, Int(UInt16.max))),
                        rows: UInt16(min(rows, Int(UInt16.max))))
    }

    func touch() { lastUsedAt = Date() }

    // MARK: - Internals

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func appendOutput(_ bytes: [UInt8]) {
        let data = Data(bytes)
        ring.append(data)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        for continuation in subscribers.values {
            continuation.yield(data)
        }
    }

    private func startReadLoop(masterFD: Int32) {
        // Event-driven read via DispatchSourceRead — NOT a blocking read() on a
        // Task.detached. With up to `maxLiveHosts` concurrent sessions, a
        // blocking-read-per-host would pin one Swift cooperative-pool thread
        // each (the pool is ~core-count) and starve the registry actor's
        // continuations → deadlock. A read source is poll-driven and holds no
        // thread while idle.
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
        // The read source OWNS closing the master fd. Closing only from the
        // cancel handler (which runs after the source is fully torn down)
        // guarantees the event handler above can never read() a closed — or
        // worse, recycled — fd. Teardown detaches the fd from PseudoTerminal so
        // this is the single close. (CL4)
        src.setCancelHandler { close(masterFD) }
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
        let exitedPid = childPid
        isRunning = false
        masterFD = -1
        childPid = 0   // already reaped via WNOHANG in the exit watcher
        exitSource?.cancel()
        exitSource = nil
        if exitedPid > 0 {
            PtyProcessTerminator.terminateProcessGroup(pid: exitedPid)
        }
        // Same fd-ownership handoff as kill(): the read source's cancel handler
        // is the sole closer; detach so PseudoTerminal won't double-close.
        if let rs = readSource {
            readSource = nil
            _ = pty?.detachMaster()
            rs.cancel()
        } else {
            pty?.closeMaster()
        }
        pty = nil
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        let sid = sessionId
        Task { @MainActor in HarnessProcessReaper.shared.remove(sessionId: sid) }
        ptyLogger.warning("ClaudePtyHost child exited unexpectedly status=\(status) session=\(self.sessionId.uuidString, privacy: .public)")
        onUnexpectedExit?(sessionId, status)
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0
            let total = raw.count
            // The master fd is O_NONBLOCK (the read source requires it), so a
            // full tty input buffer returns EAGAIN. The old `if n <= 0 { break }`
            // SILENTLY TRUNCATED prompts on the first partial write. Retry EINTR
            // immediately and EAGAIN after poll(POLLOUT) so the whole payload
            // lands. Bounded so a wedged child can't pin the actor forever.
            var eagainWaits = 0
            while off < total {
                let n = write(fd, base + off, total - off)
                if n > 0 { off += n; continue }
                if n < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    if e == EAGAIN || e == EWOULDBLOCK {
                        if eagainWaits >= 20 { return false }   // ~5s ceiling (20 × 250ms)
                        eagainWaits += 1
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pfd, 1, 250)
                        continue
                    }
                }
                return false   // n == 0 or an unrecoverable error
            }
            return off == total
        }
    }
}
