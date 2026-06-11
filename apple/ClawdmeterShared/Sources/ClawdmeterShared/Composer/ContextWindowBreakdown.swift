import Foundation

/// Per-category composition of the model's context window. Matches the
/// Cursor-style breakdown surfaced in the Code tab context-usage popover.
public struct ContextWindowBreakdown: Codable, Sendable, Equatable {
    public enum CategoryID: String, Codable, Sendable, CaseIterable {
        case freeSpace = "free-space"
        case mcpTools = "mcp-tools"
        case messages = "messages"
        case memoryFiles = "memory-files"
        case systemTools = "system-tools"
        case skills = "skills"
        case systemPrompt = "system-prompt"
        case customAgents = "custom-agents"

        public var label: String {
            switch self {
            case .freeSpace: return "Free space"
            case .mcpTools: return "MCP tools"
            case .messages: return "Messages"
            case .memoryFiles: return "Memory files"
            case .systemTools: return "System tools"
            case .skills: return "Skills"
            case .systemPrompt: return "System prompt"
            case .customAgents: return "Custom agents"
            }
        }

        /// Stable Code-tab accessibility suffix (`code.context-usage.row.*`).
        public var accessibilitySuffix: String { rawValue }
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: CategoryID
        public var label: String
        public var tokens: Int
        /// Percent of the model's context limit (0…100).
        public var percent: Double

        public init(id: CategoryID, label: String? = nil, tokens: Int, limitTokens: Int) {
            self.id = id
            self.label = label ?? id.label
            self.tokens = max(0, tokens)
            if limitTokens > 0 {
                self.percent = min(100, max(0, (Double(self.tokens) / Double(limitTokens)) * 100))
            } else {
                self.percent = 0
            }
        }
    }

    public var usedTokens: Int
    public var limitTokens: Int
    public var entries: [Entry]

    public init(usedTokens: Int, limitTokens: Int, entries: [Entry]) {
        self.usedTokens = max(0, usedTokens)
        self.limitTokens = max(0, limitTokens)
        self.entries = entries
    }

    public var fractionUsed: Double {
        guard limitTokens > 0 else { return 0 }
        return min(1, max(0, Double(usedTokens) / Double(limitTokens)))
    }

    public var headerText: String {
        "\(Self.formatTokens(usedTokens)) / \(Self.formatTokens(limitTokens))"
    }

    /// Rows for the popover, sorted like Cursor: free space first, then
    /// descending token share among the consumed categories.
    public var displayEntries: [Entry] {
        let free = entries.first { $0.id == .freeSpace }
        let consumed = entries
            .filter { $0.id != .freeSpace && $0.tokens > 0 }
            .sorted {
                if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                return $0.id.label < $1.id.label
            }
        if let free { return [free] + consumed }
        return consumed
    }

    public static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

    public static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

// MARK: - Parsing + estimation

public enum ContextWindowBreakdownParser {
    /// Decode an ACP `session/update` whose `sessionUpdate` is
    /// `context_window_update`. Accepts snake_case and camelCase keys.
    public static func fromACPUpdate(_ raw: ACPJSONValue) -> ContextWindowBreakdown? {
        let root = raw["contextWindow"] ?? raw["context_window"] ?? raw
        guard let limit = intField(root, ["limitTokens", "limit_tokens", "contextWindowTokens", "context_window_tokens"]),
              limit > 0 else {
            return nil
        }
        let used = intField(root, ["usedTokens", "used_tokens", "contextTokensUsed", "context_tokens_used"]) ?? 0

        var tokenByCategory: [ContextWindowBreakdown.CategoryID: Int] = [:]
        if let breakdown = root["breakdown"] ?? root["categories"] ?? root["composition"] {
            tokenByCategory = parseCategoryTokens(breakdown)
        }

        return build(usedTokens: used, limitTokens: limit, tokenByCategory: tokenByCategory)
    }

