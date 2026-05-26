import Foundation

/// Per-provider canonical-event adapter for OpenCode (sst/opencode).
///
/// **F1c strangler-fig migration (D23).** OpenCode persists messages in a
/// SQLite database at `~/.local/share/opencode/opencode.db`. Each `message`
/// row's `data` column carries a JSON blob shaped like:
///
/// ```json
/// {
///   "role": "assistant" | "user",
///   "cost": <usd>,
///   "tokens": {
///     "input":  N,
///     "output": N,
///     "reasoning": N,
///     "cache": { "write": N, "read": N }
///   },
///   "modelID": "claude-sonnet-4.5",
///   "providerID": "anthropic" | "openai" | "github-copilot" | "opencode" | …,
///   "time": { "created": <ms-epoch> },
///   "path": { "cwd": "/path/to/repo" }
/// }
/// ```
///
/// **Statelessness:** unlike `CodexAdapter`, OpenCode's per-message blob is
/// self-contained (no cumulative deltas). The adapter is a `pure static
/// enum` so callers can run it from any actor without ceremony.
///
/// **Cost handling parity with `OpencodeUsageParser`:**
///   - Prefer the embedded `cost` field when > 0 (OpenCode computes from
///     its own pricing at write time)
///   - Otherwise fall through to `Pricing.shared.cost()` resolution via
///     the caller (the canonical event carries the model + token counts;
///     analytics layer does the lookup)
///
/// **Mac-only at file level:** parser/source consumers are `#if os(macOS)`
/// (sandboxed iOS can't read `~/.local/share/`). The ADAPTER itself is
/// platform-agnostic — the SQLite reading is the caller's concern.
///
/// **Plan:** F1c (Phase 1; D23) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
public enum OpenCodeAdapter {

    public typealias RawMessage = [String: Any]

    /// Translate a single OpenCode message dict into canonical events.
    ///
    /// - Parameters:
    ///   - message: Parsed JSON blob from the `data` column of one
    ///              `opencode.db` `message` row.
    ///   - messageId: Row PK (`id` column) — used as the canonical
    ///                event id + dedupe key.
    ///   - timestamp: `time.created` from the row, parsed to a Date.
    ///                Adapter doesn't re-parse from the blob.
    ///   - sessionId: Clawdmeter-side session identifier.
    ///   - sequenceStart: Caller-managed sequence cursor.
    ///   - providerInstanceId: F3-ready instance id.
    ///   - rawBytes: Optional raw bytes for `rawProviderPayload`.
    public static func translate(
        message: RawMessage,
        messageId: String,
        timestamp: Date,
        sessionId: String,
        sequenceStart: UInt64,
        providerInstanceId: String? = nil,
        rawBytes: Data? = nil
    ) -> [ProviderRuntimeEvent] {
        let role = (message["role"] as? String) ?? ""

        switch role {
        case "assistant":
            return [emitAssistantMessage(
                message: message,
                messageId: messageId,
                timestamp: timestamp,
                sessionId: sessionId,
                seq: sequenceStart,
                providerInstanceId: providerInstanceId,
                rawBytes: rawBytes
            )]

        case "user":
            return [emitUserMessage(
                message: message,
                messageId: messageId,
                timestamp: timestamp,
                sessionId: sessionId,
                seq: sequenceStart,
                providerInstanceId: providerInstanceId,
                rawBytes: rawBytes
            )]

        default:
            // Wrap extensions under the "opencode" key to match the
            // canonical contract (providerExtensions is keyed by adapter
            // id, not raw field name). Assistant/user paths already do
            // this; the unknown path was leaking flat keys.
            let unknownExt = opencodeExtensions(from: message)
            let unknownWrapped: [String: ProviderRuntimeEvent.ExtensionField]? =
                unknownExt.map { ["opencode": .nested($0)] }
            return [makeEvent(
                id: makeEventId(messageId: messageId, seq: sequenceStart),
                sessionId: sessionId,
                seq: sequenceStart,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                payload: .unknown(name: "opencode.role.\(role.isEmpty ? "missing" : role)"),
                rawBytes: rawBytes,
                extensions: unknownWrapped
            )]
        }
    }

    // MARK: - Assistant message

