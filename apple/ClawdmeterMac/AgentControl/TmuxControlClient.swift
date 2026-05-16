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
            tmuxBinary: String = "/opt/homebrew/bin/tmux",
            socketName: String = "clawdmeter"
        ) {
            self.tmuxBinary = tmuxBinary
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
    private var pendingCommands: [Int: CheckedContinuation<CommandResult, Error>] = [:]
    private var currentCommandNumber: Int?
    private var currentCommandBody: [String] = []

    /// Per-pane `%output` byte sinks. The terminal WS bridge subscribes here.
    /// Key = pane id ("%5"). Value = the continuation feeding the AsyncStream.
    private var outputSinks: [String: AsyncStream<Data>.Continuation] = [:]

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
        guard pty == nil else { return }

        let pty = try PseudoTerminal()
        self.pty = pty

        let pid = try pty.spawn(
            executable: configuration.tmuxBinary,
            arguments: [
                "-C",
                "-L", configuration.socketName,
                "new-session", "-A", "-s", "control",
                // Detached so we don't fight an interactive client; we
                // drive everything via control-mode commands.
                "-d",
                "--", "/bin/bash", "-l",
            ]
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
                    if n <= 0 { break }
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
            close(pty.masterFD)
        }
        pty = nil
        isAlive = false
        lifecycleContinuation?.yield(.serverExited(reason: "explicit stop"))
        lifecycleContinuation?.finish()
        lifecycleStream = nil
        lifecycleContinuation = nil
    }

    private func markExited(reason: String?) {
        guard isAlive else { return }
        isAlive = false
        lifecycleContinuation?.yield(.serverExited(reason: reason))
        lifecycleContinuation?.finish()
        // Fail any in-flight commands.
        for (_, continuation) in pendingCommands {
            continuation.resume(throwing: TmuxError.serverExited)
        }
        pendingCommands.removeAll()
        tmuxLogger.warning("tmux server exited: \(reason ?? "unknown")")
    }

    // MARK: - Public commands

    /// Run a tmux command and wait for its `%begin/%end` or `%error` reply.
    /// Returns the response body (lines between begin and end).
    @discardableResult
    public func command(_ args: [String]) async throws -> CommandResult {
        guard pty != nil else { throw TmuxError.notStarted }
        let cmd = args.joined(separator: " ") + "\n"
        return try await withCheckedThrowingContinuation { continuation in
            // We don't know the command number until tmux echoes back
            // %begin, so we queue continuations FIFO with a sentinel key.
            // First continuation gets matched to the next %begin we see.
            // (tmux is single-threaded internally — commands return in
            // FIFO order.)
            let key = -((pendingCommands.count + 1))  // negative sentinel until %begin maps it
            pendingCommands[key] = continuation
            writePTY(cmd)
        }
    }

    /// Convenience: create a new window in the control session, running
    /// the given child command in the given cwd. Returns the new window id
    /// (e.g. "@4").
    public func newWindow(cwd: String, child: [String]) async throws -> String {
        // E4: tmux's `new-window` accepts `-c <cwd>` natively — no shell
        // concat. The child argv is joined for tmux's own parser; tmux
        // then re-tokenizes for execve.
        //
        // tmux's parser handles single-quoted segments. We quote each arg
        // to prevent re-tokenization on spaces. Backslash + single quote
        // is the escape for a literal single quote.
        let quoted = child.map { Self.tmuxQuote($0) }.joined(separator: " ")
        let result = try await command([
            "new-window",
            "-P",  // print the new window id
            "-F", "'#{window_id}'",
            "-t", "control",
            "-c", Self.tmuxQuote(cwd),
            "--",
            quoted,
        ])
        // Response body is the printed window id, e.g. "@4".
        let windowId = result.lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard windowId.hasPrefix("@") else {
            throw TmuxError.commandFailed("new-window returned unexpected: \(windowId)")
        }
        return windowId
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
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        // Multiple subscribers per pane: chain by replacing. For Phase 2
        // we support one subscriber per pane; Phase 3 adds fan-out if needed.
        outputSinks[paneId] = continuation
        return stream
    }

    public func unsubscribeFromPane(_ paneId: String) {
        outputSinks[paneId]?.finish()
        outputSinks.removeValue(forKey: paneId)
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
                let continuation = pendingCommands.removeValue(forKey: sentinelKey)!
                pendingCommands[num] = continuation
                currentCommandNumber = num
                currentCommandBody = []
            }
        case .end(_, let num, _):
            if let continuation = pendingCommands.removeValue(forKey: num) {
                let result = CommandResult(lines: currentCommandBody)
                continuation.resume(returning: result)
            }
            currentCommandNumber = nil
            currentCommandBody = []
        case .error(_, let num, _):
            if let continuation = pendingCommands.removeValue(forKey: num) {
                let errorText = currentCommandBody.joined(separator: "\n")
                continuation.resume(throwing: TmuxError.commandFailed(errorText))
            }
            currentCommandNumber = nil
            currentCommandBody = []
        case .output(let paneId, let bytes):
            // Forward bytes to the pane's subscriber. Note: pane ids
            // emitted by `%output` already include the `%` prefix (e.g. "5"
            // in the frame body but our parser strips it to "5"). Registry
            // and callers use "%5" form; reconcile here.
            let normalized = paneId.hasPrefix("%") ? paneId : "%\(paneId)"
            outputSinks[normalized]?.yield(bytes)
        case .windowAdd(let windowId):
            lifecycleContinuation?.yield(.windowAdded(windowId: windowId))
        case .windowClose(let windowId):
            lifecycleContinuation?.yield(.windowClosed(windowId: windowId))
        case .exit(let reason):
            markExited(reason: reason)
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

    private func writePTY(_ s: String) {
        guard let pty else { return }
        let bytes = Array(s.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            write(pty.masterFD, buf.baseAddress, buf.count)
        }
    }

    // MARK: - Helpers

    /// Quote a string for tmux's command-line parser. tmux uses single
    /// quotes; literal single quotes are escaped as `'\''`.
    static func tmuxQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    }
}
