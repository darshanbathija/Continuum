import Foundation

/// Store operations the daemon applies to a session's `SessionChatStore` as a
/// turn streams. Kept as a pure value type so the HarnessEvent→store mapping is
/// unit-testable without the daemon (the Mac bridge is the thin applier).
public enum AcpStoreOp: Sendable, Equatable {
    case appendAssistantText(String)
    case appendToolCall(title: String, status: String)
    case setPlanText(String?)
    case setTurnState(TurnState)
    case setPermissionPrompt(PendingPermissionPrompt?)
    case appendErrorText(String)
}

/// Folds a stream of `HarnessEvent`s (from `AcpAgentDriver`) into `AcpStoreOp`s.
/// Assistant text deltas are buffered and flushed as one message at turn end
/// (the daemon's chat store appends whole messages, not per-token rows). Plan,
/// tool calls, permission prompts, and turn state map directly.
public struct AcpHarnessProjection: Sendable {
    private var assistantBuffer = ""
    /// Display name of the agent (e.g. "Grok", "Cursor") used as the permission
    /// prompt header. Defaults to a generic label so tests/util callers needn't
    /// supply one.
    private let agentDisplayName: String

    public init(agentDisplayName: String = "Agent") {
        self.agentDisplayName = agentDisplayName
    }

    public mutating func apply(_ event: HarnessEvent) -> [AcpStoreOp] {
        switch event {
        case .agentMessageDelta(let text):
            // Codex app-server emits a final *complete* agentMessage (mapped to
            // a delta) after streaming deltas that already built the same text;
            // appending it would double the bubble. Skip a chunk that exactly
            // equals everything accumulated so far — real token deltas never do.
            if !assistantBuffer.isEmpty, text == assistantBuffer {
                return [.setTurnState(.streaming)]
            }
            assistantBuffer += text
            return [.setTurnState(.streaming)]

        case .agentThoughtDelta:
            // Reasoning is not surfaced as a chat row in v1.
            return [.setTurnState(.streaming)]

        case .plan(let entries):
            return [.setPlanText(Self.formatPlan(entries))]

        case .toolCall(let tc):
            return [.appendToolCall(title: tc.title ?? tc.kind ?? "tool", status: tc.status.rawValue)]

        case .diff:
            // Diffs render through the existing git-diff pane in v1.
            return []

        case .permissionRequest(let req):
            return [.setPermissionPrompt(Self.permissionPrompt(for: req, header: agentDisplayName))]

        case .usage:
            return []

        case .contextBreakdown:
            return []

        case .modeChanged:
            return []

        case .turnEnded(let reason):
            var ops: [AcpStoreOp] = []
            let text = assistantBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                ops.append(.appendAssistantText(text))
                assistantBuffer = ""
            }
            ops.append(.setPermissionPrompt(nil))
            ops.append(.setTurnState(reason == .cancelled ? .interrupted : .completed))
            return ops

        case .error(_, let message):
            return [.appendErrorText(message), .setTurnState(.interrupted)]

        case .unknownUpdate:
            return []
        }
    }

    /// Any buffered assistant text not yet flushed (e.g. if the child died
    /// before a turnEnded). The bridge flushes this on teardown.
    public mutating func drainAssistantBuffer() -> String? {
        let text = assistantBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        assistantBuffer = ""
        return text.isEmpty ? nil : text
    }

    // MARK: helpers (shared with the bridge so prompt ids line up)

    public static func formatPlan(_ entries: [ACPPlanEntry]) -> String {
        entries.map { entry in
            let mark: String
            switch entry.status {
            case "completed": mark = "[x]"
            case "in_progress": mark = "[~]"
            default: mark = "[ ]"
            }
            return "\(mark) \(entry.content)"
        }.joined(separator: "\n")
    }

    /// Deterministic prompt id derived from the ACP request id, so the daemon's
    /// `/permission-respond` route can map a chosen optionId back to the RPC id.
    public static func permissionPromptId(for rpcId: RpcId) -> String {
        switch rpcId {
        case .number(let n): return "acp-perm-n\(n)"
        case .string(let s): return "acp-perm-s\(s)"
        }
    }

    public static func permissionPrompt(for req: HarnessPermissionRequest, header: String = "Agent") -> PendingPermissionPrompt {
        let options = req.options.map { opt -> PermissionOption in
            let kind = opt.kind ?? ""
            return PermissionOption(
                id: opt.optionId,
                label: opt.name ?? opt.optionId,
                description: nil,
                isRecommended: kind.hasPrefix("allow"),
                isDestructive: kind.hasPrefix("reject")
            )
        }
        return PendingPermissionPrompt(
            id: permissionPromptId(for: req.requestId),
            title: req.title ?? "The agent is requesting permission",
            detail: nil,
            header: header,
            options: options
        )
    }
}
