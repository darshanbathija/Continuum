import Foundation

/// Provider-agnostic harness events — the control-plane signals the daemon needs
/// to drive UI (plan/diff/tool-call/permission/usage) plus assistant text. This
/// is deliberately independent of `AgentKind`/`ProviderRuntimeEvent` so the ACP
/// core compiles and tests standalone; the daemon seam maps `HarnessEvent` onto
/// the canonical `ProviderRuntimeEvent` spine (that mapping is where the
/// provider-kind enum gets involved).
public enum HarnessEvent: Sendable, Equatable {
    /// Assistant text delta (`agent_message_chunk`).
    case agentMessageDelta(String)
    /// Assistant reasoning/thinking delta (`agent_thought_chunk`).
    case agentThoughtDelta(String)
    /// A plan / step breakdown was produced or updated.
    case plan([ACPPlanEntry])
    /// A file diff the agent proposed.
    case diff(HarnessDiff)
    /// A tool call started/updated/finished.
    case toolCall(HarnessToolCall)
    /// The agent is asking the user for permission. `requestId` is the RPC id we
    /// must answer with `respondToPermission`.
    case permissionRequest(HarnessPermissionRequest)
    /// Token / cost accounting for the turn.
    case usage(HarnessUsage)
    /// The agent's active mode changed (`current_mode_update`).
    case modeChanged(String)
    /// The turn finished. Maps from `session/prompt`'s `stopReason`.
    case turnEnded(ACPStopReason)
    /// A provider error surfaced mid-turn.
    case error(code: String, message: String)
    /// A `session/update` variant we don't model yet (preserved for replay).
    case unknownUpdate(kind: String)
}

public struct HarnessDiff: Sendable, Equatable {
    public var path: String
    public var oldText: String?
    public var newText: String?
    public init(path: String, oldText: String?, newText: String?) {
        self.path = path; self.oldText = oldText; self.newText = newText
    }
}

public struct HarnessToolCall: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case pending, inProgress = "in_progress", completed, failed, unknown
    }
    public var toolCallId: String
    public var title: String?
    public var kind: String?
    public var status: Status
    public init(toolCallId: String, title: String? = nil, kind: String? = nil, status: Status) {
        self.toolCallId = toolCallId; self.title = title; self.kind = kind; self.status = status
    }
}

public struct HarnessPermissionRequest: Sendable, Equatable {
    public var requestId: RpcId
    public var sessionId: String
    public var title: String?
    public var options: [ACPPermissionOption]
    public init(requestId: RpcId, sessionId: String, title: String?, options: [ACPPermissionOption]) {
        self.requestId = requestId; self.sessionId = sessionId; self.title = title; self.options = options
    }
}

public struct HarnessUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.totalTokens = totalTokens
    }
}
