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

    /// Harness-internal block tags that wrap content the user never
    /// typed: system context Claude Code injects, background-task
    /// completion pings the runtime injects when a tool returns,
    /// slash-command-message wrappers. Stripping these is the
    /// difference between a chat bubble that says "<task-notification>
    /// <task-id>bywgnqlgg</task-id>..." and no bubble at all.
    public static let systemBlockTags: [String] = [
        "system-reminder",
        "task-notification",
        "local-command-stdout",
        "command-message",
        "command-args",
    ]

    /// Strip harness-injected `<system-*>` and `<task-*>` blocks from a
    /// user-message body. Preserves whitespace + line breaks in the
    /// surviving text so the chat bubble renders the way the user
    /// actually typed. Returns nil if NOTHING user-visible remains
    /// (e.g., the entire body was a `<task-notification>` and the
    /// chat UI should suppress the bubble entirely).
    public static func stripSystemContent(_ raw: String) -> String? {
        var text = raw
        for tag in systemBlockTags {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            while let openRange = text.range(of: open) {
                if let closeRange = text.range(of: close,
                                                range: openRange.upperBound..<text.endIndex) {
                    text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    // Unterminated wrapper — drop to end of body.
                    text.removeSubrange(openRange.lowerBound..<text.endIndex)
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Normalize a raw user-message body for display. Strips system-only
    /// content (system reminders, slash-command wrappers), collapses
    /// whitespace, trims to one line, caps at `maxLength` characters with
    /// a `…` suffix if needed. Returns `nil` if nothing user-visible
    /// remains after stripping.
    public static func cleanPrompt(_ raw: String, maxLength: Int = 80) -> String? {
        // Strip every harness-internal wrapper (<system-reminder>,
        // <task-notification>, etc.) — they look user-typed in the JSONL
        // but the user never wrote them. Returns nil if the body
        // collapses to empty, which lets the caller skip the whole
        // sidebar row.
        guard var text = stripSystemContent(raw) else { return nil }
        // <command-name> unwrap: keep the inner text — that IS the
        // user-intended summary for slash-command invocations
        // (the wholesale-strip <command-args>, <command-message>,
        // and <local-command-stdout> wrappers were already handled
        // by stripSystemContent above).
        if let openRange = text.range(of: "<command-name>"),
           let closeRange = text.range(of: "</command-name>",
                                        range: openRange.upperBound..<text.endIndex) {
            text = String(text[openRange.upperBound..<closeRange.lowerBound])
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
        guard let raw = rawUserText(from: json), !raw.isEmpty else { return nil }
        return cleanPrompt(raw)
    }

    /// Rich result describing the first-user line. Adds two extras beyond
    /// `decodeUserPrompt`:
    ///   • `isScheduledTask` — true when the first user content is a
    ///     `<scheduled-task ...>...</scheduled-task>` automation payload.
    ///     The sidebar filters these out so cron-style background runs
    ///     don't clutter the "Recent (last 30 days)" list.
    ///   • `prompt` — the cleaned, truncated label for the row.
    public struct FirstUserLine: Sendable, Hashable {
        public let prompt: String?
        public let isScheduledTask: Bool

        public init(prompt: String?, isScheduledTask: Bool) {
            self.prompt = prompt
            self.isScheduledTask = isScheduledTask
        }
    }

    /// Inspect a user line and return both the cleaned prompt AND whether
    /// the line is an automation/scheduled-task wrapper. Callers should
    /// drop the entire session from sidebars when `isScheduledTask` is
    /// true; they're not user-driven sessions.
    public static func decodeFirstUserLine(from json: [String: Any]) -> FirstUserLine {
        guard let raw = rawUserText(from: json), !raw.isEmpty else {
            return FirstUserLine(prompt: nil, isScheduledTask: false)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude Code wraps automated triggers in `<scheduled-task name="…">`.
        // Detect by leading tag (case-sensitive — Claude always emits
        // lowercase). The session has no user-driven content even when
        // the wrapper contains a task description.
        if trimmed.hasPrefix("<scheduled-task") {
            return FirstUserLine(prompt: nil, isScheduledTask: true)
        }
        return FirstUserLine(prompt: cleanPrompt(raw), isScheduledTask: false)
    }

    /// Pull the first plain-text content out of a user message. Walks the
    /// same block traversal as `decodeUserPrompt` but returns the raw
    /// (uncleaned) text so the caller can apply its own filters
    /// (`<scheduled-task>` detection, etc.) before truncation strips
    /// signal.
    private static func rawUserText(from json: [String: Any]) -> String? {
        guard (json["type"] as? String) == "user" else { return nil }
        guard let message = json["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                let blockType = block["type"] as? String
                if blockType == "text", let text = block["text"] as? String {
                    return text
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
