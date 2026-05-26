import Foundation

/// Per-provider canonical-event adapter for Codex (gpt-5-codex rollouts).
///
/// **F1b strangler-fig migration (D23).** Codex's JSONL rollout is
/// structurally different from Claude's: line-by-line events tagged with
/// a top-level `type` field (`session_meta`, `turn_context`, `event_msg`).
/// Token usage events carry CUMULATIVE counts; canonical events surface
/// the per-turn DELTA — same math the legacy `CodexUsageParser` uses.
///
/// Unlike `ClaudeAdapter`, `CodexAdapter` is **stateful**: each Codex
/// session needs its own instance so the cumulative→delta tracking and
/// the `currentCwd` / `currentModel` running values survive across
/// `translate(line:)` calls within a session.
///
/// **Mirrors the legacy `CodexUsageParser`** in token-math semantics:
///   - `input_tokens` total minus `cached_input_tokens` → canonical
///     `inputTokens`
///   - `cached_input_tokens` → `cacheReadTokens`
///   - `output_tokens` already rolls in reasoning → canonical `tokensOut`
///   - Non-monotonic cumulative drops are treated as session reset
///     (the new cumulative becomes the new baseline rather than a
///     negative delta)
///
/// **Plan:** F1b (Phase 1; D23) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
///
/// **What's NOT in F1b (F1b-wire follow-up):** wiring SessionChatStore
/// + UsageHistoryLoader's Codex branch through this adapter behind the
/// strangler-fig feature flag.
public final class CodexAdapter {

    public typealias RawLine = [String: Any]

    public let sessionId: String
    public let providerInstanceId: String?

    private var nextSequenceNumber: UInt64
    private var currentCwd: String?
    private var currentModel: String
    private var previousCumulative: CumulativeTokens
    private var sessionStartedEmitted: Bool

    public init(
        sessionId: String,
        providerInstanceId: String? = nil,
        initialSequenceNumber: UInt64 = 0
    ) {
        self.sessionId = sessionId
        self.providerInstanceId = providerInstanceId
        self.nextSequenceNumber = initialSequenceNumber
        self.currentCwd = nil
        self.currentModel = "gpt-5"
        self.previousCumulative = .zero
        self.sessionStartedEmitted = false
    }

    /// Translate a single Codex rollout JSONL line into zero or more
    /// canonical events. Stateful — caller must use a single
    /// `CodexAdapter` instance per session so the cumulative→delta math
    /// stays consistent.
    public func translate(
        line: RawLine,
        rawBytes: Data? = nil
    ) -> [ProviderRuntimeEvent] {
        let timestamp = parseTimestamp(line["timestamp"]) ?? Date()
        let type = (line["type"] as? String) ?? ""
        let payload = line["payload"] as? [String: Any] ?? [:]

        switch type {
        case "session_meta":
            // First metadata line of a Codex rollout — captures cwd and
            // marks the session as observed. We emit one .sessionStarted
            // event the first time we see this (or turn_context).
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                currentCwd = cwd
            }
            return maybeEmitSessionStarted(timestamp: timestamp, rawBytes: rawBytes)

        case "turn_context":
            // Each turn declares its model (may differ from the session
            // default — Codex supports mid-session model swaps). Update
            // the running model + cwd; if the model changed, we don't
            // re-emit .sessionStarted (model swaps surface in extensions
            // on subsequent tokenCount events).
            if let model = payload["model"] as? String, !model.isEmpty {
                currentModel = model
            }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                currentCwd = cwd
            }
            return maybeEmitSessionStarted(timestamp: timestamp, rawBytes: rawBytes)

        case "event_msg":
            let eventType = (payload["type"] as? String) ?? ""
            switch eventType {
            case "token_count":
                return emitTokenCount(
                    payload: payload,
                    timestamp: timestamp,
                    rawBytes: rawBytes
                )
            case "agent_message":
                // Codex sends agent text via SDK events; rollouts include
                // a summary line. Surface as assistantTokenDelta so the
                // streaming bubble (A9) can render incrementally.
                let text = (payload["message"] as? String) ?? ""
                if text.isEmpty { return [] }
                return [makeEvent(
                    timestamp: timestamp,
                    payload: .assistantTokenDelta(text: text, index: 0),
                    rawBytes: rawBytes,
                    extensions: codexExtension()
                )]
            case "user_message":
                let text = (payload["message"] as? String) ?? ""
                return [makeEvent(
                    timestamp: timestamp,
                    payload: .userMessage(text: text, attachmentRefs: []),
                    rawBytes: rawBytes,
                    extensions: codexExtension()
                )]
            case "error":
                let code = (payload["code"] as? String) ?? "error"
                let message = (payload["message"] as? String) ?? ""
                return [makeEvent(
                    timestamp: timestamp,
                    payload: .providerError(code: code, message: message),
                    rawBytes: rawBytes,
                    extensions: codexExtension()
                )]
            default:
                // Forward-compat: any event_msg subtype we don't know
                // yet surfaces as .unknown with full raw retention.
                return [makeEvent(
                    timestamp: timestamp,
                    payload: .unknown(name: "codex.event_msg.\(eventType)"),
                    rawBytes: rawBytes,
                    extensions: codexExtension()
                )]
            }

