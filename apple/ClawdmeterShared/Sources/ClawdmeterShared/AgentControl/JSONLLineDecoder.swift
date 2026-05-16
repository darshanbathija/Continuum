import Foundation

/// Pure helpers for decoding Claude Code / Codex JSONL lines.
///
/// Two consumers today:
/// 1. `RepoIndex.readFirstUserPrompt` — pulls the first user prompt out of
///    a JSONL to label sidebar rows ("fix auth bug" instead of "Claude session").
/// 2. `ChatItemBuilder` (perf overhaul T1) — converts parsed lines into
///    typed `ChatMessage` values for the chat thread.
///
/// Both used to walk the same JSONL shape with subtly different code
/// paths. This module is the single source of truth for:
/// - `<system-reminder>` tag stripping (Claude Code wraps system context
///   in these — never user intent)
/// - `<command-name>` unwrapping (slash-command sessions emit
///   `<command-name>foo</command-name><command-args>...</command-args>`)
/// - 80-char truncation with word-boundary preservation
///
/// All functions are pure value transforms with no I/O. Tests live in
/// `ClawdmeterSharedTests/AgentControl/JSONLLineDecoderTests.swift`.
public enum JSONLLineDecoder {

    /// Normalize a raw user-message body for display. Strips system-only
    /// content (system reminders, slash-command wrappers), collapses
    /// whitespace, trims to one line, caps at `maxLength` characters with
    /// a `…` suffix if needed. Returns `nil` if nothing user-visible
    /// remains after stripping.
    public static func cleanPrompt(_ raw: String, maxLength: Int = 80) -> String? {
        var text = raw
        // Strip <system-reminder>...</system-reminder> blocks Claude
        // Code injects with project context. They look user-typed in the
        // JSONL but the user never wrote them.
        while let openRange = text.range(of: "<system-reminder>") {
            let afterOpen = openRange.upperBound
            if let closeRange = text.range(of: "</system-reminder>",
                                            range: afterOpen..<text.endIndex) {
                text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                text.removeSubrange(openRange.lowerBound..<text.endIndex)
            }
        }
        // <command-name> unwrap (keep the inner text — that IS the
        // user-intended summary for slash-command invocations). Other
        // command-* tags are stripped wholesale.
        for tag in ["command-name", "command-args", "command-message",
                    "local-command-stdout"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            while let openRange = text.range(of: open) {
                if let closeRange = text.range(of: close,
                                                range: openRange.upperBound..<text.endIndex) {
                    if tag == "command-name" {
                        let inner = text[openRange.upperBound..<closeRange.lowerBound]
                        text = String(inner)
                        break
                    } else {
                        text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                    }
                } else {
                    text.removeSubrange(openRange.lowerBound..<text.endIndex)
                    break
                }
            }
        }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxLength { return collapsed }
        let head = collapsed.prefix(maxLength)
        if let lastSpace = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: lastSpace) > maxLength / 2 {
            return String(collapsed[..<lastSpace]) + "…"
        }
        return String(head) + "…"
    }

    /// Extract the FIRST user-typed prompt from a JSON dict matching one
    /// Claude Code JSONL line. Returns `nil` if the line:
    /// - isn't `type: user`
    /// - is a `tool_result`-only user message (continuation, not prompt)
    /// - has empty content after cleaning
    public static func decodeUserPrompt(from json: [String: Any]) -> String? {
        guard (json["type"] as? String) == "user" else { return nil }
        guard let message = json["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String {
            return cleanPrompt(text)
        }
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                let blockType = block["type"] as? String
                if blockType == "text", let text = block["text"] as? String,
                   let cleaned = cleanPrompt(text) {
                    return cleaned
                }
                // tool_result blocks aren't user prompts — skip.
            }
        }
        return nil
    }

    /// Decode bytes (one JSONL line) into a `[String: Any]` dict, returning
    /// nil if the line isn't valid JSON. Centralized so callers don't all
    /// have to repeat the `try? JSONSerialization.jsonObject(...) as? [String: Any]`
    /// boilerplate.
    public static func decodeJSON(line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
