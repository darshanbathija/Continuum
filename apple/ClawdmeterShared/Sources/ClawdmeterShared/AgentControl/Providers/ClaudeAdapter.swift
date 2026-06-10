import Foundation

/// Per-provider canonical-event adapter for Claude Code.
///
/// **F1a strangler-fig migration (D23).** Today, Claude JSONL lines are
/// parsed in two separate places:
///   - `SessionChatStore` (in `apple/ClawdmeterMac/AgentControl/`) for the
///     chat UI: text/tool_use/tool_result blocks → `ChatItem` shapes
///   - `ClaudeUsageParser` (in `Analytics/`) for the analytics: token
///     counts → `UsageRecord`
///
/// Both implementations read the same JSONL but extract different fields.
/// F1a introduces `ClaudeAdapter` as the **single** canonical translator
/// emitting `ProviderRuntimeEvent` values. Downstream consumers (chat
/// store, analytics, orchestration store F2, push gateway E6) all
/// subscribe to the canonical event stream.
///
/// **This PR ships the adapter and its tests only.** Wiring the existing
/// consumers (SessionChatStore + UsageHistoryLoader's Claude branch) to
/// consume canonical events is the follow-up F1a-wire PR. Per strangler-
/// fig: both paths coexist until the canonical path is proven on real
/// session data; then the legacy parsers delete in F1e.
///
/// **Plan:** F1a (Phase 1; D23) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
///
/// **Concurrency:** stateless + nonisolated. Designed to be invoked from
/// any actor / task without ceremony. State (sequence numbers, dedupe)
/// lives in the caller — typically `SessionChatStore` for the chat path
/// and `UsageHistoryLoader` for the analytics path.
public enum ClaudeAdapter {

    /// The shape this adapter consumes — one fully-parsed JSONL line from
    /// a Claude Code session log. Caller is responsible for JSON
    /// deserialization (so the adapter can be tested with hand-crafted
    /// dicts without going through Data round-trips every test).
    ///
    /// Shape mirrors what Claude Code's JSONL writes (verified against
    /// real on-disk logs):
    /// ```json
    /// {
    ///   "timestamp": "2026-05-15T10:00:00Z",
    ///   "cwd": "/Users/x/myrepo",
    ///   "requestId": "req_abc",
    ///   "sessionId": "session-xyz",
    ///   "message": {
    ///     "id": "msg_1",
    ///     "model": "claude-sonnet-4-5",
    ///     "role": "assistant",
    ///     "content": [...],
    ///     "usage": {...}
    ///   }
    /// }
    /// ```
    public typealias RawLine = [String: Any]

    // MARK: - Public surface

