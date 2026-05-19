import Foundation

/// Pure value transforms for Gemini CLI chat session JSONL files at
/// `~/.gemini/tmp/<repo>/chats/session-<timestamp>-<hash>.jsonl`.
///
/// **Wire shape** (observed on Gemini CLI 0.42.0, May 2026):
///
/// Line 1 — header:
/// ```json
/// {"sessionId":"<uuid>","projectHash":"<sha256>","startTime":"<iso>",
///  "lastUpdated":"<iso>","kind":"main"}
/// ```
///
/// Line 2+ — messages:
/// ```json
/// {"id":"<uuid>","timestamp":"<iso>","type":"user",
///  "content":[{"text":"<prompt>"}]}
/// ```
/// ```json
/// {"id":"<uuid>","timestamp":"<iso>","type":"model",
///  "content":"<assistant prose>",
///  "thoughts":[{"subject":"...","description":"..."}]}    // optional
/// ```
///
/// Differences from Claude/Codex JSONL:
///   - Top-level (no `message:` wrapper like Claude).
///   - `type: "user"` carries `content` as an ARRAY of `{text}` parts.
///   - `type: "model"` (not `"assistant"`) carries `content` as a STRING.
///   - Tool calls + function-call results aren't surfaced in the chat log
///     today — Gemini executes its `codebase_investigator` tools opaquely
///     and emits a single rolled-up `model` turn with the final prose.
///     If Google later emits tool spans here, the parser falls through
///     to a generic "unknown content block" surfacing.
///   - First-line header (`kind: "main"`) is metadata, NOT a message —
///     we skip it explicitly so the chat doesn't lead with garbage.
///
/// Mirrors `CodexJSONLParser` in shape — lives in Shared so it's testable
/// + iOS-readable. The Mac-side `SessionChatStore.ParsedLine.from` wraps
/// these helpers and supplies a `stableId` closure for chat-row IDs that
/// survive reparses.
public enum GeminiJSONLParser {

    /// Decode one Gemini JSONL line into a list of `ChatMessage`s. Returns
    /// an empty list for the header line (`kind` present, no `type`) and
    /// for non-message line types we don't surface.
    ///
    /// `stableId` should return a deterministic id given a suffix —
    /// `SessionChatStore.stableId(_:suffix:)` on Mac, or a test stub.
    public static func decode(
        json: [String: Any],
        at: Date,
        stableId: (String) -> String
    ) -> [ChatMessage] {
        // Skip the header line. It has `sessionId` + `kind` but no `type`.
        if json["type"] == nil { return [] }

        guard let type = json["type"] as? String else { return [] }
        switch type {
        case "user":
            return decodeUser(json: json, at: at, stableId: stableId)
        case "model", "gemini", "assistant":
            return decodeModel(json: json, at: at, stableId: stableId)
        case "system":
            // Synthetic context injection (env, instructions). Filter
            // out — same treatment as Codex's `developer`-role messages.
            return []
        default:
            return []
        }
    }

    // MARK: - User turns

    private static func decodeUser(
        json: [String: Any],
        at: Date,
        stableId: (String) -> String
    ) -> [ChatMessage] {
        // Gemini user `content` is `[{text: "..."}]` — an array of parts.
        // We concatenate text parts into a single chat bubble; this is
        // what the user actually typed.
        guard let parts = json["content"] as? [[String: Any]] else {
            // Fallback: some lines have content as a bare string instead
            // of array (older / future schema). Surface it directly.
            if let bare = json["content"] as? String, !bare.isEmpty {
                return [ChatMessage(
                    id: stableId("user-text"),
                    kind: .userText,
                    title: "You",
                    body: bare,
                    at: at
                )]
            }
            return []
        }
        let combined = parts.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        guard !combined.isEmpty else { return [] }
        return [ChatMessage(
            id: stableId("user-text"),
            kind: .userText,
            title: "You",
            body: combined,
            at: at
        )]
    }

    // MARK: - Model / assistant turns

    private static func decodeModel(
        json: [String: Any],
        at: Date,
        stableId: (String) -> String
    ) -> [ChatMessage] {
        var out: [ChatMessage] = []

        // `thoughts: [{subject, description}]` is Gemini's chain-of-thought
        // surface — render as a single collapsed reasoning bubble (mirrors
        // Codex's `reasoning` payload). Only surface when both fields are
        // non-empty so we don't pollute the chat with empty thought stubs.
        if let thoughts = json["thoughts"] as? [[String: Any]], !thoughts.isEmpty {
            let body = thoughts.compactMap { t -> String? in
                let subject = (t["subject"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let description = (t["description"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if subject.isEmpty && description.isEmpty { return nil }
                if subject.isEmpty { return description }
                if description.isEmpty { return subject }
                return "**\(subject)**\n\(description)"
            }.joined(separator: "\n\n")
            if !body.isEmpty {
                // `.meta` is the existing kind for non-user/non-assistant
                // chat rows (Codex's reasoning payloads use this too).
                // Rendered as a muted secondary bubble in the chat IDE.
                out.append(ChatMessage(
                    id: stableId("model-thoughts"),
                    kind: .meta,
                    title: "Reasoning",
                    body: body,
                    at: at
                ))
            }
        }

        // Main prose. Gemini's `content` here is a STRING (vs Claude's
        // array). Surface as an assistant chat bubble.
        if let text = json["content"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(ChatMessage(
                id: stableId("model-text"),
                kind: .assistantText,
                title: "Gemini",
                body: text,
                at: at
            ))
        } else if let parts = json["content"] as? [[String: Any]] {
            // Future-shape: array of content parts (mirroring user's shape
            // or matching Claude's assistant text blocks). Tolerantly merge.
            let combined = parts.compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            if !combined.isEmpty {
                out.append(ChatMessage(
                    id: stableId("model-text"),
                    kind: .assistantText,
                    title: "Gemini",
                    body: combined,
                    at: at
                ))
            }
        }

        return out
    }
}
