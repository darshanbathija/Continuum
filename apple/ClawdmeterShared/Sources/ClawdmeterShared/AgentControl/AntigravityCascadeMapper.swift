import Foundation

/// A decoded Antigravity "Cascade" trajectory step, normalized off the gRPC
/// `LanguageServerService` protobufs into a provider-neutral value the daemon
/// can map onto `HarnessEvent`. Keeping this a plain Swift model (no protobuf,
/// no gRPC) means the mapper is unit-testable + Watch-safe; the Mac-only gRPC
/// client decodes `StreamCascadeReactiveUpdates` payloads into these.
///
/// Field provenance: `tools/extract-antigravity-proto.sh` —
/// `docs/acp-harness/antigravity-proto/v1internal-fields.txt`. The Cascade step
/// payload is a oneof; these cases mirror the ones we surface (assistant text,
/// tool_call, file diffs, permission/approval, completion).
public enum AntigravityCascadeStep: Sendable, Equatable {
    /// Assistant message / summary delta.
    case assistantText(String)
    /// Model reasoning delta (rendered as a thought, not a chat row in v1).
    case thinking(String)
    /// A tool call (`tool_call` / `tool_call_id` / `tool_call_json`).
    case toolCall(id: String, title: String?, kind: String?, status: HarnessToolCall.Status)
    /// A proposed file edit (`file_diffs` → `unified_diff`). `unifiedDiff` is the
    /// new-content patch; the diff pane derives the old side.
    case fileDiff(path: String, unifiedDiff: String?)
    /// The agent is requesting approval (`is_permission` / `approval_type` /
    /// `proposal_tool_calls`). `permissionId` is the Cascade-side id we answer
    /// the approval RPC with.
    case permission(permissionId: String, title: String?, proposalToolCalls: [String])
    /// The turn finished.
    case turnFinished(AntigravityTurnOutcome)
    /// A provider error surfaced mid-turn.
    case error(message: String)
    /// A step kind we don't model yet (preserved for diagnostics/replay).
    case unknown(kind: String)
}

public enum AntigravityTurnOutcome: String, Sendable, Equatable {
    case completed, cancelled, failed
}

/// Folds decoded Cascade steps into provider-neutral `HarnessEvent`s, so an
/// Antigravity turn flows through the SAME `AcpHarnessProjection` → store path
/// the ACP agents use. Mirrors `ACPEventMapper`; deliberately has no gRPC /
/// protobuf dependency.
public struct AntigravityCascadeMapper: Sendable {
    public init() {}

    public func map(_ step: AntigravityCascadeStep, sessionId: String) -> HarnessEvent? {
        switch step {
        case .assistantText(let text):
            return .agentMessageDelta(text)
        case .thinking(let text):
            return .agentThoughtDelta(text)
        case .toolCall(let id, let title, let kind, let status):
            return .toolCall(HarnessToolCall(toolCallId: id, title: title, kind: kind, status: status))
        case .fileDiff(let path, let unifiedDiff):
            return .diff(HarnessDiff(path: path, oldText: nil, newText: unifiedDiff))
        case .permission(let permissionId, let title, let proposals):
            // Antigravity approval is binary (approve / reject the proposed
            // steps); synthesize the two options the permission card renders.
            // `requestId` carries the Cascade permission id so the driver can
            // answer the approval RPC. proposalToolCalls enriches the title.
            let detail = proposals.isEmpty ? "" : " (\(proposals.count) proposed action\(proposals.count == 1 ? "" : "s"))"
            let options = [
                ACPPermissionOption(optionId: "allow_once", name: "Approve", kind: "allow_once"),
                ACPPermissionOption(optionId: "reject_once", name: "Reject", kind: "reject_once"),
            ]
            return .permissionRequest(HarnessPermissionRequest(
                requestId: .string(permissionId),
                sessionId: sessionId,
                title: (title ?? "Antigravity is requesting approval") + detail,
                options: options
            ))
        case .turnFinished(let outcome):
            switch outcome {
            case .completed: return .turnEnded(.endTurn)
            case .cancelled: return .turnEnded(.cancelled)
            // Abnormal end: the preceding `.error` step drives the message;
            // `.unknown` stop reason keeps the projection from claiming a clean
            // completion without misreporting it as a user cancel.
            case .failed: return .turnEnded(.unknown)
            }
        case .error(let message):
            return .error(code: "antigravity", message: message)
        case .unknown(let kind):
            return .unknownUpdate(kind: kind)
        }
    }

    public func map(steps: [AntigravityCascadeStep], sessionId: String) -> [HarnessEvent] {
        steps.compactMap { map($0, sessionId: sessionId) }
    }
}