    /// Translate a single Claude JSONL line into zero or more canonical
    /// events. Returns `[]` for lines we don't have a canonical mapping
    /// for yet — caller logs + carries on.
    ///
    /// Returns multiple events when a single Claude turn surfaces both a
    /// completed assistant message AND its embedded tool_use blocks; the
    /// adapter emits them in order so downstream sequence numbers stay
    /// monotonic.
    ///
    /// - Parameters:
    ///   - line: Parsed JSONL line dict
    ///   - sessionId: Caller's session identifier (Clawdmeter session id;
    ///                may differ from Claude's internal sessionId field)
    ///   - sequenceStart: Next sequence number to use. Caller increments
    ///                    `sequenceStart` by the count of returned events
    ///                    before the next call.
    ///   - providerInstanceId: Optional F3 instance id (claude_personal /
    ///                          claude_work) — passed through to all
    ///                          emitted events.
    ///   - rawBytes: Optional raw JSONL line bytes for lossless retention
    ///                in `ProviderRuntimeEvent.rawProviderPayload` (codex
    ///                eng-review #8). Caller passes if the bytes are
    ///                cheap to forward; adapter doesn't re-serialize.
    public static func translate(
        line: RawLine,
        sessionId: String,
        sequenceStart: UInt64,
        providerInstanceId: String? = nil,
        rawBytes: Data? = nil
    ) -> [ProviderRuntimeEvent] {
        let timestamp = parseTimestamp(line["timestamp"]) ?? Date()
        let messageRaw = line["message"] as? [String: Any]

        // Branch on the high-level shape. Claude's JSONL is consistently
        // wrapped with `message.role` — that's the discriminator we use.
        guard let messageRaw else {
            // Lines without a `message` envelope: known meta lines map to
            // canonical events; unknown shapes surface as `.unknown` so
            // downstream replay never silently drops data (review P1).
            if let kind = line["type"] as? String, kind == "system" {
                return [makeEvent(
                    sessionId: sessionId,
                    seq: sequenceStart,
                    timestamp: timestamp,
                    providerInstanceId: providerInstanceId,
                    payload: .sessionStarted(
                        model: (line["model"] as? String) ?? "",
                        settings: extractSystemSettings(line)
                    ),
                    rawBytes: rawBytes,
                    extensions: nil
                )]
            }
            // Forward-compat: unrecognized envelope shape. Emit `.unknown`
            // so observers can log/replay; raw bytes carry the full data.
            let kindName = (line["type"] as? String) ?? "missing"
            return [makeEvent(
                sessionId: sessionId,
                seq: sequenceStart,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                payload: .unknown(name: "claude.line.\(kindName)"),
                rawBytes: rawBytes,
                extensions: nil
            )]
        }

        let role = (messageRaw["role"] as? String) ?? ""
        let model = messageRaw["model"] as? String
        let usage = messageRaw["usage"] as? [String: Any]

        // Build Claude-specific extension data once; attach to whichever
        // event(s) we emit for this line so downstream replay never loses
        // the cache-token / requestId / dedupe-key information.
        let claudeExt = makeClaudeExtension(
            line: line,
            messageRaw: messageRaw,
            usage: usage
        )
        let extensions: [String: ProviderRuntimeEvent.ExtensionField]? =
            claudeExt.map { ["claude": .nested($0)] }

        switch role {
        case "user":
            return [emitUserMessage(
                line: line,
                messageRaw: messageRaw,
                sessionId: sessionId,
                seq: sequenceStart,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                rawBytes: rawBytes,
                extensions: extensions
            )]

        case "assistant":
            return emitAssistantTurn(
                messageRaw: messageRaw,
                model: model,
                usage: usage,
                sessionId: sessionId,
                seqStart: sequenceStart,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                rawBytes: rawBytes,
                extensions: extensions
            )

        case "tool":
            // Tool result delivered as a top-level message. Some Claude
            // sessions wrap tool_result inside an assistant content block;
            // others write a dedicated role="tool" line. Handle both.
            if let toolEvent = emitToolResultRole(
                messageRaw: messageRaw,
                sessionId: sessionId,
                seq: sequenceStart,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                rawBytes: rawBytes,
                extensions: extensions
            ) {
                return [toolEvent]
            }
            return []

        default:
            // Unknown role — forward-compat surface. We emit an .unknown
            // event so consumers can observe + replay; the raw bytes
            // carry the full original data.
            return [makeEvent(
                sessionId: sessionId,
                seq: sequenceStart,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                payload: .unknown(name: "claude.role.\(role.isEmpty ? "missing" : role)"),
                rawBytes: rawBytes,
                extensions: extensions
            )]
        }
    }

    // MARK: - Assistant turn

    private static func emitAssistantTurn(
        messageRaw: [String: Any],
        model: String?,
        usage: [String: Any]?,
        sessionId: String,
        seqStart: UInt64,
        timestamp: Date,
        providerInstanceId: String?,
        rawBytes: Data?,
        extensions: [String: ProviderRuntimeEvent.ExtensionField]?
    ) -> [ProviderRuntimeEvent] {
        var events: [ProviderRuntimeEvent] = []
        var seq = seqStart

        let content = messageRaw["content"] as? [[String: Any]] ?? []

        // Walk content blocks. Each tool_use → ProviderRuntimeEvent.toolUse;
        // the text accumulates into the final assistantMessageCompleted.
        var combinedText = ""
        for block in content {
            let blockType = (block["type"] as? String) ?? ""
            switch blockType {
            case "text":
                if let text = block["text"] as? String {
                    combinedText += text
                }
            case "tool_use":
                let toolName = (block["name"] as? String) ?? ""
                let toolId = (block["id"] as? String) ?? ""
                let params = stringifyParameters(block["input"])
                events.append(makeEvent(
                    sessionId: sessionId,
                    seq: seq,
                    timestamp: timestamp,
                    providerInstanceId: providerInstanceId,
                    payload: .toolUse(
                        name: toolName,
                        parameters: params,
                        invocationId: toolId
                    ),
                    rawBytes: rawBytes,
                    extensions: extensions
                ))
                seq += 1
            case "tool_result":
                // Embedded tool_result inside an assistant content array.
                let invocationId = (block["tool_use_id"] as? String) ?? ""
                let isError = (block["is_error"] as? Bool) ?? false
                let resultText = flattenToolResultContent(block["content"])
                events.append(makeEvent(
                    sessionId: sessionId,
                    seq: seq,
                    timestamp: timestamp,
                    providerInstanceId: providerInstanceId,
                    payload: .toolResult(
                        invocationId: invocationId,
                        success: !isError,
                        text: resultText
                    ),
                    rawBytes: rawBytes,
                    extensions: extensions
                ))
                seq += 1
            case "thinking":
                // Claude's extended-thinking surfaces as a `thinking`
                // block. Stash in extensions; never lose it.
                // (No canonical case today; future work may add .thinking.)
                continue
            default:
                // Unknown content block — surface as an .unknown event so
                // downstream consumers see something rather than dropping.
                events.append(makeEvent(
                    sessionId: sessionId,
                    seq: seq,
                    timestamp: timestamp,
                    providerInstanceId: providerInstanceId,
                    payload: .unknown(name: "claude.assistant.content.\(blockType)"),
                    rawBytes: rawBytes,
                    extensions: extensions
                ))
                seq += 1
            }
        }

        // Closing event: assistantMessageCompleted with the accumulated
        // text + usage tokens. Only emit when usage exists (mirrors the
        // analytics parser's contract — usage-bearing lines are turn-end).
        if let usage {
            let tokensIn = intValue(usage["input_tokens"])
            let tokensOut = intValue(usage["output_tokens"])
            events.append(makeEvent(
                sessionId: sessionId,
                seq: seq,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                payload: .assistantMessageCompleted(
                    text: combinedText,
                    tokensIn: tokensIn,
                    tokensOut: tokensOut
                ),
                rawBytes: rawBytes,
                extensions: extensions
            ))
        } else if !combinedText.isEmpty {
            // Streaming partial — no usage yet, but we did get text.
            // Emit as a single delta so the active streaming bubble can
            // render. A9 (isolated streaming view) consumes these.
            events.append(makeEvent(
                sessionId: sessionId,
                seq: seq,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                payload: .assistantTokenDelta(text: combinedText, index: 0),
                rawBytes: rawBytes,
                extensions: extensions
            ))
        }

        _ = model // model is captured in extensions; not in the canonical payload today

        return events
    }

