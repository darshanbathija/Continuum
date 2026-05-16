import Foundation

/// Pure value transforms for Codex JSONL session rollouts. Mirrors the
/// Claude-side decoders in shape (and lives in Shared so it's
/// unit-testable + iOS-readable).
///
/// Codex's wire shape diverges from Claude's flat `user`/`assistant`
/// lines:
///   - Each rollout line is `{type: "response_item", payload: {...}}`
///   - `payload.type` is one of `message` (user/assistant prose),
///     `function_call` (tool invocation), `function_call_output`
///     (tool result), or `reasoning` (private chain-of-thought summary)
///   - Tool names + argument schemas differ from Claude's (e.g.
///     `exec_command.cmd` vs `Bash.command`)
///
/// The Mac-side `SessionChatStore` wraps these helpers and supplies a
/// `stableId` closure so the chat row IDs are deterministic across
/// reparses.
public enum CodexJSONLParser {

    // MARK: - Tool-input summarizers

    /// Compact one-line summary of a Codex tool's arguments for the chat
    /// row headline. Returns `fallback` (or the shortest non-empty
    /// string field) when no Codex-specific pattern matches.
    public static func summarizeInput(
        _ dict: [String: Any],
        for tool: String,
        fallback: String
    ) -> String {
        switch tool {
        case "exec_command", "shell":
            // Codex's exec_command: `cmd` is the shell command;
            // `description` is sometimes set as a one-liner summary.
            if let desc = (dict["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !desc.isEmpty { return desc }
            if let cmd = dict["cmd"] as? String {
                return cmd.replacingOccurrences(of: "\n", with: " ")
            }
        case "spawn_agent":
            if let brief = dict["brief"] as? String { return brief }
            if let task = dict["task"] as? String { return task }
        case "apply_patch":
            // apply_patch takes a unified diff in `input` / `patch` /
            // `diff`; pull whichever's set, peek at the first file.
            for key in ["input", "patch", "diff"] {
                if let s = dict[key] as? String {
                    if let line = s.split(separator: "\n").first(where: {
                        $0.hasPrefix("*** ") || $0.hasPrefix("+++ ") || $0.hasPrefix("--- ")
                    }) {
                        return String(line)
                    }
                    return s.replacingOccurrences(of: "\n", with: " ")
                }
            }
        case "read_file":
            if let path = dict["path"] as? String { return path }
        case "write_file":
            if let path = dict["path"] as? String { return path }
        default:
            break
        }
        // Generic fallback: shortest non-empty string field, else the raw
        // JSON args.
        let stringFields = dict.compactMap { (_, v) -> String? in
            if let s = v as? String, !s.isEmpty { return s }
            return nil
        }
        if let pick = stringFields.min(by: { $0.count < $1.count }) {
            return pick.replacingOccurrences(of: "\n", with: " ")
        }
        return fallback.replacingOccurrences(of: "\n", with: " ")
    }

    /// Verbose detail shown when the user expands a Codex tool row.
    /// Returns nil for tools whose summary already carries the full
    /// detail (e.g. `read_file`, `write_file` — the path is the detail).
    public static func expandedDetail(
        _ dict: [String: Any],
        for tool: String
    ) -> String? {
        switch tool {
        case "exec_command", "shell":
            return dict["cmd"] as? String
        case "spawn_agent":
            return dict["brief"] as? String ?? dict["task"] as? String
        case "apply_patch":
            return (dict["input"] as? String)
                ?? (dict["patch"] as? String)
                ?? (dict["diff"] as? String)
        default:
            return nil
        }
    }

    // MARK: - Response-item decoder

    /// Decode a single `response_item` JSON object into a list of
    /// `ChatMessage`s. Returns an empty array when the line should be
    /// skipped (developer-role wrappers, environment-context user turns,
    /// unknown payload types).
    ///
    /// `idForSuffix` produces a stable ID from a suffix — keeps the
    /// decoder pure while letting callers anchor IDs on whatever
    /// per-line cursor they use (uuid, timestamp, offset).
    public static func decodeResponseItem(
        json: [String: Any],
        at: Date,
        idForSuffix: (_ suffix: String) -> String
    ) -> [ChatMessage] {
        guard let payload = json["payload"] as? [String: Any] else { return [] }
        let payloadType = payload["type"] as? String ?? ""

        switch payloadType {
        case "message":
            return decodeMessage(payload: payload, at: at, baseId: idForSuffix("codex-message"))
        case "function_call":
            return decodeFunctionCall(payload: payload, at: at, baseId: idForSuffix("codex-function_call"))
        case "function_call_output":
            return decodeFunctionCallOutput(payload: payload, at: at, baseId: idForSuffix("codex-function_call_output"))
        case "reasoning":
            return decodeReasoning(payload: payload, at: at, baseId: idForSuffix("codex-reasoning"))
        default:
            return []
        }
    }

    private static func decodeMessage(payload: [String: Any], at: Date, baseId: String) -> [ChatMessage] {
        let role = payload["role"] as? String ?? ""
        guard role == "user" || role == "assistant" else { return [] }
        // Flatten content blocks into a single string. Codex blocks use
        // `type: "input_text"` (user) or `output_text` (assistant) with
        // the prose in `text`. Older rollouts also include a top-level
        // `content` string; handle both.
        var bodyParts: [String] = []
        if let s = payload["content"] as? String {
            bodyParts.append(s)
        } else if let blocks = payload["content"] as? [[String: Any]] {
            for block in blocks {
                if let s = block["text"] as? String, !s.isEmpty {
                    bodyParts.append(s)
                }
            }
        }
        let body = bodyParts.joined(separator: "\n")
        // Drop Codex's auto-injected environment-context user turns —
        // they clutter the chat with state the user already knows.
        if role == "user", body.hasPrefix("<environment_context>") {
            return []
        }
        guard !body.isEmpty else { return [] }
        return [ChatMessage(
            id: baseId,
            kind: role == "user" ? .userText : .assistantText,
            title: role == "user" ? "You" : "Codex",
            body: body,
            at: at
        )]
    }

    private static func decodeFunctionCall(payload: [String: Any], at: Date, baseId: String) -> [ChatMessage] {
        let name = (payload["name"] as? String) ?? "tool"
        let argsString = (payload["arguments"] as? String) ?? ""
        // Try to parse the args JSON so we can summarize the same way
        // we do for Claude. Fall back to the raw string.
        var inputDict: [String: Any]? = nil
        if let data = argsString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            inputDict = parsed
        }
        let summary: String
        let detail: String?
        if let dict = inputDict {
            summary = summarizeInput(dict, for: name, fallback: argsString)
            detail = expandedDetail(dict, for: name) ?? argsString
        } else {
            // Args weren't JSON — show the raw string truncated.
            summary = argsString.replacingOccurrences(of: "\n", with: " ")
            detail = argsString
        }
        // Codex emits a `call_id` field at the payload level for pairing
        // with the matching function_call_output.
        let callId = (payload["call_id"] as? String) ?? baseId
        return [ChatMessage(
            id: "call:\(callId)",
            kind: .toolCall,
            title: name,
            body: summary,
            detail: detail,
            at: at
        )]
    }

    private static func decodeFunctionCallOutput(payload: [String: Any], at: Date, baseId: String) -> [ChatMessage] {
        let output = (payload["output"] as? String) ?? ""
        let callId = (payload["call_id"] as? String) ?? baseId
        // Some Codex builds wrap the output in a status envelope —
        // `{"output": "...", "metadata": {...}}`. Unwrap if present.
        var body = output
        if let data = output.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = obj["output"] as? String {
            body = inner
        }
        // Cap chat-row body at 4KB; users expand the disclosure for the
        // full thing.
        if body.count > 4096 {
            body = String(body.prefix(4096)) + "\n…[truncated]"
        }
        guard !body.isEmpty else { return [] }
        return [ChatMessage(
            id: "result:\(callId)",
            kind: .toolResult,
            title: "Tool result",
            body: body,
            at: at
        )]
    }

    private static func decodeReasoning(payload: [String: Any], at: Date, baseId: String) -> [ChatMessage] {
        var summaryText = ""
        if let summary = payload["summary"] as? [[String: Any]] {
            for block in summary {
                if let s = block["text"] as? String, !s.isEmpty {
                    summaryText += (summaryText.isEmpty ? "" : "\n") + s
                }
            }
        } else if let s = payload["summary"] as? String {
            summaryText = s
        }
        guard !summaryText.isEmpty else { return [] }
        return [ChatMessage(
            id: baseId,
            kind: .meta,
            title: "Thinking",
            body: summaryText,
            at: at
        )]
    }
}
