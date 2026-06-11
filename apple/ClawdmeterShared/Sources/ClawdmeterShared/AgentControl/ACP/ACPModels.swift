import Foundation

// Typed ACP wire models — the ~subset the harness drives. Every type decodes
// leniently: unknown enum discriminators fall to a `.unknown` case (with the
// raw value preserved) rather than throwing, so a newer agent that adds a
// `session/update` variant degrades gracefully instead of killing the turn.
// Mirrors ACP v0.11.3. Verified against captured fixtures in
// docs/acp-harness/fixtures/.

// MARK: - initialize

public struct ACPClientCapabilities: Sendable, Codable, Equatable {
    public struct FS: Sendable, Codable, Equatable {
        public var readTextFile: Bool
        public var writeTextFile: Bool
        public init(readTextFile: Bool, writeTextFile: Bool) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
        }
    }
    public var fs: FS
    public var terminal: Bool
    public init(fs: FS, terminal: Bool) { self.fs = fs; self.terminal = terminal }
}

public struct ACPClientInfo: Sendable, Codable, Equatable {
    public var name: String
    public var version: String
    public init(name: String, version: String) { self.name = name; self.version = version }
}

public struct ACPInitializeRequest: Sendable, Codable, Equatable {
    public var protocolVersion: Int
    public var clientCapabilities: ACPClientCapabilities
    public var clientInfo: ACPClientInfo
    public init(protocolVersion: Int = ACP.protocolVersion,
                clientCapabilities: ACPClientCapabilities,
                clientInfo: ACPClientInfo) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
    }
}

public struct ACPAuthMethod: Sendable, Codable, Equatable {
    public var id: String
    public var name: String?
    public var description: String?
    public init(id: String, name: String? = nil, description: String? = nil) {
        self.id = id; self.name = name; self.description = description
    }
}

public struct ACPModelInfo: Sendable, Codable, Equatable {
    public var modelId: String
    public var name: String?
    public var description: String?

    private enum CodingKeys: String, CodingKey { case modelId, name, description }
    public init(modelId: String, name: String? = nil, description: String? = nil) {
        self.modelId = modelId; self.name = name; self.description = description
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept both `modelId` (ACP) and `id` defensively.
        if let m = try c.decodeIfPresent(String.self, forKey: .modelId) {
            modelId = m
        } else {
            modelId = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }
}

public struct ACPInitializeResult: Sendable, Codable, Equatable {
    public var protocolVersion: Int
    public var agentCapabilities: ACPJSONValue?
    public var authMethods: [ACPAuthMethod]

    /// Whether the agent advertised `agentCapabilities.loadSession: true`
    /// (so `session/load` can be used for revive).
    public var supportsLoadSession: Bool {
        agentCapabilities?["loadSession"]?.boolValue ?? false
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, agentCapabilities, authMethods }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        agentCapabilities = try c.decodeIfPresent(ACPJSONValue.self, forKey: .agentCapabilities)
        authMethods = try c.decodeIfPresent([ACPAuthMethod].self, forKey: .authMethods) ?? []
    }
    public init(protocolVersion: Int, agentCapabilities: ACPJSONValue?, authMethods: [ACPAuthMethod]) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.authMethods = authMethods
    }
}

// MARK: - session lifecycle

public struct ACPNewSessionRequest: Sendable, Codable, Equatable {
    public var cwd: String
    public var mcpServers: [ACPJSONValue]?
    public init(cwd: String, mcpServers: [ACPJSONValue]? = nil) {
        self.cwd = cwd; self.mcpServers = mcpServers
    }
}

public struct ACPNewSessionResult: Sendable, Codable, Equatable {
    public var sessionId: String
    private enum CodingKeys: String, CodingKey { case sessionId }
    public init(sessionId: String) { self.sessionId = sessionId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
    }
}

public struct ACPContentBlock: Sendable, Codable, Equatable {
    public var type: String
    public var text: String?
    public init(type: String = "text", text: String?) { self.type = type; self.text = text }
    public static func text(_ s: String) -> ACPContentBlock { ACPContentBlock(type: "text", text: s) }
}

public struct ACPPromptRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var prompt: [ACPContentBlock]
    public init(sessionId: String, prompt: [ACPContentBlock]) {
        self.sessionId = sessionId; self.prompt = prompt
    }
}

/// Terminal stop reason from `session/prompt`'s response.
public enum ACPStopReason: String, Sendable, Codable, Equatable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ACPStopReason(rawValue: raw) ?? .unknown
    }
}

public struct ACPPromptResponse: Sendable, Codable, Equatable {
    public var stopReason: ACPStopReason
    private enum CodingKeys: String, CodingKey { case stopReason }
    public init(stopReason: ACPStopReason) { self.stopReason = stopReason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stopReason = try c.decodeIfPresent(ACPStopReason.self, forKey: .stopReason) ?? .unknown
    }
}

// MARK: - client callbacks: permission

public struct ACPPermissionOption: Sendable, Codable, Equatable {
    public var optionId: String
    public var name: String?
    /// allow_once | allow_always | reject_once | reject_always
    public var kind: String?
    public init(optionId: String, name: String? = nil, kind: String? = nil) {
        self.optionId = optionId; self.name = name; self.kind = kind
    }
}

public struct ACPRequestPermissionRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var options: [ACPPermissionOption]
    public var toolCall: ACPJSONValue?
    private enum CodingKeys: String, CodingKey { case sessionId, options, toolCall }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        options = try c.decodeIfPresent([ACPPermissionOption].self, forKey: .options) ?? []
        toolCall = try c.decodeIfPresent(ACPJSONValue.self, forKey: .toolCall)
    }
}

// MARK: - session/update streaming union

/// One entry of a `plan` update.
public struct ACPPlanEntry: Sendable, Codable, Equatable {
    public var content: String
    public var status: String?
    public var priority: String?
    public init(content: String, status: String? = nil, priority: String? = nil) {
        self.content = content; self.status = status; self.priority = priority
    }
}

/// The streamed `session/update` notification payload. We decode the
/// discriminator (`sessionUpdate`) and keep the full raw object so the mapper
/// can pull whatever fields a given variant carries; unknown variants are
/// preserved, never dropped.
public struct ACPSessionUpdate: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case userMessageChunk = "user_message_chunk"
        case agentMessageChunk = "agent_message_chunk"
        case agentThoughtChunk = "agent_thought_chunk"
        case toolCall = "tool_call"
        case toolCallUpdate = "tool_call_update"
        case plan
        case availableCommandsUpdate = "available_commands_update"
        case currentModeUpdate = "current_mode_update"
        case usage = "usage_update"
        case contextWindowUpdate = "context_window_update"
        case unknown
    }
    public var kind: Kind
    public var rawKind: String
    public var raw: ACPJSONValue
}

public struct ACPSessionNotification: Sendable, Equatable, Decodable {
    public var sessionId: String
    public var update: ACPSessionUpdate

    private enum CodingKeys: String, CodingKey { case sessionId, update }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        let raw = try c.decode(ACPJSONValue.self, forKey: .update)
        let rawKind = raw["sessionUpdate"]?.stringValue ?? "unknown"
        update = ACPSessionUpdate(
            kind: ACPSessionUpdate.Kind(rawValue: rawKind) ?? .unknown,
            rawKind: rawKind,
            raw: raw
        )
    }
    public init(sessionId: String, update: ACPSessionUpdate) {
        self.sessionId = sessionId; self.update = update
    }
}
