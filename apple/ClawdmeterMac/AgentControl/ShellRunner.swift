import Foundation
import OSLog
import ClawdmeterShared

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
    /// - Centralizes the boilerplate so git/tailscale/provider callers don't each
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
    public enum ShellError: Error, Sendable, LocalizedError {
        case executableNotFound(path: String)
        case spawnFailed(underlying: String)
        case nonZeroExit(exitStatus: Int32, stderr: String)
        case timedOut(after: TimeInterval)

        // Without LocalizedError, `localizedDescription` collapses to the
        // useless "The operation couldn’t be completed. (…ShellError error 2.)"
        // — which used to leak opaque enum names into the UI. Every caller that
        // surfaces a ShellError via `error.localizedDescription` (frontier slot
        // reasons, chat-cwd create) now gets a message that names the failure + the
        // process's own stderr.
        public var errorDescription: String? {
            switch self {
            case .executableNotFound(let path):
                return "Couldn’t find an executable at \(path)."
            case .spawnFailed(let underlying):
                return "Failed to launch the process: \(underlying)"
            case .nonZeroExit(let exitStatus, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "Process exited with status \(exitStatus)."
                    : "Process exited with status \(exitStatus): \(detail)"
            case .timedOut(let after):
                return "Process timed out after \(Int(after))s."
            }
        }
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
    ///     short enough that a hung subprocess surfaces fast.
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

        // Codex fix: set terminationHandler BEFORE `run()`. For very
        // short-lived commands (`true`, `which`, small git probes) the
        // child can exit between `process.run()` and a later handler
        // assignment, in which case the handler never fires, the
        // timeout Task observes `!process.isRunning` and returns
        // without resuming the continuation, and `ShellRunner.run`
        // hangs forever. Wire `resumed`/handler now so the slot is
        // armed before the process is even alive.
        let resumed = ResumeOnce()
        // The continuation reference is filled in below via the
        // box; the terminationHandler closure captures the box so
        // it can resume whichever continuation withCheckedContinuation
        // installs in a moment.
        let continuationBox = ContinuationBox()
        process.terminationHandler = { _ in
            if resumed.fire() {
                continuationBox.continuation?.resume(returning: true)
            }
        }

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

        // P2-Shared-2 + Codex structured: wait via terminationHandler
        // (set above, BEFORE `run()`) + a racing timeout Task. Caller
        // cancellation is bridged through `withTaskCancellationHandler`;
        // the onCancel closure terminates the process synchronously,
        // which fires the terminationHandler set above, which resumes
        // the continuation. The post-await `if Task.isCancelled`
        // block converts this into a thrown CancellationError.
        //
        // If the child has already exited before this `await`
        // (very short-lived commands like `true`), resume immediately
        // — the terminationHandler may have fired before continuationBox
        // had a continuation to deliver to, but the `process.isRunning`
        // poll below catches it.
        let exitedNormally: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                continuationBox.continuation = cont
                // If the child already terminated between run() and
                // here (handler fired with a nil continuation), resume
                // now ourselves so we don't hang.
                if !process.isRunning, resumed.fire() {
                    cont.resume(returning: true)
                    return
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
                        if !process.isRunning {
                            // Child finished but handler may have raced
                            // us — resume only if we won the race.
                            if resumed.fire() { cont.resume(returning: true) }
                            return
                        }
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
    /// 2. App-bundled vendor binary under Contents/Resources/Vendor/<name>/
    /// 3. Environment override at `CLAWDMETER_BIN_<NAME_UPPERCASED>` (Debug only)
    /// 4. Known candidate paths (Homebrew, system, user local)
    /// 5. `which <name>` via PATH
    ///
    /// Bundled is preferred over the env override so an inherited or
    /// attacker-set `CLAWDMETER_BIN_<NAME>` can't redirect a
    /// security-sensitive binary to an arbitrary path. The
    /// env override is retained in Debug builds for dev convenience.
    /// UserDefaults stays first because it requires an explicit Settings
    /// action — user-consented.
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
        // 2. App-bundled vendor binary. Bundled is checked BEFORE the env
        // override so a hostile env var can't replace a security-sensitive
        // binary the app ships with.
        if let resourceURL = Bundle.main.resourceURL {
            let bundledCandidates = [
                resourceURL
                    .appendingPathComponent("Vendor", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
                    .path,
                resourceURL
                    .appendingPathComponent("Vendor", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
                    .path,
            ]
            for path in bundledCandidates {
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        // 3. Environment override — DEBUG builds only. In Release the
        // env override would let a hostile parent process redirect
        // claude/codex/etc. to an attacker-controlled path; user-explicit
        // overrides go through UserDefaults instead.
        #if DEBUG
        let envKey = "CLAWDMETER_BIN_\(name.uppercased())"
        if let envOverride = ProcessInfo.processInfo.environment[envKey],
           !envOverride.isEmpty,
           FileManager.default.isExecutableFile(atPath: envOverride) {
            return envOverride
        }
        #endif
        // 4. Known candidate paths.
        // v0.28.0: ClawdmeterRealHome (getpwuid) rather than
        // FileManager.default.homeDirectoryForCurrentUser so the sandboxed
        // Release build searches the user's actual `~/.local/bin/` (where
        // cursor-agent, claude, etc. typically install) instead of the
        // app container's empty `.local/bin/`. The Release entitlements
        // grant read-only access to /.local/bin/ — see
        // ClawdmeterMac-Release.entitlements.
        let home = ClawdmeterRealHome.path()
        let candidates = [
            "\(home)/.local/bin/\(name)",   // Claude Code, cursor-agent, etc. — user-local installs
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

/// v0.7.7: ResumeOnce replaced by the shared `FireOnce` primitive in
/// ClawdmeterShared. Typealias kept here so the existing call sites
/// in `run(...)` stay readable — "resumed.fire()" reads better than
/// "fireOnce.fire()" at the continuation race site.
private typealias ResumeOnce = FireOnce

/// Holds the continuation reference so the terminationHandler (set
/// before `process.run()` to avoid the fast-exit hang) can resume
/// whichever continuation withCheckedContinuation produces a moment
/// later. Access is single-writer (the body closure assigns once),
/// single-reader (the handler reads once), so a plain class with
/// implicit nil-init suffices.
private final class ContinuationBox: @unchecked Sendable {
    var continuation: CheckedContinuation<Bool, Never>?
}