    /// Best-effort breakdown when the provider did not publish category
    /// token counts. Uses transcript size + fixed overheads so the Code tab
    /// still renders a useful composition instead of session cost.
    public static func estimate(
        usedTokens: Int,
        limitTokens: Int,
        messages: [ChatMessage],
        inheritedContextBytes: Int = 0,
        loadedSkillCount: Int = 0,
        mcpServerCount: Int = 0
    ) -> ContextWindowBreakdown? {
        guard limitTokens > 0 else { return nil }
        let used = min(max(0, usedTokens), limitTokens)

        var messageTokens = min(used, estimateTranscriptTokens(messages))
        var memoryTokens = min(used, inheritedContextBytes / 4)
        var skillTokens = min(used, loadedSkillCount * 600)
        var mcpTokens = min(used, mcpServerCount * 8_000)
        var systemPromptTokens = min(used, 2_000)
        var systemToolTokens = min(used, 4_000)
        let customAgentTokens = 0

        var consumed = messageTokens + memoryTokens + skillTokens + mcpTokens
            + systemPromptTokens + systemToolTokens + customAgentTokens
        if consumed > used {
            let scale = used > 0 ? Double(used) / Double(consumed) : 0
            messageTokens = Int(Double(messageTokens) * scale)
            memoryTokens = Int(Double(memoryTokens) * scale)
            skillTokens = Int(Double(skillTokens) * scale)
            mcpTokens = Int(Double(mcpTokens) * scale)
            systemPromptTokens = Int(Double(systemPromptTokens) * scale)
            systemToolTokens = Int(Double(systemToolTokens) * scale)
            consumed = used
        } else if consumed < used {
            // Attribute the remainder to MCP/tooling overhead — common when
            // the agent loads many tool schemas but we lack a live breakdown.
            mcpTokens = min(used, mcpTokens + (used - consumed))
            consumed = used
        }

        return estimate(
            usedTokens: used,
            limitTokens: limitTokens,
            tokenByCategory: [
                .messages: messageTokens,
                .memoryFiles: memoryTokens,
                .skills: skillTokens,
                .mcpTools: mcpTokens,
                .systemPrompt: systemPromptTokens,
                .systemTools: systemToolTokens,
                .customAgents: customAgentTokens,
            ]
        )
    }

    private static func estimate(
        usedTokens: Int,
        limitTokens: Int,
        tokenByCategory: [ContextWindowBreakdown.CategoryID: Int]
    ) -> ContextWindowBreakdown {
        build(usedTokens: usedTokens, limitTokens: limitTokens, tokenByCategory: tokenByCategory)
    }

    private static func build(
        usedTokens: Int,
        limitTokens: Int,
        tokenByCategory: [ContextWindowBreakdown.CategoryID: Int]
    ) -> ContextWindowBreakdown {
        let used = min(max(0, usedTokens), limitTokens)
        let freeTokens = max(0, limitTokens - used)

        var entries: [ContextWindowBreakdown.Entry] = [
            .init(id: .freeSpace, tokens: freeTokens, limitTokens: limitTokens),
        ]
        for id in ContextWindowBreakdown.CategoryID.allCases where id != .freeSpace {
            let tokens = max(0, tokenByCategory[id] ?? 0)
            if tokens > 0 || id == .customAgents {
                entries.append(.init(id: id, tokens: tokens, limitTokens: limitTokens))
            }
        }
        return ContextWindowBreakdown(usedTokens: used, limitTokens: limitTokens, entries: entries)
    }

    private static func parseCategoryTokens(_ value: ACPJSONValue) -> [ContextWindowBreakdown.CategoryID: Int] {
        var out: [ContextWindowBreakdown.CategoryID: Int] = [:]
        switch value {
        case .object(let object):
            for (key, rawValue) in object {
                guard let id = categoryID(forWireKey: key) else { continue }
                out[id] = intValue(rawValue)
            }
        case .array(let array):
            for element in array {
                guard case .object(let object) = element else { continue }
                let key = object["id"]?.stringValue
                    ?? object["category"]?.stringValue
                    ?? object["name"]?.stringValue
                guard let key, let id = categoryID(forWireKey: key) else { continue }
                let tokens = intField(.object(object), ["tokens", "tokenCount", "token_count", "value"]) ?? 0
                out[id] = tokens
            }
        default:
            break
        }
        return out
    }

    private static func categoryID(forWireKey key: String) -> ContextWindowBreakdown.CategoryID? {
        let normalized = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "free_space", "freespace", "free": return .freeSpace
        case "mcp_tools", "mcptools", "mcp": return .mcpTools
        case "messages", "message", "conversation", "chat": return .messages
        case "memory_files", "memoryfiles", "memory", "memories": return .memoryFiles
        case "system_tools", "systemtools", "tools": return .systemTools
        case "skills", "skill": return .skills
        case "system_prompt", "systemprompt", "prompt": return .systemPrompt
        case "custom_agents", "customagents", "agents", "subagents": return .customAgents
        default:
            return ContextWindowBreakdown.CategoryID(rawValue: key)
        }
    }

    private static func estimateTranscriptTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(into: 0) { partial, message in
            let body = [message.title, message.detail, message.body]
                .compactMap { $0 }
                .joined(separator: "\n")
            partial += max(1, body.utf8.count / 4)
        }
    }

    private static func intField(_ object: ACPJSONValue, _ keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(object[key]) { return value }
        }
        return nil
    }

    private static func intValue(_ value: ACPJSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let v): return Int(v)
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
}
