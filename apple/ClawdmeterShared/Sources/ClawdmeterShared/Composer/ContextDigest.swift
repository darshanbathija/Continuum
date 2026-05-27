import Foundation

/// Markdown renderer for one-shot inherited context between sibling code
/// sessions. The output is attached to the first prompt as an `@file`
/// reference, so keep it deterministic, bounded, and readable.
public enum ContextDigest {
    public struct Options: Sendable, Hashable {
        public let toolResultByteLimit: Int
        public let maxDigestBytes: Int

        public init(
            toolResultByteLimit: Int = 2_048,
            maxDigestBytes: Int = 256 * 1_024
        ) {
            self.toolResultByteLimit = toolResultByteLimit
            self.maxDigestBytes = maxDigestBytes
        }

        public static let `default` = Options()
    }

    public static func render(
        snapshot: WireChatSnapshot,
        sourceSession: AgentSession,
        options: Options = .default
    ) -> String {
        var sections: [String] = []
        sections.append(header(snapshot: snapshot, sourceSession: sourceSession, options: options))

        let conversation = renderConversation(snapshot.items, options: options)
        if !conversation.isEmpty {
            sections.append("## Conversation\n\n\(conversation)")
        }

        let plan = renderPlan(snapshot: snapshot, sourceSession: sourceSession)
        if !plan.isEmpty {
            sections.append("## Plan\n\n\(plan)")
        }

        let sources = renderSources(snapshot.sourceEntries)
        if !sources.isEmpty {
            sections.append("## Sources\n\n\(sources)")
        }

        let artifacts = renderArtifacts(snapshot.artifactEntries)
        if !artifacts.isEmpty {
            sections.append("## Artifacts\n\n\(artifacts)")
        }

        let rendered = sections.joined(separator: "\n\n") + "\n"
        return cap(rendered, to: options.maxDigestBytes)
    }

    private static func header(
        snapshot: WireChatSnapshot,
        sourceSession: AgentSession,
        options: Options
    ) -> String {
        var metadata: [String] = []
        metadata.append("Repo: \(sourceSession.repoKey ?? sourceSession.repoDisplayName)")
        metadata.append("Agent: \(sourceSession.agent.rawValue)")
        if let model = sourceSession.model, !model.isEmpty { metadata.append("Model: \(model)") }
        metadata.append("Mode: \(sourceSession.mode.rawValue)")
        metadata.append("Workspace: \(WorkspaceKey.workspacePath(for: sourceSession))")
        if let at = snapshot.lastEventAt ?? Optional(sourceSession.lastEventAt) {
            metadata.append("Last event: \(ISO8601DateFormatter().string(from: at))")
        }
        metadata.append("Tool results clamped to \(options.toolResultByteLimit) bytes each")
        metadata.append("Digest capped at \(options.maxDigestBytes) bytes")

        return """
        # Inherited context - \(sourceSession.displayLabel)

        > \(metadata.joined(separator: " | "))
        """
    }

    private static func renderConversation(_ items: [ChatItem], options: Options) -> String {
        items.flatMap { item -> [String] in
            switch item {
            case .message(let message):
                return [renderMessage(message, options: options)]
            case .toolRun(_, let pairs):
                return pairs.flatMap { pair in
                    var out = [renderMessage(pair.call, options: options)]
                    if let result = pair.result {
                        out.append(renderMessage(result, options: options))
                    }
                    return out
                }
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func renderMessage(_ message: ChatMessage, options: Options) -> String {
        let title: String
        switch message.kind {
        case .userText: title = "You"
        case .assistantText: title = "Assistant"
        case .toolCall: title = "Tool: \(message.title)"
        case .toolResult: title = "Tool result: \(message.title)"
        case .meta: title = "Meta"
        }

        let rawBody = [message.detail, message.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let body: String
        if message.kind == .toolResult {
            body = clamp(rawBody, to: options.toolResultByteLimit)
        } else {
            body = rawBody
        }
        guard !body.isEmpty else { return "" }
        return "### \(title)\n\n\(body)"
    }

    private static func renderPlan(snapshot: WireChatSnapshot, sourceSession: AgentSession) -> String {
        var lines: [String] = []
        let approvedOrPlan = sourceSession.approvedPlanText ?? sourceSession.planText
        if let plan = approvedOrPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            lines.append(plan)
        }
        for step in snapshot.planSteps {
            let marker = step.isComplete ? "x" : " "
            lines.append("- [\(marker)] \(step.text)")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderSources(_ entries: [SourceEntry]) -> String {
        entries
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.label < rhs.label
            }
            .map { "- \($0.label) (\($0.kind.rawValue), \($0.count)x): \($0.payload)" }
            .joined(separator: "\n")
    }

    private static func renderArtifacts(_ entries: [ArtifactEntry]) -> String {
        entries
            .sorted { $0.filename < $1.filename }
            .map { "- \($0.filename): \($0.path)" }
            .joined(separator: "\n")
    }

    private static func clamp(_ string: String, to maxBytes: Int) -> String {
        guard maxBytes > 0, string.utf8.count > maxBytes else { return string }
        var bytes = Array(string.utf8.prefix(maxBytes))
        while String(bytes: bytes, encoding: .utf8) == nil, !bytes.isEmpty {
            bytes.removeLast()
        }
        let clipped = String(bytes: bytes, encoding: .utf8) ?? ""
        let omitted = string.utf8.count - bytes.count
        return "\(clipped)\n\n... \(omitted) bytes elided ..."
    }

    private static func cap(_ string: String, to maxBytes: Int) -> String {
        guard maxBytes > 0, string.utf8.count > maxBytes else { return string }
        let suffix = "\n\n... earlier inherited context elided to keep the digest under \(maxBytes) bytes ...\n"
        let budget = max(0, maxBytes - suffix.utf8.count)
        var bytes = Array(string.utf8.suffix(budget))
        while String(bytes: bytes, encoding: .utf8) == nil, !bytes.isEmpty {
            bytes.removeFirst()
        }
        return suffix + (String(bytes: bytes, encoding: .utf8) ?? "")
    }
}
