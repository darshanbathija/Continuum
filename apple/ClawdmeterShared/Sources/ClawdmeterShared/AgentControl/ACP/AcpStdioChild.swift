#if os(macOS) || os(Linux)
import Foundation

/// A long-lived agent child process with piped stdin/stdout/stderr — the one
/// genuinely-new transport primitive (neither `ShellRunner`, which waits for
/// exit, nor `PseudoTerminal`, which is a tty, gives a persistent line-streamed
/// child). Conforms to `AcpByteWriter` so it plugs straight into
/// `NdjsonRpcConnection`. macOS/Linux only — iOS/Watch drive via the daemon.
///
/// Lifecycle hardening (review A6 + the documented `ShellRunner` hang):
/// `terminationHandler` is installed before `run()`, child exit fails in-flight
/// requests, and teardown is SIGTERM → grace → SIGKILL.
public actor AcpStdioChild: AcpByteWriter {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var onStdout: (@Sendable (Data) async -> Void)?
    private var onExit: (@Sendable (Int32?) -> Void)?
    private var stderrRing = Data()
    private var launched = false

    public init() {}

    public func setOnStdout(_ h: @escaping @Sendable (Data) async -> Void) { onStdout = h }
    public func setOnExit(_ h: @escaping @Sendable (Int32?) -> Void) { onExit = h }

    /// Resolve a binary name to an absolute path via PATH (the daemon uses
    /// `ShellRunner.locateBinary`; this is the standalone fallback for the
    /// shared package + tests).
    public static func resolve(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func launch(executable: String, arguments: [String], cwd: String?, env: [String: String]?) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd, !cwd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { process.environment = env }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let child = self else { return }
            Task { await child.emitStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let child = self else { return }
            Task { await child.appendStderr(data) }
        }
        // MUST be set before run(): if the child exits between run() and a later
        // assignment, the handler never fires and awaiters hang forever.
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            guard let child = self else { return }
            Task { await child.emitExit(code) }
        }
        try process.run()
        launched = true
    }

    // AcpByteWriter
    public func write(_ data: Data) async throws {
        guard launched else { throw ACPError.processExited(code: nil) }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Graceful teardown: detach handlers, SIGTERM, then SIGKILL after a grace.
    public func terminate(graceSeconds: Double = 0.2) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
        let p = process
        Task {
            try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    public var stderrText: String { String(data: stderrRing, encoding: .utf8) ?? "" }
    public var isRunning: Bool { process.isRunning }
    public var pid: Int32 { process.processIdentifier }

    private func emitStdout(_ d: Data) async { await onStdout?(d) }
    private func emitExit(_ code: Int32) async { onExit?(code) }
    private func appendStderr(_ d: Data) {
        stderrRing.append(d)
        if stderrRing.count > 64_000 { stderrRing.removeFirst(stderrRing.count - 64_000) }
    }
}
#endif