    // MARK: - User message

    private static func emitUserMessage(
        line: RawLine,
        messageRaw: [String: Any],
        sessionId: String,
        seq: UInt64,
        timestamp: Date,
        providerInstanceId: String?,
        rawBytes: Data?,
        extensions: [String: ProviderRuntimeEvent.ExtensionField]?
    ) -> ProviderRuntimeEvent {
        // User content can be a plain string OR a content-block array.
        // Flatten both shapes to a single string for the canonical event.
        let text: String
        if let s = messageRaw["content"] as? String {
            text = s
        } else if let blocks = messageRaw["content"] as? [[String: Any]] {
            text = blocks.compactMap { block in
                if let t = block["text"] as? String { return t }
                if (block["type"] as? String) == "tool_result" {
                    // tool_result delivered inside a user message — common
                    // shape in Claude turns where the agent's reply
                    // includes a tool result. We strip the text out as
                    // user content; the dedicated tool_result event
                    // would have already been emitted by the assistant's
                    // matching block.
                    return flattenToolResultContent(block["content"])
                }
                return nil
            }.joined(separator: "\n")
        } else {
            text = ""
        }

        // Attachment refs: Claude doesn't carry these inline today;
        // Clawdmeter's own attachment store wraps them separately. Stash
        // any visible filenames in user content blocks.
        let attachmentRefs: [String] = {
            guard let blocks = messageRaw["content"] as? [[String: Any]] else { return [] }
            return blocks.compactMap { ($0["source"] as? [String: Any])?["filename"] as? String }
        }()

        _ = line // line is captured in rawBytes; metadata via extensions

        return makeEvent(
            sessionId: sessionId,
            seq: seq,
            timestamp: timestamp,
            providerInstanceId: providerInstanceId,
            payload: .userMessage(text: text, attachmentRefs: attachmentRefs),
            rawBytes: rawBytes,
            extensions: extensions
        )
    }

    // MARK: - Tool result (top-level role)

    private static func emitToolResultRole(
        messageRaw: [String: Any],
        sessionId: String,
        seq: UInt64,
        timestamp: Date,
        providerInstanceId: String?,
        rawBytes: Data?,
        extensions: [String: ProviderRuntimeEvent.ExtensionField]?
    ) -> ProviderRuntimeEvent? {
        // Two shapes observed in real Claude logs:
        //   { "role": "tool", "tool_use_id": "...", "content": "...", "is_error": false }
        //   { "role": "tool", "content": [{ "type": "tool_result", "tool_use_id": "...", "content": "..." }] }
        if let invocationId = messageRaw["tool_use_id"] as? String {
            let isError = (messageRaw["is_error"] as? Bool) ?? false
            let text = flattenToolResultContent(messageRaw["content"])
            return makeEvent(
                sessionId: sessionId,
                seq: seq,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                payload: .toolResult(
                    invocationId: invocationId,
                    success: !isError,
                    text: text
                ),
                rawBytes: rawBytes,
                extensions: extensions
            )
        }
        if let blocks = messageRaw["content"] as? [[String: Any]],
           let block = blocks.first(where: { ($0["type"] as? String) == "tool_result" }) {
            let invocationId = (block["tool_use_id"] as? String) ?? ""
            let isError = (block["is_error"] as? Bool) ?? false
            let text = flattenToolResultContent(block["content"])
            return makeEvent(
                sessionId: sessionId,
                seq: seq,
                timestamp: timestamp,
                providerInstanceId: providerInstanceId,
                payload: .toolResult(
                    invocationId: invocationId,
                    success: !isError,
                    text: text
                ),
                rawBytes: rawBytes,
                extensions: extensions
            )
        }
        return nil
    }

