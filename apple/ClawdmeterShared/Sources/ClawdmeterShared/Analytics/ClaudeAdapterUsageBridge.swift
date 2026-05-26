import Foundation

/// F1a-wire (strangler-fig per D23): adapter-routed equivalent of
/// `ClaudeUsageParser.parse(line:)`.
///
/// Re-projects the canonical `ProviderRuntimeEvent`s emitted by
/// `ClaudeAdapter.translate(...)` back into the `UsageRecord` shape
/// `UsageHistoryLoader` expects. With the feature flag on, the
/// analytics path calls this; with the flag off, it calls the legacy
/// `ClaudeUsageParser`. The bridge MUST be a behavioral identity over
/// the legacy parser — `F1aWireParityTests` enforces this.
///
/// **Why a separate type?** The legacy parser is a pure function from
/// JSON line → `UsageRecord?`. The adapter is a pure function from
/// parsed JSON dict → `[ProviderRuntimeEvent]`. The shapes don't
/// compose 1:1: a single Claude line can emit multiple canonical events
/// (e.g. an assistant turn with N `tool_use` blocks emits N+1 events).
/// This bridge owns the "pick the usage-bearing event and re-flatten"
/// projection in one place, separate from the adapter that stays
/// general-purpose.
///
/// **Parity contract.** For every Claude JSONL line, this MUST return
/// the same `UsageRecord?` as `ClaudeUsageParser.parse(line:)` — same
/// provider, timestamp, model, tokens (all four categories), repo, and
/// dedupKey. Cases the legacy parser drops (no `message.usage`,
/// `totalTokens == 0`, malformed JSON) MUST return nil here too.
///
/// **Plan reference:** F1a-wire (Phase 1; D23 strangler-fig).
public enum ClaudeAdapterUsageBridge {

    /// Parse one JSONL line via the canonical adapter and project it
    /// back into the legacy `UsageRecord` shape. Returns nil for the
    /// same cases `ClaudeUsageParser.parse(line:)` returns nil:
    /// malformed JSON, missing usage, zero tokens.
    public static func parseLine(_ line: Data) -> UsageRecord? {
        // JSON deserialization is the adapter caller's job — keep that
        // contract here so the adapter stays stateless + symmetric to
        // the legacy parser's "raw bytes in" surface.
        guard let json = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any] else {
            return nil
        }

        // Legacy-compat shim: the legacy ClaudeUsageParser pulls tokens
        // off `message.usage` without inspecting role. The adapter
        // switches on role and falls through to `.unknown` when role is
        // missing — which would silently drop usage-bearing lines whose
        // shape is "message.usage present but no role" (older / partial
        // log fixtures). Synthesize an "assistant" role here when
        // usage is present so the adapter takes the assistant branch
        // and emits the matching `.assistantMessageCompleted` event.
        // The fix is in the bridge rather than the adapter so the
        // adapter's contract (role-driven) stays clean — this is the
        // strangler-fig shim, not a contract change.
        let normalized = normalizeForLegacyCompat(json)

        // The adapter doesn't know the analytics session id — that's a
        // Clawdmeter concept, not a Claude one. Pass an empty string;
        // analytics doesn't read sessionId off the canonical event.
        let events = ClaudeAdapter.translate(
            line: normalized,
            sessionId: "",
            sequenceStart: 0,
            providerInstanceId: nil,
            rawBytes: nil
        )

        // The legacy parser only emits a record when `message.usage`
        // exists. The adapter mirrors that contract by emitting an
        // `.assistantMessageCompleted` payload only when usage is
        // present (see ClaudeAdapter.emitAssistantTurn). Anything else
        // (user message, tool_use, partial text) is non-billing.
        guard let usageEvent = events.first(where: { event in
            if case .assistantMessageCompleted = event.payload { return true }
            return false
        }) else {
            return nil
        }
        guard case let .assistantMessageCompleted(_, tokensIn, tokensOut) = usageEvent.payload else {
            return nil
        }

        // Pull cache tokens from the canonical extension envelope. The
        // adapter stashes them under `providerExtensions["claude"]` as a
        // nested map; legacy reads them directly off `usage`. Defaulting
        // to 0 matches legacy's `intValue(usageRaw[...])` semantics.
        let claudeExt: [String: ProviderRuntimeEvent.ExtensionField] = {
            guard let outer = usageEvent.providerExtensions?["claude"],
                  case let .nested(inner) = outer else { return [:] }
            return inner
        }()

        let cacheCreate = extensionInt(claudeExt["cache_creation_input_tokens"])
        let cacheRead = extensionInt(claudeExt["cache_read_input_tokens"])

        let tokens = TokenTotals(
            inputTokens: tokensIn,
            outputTokens: tokensOut,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            reasoningTokens: 0,
            costUSD: 0
        )

        // Legacy parser drops zero-token lines as the empty-completion
        // edge case (matches ccusage). Mirror that drop here so parity
        // holds bit-for-bit.
        if tokens.totalTokens == 0 { return nil }

        // Model — extension stores the message-level model string;
        // legacy falls back to the sentinel "unknown" when absent.
        let model = extensionString(claudeExt["model"]) ?? "unknown"

        // Repo — extension stores the top-level cwd. Legacy normalizes
        // via `RepoIdentity.normalize(cwd)`; do the same here so the
        // aggregator's per-repo bucketing is identical.
        let repo: RepoKey? = {
            guard let cwd = extensionString(claudeExt["cwd"]),
                  !cwd.isEmpty else { return nil }
            return RepoIdentity.normalize(cwd)
        }()

        // Dedup key — legacy requires BOTH message.id AND requestId.
        // Extension carries both as separate scalars; missing either
        // → nil dedup (treat as unique).
        let dedupKey: String? = {
            guard let messageID = extensionString(claudeExt["message_id"]),
                  let requestID = extensionString(claudeExt["request_id"]) else {
                return nil
            }
            return "\(messageID):\(requestID)"
        }()

        return UsageRecord(
            provider: .claude,
            timestamp: usageEvent.emittedAt,
            model: model,
            tokens: tokens,
            repo: repo,
            dedupKey: dedupKey
        )
    }

    // MARK: - Legacy-compat normalization

    /// Insert a synthetic `role: "assistant"` into the message envelope
    /// when usage is present but role is missing. The legacy parser
    /// ignores role entirely; the adapter requires it. This shim keeps
    /// the strangler-fig boundary clean — the adapter's role-driven
    /// contract stays unchanged, and the bridge handles back-compat for
    /// the "no role + usage" shape that legacy tolerated.
    ///
    /// Returns the input unchanged when the envelope already has a role
    /// or when usage is missing.
    private static func normalizeForLegacyCompat(_ json: [String: Any]) -> [String: Any] {
        guard var message = json["message"] as? [String: Any],
              message["usage"] is [String: Any],
              (message["role"] as? String) == nil
        else { return json }
        message["role"] = "assistant"
        var copy = json
        copy["message"] = message
        return copy
    }

    // MARK: - Extension scalar helpers

    private static func extensionString(_ field: ProviderRuntimeEvent.ExtensionField?) -> String? {
        guard case let .string(v) = field else { return nil }
        return v
    }

    private static func extensionInt(_ field: ProviderRuntimeEvent.ExtensionField?) -> Int {
        guard case let .int(v) = field else { return 0 }
        return Int(v)
    }
}