    private static func emitAssistantMessage(
        message: RawMessage,
        messageId: String,
        timestamp: Date,
        sessionId: String,
        seq: UInt64,
        providerInstanceId: String?,
        rawBytes: Data?
    ) -> ProviderRuntimeEvent {
        // Tokens. Mirror OpencodeUsageParser exactly: input + output +
        // reasoning + cache.{write, read}. Canonical surface uses tokensIn
        // + tokensOut (the analytics-relevant rollup); the full breakdown
        // lives in opencode extension fields.
        let tokensDict = (message["tokens"] as? [String: Any]) ?? [:]
        let inputTokens = (tokensDict["input"] as? Int) ?? 0
        let outputTokens = (tokensDict["output"] as? Int) ?? 0
        let reasoningTokens = (tokensDict["reasoning"] as? Int) ?? 0
        let cacheDict = tokensDict["cache"] as? [String: Any]
        let cacheWrite = (cacheDict?["write"] as? Int) ?? 0
        let cacheRead = (cacheDict?["read"] as? Int) ?? 0

        // OpenCode embeds the assistant text in a `content` or `parts`
        // array depending on version; check both. The aggregator doesn't
        // use this field today (it only needs token counts), but the
        // chat path will need it once F1c-wire flips SessionChatStore.
        let text: String = {
            if let s = message["content"] as? String { return s }
            if let parts = message["parts"] as? [[String: Any]] {
                return parts.compactMap { ($0["text"] as? String) }.joined(separator: "\n")
            }
            return ""
        }()

        // Build extensions BEFORE the event so we can include the full
        // token breakdown + cost.
        var ext = opencodeExtensions(from: message) ?? [:]
        ext["reasoning_tokens"] = .int(Int64(reasoningTokens))
        ext["cache_write_tokens"] = .int(Int64(cacheWrite))
        ext["cache_read_tokens"] = .int(Int64(cacheRead))
        if let embeddedCost = message["cost"] as? Double {
            ext["embedded_cost_usd"] = .double(embeddedCost)
        }

        return makeEvent(
            id: makeEventId(messageId: messageId, seq: seq),
            sessionId: sessionId,
            seq: seq,
            timestamp: timestamp,
            providerInstanceId: providerInstanceId,
            payload: .assistantMessageCompleted(
                text: text,
                tokensIn: inputTokens,
                tokensOut: outputTokens
            ),
            rawBytes: rawBytes,
            extensions: ["opencode": .nested(ext)]
        )
    }

    // MARK: - User message

    private static func emitUserMessage(
        message: RawMessage,
        messageId: String,
        timestamp: Date,
        sessionId: String,
        seq: UInt64,
        providerInstanceId: String?,
        rawBytes: Data?
    ) -> ProviderRuntimeEvent {
        let text: String = {
            if let s = message["content"] as? String { return s }
            if let parts = message["parts"] as? [[String: Any]] {
                return parts.compactMap { ($0["text"] as? String) }.joined(separator: "\n")
            }
            return ""
        }()
        let extensions = opencodeExtensions(from: message)
        let wrapped: [String: ProviderRuntimeEvent.ExtensionField]? =
            extensions.map { ["opencode": .nested($0)] }
        return makeEvent(
            id: makeEventId(messageId: messageId, seq: seq),
            sessionId: sessionId,
            seq: seq,
            timestamp: timestamp,
            providerInstanceId: providerInstanceId,
            payload: .userMessage(text: text, attachmentRefs: []),
            rawBytes: rawBytes,
            extensions: wrapped
        )
    }

    // MARK: - Extension fields

    private static func opencodeExtensions(from message: RawMessage) -> [String: ProviderRuntimeEvent.ExtensionField]? {
        var out: [String: ProviderRuntimeEvent.ExtensionField] = [:]
        if let modelID = message["modelID"] as? String { out["model_id"] = .string(modelID) }
        if let providerID = message["providerID"] as? String { out["provider_id"] = .string(providerID) }
        if let pathDict = message["path"] as? [String: Any],
           let cwd = pathDict["cwd"] as? String {
            out["cwd"] = .string(cwd)
        }
        if let timeDict = message["time"] as? [String: Any],
           let created = timeDict["created"] as? Int {
            out["created_ms"] = .int(Int64(created))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Event builder

    private static func makeEventId(messageId: String, seq: UInt64) -> String {
        // OpenCode messageIds are stable PKs from SQLite — use as the
        // canonical event id. Sequence number is appended for events
        // that fan out from a single row (none today, but reserved).
        return "opencode-\(messageId)-\(seq)"
    }

    private static func makeEvent(
        id: String,
        sessionId: String,
        seq: UInt64,
        timestamp: Date,
        providerInstanceId: String?,
        payload: ProviderRuntimeEvent.Payload,
        rawBytes: Data?,
        extensions: [String: ProviderRuntimeEvent.ExtensionField]?
    ) -> ProviderRuntimeEvent {
        return ProviderRuntimeEvent(
            id: id,
            providerKind: .opencode,
            providerInstanceId: providerInstanceId,
            sessionId: sessionId,
            sequenceNumber: seq,
            emittedAt: timestamp,
            payload: payload,
            rawProviderPayload: rawBytes,
            providerExtensions: extensions
        )
    }
}
