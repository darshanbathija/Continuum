#if os(macOS) || os(Linux)
import Foundation
import ClawdmeterShared

/// Codex `app-server` driver — drives `codex app-server` (experimental stdio
/// JSON-RPC, CLI 0.136.0) over an injected `NdjsonRpcConnection`, the same way
/// `AcpAgentDriver` drives ACP agents. Transport (process spawn vs in-memory
/// test channel) is injected, so this is unit-testable end to end with a fake
/// codex server.
///
/// This is for NEW codex sessions only. The existing `CodexSDKManager` relay +
/// JSONL decode path stays for back-compat; this driver speaks the native
/// app-server dialect (thread/turn lifecycle, item streaming, native approval
/// requests) instead.
///
/// Dialect (`codex app-server generate-ts --experimental`, verified live
/// 2026-06-02):
///   - start  = `initialize` (no auth round-trip; codex uses its cached login)
///              then `thread/start` → `result.thread.id` is the thread id we
///              return as the external session id.
///   - prompt = `turn/start {threadId, input:[{type:"text", …}]}` →
///              `result.turn.id` is the in-flight turn id. The request resolves
///              at turn *acceptance* (status inProgress); turn END arrives as a
///              `turn/completed` notification (unlike ACP's `session/prompt`,
///              which resolves at turn end). So `.turnEnded` is emitted from the
///              notification stream, not the request response.
///   - cancel = `turn/interrupt {threadId, turnId}`.
///   - respondToPermission = answer the server→client `*requestApproval`
///              request with the kind-specific response body.
///   - close  = close the connection + finish events.
public actor CodexAppServerDriver: AgentDriver {
    public nonisolated let events: AsyncStream<HarnessEvent>
    private let eventCont: AsyncStream<HarnessEvent>.Continuation

    private let connection: NdjsonRpcConnection
    private let clientInfo: ACPClientInfo
    private let mapper = CodexAppServerMapper()

    private var threadId: String?
    /// The in-flight turn id (from the latest `turn/start` response), needed for
    /// `turn/interrupt`.
    private var currentTurnId: String?
    /// Pending approval kind keyed by the server-request RpcId, so
    /// `respondToPermission` can pick the right response shape.
    private var pendingApprovals: [RpcId: CodexApprovalKind] = [:]

    public init(connection: NdjsonRpcConnection, clientInfo: ACPClientInfo) {
        self.connection = connection
        self.clientInfo = clientInfo
        var cont: AsyncStream<HarnessEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.eventCont = cont
    }

    // MARK: start (two-phase: throws synchronously)

    public func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String {
        await wireHandlers()

        // initialize — codex authenticates from its own cached login, so there
        // is no ACP-style authenticate round-trip. capabilities.experimentalApi
        // is on because the thread/turn v2 dialect lives behind it.
        let initParams = ACPJSONValue.object([
            "clientInfo": .object([
                "name": .string(clientInfo.name),
                "title": .null,
                "version": .string(clientInfo.version),
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(true),
                "requestAttestation": .bool(false),
            ]),
        ])
        do {
            _ = try await connection.request(CodexAppServerMethod.initialize, params: initParams)
        } catch {
            throw ACPError.startFailed("codex initialize failed: \(error)")
        }

        // thread/start — model/effort/sandbox are launch-time overrides. When
        // alwaysApprove is set we let codex run untrusted commands without
        // prompting; otherwise it raises approval requests we surface.
        var threadParams: [String: ACPJSONValue] = [
            "cwd": .string(cwd),
            "approvalPolicy": .string(alwaysApprove ? "never" : "on-request"),
            "sandbox": .string(alwaysApprove ? "danger-full-access" : "workspace-write"),
        ]
        if let model, !model.isEmpty { threadParams["model"] = .string(model) }
        let startRaw: ACPJSONValue
        do {
            startRaw = try await connection.request(CodexAppServerMethod.threadStart, params: .object(threadParams))
        } catch {
            throw ACPError.startFailed("codex thread/start failed: \(error). Sign in to codex first (`codex login`).")
        }
        guard let tid = startRaw["thread"]?["id"]?.stringValue else {
            throw ACPError.startFailed("codex thread/start returned no thread id")
        }
        threadId = tid
        return tid
    }

    // MARK: turn loop

    public func prompt(_ text: String) async {
        guard let tid = threadId else {
            eventCont.yield(.error(code: "no_thread", message: "prompt before start"))
            eventCont.yield(.turnEnded(.unknown))
            return
        }
        // input is the codex UserInput union; a plain text turn carries an empty
        // text_elements array (UI span metadata we don't produce).
        let params = ACPJSONValue.object([
            "threadId": .string(tid),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                    "text_elements": .array([]),
                ]),
            ]),
        ])
        // Fire-and-accept: the request resolves at turn acceptance (status
        // inProgress) and yields the turn id for interrupt. Turn END is the
        // `turn/completed` notification handled in the stream, NOT this response.
        Task { [connection, eventCont] in
            do {
                let raw = try await connection.request(CodexAppServerMethod.turnStart, params: params)
                if let turnId = raw["turn"]?["id"]?.stringValue {
                    await self.setCurrentTurnId(turnId)
                }
            } catch let ACPError.processExited(code) {
                eventCont.yield(.error(code: "process_exited", message: "codex exited (code \(code.map(String.init) ?? "?"))"))
                eventCont.yield(.turnEnded(.unknown))
            } catch {
                eventCont.yield(.error(code: "turn_start_failed", message: "\(error)"))
                eventCont.yield(.turnEnded(.unknown))
            }
        }
    }

    public func cancel() async {
        guard let tid = threadId, let turnId = currentTurnId else { return }
        try? await connection.notify(CodexAppServerMethod.turnInterrupt,
                                     params: .object(["threadId": .string(tid), "turnId": .string(turnId)]))
    }

    public func respondToPermission(requestId: RpcId, optionId: String?) async {
        // Recover which approval-response shape this request expects. Default to
        // the v2 commandExecution shape if the kind wasn't recorded (forward-
        // compat) — `decline` is the safe fallback for a cancelled prompt.
        let kind = pendingApprovals.removeValue(forKey: requestId) ?? .commandExecution
        // allow_once → accept/approve; anything else (reject_once or nil/cancel)
        // → decline/deny. The synthesized option ids come from CodexAppServerMapper.
        let approved = optionId == "allow_once"
        let result: ACPJSONValue
        switch kind {
        case .commandExecution, .fileChange:
            // v2 *requestApproval → {decision: "accept" | "decline"}.
            result = .object(["decision": .string(approved ? "accept" : "decline")])
        case .execCommand, .applyPatch:
            // Legacy execCommandApproval / applyPatchApproval → ReviewDecision
            // ({decision: "approved" | "denied"}).
            result = .object(["decision": .string(approved ? "approved" : "denied")])
        }
        try? await connection.respond(to: requestId, result: result)
    }

    public func close() async {
        await connection.close()
        eventCont.finish()
    }

    // MARK: handlers

    private func setCurrentTurnId(_ id: String) { currentTurnId = id }

    private func wireHandlers() async {
        await connection.setOnNotification { [weak self] method, params in
            await self?.handleNotification(method: method, params: params)
        }
        await connection.setOnClientRequest { [weak self] method, id, params in
            await self?.handleServerRequest(method: method, id: id, params: params)
        }
    }

    /// Server→client notifications: the turn/item stream. Decode each into a
    /// `CodexAppServerEvent`, run it through the mapper, and emit on `events`.
    private func handleNotification(method: String, params: ACPJSONValue) async {
        guard let ev = decodeNotification(method: method, params: params) else { return }
        if let harnessEvent = mapper.map(ev, sessionId: threadId ?? "") {
            eventCont.yield(harnessEvent)
        }
    }

    /// Server→client requests: codex approval prompts. We surface them as
    /// permission requests carrying the JSON-RPC id (the daemon answers later via
    /// `respondToPermission`). fs/process/other server requests we don't
    /// implement get a clean method-not-found refusal.
    private func handleServerRequest(method: String, id: RpcId, params: ACPJSONValue) async {
        guard let kind = CodexAppServerDriver.approvalKind(for: method) else {
            try? await connection.respondError(to: id, code: ACP.ErrorCode.methodNotFound,
                                               message: "codex client method \(method) not enabled")
            return
        }
        pendingApprovals[id] = kind
        let (title, detail) = CodexAppServerDriver.approvalTitle(method: method, params: params)
        let ev = CodexAppServerEvent.approval(requestId: id, kind: kind, title: title, detail: detail)
        if let harnessEvent = mapper.map(ev, sessionId: threadId ?? "") {
            eventCont.yield(harnessEvent)
        }
        // Deferred: the daemon answers later via respondToPermission(requestId:).
    }

    // MARK: notification decode (CodexAppServerEvent from raw JSON-RPC params)

    /// Map a `ServerNotification` method + params to a `CodexAppServerEvent`.
    /// Unmodeled methods return nil (silently dropped) EXCEPT for ones whose
    /// loss would corrupt the turn lifecycle, which fall through to `.unknown`.
    private func decodeNotification(method: String, params: ACPJSONValue) -> CodexAppServerEvent? {
        switch method {
        case "item/agentMessage/delta":
            return params["delta"]?.stringValue.map { .agentMessageDelta($0) }
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            return params["delta"]?.stringValue.map { .reasoningDelta($0) }
        case "item/started":
            return Self.eventFromItem(params["item"], started: true)
        case "item/completed":
            return Self.eventFromItem(params["item"], started: false)
        case "item/fileChange/patchUpdated", "item/fileChange/outputDelta":
            return Self.fileDiffFromItemParams(params)
        case "turn/plan/updated":
            let steps = (params["plan"]?.arrayValue ?? []).compactMap { entry -> CodexPlanStep? in
                guard let step = entry["step"]?.stringValue else { return nil }
                return CodexPlanStep(step: step, status: entry["status"]?.stringValue)
            }
            return steps.isEmpty ? nil : .plan(steps)
        case "thread/tokenUsage/updated":
            let last = params["tokenUsage"]?["last"]
            return .usage(HarnessUsage(
                inputTokens: last?["inputTokens"]?.intValue,
                outputTokens: last?["outputTokens"]?.intValue,
                totalTokens: last?["totalTokens"]?.intValue))
        case "turn/completed":
            let status = params["turn"]?["status"]?.stringValue ?? "completed"
            return .turnFinished(CodexTurnStatus(rawCodexStatus: status))
        case "error":
            // A turn-level `error` notification (TurnError under `error.message`).
            let message = params["error"]?["message"]?.stringValue ?? "codex error"
            return .error(message: message)
        // Lifecycle / chatter we deliberately don't surface as events (the turn
        // start/end is driven by turn/completed + the prompt response).
        case "thread/started", "thread/status/changed", "turn/started",
             "turn/diff/updated", "mcpServer/startupStatus/updated",
             "remoteControl/status/changed", "warning", "thread/tokenUsage",
             "item/plan/delta", "serverRequest/resolved":
            return nil
        default:
            return nil
        }
    }

    /// Build an event from a `ThreadItem` (item/started or item/completed). The
    /// item is tagged by `type`; we surface the kinds the harness renders.
    private static func eventFromItem(_ item: ACPJSONValue?, started: Bool) -> CodexAppServerEvent? {
        guard let item, let type = item["type"]?.stringValue, let id = item["id"]?.stringValue else { return nil }
        switch type {
        case "agentMessage":
            // The full assistant text lands on item/completed; on item/started
            // there's usually no text yet, so only emit when present.
            guard !started, let text = item["text"]?.stringValue, !text.isEmpty else { return nil }
            return .agentMessage(text)
        case "commandExecution":
            let title = item["command"]?.stringValue
            let status = mapCommandStatus(item["status"]?.stringValue, started: started)
            return .toolCall(id: id, title: title, kind: "commandExecution", status: status)
        case "mcpToolCall":
            let server = item["server"]?.stringValue ?? ""
            let tool = item["tool"]?.stringValue ?? "tool"
            let title = server.isEmpty ? tool : "\(server)/\(tool)"
            let status = mapMcpStatus(item["status"]?.stringValue, started: started)
            return .toolCall(id: id, title: title, kind: "mcpToolCall", status: status)
        case "dynamicToolCall":
            let title = item["tool"]?.stringValue ?? "tool"
            let status: HarnessToolCall.Status = started ? .inProgress : .completed
            return .toolCall(id: id, title: title, kind: "dynamicToolCall", status: status)
        case "webSearch":
            let title = item["query"]?.stringValue.map { "web search: \($0)" } ?? "web search"
            return .toolCall(id: id, title: title, kind: "webSearch", status: started ? .inProgress : .completed)
        case "fileChange":
            // A fileChange item carries `changes: [{path, kind, diff}]` — emit one
            // diff per file. eventFromItem returns a single event, so emit the
            // first change here; multi-file is rare and the turn diff covers it.
            guard let first = item["changes"]?.arrayValue?.first,
                  let path = first["path"]?.stringValue else { return nil }
            return .fileDiff(path: path, unifiedDiff: first["diff"]?.stringValue)
        case "plan":
            // A completed plan item carries the whole plan text; surface as a
            // single-step plan so the projection shows it.
            guard let text = item["text"]?.stringValue, !text.isEmpty else { return nil }
            return .plan([CodexPlanStep(step: text, status: started ? "in_progress" : "completed")])
        default:
            // userMessage / reasoning / contextCompaction / imageView / review
            // modes etc. — not surfaced as harness events here.
            return nil
        }
    }

    /// Build a fileDiff from an `item/fileChange/*` notification (params carry the
    /// patch directly rather than a ThreadItem).
    private static func fileDiffFromItemParams(_ params: ACPJSONValue) -> CodexAppServerEvent? {
        if let path = params["path"]?.stringValue {
            return .fileDiff(path: path, unifiedDiff: params["diff"]?.stringValue ?? params["delta"]?.stringValue)
        }
        // patchUpdated may nest the change list; take the first.
        if let first = params["changes"]?.arrayValue?.first, let path = first["path"]?.stringValue {
            return .fileDiff(path: path, unifiedDiff: first["diff"]?.stringValue)
        }
        return nil
    }

    private static func mapCommandStatus(_ raw: String?, started: Bool) -> HarnessToolCall.Status {
        switch raw {
        case "inProgress": return .inProgress
        case "completed": return .completed
        case "failed", "declined": return .failed
        default: return started ? .inProgress : .completed
        }
    }

    private static func mapMcpStatus(_ raw: String?, started: Bool) -> HarnessToolCall.Status {
        switch raw {
        case "inProgress", "running": return .inProgress
        case "completed", "success": return .completed
        case "failed", "error": return .failed
        default: return started ? .inProgress : .completed
        }
    }

    /// Which approval-response shape a server→client request method maps to. Nil
    /// for non-approval server requests (fs/process/elicitation) we refuse.
    static func approvalKind(for method: String) -> CodexApprovalKind? {
        switch method {
        case "item/commandExecution/requestApproval": return .commandExecution
        case "item/fileChange/requestApproval": return .fileChange
        case "item/permissions/requestApproval": return .commandExecution // accept/decline-shaped at the option level
        case "execCommandApproval": return .execCommand
        case "applyPatchApproval": return .applyPatch
        default: return nil
        }
    }

    /// A human title + detail for an approval prompt, from the request params.
    static func approvalTitle(method: String, params: ACPJSONValue) -> (String?, String?) {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            // v2 carries `command` (string); legacy carries `command` (string array).
            let cmd = params["command"]?.stringValue
                ?? params["command"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: " ")
            return ("Run command?", cmd ?? params["reason"]?.stringValue)
        case "item/fileChange/requestApproval", "applyPatchApproval":
            return ("Apply file changes?", params["reason"]?.stringValue)
        case "item/permissions/requestApproval":
            return ("Grant permissions?", params["reason"]?.stringValue)
        default:
            return (nil, params["reason"]?.stringValue)
        }
    }
}

/// codex app-server JSON-RPC method names (the subset the driver calls). Mirrors
/// `ACP.AgentMethod` so the dialect is one grep away from the wire. Verified
/// against `codex app-server generate-ts --experimental` (CLI 0.136.0).
public enum CodexAppServerMethod {
    public static let initialize = "initialize"
    public static let threadStart = "thread/start"
    public static let threadResume = "thread/resume"
    public static let turnStart = "turn/start"
    public static let turnInterrupt = "turn/interrupt"
}
#endif
