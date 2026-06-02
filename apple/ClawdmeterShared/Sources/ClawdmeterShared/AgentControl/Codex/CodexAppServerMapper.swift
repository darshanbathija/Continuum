import Foundation

/// A decoded codex `app-server` event, normalized off the experimental stdio
/// JSON-RPC dialect (`codex app-server`, CLI 0.136.0) into a provider-neutral
/// value the daemon can fold onto `HarnessEvent`. Keeping this a plain Swift
/// model (no Mac imports, no live JSON-RPC) makes the mapper unit-testable +
/// Watch-safe; the Mac-only `CodexAppServerDriver` decodes inbound
/// `ServerNotification` / `ServerRequest` frames into these.
///
/// Dialect provenance: `codex app-server generate-ts --experimental`. This is
/// the v2 (thread/turn) dialect — `thread/start` → `turn/start` →
/// `item/agentMessage/delta` + `item/started`/`item/completed` (a `ThreadItem`
/// tagged by `type`) → `turn/completed`/`error`, with approvals arriving as
/// server→client requests (`item/commandExecution/requestApproval`,
/// `item/fileChange/requestApproval`, …). The cases mirror the ones we surface;
/// everything else degrades to `.unknown` so a newer CLI never tears a turn.
public enum CodexAppServerEvent: Sendable, Equatable {
    /// Assistant message delta (`item/agentMessage/delta`).
    case agentMessageDelta(String)
    /// Model reasoning delta (`item/reasoning/textDelta` /
    /// `item/reasoning/summaryTextDelta`), rendered as a thought, not a chat row.
    case reasoningDelta(String)
    /// A whole assistant message landed at once (`item/completed` with
    /// `type:"agentMessage"`) — codex emits the full text here even when no
    /// deltas streamed, so the projection has a non-empty turn body.
    case agentMessage(String)
    /// A command / tool call started or finished. `id` is the codex item id,
    /// `kind` the `ThreadItem.type` (commandExecution / mcpToolCall / …),
    /// `title` a human label (the command, the tool name, …).
    case toolCall(id: String, title: String?, kind: String?, status: HarnessToolCall.Status)
    /// A proposed file edit (`item/fileChange/*` or an `item` of
    /// `type:"fileChange"`). `unifiedDiff` is the per-file patch text.
    case fileDiff(path: String, unifiedDiff: String?)
    /// The agent is requesting approval (a server→client `*requestApproval`
    /// request). `requestId` is the JSON-RPC id we must answer; `kind` selects
    /// which approval-response shape the driver sends; `command`/`reason`
    /// enrich the title.
    case approval(requestId: RpcId, kind: CodexApprovalKind, title: String?, detail: String?)
    /// A plan / step breakdown (`turn/plan/updated`). Steps are
    /// `(text, status)` so the projection renders the same checklist the ACP
    /// `plan` update produces.
    case plan([CodexPlanStep])
    /// Token / cost accounting (`thread/tokenUsage/updated`).
    case usage(HarnessUsage)
    /// The turn finished (`turn/completed` carries `turn.status`).
    case turnFinished(CodexTurnStatus)
    /// A provider error surfaced mid-turn (`error` notification).
    case error(message: String)
    /// A frame kind we don't model yet (preserved for diagnostics/replay).
    case unknown(kind: String)
}

/// Which codex approval-response shape the driver must send back. Codex routes
/// approvals through several distinct server→client request methods, each with
/// its own response body (a `decision` enum, or a permissions grant), so the
/// mapper records the kind and the driver re-derives the response from the
/// chosen allow/reject option.
public enum CodexApprovalKind: String, Sendable, Equatable {
    /// `item/commandExecution/requestApproval` → `{decision: accept|decline}`.
    case commandExecution
    /// `item/fileChange/requestApproval` → `{decision: accept|decline}`.
    case fileChange
    /// Legacy `execCommandApproval` → `{decision: approved|denied}` (ReviewDecision).
    case execCommand
    /// Legacy `applyPatchApproval` → `{decision: approved|denied}` (ReviewDecision).
    case applyPatch
}

