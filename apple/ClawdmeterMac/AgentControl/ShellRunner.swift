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

        // Wait with timeout. Process.waitUntilExit doesn't take a timeout,
        // so we poll. Cooperative cancellation across Tasks is handled by
        // calling `terminate()` on the process if the surrounding Task is
        // cancelled.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                shellLogger.warning("\(executable, privacy: .public): task cancelled, sent SIGTERM")
                break
            }
            if Date() > deadline {
                process.terminate()
                shellLogger.warning("\(executable, privacy: .public): timed out after \(timeout)s, sent SIGTERM")
                // Give it a beat to die from SIGTERM; otherwise SIGKILL.
                try? await Task.sleep(nanoseconds: 200_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                throw ShellError.timedOut(after: timeout)
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
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
    nonisolated public static func locateBinary(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",   // Apple Silicon Homebrew (default)
            "/usr/local/bin/\(name)",      // Intel Homebrew / legacy
            "/usr/bin/\(name)",            // system
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
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
