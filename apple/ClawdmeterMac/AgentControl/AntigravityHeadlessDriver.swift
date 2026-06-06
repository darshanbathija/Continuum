import Foundation
import OSLog
import ClawdmeterShared

private let agyLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AntigravityHeadless")

/// Drives Google Antigravity (Gemini) via its HEADLESS `agy` CLI — Antigravity
/// 2.0 (Google I/O 2026) decoupled the agent from the IDE, so we no longer need
/// the desktop app running or the reverse-engineered Cascade gRPC transport.
/// Each turn spawns:
///
///   agy --dangerously-skip-permissions [--continue] --print "<prompt>"
///
/// `agy --print` runs a single prompt non-interactively and streams the response
/// as plain text to stdout. Multi-turn uses `--continue`, which resumes the most
/// recent conversation for the cwd — and each chat/Sessions workspace has its
/// own cwd, so turns chain correctly (same model as `GrokHeadlessDriver`).
///
/// Conforms to `AgentDriver` so it plugs into `AcpHarnessBridge` via the
/// `.transportOwning` factory (binary == nil; this driver owns its per-turn
/// processes). The legacy gRPC `AntigravityCascadeDriver` stays behind the
/// `antigravity.grpc.enabled` kill-switch as an opt-in fallback.
public actor AntigravityHeadlessDriver: AgentDriver {
    public nonisolated let events: AsyncStream<HarnessEvent>
    private let eventCont: AsyncStream<HarnessEvent>.Continuation

    private let binaryPath: String
    private var cwd: String = ""
    private var alwaysApprove = false

    // Per-turn state.
    private var hasRunFirstTurn = false
    private var currentProc: Process?
    private var turnFinished = true
    private var sawOutput = false

    public init(binaryPath: String) {
        self.binaryPath = binaryPath
        var c: AsyncStream<HarnessEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        self.eventCont = c
    }

    // MARK: AgentDriver

    public func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw ACPError.startFailed("agy binary not found at \(binaryPath). Install Antigravity 2 (agy CLI) first.")
        }
        self.cwd = cwd
        self.alwaysApprove = alwaysApprove
        // Headless agy has no persistent session handle; the cwd keys --continue.
        return "agy-headless:\(cwd.isEmpty ? UUID().uuidString : cwd)"
    }

    public func prompt(_ text: String) async {
        turnFinished = false
        sawOutput = false

        // Flags BEFORE the prompt so Go flag parsing applies them; the prompt is
        // the value of --print (last). alwaysApprove is on for harness sessions.
        var args: [String] = []
        if alwaysApprove { args.append("--dangerously-skip-permissions") }
        if hasRunFirstTurn { args.append("--continue") }   // resume this cwd's conversation
        args += ["--print", text]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        if !cwd.isEmpty { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        proc.environment = ProcessInfo.processInfo.environment
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // agy logs auth/status noise to stderr; ignore.

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { await self?.finishTurn(reason: .endTurn) }
            } else {
                Task { await self?.ingest(data) }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.finishTurn(reason: .endTurn) }
        }

        do {
            try proc.run()
        } catch {
            eventCont.yield(.error(code: "agy_spawn", message: "failed to launch agy: \(error)"))
            finishTurn(reason: .endTurn)
            return
        }
        currentProc = proc
        // Deltas + `.turnEnded` stream from the readability/termination handlers.
    }

    public func cancel() async {
        currentProc?.terminate()
        finishTurn(reason: .cancelled)
    }

    /// Headless agy auto-approves via `--dangerously-skip-permissions`, so there
    /// is no interactive permission round-trip to answer.
    public func respondToPermission(requestId: RpcId, optionId: String?) async {}

    public func close() async {
        currentProc?.terminate()
        currentProc = nil
        eventCont.finish()
    }

    // MARK: plain-text stdout → assistant deltas

    /// `agy --print` emits plain text (no NDJSON), so each stdout chunk is an
    /// assistant message delta. The store buffers + flushes them as one row on
    /// `.turnEnded` (same projection the other drivers use).
    private func ingest(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return }
        sawOutput = true
        eventCont.yield(.agentMessageDelta(s))
    }

    /// Idempotent turn completion — EOF and terminationHandler can both fire;
    /// cancel() pre-empts with `.cancelled`. First caller wins.
    private func finishTurn(reason: ACPStopReason) {
        guard !turnFinished else { return }
        turnFinished = true
        hasRunFirstTurn = true
        currentProc = nil
        if !sawOutput && reason == .endTurn {
            eventCont.yield(.error(code: "agy_empty", message: "agy produced no output (check `agy` auth)."))
        }
        eventCont.yield(.turnEnded(reason))
    }
}