        default:
            // Unknown top-level type — forward-compat.
            return [makeEvent(
                timestamp: timestamp,
                payload: .unknown(name: "codex.type.\(type.isEmpty ? "missing" : type)"),
                rawBytes: rawBytes,
                extensions: codexExtension()
            )]
        }
    }

    // MARK: - Token count delta math

    private func emitTokenCount(
        payload: [String: Any],
        timestamp: Date,
        rawBytes: Data?
    ) -> [ProviderRuntimeEvent] {
        guard let info = payload["info"] as? [String: Any],
              let totalUsage = info["total_token_usage"] as? [String: Any]
        else { return [] }

        let inputTotal = intValue(totalUsage["input_tokens"])
        let cachedInput = intValue(totalUsage["cached_input_tokens"])
        let output = intValue(totalUsage["output_tokens"])

        let cumulative = CumulativeTokens(
            input: max(0, inputTotal - cachedInput),
            output: output,
            cacheRead: cachedInput
        )

        // Detect session reset (non-monotonic drop on ANY field — Codex
        // can reset individual counters while total stays the same).
        let isReset =
            cumulative.input < previousCumulative.input
            || cumulative.output < previousCumulative.output
            || cumulative.cacheRead < previousCumulative.cacheRead

        let delta: CumulativeTokens
        if isReset {
            delta = cumulative
        } else {
            delta = CumulativeTokens(
                input: cumulative.input - previousCumulative.input,
                output: cumulative.output - previousCumulative.output,
                cacheRead: cumulative.cacheRead - previousCumulative.cacheRead
            )
        }
        previousCumulative = cumulative

        // Skip heartbeat / no-op snapshots — same logic as legacy parser.
        guard delta.total > 0 else { return [] }

        // The canonical event for a Codex turn-end. Codex doesn't emit
        // assistant text inline (SDK fans that out separately), so the
        // canonical text is empty; tokens are the delta.
        var ext = codexExtension() ?? [:]
        // Carry the raw cumulative + delta breakdown so analytics layer
        // can reproduce the legacy parser's exact numbers.
        ext["cumulative_input"] = .int(Int64(cumulative.input))
        ext["cumulative_output"] = .int(Int64(cumulative.output))
        ext["cumulative_cache_read"] = .int(Int64(cumulative.cacheRead))
        ext["delta_input"] = .int(Int64(delta.input))
        ext["delta_output"] = .int(Int64(delta.output))
        ext["delta_cache_read"] = .int(Int64(delta.cacheRead))
        ext["was_session_reset"] = .bool(isReset)

        return [makeEvent(
            timestamp: timestamp,
            payload: .assistantMessageCompleted(
                text: "",
                tokensIn: delta.input,
                tokensOut: delta.output
            ),
            rawBytes: rawBytes,
            extensions: ["codex": .nested(ext)]
        )]
    }

    // MARK: - Session-started emission (once per session)

    private func maybeEmitSessionStarted(
        timestamp: Date,
        rawBytes: Data?
    ) -> [ProviderRuntimeEvent] {
        guard !sessionStartedEmitted else { return [] }
        sessionStartedEmitted = true
        var settings: [String: String] = [:]
        if let cwd = currentCwd { settings["cwd"] = cwd }
        return [makeEvent(
            timestamp: timestamp,
            payload: .sessionStarted(model: currentModel, settings: settings),
            rawBytes: rawBytes,
            extensions: codexExtension()
        )]
    }

    // MARK: - Codex extension fields

    private func codexExtension() -> [String: ProviderRuntimeEvent.ExtensionField]? {
        var out: [String: ProviderRuntimeEvent.ExtensionField] = [:]
        out["model"] = .string(currentModel)
        if let cwd = currentCwd { out["cwd"] = .string(cwd) }
        return out
    }

    // MARK: - Event builder

    private func makeEvent(
        timestamp: Date,
        payload: ProviderRuntimeEvent.Payload,
        rawBytes: Data?,
        extensions: [String: ProviderRuntimeEvent.ExtensionField]?
    ) -> ProviderRuntimeEvent {
        let seq = nextSequenceNumber
        nextSequenceNumber += 1
        let extPayload: [String: ProviderRuntimeEvent.ExtensionField]?
        if let existing = extensions {
            // codexExtension() already wraps under "codex" in tokenCount
            // path; for other paths we wrap here. Use a stable shape.
            if existing["codex"] != nil {
                extPayload = existing
            } else {
                extPayload = ["codex": .nested(existing)]
            }
        } else {
            extPayload = nil
        }
        return ProviderRuntimeEvent(
            id: "codex-\(sessionId)-\(seq)",
            providerKind: .codex,
            providerInstanceId: providerInstanceId,
            sessionId: sessionId,
            sequenceNumber: seq,
            emittedAt: timestamp,
            payload: payload,
            rawProviderPayload: rawBytes,
            providerExtensions: extPayload
        )
    }

    // MARK: - Cumulative-tokens snapshot

    private struct CumulativeTokens: Equatable {
        let input: Int
        let output: Int
        let cacheRead: Int
        var total: Int { input + output + cacheRead }
        static let zero = CumulativeTokens(input: 0, output: 0, cacheRead: 0)
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

    private func parseTimestamp(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        if let d = Self.isoFractional.date(from: s) { return d }
        if let d = Self.isoFormatter.date(from: s) { return d }
        return nil
    }

    private func intValue(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
    }
}