    // MARK: - Claude extension fields

    private static func makeClaudeExtension(
        line: RawLine,
        messageRaw: [String: Any],
        usage: [String: Any]?
    ) -> [String: ProviderRuntimeEvent.ExtensionField]? {
        var out: [String: ProviderRuntimeEvent.ExtensionField] = [:]
        if let id = messageRaw["id"] as? String { out["message_id"] = .string(id) }
        if let model = messageRaw["model"] as? String { out["model"] = .string(model) }
        if let stop = messageRaw["stop_reason"] as? String { out["stop_reason"] = .string(stop) }
        if let req = line["requestId"] as? String { out["request_id"] = .string(req) }
        if let cwd = line["cwd"] as? String { out["cwd"] = .string(cwd) }
        if let sess = line["sessionId"] as? String { out["claude_session_id"] = .string(sess) }
        if let usage {
            // Cache tokens — Claude's distinctive feature. Carried so the
            // analytics layer can keep the cache-aware cost math.
            if let v = usage["cache_creation_input_tokens"] as? Int {
                out["cache_creation_input_tokens"] = .int(Int64(v))
            }
            if let v = usage["cache_read_input_tokens"] as? Int {
                out["cache_read_input_tokens"] = .int(Int64(v))
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func extractSystemSettings(_ line: RawLine) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["subtype", "client", "homePath"] {
            if let v = line[key] as? String { out[key] = v }
        }
        return out
    }

    // MARK: - Event builder

    private static func makeEvent(
        sessionId: String,
        seq: UInt64,
        timestamp: Date,
        providerInstanceId: String?,
        payload: ProviderRuntimeEvent.Payload,
        rawBytes: Data?,
        extensions: [String: ProviderRuntimeEvent.ExtensionField]?
    ) -> ProviderRuntimeEvent {
        return ProviderRuntimeEvent(
            id: "claude-\(sessionId)-\(seq)",
            providerKind: .claude,
            providerInstanceId: providerInstanceId,
            sessionId: sessionId,
            sequenceNumber: seq,
            emittedAt: timestamp,
            payload: payload,
            rawProviderPayload: rawBytes,
            providerExtensions: extensions
        )
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        // Hot path: lock-free parse. The ICU-backed formatters serialize
        // every call behind global mutexes, which pegged all cores during
        // cold analytics reparses (v0.31.17 energy bug).
        if let d = ISO8601Fast.parse(s) { return d }
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFractional.date(from: s) { return d }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
    }

    /// Claude's `tool_use.input` can be any JSON shape (object / array /
    /// scalar). For the canonical event we stringify each key→value to a
    /// flat dict. Full original shape lives in `rawProviderPayload`.
    private static func stringifyParameters(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String { out[k] = s }
            else if let n = v as? Int { out[k] = String(n) }
            else if let d = v as? Double { out[k] = String(d) }
            else if let b = v as? Bool { out[k] = String(b) }
            else if let data = try? JSONSerialization.data(withJSONObject: v, options: []),
                    let s = String(data: data, encoding: .utf8) {
                out[k] = s
            } else {
                out[k] = String(describing: v)
            }
        }
        return out
    }

    /// `tool_result.content` is either a plain String or an array of
    /// content blocks (each `{ "type": "text", "text": "..." }` or
    /// `{ "type": "image", ... }`). Flatten to a string for the canonical
    /// event; image blocks become a `[image]` placeholder (the raw bytes
    /// are still available via rawProviderPayload for any consumer that
    /// needs the image).
    private static func flattenToolResultContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let arr = raw as? [[String: Any]] {
            return arr.map { block in
                if (block["type"] as? String) == "text" {
                    return (block["text"] as? String) ?? ""
                }
                if (block["type"] as? String) == "image" { return "[image]" }
                return ""
            }.joined(separator: "\n")
        }
        return ""
    }
}
