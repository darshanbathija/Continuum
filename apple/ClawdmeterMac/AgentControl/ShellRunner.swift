import Foundation
import OSLog

private let shellLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ShellRunner")

/// Type-safe subprocess wrapper. Builds argv arrays and uses Foundation's
/// `Process` (which calls posix_spawn under the hood) — NEVER concatenates
/// args into a shell string.
///
/// Why this exists (E4 + Codex eng-round):
/// - Your working dir is `/Users/.../CC Watch/Clawdmeter`. The space in
///   `CC Watch` breaks naive `cd <cwd> && exec <agent>` constructions: the
///   shell tokenizes on whitespace and `cd /Users/.../CC` separates from
///   `Watch/Clawdmeter`. argv arrays sidestep this entirely.
/// - Defends against shell injection if a future caller passes a path or
///   filename with `;`, `$()`, backticks, etc. The bytes go directly to
///   `execve` — no shell interprets them.
/// - Centralizes the boilerplate so tmux/git/tailscale callers don't each
///   reinvent stdout/stderr piping, exit-code checking, and error mapping.
///
/// The actor wrapper serializes shell-outs that share a tty / fd resource;
/// most callers don't share, but the actor isolation makes the cancel
/// semantics + lifetime tracking obvious.
public actor ShellRunner {

    public static let shared = ShellRunner()

    /// Result of a non-streaming `run(...)` call.
    public struct Result: Sendable {
        public let exitStatus: Int32
        public let stdout: Data
        public let stderr: Data

        public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Errors that surface to the caller. Specific cases (per E2 + Section 2):
    /// `Process` constructor failures vs. non-zero exit are different concerns.
    public enum ShellError: Error, Sendable {
        case executableNotFound(path: String)
        case spawnFailed(underlying: String)
        case nonZeroExit(exitStatus: Int32, stderr: String)
        case timedOut(after: TimeInterval)
    }

    public init() {}

    /// Run a command non-interactively, capture stdout+stderr, wait for exit.
    ///
    /// - Parameters:
    ///   - executable: absolute path. Caller is responsible for resolving
    ///     (e.g. via `which` at startup) so we don't depend on PATH at runtime.
    ///   - arguments: argv array (no shell-quoting needed, ever).
    ///   - cwd: working directory for the child. `nil` inherits ours.
    ///   - environment: `nil` inherits ours.
    ///   - timeout: kill the child if it hasn't exited by then. Defaults
    ///     to 30s — long enough for `git worktree add` on a fresh clone,
    ///     short enough that a hung tmux command surfaces fast.
    @discardableResult
    public func run(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShellError.executableNotFound(path: executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ShellError.spawnFailed(underlying: "\(error)")
        }

        // Drain stdout/stderr on background queues so the pipes don't fill
        // and block the child. AsyncStream is over-engineering for fixed-
        // size captures; explicit reads are fine.
        let outBox = DataBox()
        let errBox = DataBox()

        let drainQueue = DispatchQueue(label: "ShellRunner.drain")
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        drainQueue.async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            outDone.signal()
        }
        drainQueue.async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }

        // P2-Shared-2 + Codex structured P2: wait via terminationHandler
        // + a racing timeout Task instead of a 50ms poll. The earlier
        // patch added a bare `Task { ... }` for the timeout race, which
        // is unstructured and does NOT inherit the caller's cancellation.
        // If the caller's Task was cancelled mid-shell-out, the child
        // process kept running until the deadline expired (regressing
        // the previous explicit cancellation behavior).
        //
        // Bridge caller cancellation through `withTaskCancellationHandler`:
        // the onCancel closure terminates the process synchronously when
        // the calling Task is cancelled. terminate() triggers the
        // terminationHandler, which resumes the continuation with `true`.
        // We then detect cancellation by checking Task.isCancelled
        // after the await and throw CancellationError below.
        let resumed = ResumeOnce()
        let exitedNormally: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // `terminationHandler` runs on a background queue exactly
                // once when the process is reaped.
                process.terminationHandler = { _ in
                    if resumed.fire() { cont.resume(returning: true) }
                }
                // Timeout race only — caller cancellation is delivered
                // through the outer onCancel below.
                Task {
                    // Codex fix: `Duration.seconds(_:)` only accepts
                    // BinaryInteger — passing a TimeInterval (Double)
                    // doesn't compile. Convert through milliseconds so
                    // sub-second `timeout` values still work.
                    let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
                    while ContinuousClock.now < deadline {
                        if !process.isRunning { return }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if process.isRunning, resumed.fire() {
                        cont.resume(returning: false)
                    }
                }
            }
        } onCancel: {
            // Synchronous on the cancelling thread. Terminate the child
            // so terminationHandler fires and the awaiting continuation
            // wakes immediately. The `if Task.isCancelled` block below
            // converts this into a thrown CancellationError.
            if process.isRunning {
                process.terminate()
            }
        }
        if !exitedNormally {
            // Task cancelled OR deadline hit. Tear the child down. SIGTERM
            // first, give it 200ms, then SIGKILL.
            if process.isRunning {
                process.terminate()
                shellLogger.warning("\(executable, privacy: .public): terminating (cancelled or timed out after \(timeout)s)")
                try? await Task.sleep(nanoseconds: 200_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            if Task.isCancelled {
                // Best-effort drain so caller observation is consistent.
                outDone.wait()
                errDone.wait()
                throw CancellationError()
            }
            outDone.wait()
            errDone.wait()
            throw ShellError.timedOut(after: timeout)
        }

        outDone.wait()
        errDone.wait()

        let result = Result(
            exitStatus: process.terminationStatus,
            stdout: outBox.data,
            stderr: errBox.data
        )

        if result.exitStatus != 0 {
            shellLogger.debug("\(executable, privacy: .public) \(arguments, privacy: .public) → exit \(result.exitStatus)")
        }
        return result
    }

    /// Run a command and throw if exit status != 0.
    @discardableResult
    public func runOrThrow(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Result {
        let result = try await run(
            executable: executable, arguments: arguments,
            cwd: cwd, environment: environment, timeout: timeout
        )
        guard result.exitStatus == 0 else {
            throw ShellError.nonZeroExit(
                exitStatus: result.exitStatus,
                stderr: result.stderrString
            )
        }
        return result
    }

    /// Probe the filesystem for a known binary at one of the standard paths.
    /// Used at startup so we don't re-resolve on every call.
    ///
    /// Resolution order (first match wins):
    /// 1. UserDefaults override at `clawdmeter.binaries.<name>` (Settings → Diagnostics)
    /// 2. Environment override at `CLAWDMETER_BIN_<NAME_UPPERCASED>`
    /// 3. Known candidate paths (Homebrew, system, user local)
    /// 4. `which <name>` via PATH
    ///
    /// Replaces the previous hardcoded `/Users/darshanbathija_1/.local/bin/claude`
    /// pattern that broke for other users (T2 in Sessions v2 plan).
    nonisolated public static func locateBinary(_ name: String) -> String? {
        // 1. UserDefaults override (Settings → Diagnostics fallback path).
        let overrideKey = "clawdmeter.binaries.\(name)"
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // 2. Environment override.
        let envKey = "CLAWDMETER_BIN_\(name.uppercased())"
        if let envOverride = ProcessInfo.processInfo.environment[envKey],
           !envOverride.isEmpty,
           FileManager.default.isExecutableFile(atPath: envOverride) {
            return envOverride
        }
        // 3. Known candidate paths.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",   // Claude Code's user install (claude)
            "/opt/homebrew/bin/\(name)",    // Apple Silicon Homebrew (default for codex, gh, git)
            "/usr/local/bin/\(name)",       // Intel Homebrew / legacy
            "\(home)/.claude/local/\(name)",// alternate Claude install location
            "/usr/bin/\(name)",             // system
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // 4. `which` via PATH — last resort.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            if which.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            // best-effort; fall through to nil
        }
        return nil
    }
}

/// Reference-typed box for safely capturing `Data` across drain queues.
/// `DispatchQueue.async` captures `inout` Data by value, so a class wrapper
/// is the right shape here.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Single-shot guard so the terminationHandler and the timeout/cancellation
/// race can both attempt to resume the continuation without double-resume
/// traps. `fire()` returns true exactly once for the first caller.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
