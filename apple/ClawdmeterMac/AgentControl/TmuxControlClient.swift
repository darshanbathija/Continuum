import Foundation
import Darwin
import OSLog

private let tmuxLogger = Logger(subsystem: "com.clawdmeter.mac", category: "TmuxControlClient")

/// Long-lived client for a `tmux -C` server.
///
/// Spawns `tmux -C -L clawdmeter new-session -A -s control` over a PTY
/// (per Phase 0: tmux refuses to start without a real tty for stdin).
/// Parses incoming control-mode frames and lets callers issue commands
/// (`newWindow`, `sendKeys`, `pasteBytes`, `killWindow`, etc.) that wait
/// for the matching `%begin/%end` cycle.
///
/// Per E2: this is an `actor`. State (`pendingCommands`, parser buffer,
/// per-pane output sinks) is actor-isolated. External callers `await` to
/// queue work; the background read loop pushes parsed frames in via an
/// AsyncStream consumed by the actor's run-loop task.
///
/// Per Codex eng-round High #4 + T23: supervisor logic (detect %exit,
/// auto-restart, mark sessions degraded) is layered above this actor —
/// this actor exposes the lifecycle signals (`exited` event), and the
/// supervisor reacts to them.
public actor TmuxControlClient {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let tmuxBinary: String
        public let socketName: String

        public init(
            tmuxBinary: String? = nil,
            socketName: String = "clawdmeter"
        ) {
            // Default: resolve via ShellRunner.locateBinary so the same code path
            // works on Apple Silicon Homebrew (/opt/homebrew/bin/tmux), Intel
            // Homebrew (/usr/local/bin/tmux), and tests with explicit overrides.
            self.tmuxBinary = tmuxBinary
                ?? ShellRunner.locateBinary("tmux")
                ?? "/usr/bin/tmux"
            self.socketName = socketName
        }
    }

    // MARK: - State

    public let configuration: Configuration
    private var pty: PseudoTerminal?
    private var childPid: pid_t = 0
    private var parser = ControlModeParser()
    private var readTask: Task<Void, Never>?

    /// In-flight commands awaiting their `%end`/`%error` response.
    /// Indexed by tmux's command sequence number (parsed from %begin).
    private struct PendingCommand {
        let id: UUID
        let summary: String
        let continuation: CheckedContinuation<CommandResult, Error>
        // Owns the timeout Task created in `command()`. Cancelled by
        // `%end`/`%error` handlers so successful commands don't keep a
        // 10s `Task.sleep` alive and wake the actor for nothing.
        var timeoutTask: Task<Void, Never>?
    }
    private var pendingCommands: [Int: PendingCommand] = [:]
    private var currentCommandNumber: Int?
    private var currentCommandBody: [String] = []

    /// Per-pane `%output` byte sinks. Terminal consumers include the Mac
    /// workbench, the iOS Tailscale tunnel, and auth/setup sheets. A pane
    /// can have several viewers at once; all must receive the same bytes.
    /// Key = pane id ("%5"). Inner key = subscription id.
    private var outputSinks: [String: [UUID: AsyncStream<Data>.Continuation]] = [:]

    /// Lifecycle event stream. Emits high-level signals (server-exited,
    /// window-added, window-closed) that the supervisor + registry consume.
    /// Created in `start()`; nil before start.
    public private(set) var lifecycleStream: AsyncStream<LifecycleEvent>?
    private var lifecycleContinuation: AsyncStream<LifecycleEvent>.Continuation?

    /// Set on observed `%exit` or PTY EOF. Used by supervisor.
    public private(set) var isAlive: Bool = false

    public enum LifecycleEvent: Sendable, Equatable {
        case ready
        case windowAdded(windowId: String)
        case windowClosed(windowId: String)
        case serverExited(reason: String?)
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    /// Start the tmux server over a PTY and begin the read loop.
    /// Idempotent: returns immediately if already started.
    public func start() async throws {
        if pty != nil {
            if isAlive && Self.isProcessAlive(childPid) {
                return
            }
            clearPTYState(reason: "stale PTY before start")
        }

        guard FileManager.default.isExecutableFile(atPath: configuration.tmuxBinary) else {
            throw TmuxError.commandFailed(
                "tmux not found at \(configuration.tmuxBinary). Reinstall Clawdmeter or configure a tmux path in Settings -> Diagnostics."
            )
        }

        // v0.8 QA ISSUE-002 fix: the original `tmux -C ... new-session ... -d`
        // single-command pattern exits the control-mode client as soon as the
        // new-session command completes — tmux interprets a command-line
        // subcommand as "run this and exit", regardless of whether it's
        // control mode. Result: PTY hits EOF immediately, markExited fires,
        // pty=nil, and every subsequent /sessions or /chat-sessions POST
        // hangs waiting on the wedged control client.
        //
        // The fix: two-phase startup.
        // Phase A — regular (non-control) `new-session -A -s control -d`
        //   ensures the session exists. Idempotent: -A attaches if present,
        //   creates if not. -d detaches so this client exits cleanly without
        //   blocking. We run this synchronously via ShellRunner.
        // Phase B — spawn the long-running PTY client as
        //   `tmux -C attach -t control`. WITHOUT a subcommand (other than
        //   `attach`), the control client stays alive as long as its PTY
        //   master is open. The daemon's commands flow through the PTY.
        // Also kills any pre-existing server on our socket first so we
        // don't inherit a zombie session from a prior Clawdmeter instance.

        _ = try? await ShellRunner.shared.run(
            executable: configuration.tmuxBinary,
            arguments: ["-L", configuration.socketName, "kill-server"],
            timeout: 3
        )

        // Phase A: create the session (regular client, exits cleanly).
        let phaseAResult = try? await ShellRunner.shared.run(
            executable: configuration.tmuxBinary,
            arguments: [
                "-L", configuration.socketName,
                "new-session", "-A", "-s", "control",
                "-d",
                "--", "/bin/bash", "-l",
            ],
            timeout: 5
        )
        if phaseAResult == nil {
            tmuxLogger.warning("tmux phase-A new-session call may have failed; continuing to phase B")
        }

        // Phase B: spawn the long-running control-mode client over PTY.
        let pty = try PseudoTerminal()
        self.pty = pty

        let pid = try pty.spawn(
            executable: configuration.tmuxBinary,
            arguments: [
                "-C",
                "-L", configuration.socketName,
                "attach", "-t", "control",
            ],
            // tmux server inherits the daemon env on purpose (PATH etc).
            // `environment` is non-defaulting on PseudoTerminal.spawn so this
            // inheritance is explicit, not an accidental nil-default — the
            // Claude PTY host instead passes ClaudeSpawnEnv.sanitized().
            environment: ProcessInfo.processInfo.environment
        )
        self.childPid = pid
        self.isAlive = true

        // Create lifecycle stream.
        let (stream, cont) = AsyncStream.makeStream(of: LifecycleEvent.self)
        self.lifecycleStream = stream
        self.lifecycleContinuation = cont

        // Spawn the read loop. AsyncStream-based so we can `await` parsing.
        let readerPtyFd = pty.masterFD
        let frames = AsyncStream<ControlModeFrame> { continuation in
            Task.detached {
                var buf = [UInt8](repeating: 0, count: 8192)
                var localParser = ControlModeParser()
                while true {
                    let n = read(readerPtyFd, &buf, buf.count)
                    if n < 0 {
                        // P2-Mac-9: previously the read loop fell through to
                        // `if n <= 0 { break }` for both EOF (n==0) and error
                        // (n<0), silently treating signal-interrupted/transient
                        // errors the same as a clean exit. Log the errno
                        // before exit so PTY misbehavior is debuggable.
                        let err = errno
                        tmuxLogger.warning("tmux PTY read error errno=\(err) — exiting read loop")
                        break
                    }
                    if n == 0 { break }
                    localParser.feed(buf[0..<n])
                    while let frame = localParser.nextFrame() {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }
        }

        self.readTask = Task { [weak self] in
            for await frame in frames {
                await self?.handle(frame: frame)
            }
            await self?.markExited(reason: "PTY EOF")
        }

        tmuxLogger.info("Started tmux pid=\(pid) socket=\(self.configuration.socketName)")
        lifecycleContinuation?.yield(.ready)
    }

    /// Cleanly shut down the tmux server.
    public func stop() async {
        guard pty != nil else { return }
        // Best-effort: send `kill-server` via a separate process (the
        // in-band PTY may be backed up; the new client is fresh).
        _ = try? await ShellRunner.shared.run(
            executable: configuration.tmuxBinary,
            arguments: ["-L", configuration.socketName, "kill-server"],
            timeout: 5
        )
        readTask?.cancel()
        readTask = nil
        if let pty {
            pty.closeMaster()
        }
        pty = nil
        isAlive = false
        lifecycleContinuation?.yield(.serverExited(reason: "explicit stop"))
        lifecycleContinuation?.finish()
        lifecycleStream = nil
        lifecycleContinuation = nil
    }

    private func markExited(reason: String?) {
        guard isAlive || pty != nil || !pendingCommands.isEmpty else { return }
        clearPTYState(reason: reason)
    }

    private func clearPTYState(reason: String?) {
        let wasAlive = isAlive
        isAlive = false
        // P1-Mac-3: clear PTY + read-task state on exit so the supervisor's
        // restart path (which calls `start()`) can actually spawn a fresh
        // server. Previously `start()`'s `guard pty == nil else { return }`
        // silently returned because `pty` was left non-nil; subsequent
        // commands then wrote to a closed file descriptor.
        if let pty {
            pty.closeMaster()
        }
        pty = nil
        readTask?.cancel()
        readTask = nil
        childPid = 0
        // Fail any in-flight commands.
        for (_, pending) in pendingCommands {
            pending.continuation.resume(throwing: TmuxError.serverExited)
        }
        pendingCommands.removeAll()
        // Drop output sinks — paneIds will be reassigned by the new server.
        for sinks in outputSinks.values {
            for continuation in sinks.values {
                continuation.finish()
            }
        }
        outputSinks.removeAll()
        currentCommandNumber = nil
        currentCommandBody = []
        if wasAlive {
            lifecycleContinuation?.yield(.serverExited(reason: reason))
            lifecycleContinuation?.finish()
        }
        lifecycleStream = nil
        lifecycleContinuation = nil
        tmuxLogger.warning("tmux server exited: \(reason ?? "unknown")")
    }

    // MARK: - Public commands

    /// Run a tmux command and wait for its `%begin/%end` or `%error` reply.
    /// Returns the response body (lines between begin and end).
    @discardableResult
    public func command(_ args: [String], timeout: TimeInterval = 10) async throws -> CommandResult {
        guard pty != nil else { throw TmuxError.notStarted }
        guard isAlive else { throw TmuxError.serverExited }
        // P1-Mac-6: reject CR/LF and ASCII control bytes via the static
        // helper so the regression test can exercise the same code path
        // without a live PTY. The wire format here is plaintext joined
        // with spaces and terminated by `\n`, so any control byte in an
        // arg can split the line and inject an unrelated tmux command
        // (or worse, paste into a child pane). `tmuxQuote` below only
        // escapes single quotes; it cannot prevent this class of injection.
        try Self.validateArgs(args)
        let cmd = args.joined(separator: " ") + "\n"
        let commandId = UUID()
        let summary = args.prefix(4).joined(separator: " ")
        return try await withCheckedThrowingContinuation { continuation in
            // We don't know the command number until tmux echoes back
            // %begin, so we queue continuations FIFO with a sentinel key.
            // First continuation gets matched to the next %begin we see.
            // (tmux is single-threaded internally — commands return in
            // FIFO order.)
            let key = -((pendingCommands.count + 1))  // negative sentinel until %begin maps it
            pendingCommands[key] = PendingCommand(
                id: commandId,
                summary: summary,
                continuation: continuation,
                timeoutTask: nil
            )
            do {
                try writePTY(cmd)
            } catch {
                pendingCommands.removeValue(forKey: key)
                continuation.resume(throwing: error)
                return
            }
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutPendingCommand(id: commandId)
            }
            // PendingCommand may have already been remapped from `key`
            // (negative sentinel) to the tmux-assigned `num` if %begin
            // arrived before this line executed. Update whichever entry
            // currently holds the pending continuation for this id.
            if let existingKey = pendingCommands.first(where: { $0.value.id == commandId })?.key {
                pendingCommands[existingKey]?.timeoutTask = timeoutTask
            } else {
                // Already completed (impossibly fast tmux); cancel
                // the timer immediately to keep it from firing.
                timeoutTask.cancel()
            }
        }
    }

    public struct WindowRef: Sendable, Hashable {
        public let windowId: String
        public let paneId: String
    }

    /// Convenience: create a new window in the control session, running
    /// the given child command in the given cwd. Returns both the new window
    /// id (e.g. "@4") and primary pane id (e.g. "%5").
    public func newWindow(
        cwd: String,
        child: [String],
        environment: [String: String] = [:]
    ) async throws -> WindowRef {
        // Spawned agent panes must run with the user's real PATH so the
        // agent's own tooling resolves — most visibly Claude Code's
        // node-based SessionStart hooks, which fail with "node: command not
        // found" under launchd's minimal GUI PATH. See SpawnPathResolver.
        let environment = SpawnPathResolver.merged(into: environment)
        // E4: tmux's `new-window` accepts `-c <cwd>` natively — no shell
        // concat. The child argv is joined for tmux's own parser; tmux
        // then re-tokenizes for execve.
        //
        // tmux's parser handles single-quoted segments. We quote each arg
        // to prevent re-tokenization on spaces. Backslash + single quote
        // is the escape for a literal single quote.
        do {
            let quoted = child.map { Self.tmuxQuote($0) }.joined(separator: " ")
            let envArgs = Self.environmentArgs(environment)
            let result = try await command([
                "new-window",
                "-P",  // print the new window + primary pane ids
                "-F", "'#{window_id} #{pane_id}'",
                "-t", "control",
                "-c", Self.tmuxQuote(cwd),
            ] + envArgs + [
                "--",
                quoted,
            ])
            // Response body is the printed ids, e.g. "@4 %5".
            if let ref = Self.parseWindowRef(from: result.lines.first) {
                return ref
            }
            throw TmuxError.commandFailed("new-window returned unexpected: \(result.lines.first ?? "")")
        } catch {
            tmuxLogger.warning("control-mode new-window failed; retrying with fresh tmux client: \(String(describing: error), privacy: .public)")
            return try await newWindowUsingFreshClient(cwd: cwd, child: child, environment: environment)
        }
    }

    private func newWindowUsingFreshClient(
        cwd: String,
        child: [String],
        environment: [String: String]
    ) async throws -> WindowRef {
        let envArgs = Self.environmentArgs(environment, quoteForControlMode: false)
        let result = try await ShellRunner.shared.runOrThrow(
            executable: configuration.tmuxBinary,
            arguments: [
                "-L", configuration.socketName,
                "new-window",
                "-P",
                "-F", "#{window_id} #{pane_id}",
                "-t", "control",
                "-c", cwd,
            ] + envArgs + [
                "--",
            ] + child,
            timeout: 10
        )
        let line = result.stdoutString
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)
        guard let ref = Self.parseWindowRef(from: line) else {
            throw TmuxError.commandFailed("fresh-client new-window returned unexpected: \(result.stdoutString)")
        }
        return ref
    }

    private static func parseWindowRef(from rawLine: String?) -> WindowRef? {
        let line = (rawLine ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].hasPrefix("@"), parts[1].hasPrefix("%") else {
            return nil
        }
        return WindowRef(windowId: parts[0], paneId: parts[1])
    }

    /// Split an existing window vertically (a new pane below the current).
    /// Returns the new pane id (e.g. "%9"). Used by the multi-terminal tab
    /// strip (G12) to give a session N tmux panes that share the window.
    /// Spawns the user's default shell — no child argv is forced.
    public func splitWindow(
        windowId: String,
        cwd: String,
        horizontal: Bool = false
    ) async throws -> String {
        let direction = horizontal ? "-h" : "-v"
        let result = try await command([
            "split-window",
            direction,
            "-P",
            "-F", "'#{pane_id}'",
            "-t", windowId,
            "-c", Self.tmuxQuote(cwd),
        ])
        let paneId = result.lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard paneId.hasPrefix("%") else {
            throw TmuxError.commandFailed("split-window returned unexpected: \(paneId)")
        }
        return paneId
    }

    /// Kill a specific pane. Used when the user closes a multi-terminal tab.
    public func killPane(_ paneId: String) async throws {
        try await command(["kill-pane", "-t", paneId])
    }

    /// Send raw bytes to a pane via `send-keys -l`. Suitable for short
    /// keystrokes (<256 bytes, no escape sequences). Longer / risky payloads
    /// go through `pasteBytes` which uses `set-buffer + paste-buffer`.
    public func sendKeys(paneId: String, bytes: Data) async throws {
        // `-l` makes tmux treat the input literally instead of as key names.
        // Encode as hex so we don't trip on shell-special bytes.
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try await command([
            "send-keys",
            "-l",
            "-t", paneId,
            "-H",  // hex-encoded literal input
            hex,
        ])
    }

    /// Send a large or escape-rich payload via tmux's paste buffer.
    /// Codex review reviewer concern #1: send-keys -l is not byte-safe for
    /// IME, paste-bursts, or complex escape sequences. set-buffer +
    /// paste-buffer is.
    public func pasteBytes(paneId: String, bytes: Data) async throws {
        // Unique buffer name per paste so concurrent sends don't collide.
        let bufferName = "clawdmeter-paste-\(UUID().uuidString.prefix(8))"
        // Base64 the bytes — tmux's set-buffer reads from stdin via `-` or
        // from a literal. We use the `-` stdin form, but our command()
        // method doesn't currently support stdin. So we use the literal
        // form with shell-safe encoding.
        //
        // Actually: tmux 3.4+ has `load-buffer -b <name> -` reading stdin.
        // We don't have a stdin channel through control-mode commands.
        // Workaround: write the buffer to a temp file, then `load-buffer`
        // it.
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(bufferName)
        try bytes.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        try await command([
            "load-buffer", "-b", bufferName,
            Self.tmuxQuote(tmpFile.path),
        ])
        try await command([
            "paste-buffer", "-b", bufferName,
            "-d",  // delete the buffer after paste
            "-t", paneId,
        ])
    }

    /// Subscribe to `%output` bytes from a specific pane. Returns an
    /// AsyncStream; iterate to receive bytes. Phase 3 wires this to the
    /// WebSocket bridge.
    public func subscribeToPane(_ paneId: String) -> AsyncStream<Data> {
        let normalized = Self.normalizedPaneId(paneId)
        let subscriptionId = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        var sinks = outputSinks[normalized] ?? [:]
        sinks[subscriptionId] = continuation
        outputSinks[normalized] = sinks
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeOutputSink(paneId: normalized, subscriptionId: subscriptionId)
            }
        }
        return stream
    }

    public func unsubscribeFromPane(_ paneId: String) {
        let normalized = Self.normalizedPaneId(paneId)
        let sinks = outputSinks.removeValue(forKey: normalized) ?? [:]
        for continuation in sinks.values {
            continuation.finish()
        }
    }

    private func removeOutputSink(paneId: String, subscriptionId: UUID) {
        outputSinks[paneId]?.removeValue(forKey: subscriptionId)
        if outputSinks[paneId]?.isEmpty == true {
            outputSinks.removeValue(forKey: paneId)
        }
    }

    func publishOutputForPane(_ paneId: String, bytes: Data) {
        let normalized = Self.normalizedPaneId(paneId)
        if let sinks = outputSinks[normalized] {
            for continuation in sinks.values {
                continuation.yield(bytes)
            }
        }
    }

    /// List current windows in the control session. Used by registry on
    /// rehydrate.
    public func listWindows() async throws -> [(windowId: String, paneId: String, paneCurrentPath: String)] {
        let result = try await command([
            "list-windows",
            "-t", "control",
            "-F", "'#{window_id} #{pane_id} #{pane_current_path}'",
        ])
        return result.lines.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return (windowId: parts[0], paneId: parts[1], paneCurrentPath: parts[2])
        }
    }

    /// Kill a specific window by id.
    public func killWindow(_ windowId: String) async throws {
        try await command(["kill-window", "-t", windowId])
    }

    /// Resize a pane's terminal dimensions.
    public func resizePane(_ paneId: String, cols: Int, rows: Int) async throws {
        try await command([
            "resize-pane", "-t", paneId,
            "-x", "\(cols)", "-y", "\(rows)",
        ])
    }

    // MARK: - Frame handling

    private func handle(frame: ControlModeFrame) {
        switch frame {
        case .begin(_, let num, _):
            // Map the sentinel-keyed continuation to the actual number.
            // First (smallest negative) sentinel wins, FIFO.
            if let sentinelKey = pendingCommands.keys.filter({ $0 < 0 }).max() {
                let pending = pendingCommands.removeValue(forKey: sentinelKey)!
                pendingCommands[num] = pending
                currentCommandNumber = num
                currentCommandBody = []
            }
        case .end(_, let num, _):
            if let pending = pendingCommands.removeValue(forKey: num) {
                pending.timeoutTask?.cancel()
                let result = CommandResult(lines: currentCommandBody)
                pending.continuation.resume(returning: result)
            }
            currentCommandNumber = nil
            currentCommandBody = []
        case .error(_, let num, _):
            if let pending = pendingCommands.removeValue(forKey: num) {
                pending.timeoutTask?.cancel()
                let errorText = currentCommandBody.joined(separator: "\n")
                pending.continuation.resume(throwing: TmuxError.commandFailed(errorText))
            }
            currentCommandNumber = nil
            currentCommandBody = []
        case .output(let paneId, let bytes):
            // Forward bytes to the pane's subscriber. Note: pane ids
            // emitted by `%output` already include the `%` prefix (e.g. "5"
            // in the frame body but our parser strips it to "5"). Registry
            // and callers use "%5" form; reconcile here.
            publishOutputForPane(paneId, bytes: bytes)
        case .windowAdd(let windowId):
            lifecycleContinuation?.yield(.windowAdded(windowId: windowId))
        case .windowClose(let windowId):
            lifecycleContinuation?.yield(.windowClosed(windowId: windowId))
        case .exit(let reason):
            markExited(reason: reason)
        case .body(let line):
            // v0.8 QA fix: command-response body line. Accumulate while
            // we're between %begin and %end so the final continuation
            // gets the response body (e.g. `@1 %1` from newWindow -P -F).
            if currentCommandNumber != nil {
                currentCommandBody.append(line)
            }
        case .unknown(let raw):
            tmuxLogger.debug("Unknown frame: \(raw, privacy: .public)")
            // If we're inside a command response, accumulate as body.
            if currentCommandNumber != nil && !raw.hasPrefix("%") {
                currentCommandBody.append(raw)
            }
        default:
            break  // pause/continue/etc — not handled in v1
        }
    }

    private func writePTY(_ s: String) throws {
        guard let pty, pty.masterFD >= 0 else { throw TmuxError.ptyClosed }
        let bytes = Array(s.utf8)
        // Loop until every byte is written. PTYs short-write under
        // backpressure; throwing on a partial write would spuriously
        // fail the in-flight tmux command and tear down the session.
        // Retry EINTR; surface any other write(2) failure as ptyClosed
        // so clearPTYState handles UI teardown.
        try bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = write(pty.masterFD, base.advanced(by: offset), buf.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n == -1 && errno == EINTR { continue }
                throw TmuxError.ptyClosed
            }
        }
    }

    private func timeoutPendingCommand(id: UUID) {
        guard let match = pendingCommands.first(where: { $0.value.id == id }) else { return }
        pendingCommands.removeValue(forKey: match.key)
        if currentCommandNumber == match.key {
            currentCommandNumber = nil
            currentCommandBody = []
        }
        tmuxLogger.warning("tmux command timed out: \(match.value.summary, privacy: .public)")
        match.value.continuation.resume(
            throwing: TmuxError.commandFailed("tmux command timed out after 10s: \(match.value.summary)")
        )
        clearPTYState(reason: "tmux command timeout: \(match.value.summary)")
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Helpers

    /// Quote a string for tmux's command-line parser. tmux uses single
    /// quotes; literal single quotes are escaped as `'\''`.
    static func tmuxQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func environmentArgs(
        _ environment: [String: String],
        quoteForControlMode: Bool = true
    ) -> [String] {
        environment
            .sorted { $0.key < $1.key }
            .flatMap { key, value -> [String] in
                let safeValue = value
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\u{0000}", with: "")
                let assignment = "\(key)=\(safeValue)"
                return ["-e", quoteForControlMode ? tmuxQuote(assignment) : assignment]
            }
    }

    private static func normalizedPaneId(_ paneId: String) -> String {
        paneId.hasPrefix("%") ? paneId : "%\(paneId)"
    }

    // MARK: - Types

    public struct CommandResult: Sendable {
        public let lines: [String]
    }

    public enum TmuxError: Error, Sendable {
        case notStarted
        case commandFailed(String)
        case serverExited
        case ptyClosed
        case invalidArgument(String)
    }

    /// v0.7.7: extracted from `command(_:)` so the regression test for
    /// CR/LF / control-byte rejection can exercise the same code path
    /// without a live PTY. Throws `.invalidArgument(arg)` on the first
    /// arg that contains any C0 (< 0x20) or DEL (0x7F) byte.
    public static func validateArgs(_ args: [String]) throws {
        for arg in args {
            for scalar in arg.unicodeScalars {
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    throw TmuxError.invalidArgument(arg)
                }
            }
        }
    }
}
