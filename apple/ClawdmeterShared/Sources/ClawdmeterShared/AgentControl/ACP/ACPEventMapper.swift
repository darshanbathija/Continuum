import Foundation

/// Pure mapping from ACP `session/update` notifications to `HarnessEvent`s.
/// Stateless and `Sendable`; the only state (tool-call titles seen on `start`,
/// reused on `update`) is held by the caller and passed back in. Mirrors the
/// reference `AcpRuntimeModel.ts` `parseSessionUpdateEvent` + tool-call merge.
public enum ACPEventMapper {

    /// Map one `session/update`. `toolTitles` carries forward tool titles from a
    /// prior `tool_call` so a later `tool_call_update` (which often omits the
    /// title) can still render it. Caller owns the dictionary across a turn.
    public static func map(
        _ note: ACPSessionNotification,
        toolTitles: inout [String: String]
    ) -> [HarnessEvent] {
        let u = note.update
        let raw = u.raw
        switch u.kind {
        case .agentMessageChunk:
            if let text = chunkText(raw) { return [.agentMessageDelta(text)] }
            return []

        case .agentThoughtChunk:
            if let text = chunkText(raw) { return [.agentThoughtDelta(text)] }
            return []

        case .userMessageChunk:
            return [] // echoes of our own prompt; the daemon already has it

        case .plan:
            let entries = (raw["plan"]?["entries"]?.arrayValue ?? raw["entries"]?.arrayValue ?? [])
                .compactMap { planEntry($0) }
            return entries.isEmpty ? [] : [.plan(entries)]

        case .toolCall, .toolCallUpdate:
            guard let tc = raw["toolCall"] ?? raw["tool_call"] else { return [] }
            let id = tc["toolCallId"]?.stringValue ?? tc["id"]?.stringValue ?? ""
            if let t = tc["title"]?.stringValue, !id.isEmpty { toolTitles[id] = t }
            let title = tc["title"]?.stringValue ?? toolTitles[id]
            let statusRaw = tc["status"]?.stringValue ?? "pending"
            let status = HarnessToolCall.Status(rawValue: statusRaw) ?? .unknown
            var events: [HarnessEvent] = [.toolCall(
                HarnessToolCall(toolCallId: id, title: title, kind: tc["kind"]?.stringValue, status: status)
            )]
            // tool calls can carry a diff in their content blocks
            if let content = tc["content"]?.arrayValue {
                for block in content {
                    if let d = diff(fromContentBlock: block) { events.append(.diff(d)) }
                }
            }
            return events

        case .currentModeUpdate:
            if let mode = raw["currentModeId"]?.stringValue ?? raw["modeId"]?.stringValue {
                return [.modeChanged(mode)]
            }
            return []

        case .usage:
            let usageObj = raw["usage"] ?? raw
            let usage = HarnessUsage(
                inputTokens: usageObj["inputTokens"]?.intValue,
                outputTokens: usageObj["outputTokens"]?.intValue,
                totalTokens: usageObj["totalTokens"]?.intValue
            )
            return [.usage(usage)]

        case .availableCommandsUpdate:
            return [] // surfaced via initialize; not a turn event

        case .unknown:
            return [.unknownUpdate(kind: u.rawKind)]
        }
    }

    // MARK: helpers

    /// Extract text from an `agent_message_chunk` / `agent_thought_chunk`.
    /// ACP carries it as `content: {type:"text", text:"..."}` or `text:"..."`.
    private static func chunkText(_ raw: ACPJSONValue) -> String? {
        if let c = raw["content"] {
            if let t = c["text"]?.stringValue { return t }
            if let s = c.stringValue { return s }
        }
        if let t = raw["text"]?.stringValue { return t }
        return nil
    }

    private static func planEntry(_ v: ACPJSONValue) -> ACPPlanEntry? {
        guard let content = v["content"]?.stringValue ?? v["text"]?.stringValue else { return nil }
        return ACPPlanEntry(
            content: content,
            status: v["status"]?.stringValue,
            priority: v["priority"]?.stringValue
        )
    }

    private static func diff(fromContentBlock block: ACPJSONValue) -> HarnessDiff? {
        // ACP diff content: {type:"diff", path, oldText?, newText}
        guard block["type"]?.stringValue == "diff" else { return nil }
        guard let path = block["path"]?.stringValue else { return nil }
        return HarnessDiff(
            path: path,
            oldText: block["oldText"]?.stringValue,
            newText: block["newText"]?.stringValue
        )
    }
}