/// One step of a `turn/plan/updated` plan.
public struct CodexPlanStep: Sendable, Equatable {
    public var step: String
    /// Raw codex status string (`pending` / `in_progress` / `completed`).
    public var status: String?
    public init(step: String, status: String? = nil) {
        self.step = step; self.status = status
    }
}

/// Terminal turn status from `turn/completed` (or a `turn` payload).
public enum CodexTurnStatus: String, Sendable, Equatable {
    case completed
    case interrupted
    case failed
    /// Anything codex adds later degrades here so the projection never claims a
    /// clean completion it can't vouch for.
    case unknown

    public init(rawCodexStatus: String) {
        switch rawCodexStatus {
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: self = .unknown
        }
    }
}

/// Folds decoded codex app-server events into provider-neutral `HarnessEvent`s,
/// so a codex turn flows through the SAME `AcpHarnessProjection` → store path the
/// ACP agents use. Mirrors `AntigravityCascadeMapper` (text/thought/tool/diff/
/// permission/turn/error) — deliberately has no Mac / JSON-RPC dependency.
public struct CodexAppServerMapper: Sendable {
    public init() {}

    public func map(_ event: CodexAppServerEvent, sessionId: String) -> HarnessEvent? {
        switch event {
        case .agentMessageDelta(let text):
            return .agentMessageDelta(text)
        case .reasoningDelta(let text):
            return .agentThoughtDelta(text)
        case .agentMessage(let text):
            // A completed assistant message: feed it as a message delta so the
            // projection's assistant buffer flushes it at turn end (same as the
            // delta path — the projection appends whole messages, not rows).
            return .agentMessageDelta(text)
        case .toolCall(let id, let title, let kind, let status):
            return .toolCall(HarnessToolCall(toolCallId: id, title: title, kind: kind, status: status))
        case .fileDiff(let path, let unifiedDiff):
            return .diff(HarnessDiff(path: path, oldText: nil, newText: unifiedDiff))
        case .approval(let requestId, _, let title, let detail):
            // Codex approvals are binary (approve / decline the proposed action);
            // synthesize the two options the permission card renders. The
            // `requestId` carries the JSON-RPC id so the driver answers the right
            // server request; the approval `kind` is recovered from the option id
            // the user picks (allow_once → accept/approved, reject_once →
            // decline/denied) by the driver, so it isn't needed on the option.
            let suffix = (detail?.isEmpty == false) ? " (\(detail!))" : ""
            let options = [
                ACPPermissionOption(optionId: "allow_once", name: "Approve", kind: "allow_once"),
                ACPPermissionOption(optionId: "reject_once", name: "Decline", kind: "reject_once"),
            ]
            return .permissionRequest(HarnessPermissionRequest(
                requestId: requestId,
                sessionId: sessionId,
                title: (title ?? "Codex is requesting approval") + suffix,
                options: options
            ))
        case .plan(let steps):
            return .plan(steps.map { ACPPlanEntry(content: $0.step, status: $0.status) })
        case .usage(let usage):
            return .usage(usage)
        case .turnFinished(let status):
            switch status {
            case .completed: return .turnEnded(.endTurn)
            case .interrupted: return .turnEnded(.cancelled)
            // Abnormal end: the preceding `.error` event drives the message;
            // `.unknown` stop reason keeps the projection from misreporting a
            // failure as a clean completion or a user cancel.
            case .failed, .unknown: return .turnEnded(.unknown)
            }
        case .error(let message):
            return .error(code: "codex", message: message)
        case .unknown(let kind):
            return .unknownUpdate(kind: kind)
        }
    }

    public func map(events: [CodexAppServerEvent], sessionId: String) -> [HarnessEvent] {
        events.compactMap { map($0, sessionId: sessionId) }
    }
}
