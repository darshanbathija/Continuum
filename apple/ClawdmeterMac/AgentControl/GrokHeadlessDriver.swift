import Foundation
import OSLog
import ClawdmeterShared

private let grokLogger = Logger(subsystem: "com.clawdmeter.mac", category: "GrokHeadless")

/// Drives Grok via its HEADLESS mode — there is no ACP server in the shipping
/// grok binary (cmux "Grok Build" v0.2.x: TUI + headless one-shot + MCP client,
/// no persistent JSON-RPC agent). Each turn spawns:
///
///   grok --prompt-file <tmp> --output-format streaming-json --no-leader \
///        [--continue] [--model <m>] [--reasoning-effort <e>] [--always-approve]
///
/// and parses the NDJSON stream (one `{"type":"thought|text","data":"…"}` per
/// line, verified live 2026-06-03) into `HarnessEvent` deltas. Multi-turn uses
/// `--continue`, which resumes the most recent grok session for the cwd — and
/// each chat/Sessions workspace has its own cwd, so turns chain correctly.
///
/// Conforms to `AgentDriver` so it plugs into `AcpHarnessBridge` via the
/// `.transportOwning` factory (binary == nil; this driver owns its per-turn
/// processes, like the Antigravity gRPC driver owns its transport).
public actor GrokHeadlessDriver: AgentDriver {
    public nonisolated let events: AsyncStream<HarnessEvent>
    private let eventCont: AsyncStream<HarnessEvent>.Continuation

    private let binaryPath: String
    private var model: String?
    private var effort: String?
    private var cwd: String = ""
    private var alwaysApprove = false

    // Per-turn state.
    private var hasRunFirstTurn = false
    private var currentProc: Process?
    private var currentPromptURL: URL?
    private var lineBuf = Data()
    private var turnFinished = true

    public init(binaryPath: String) {
        self.binaryPath = binaryPath
        var c: AsyncStream<HarnessEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        self.eventCont = c
    }

    // MARK: AgentDriver

    public func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw ACPError.startFailed("grok binary not found at \(binaryPath). Install Grok / cmux first.")
        }
        self.model = model
        self.effort = effort
        self.cwd = cwd
        self.alwaysApprove = alwaysApprove
        // Headless grok has no persistent session; the cwd keys --continue.
        return "grok-headless:\(cwd.isEmpty ? UUID().uuidString : cwd)"
    }

    public func prompt(_ text: String) async {
        // Reset per-turn state.
        lineBuf = Data()
        turnFinished = false

        let promptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-prompt-\(UUID().uuidString).txt")
        do {
            try text.write(to: promptURL, atomically: true, encoding: .utf8)
        } catch {
            eventCont.yield(.error(code: "grok_prompt_write", message: "\(error)"))
            finishTurn(reason: .endTurn)
            return
        }
        currentPromptURL = promptURL

        var args = ["--prompt-file", promptURL.path, "--output-format", "streaming-json", "--no-leader"]
        if hasRunFirstTurn { args.append("--continue") }   // resume this cwd's session
        if alwaysApprove { args.append("--always-approve") }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let effort, !effort.isEmpty { args += ["--reasoning-effort", effort] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        if !cwd.isEmpty { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        proc.environment = ProcessInfo.processInfo.environment
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // grok logs auth/shutdown noise to stderr; ignore.

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
            eventCont.yield(.error(code: "grok_spawn", message: "failed to launch grok: \(error)"))
            finishTurn(reason: .endTurn)
            return
        }
        currentProc = proc
        // Return: the turn is accepted; deltas + `.turnEnded` stream from the
        // readability/termination handlers.
    }

    public func cancel() async {
        currentProc?.terminate()
        finishTurn(reason: .cancelled)
    }

    /// Headless grok has no interactive permission flow (it either auto-approves
    /// via `--always-approve` or doesn't run tools), so there's nothing to answer.
    public func respondToPermission(requestId: RpcId, optionId: String?) async {}

    public func close() async {
        currentProc?.terminate()
        currentProc = nil
        eventCont.finish()
    }

    // MARK: streaming-json parse

    private func ingest(_ data: Data) {
        lineBuf.append(data)
        while let nl = lineBuf.firstIndex(of: 0x0A) {
            let line = lineBuf.subdata(in: lineBuf.startIndex..<nl)
            lineBuf.removeSubrange(lineBuf.startIndex...nl)
            emitLine(line)
        }
    }

    private func emitLine(_ data: Data) {
        if let event = Self.parseLine(data) { eventCont.yield(event) }
    }

    /// Map one grok streaming-json line to a HarnessEvent. Pure + nonisolated so
    /// it is unit-testable without spawning grok. Shape (verified live 2026-06-03):
    /// `{"type":"thought"|"text"|"error","data":"<delta>"}`. Empty deltas and
    /// unmodeled types (tool calls, etc.) return nil.
    nonisolated static func parseLine(_ data: Data) -> HarnessEvent? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        let payload = obj["data"] as? String ?? ""
        switch type {
        case "text":    return payload.isEmpty ? nil : .agentMessageDelta(payload)
        case "thought": return payload.isEmpty ? nil : .agentThoughtDelta(payload)
        case "error":   return .error(code: "grok", message: payload)
        default:        return nil
        }
    }

    /// Idempotent turn completion — EOF and terminationHandler can both fire;
    /// cancel() pre-empts with `.cancelled`. First caller wins.
    private func finishTurn(reason: ACPStopReason) {
        guard !turnFinished else { return }
        turnFinished = true
        if !lineBuf.isEmpty { emitLine(lineBuf); lineBuf = Data() }
        hasRunFirstTurn = true
        currentProc = nil
        if let url = currentPromptURL {
            try? FileManager.default.removeItem(at: url)
            currentPromptURL = nil
        }
        eventCont.yield(.turnEnded(reason))
    }
}
