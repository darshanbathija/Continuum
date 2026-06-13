import Foundation

/// Serializes a chat transcript into a priming-context block fed to a harness
/// agent after its bridge is respawned with new config (model / effort /
/// approval policy).
///
/// Why this exists: a harness provider (Grok / Codex / Cursor / Gemini) takes
/// its model + approval policy only at bridge-launch time, so a mid-session
/// config change is a kill + respawn. The respawned provider thread starts with
/// no memory of the conversation. The on-screen transcript survives (the
/// `SessionChatStore` is kept across the respawn), but the *model* needs the
/// history re-handed to it — this builds that hand-off text.
///
/// Pure + `Sendable` so it unit-tests without a live store.
public enum HarnessTranscriptContext {

    /// Default cap. Keeps the priming turn bounded — very long sessions hand
    /// back only their most recent turns rather than blowing the context window
    /// (and the provider's per-turn cost) on a respawn.
    public static let defaultMaxChars = 12_000

    /// Build the priming block from a transcript, newest-bounded to `maxChars`.
    ///
    /// Only `userText` / `assistantText` turns are included — tool calls and
    /// results are noise for re-priming and balloon the size. Returns `nil` when
    /// there is nothing worth carrying (empty / whitespace-only transcript), so
    /// callers skip the priming prompt entirely.
    public static func preamble(
        from messages: [ChatMessage],
        maxChars: Int = defaultMaxChars
    ) -> String? {
        let turns: [String] = messages.compactMap { message in
            switch message.kind {
            case .userText:
                let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? nil : "User: \(body)"
            case .assistantText:
                let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? nil : "Assistant: \(body)"
            case .toolCall, .toolResult, .meta:
                return nil
            }
        }
        guard !turns.isEmpty else { return nil }

        // Keep the most RECENT turns under the cap: walk from the end, prepend
        // until the next turn would exceed the budget. Recency beats completeness
        // — the tail of a conversation is what the next instruction builds on.
        var kept: [String] = []
        var used = 0
        for turn in turns.reversed() {
            let cost = turn.count + 1  // +1 for the joining newline
            if used + cost > maxChars, !kept.isEmpty { break }
            kept.insert(turn, at: 0)
            used += cost
        }
        let truncated = kept.count < turns.count

        var lines: [String] = []
        lines.append(
            "[Context hand-off] You are resuming this conversation after a "
            + "configuration change. Here is the conversation so far"
            + (truncated ? " (older turns omitted)" : "")
            + " — use it as context and continue from where it left off. "
            + "Acknowledge briefly; do not redo prior work."
        )
        lines.append("")
        lines.append(contentsOf: kept)
        return lines.joined(separator: "\n")
    }
}
