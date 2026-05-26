#if os(macOS)
import Foundation

/// F1c-wire (strangler-fig per D23): adapter-routed equivalent of
/// `OpencodeUsageParser.decode(jsonBlob:messageId:timestamp:)`.
///
/// Re-projects the canonical `ProviderRuntimeEvent`s emitted by
/// `OpenCodeAdapter.translate(...)` back into the `UsageRecord` shape
/// `UsageHistoryLoader` expects. With the feature flag on, the
/// analytics path calls this; with the flag off, it calls the legacy
/// `OpencodeUsageParser.decode(...)`. The bridge MUST be a behavioral
/// identity over the legacy parser — `F1cParityTests` enforces this.
///
/// **Why a separate type?** The legacy parser is a pure function from
/// JSON blob → `UsageRecord?`. The adapter is a pure function from
/// parsed JSON dict → `[ProviderRuntimeEvent]`. This bridge owns the
/// "pick the usage-bearing event and re-flatten" projection in one
/// place, separate from the adapter that stays general-purpose.
///
/// **Parity contract.** For every OpenCode `data` JSON blob, this MUST
/// return the same `UsageRecord?` as `OpencodeUsageParser.decode(...)`
/// — same provider, timestamp, model, tokens (all categories), repo,
/// cost (with the embedded-cost > 0 preference), and dedupKey. Cases
/// the legacy parser drops (no `tokens` block, zero-token rows,
/// malformed JSON) MUST return nil here too.
///
/// **Mac-only:** parser/source consumers are `#if os(macOS)` because
/// `OpencodeUsageParser` is gated the same way (sandboxed iOS can't
/// read `~/.local/share/opencode/`). The adapter itself is
/// platform-agnostic, but the bridge sits on the analytics path that
/// only exists on macOS.
///
/// **Plan reference:** F1c-wire (Phase 1; D23 strangler-fig).
public enum OpenCodeAdapterUsageBridge {

    /// Decode one OpenCode `data` JSON blob via the canonical adapter
    /// and project it back into the legacy `UsageRecord` shape. Returns
    /// nil for the same cases `OpencodeUsageParser.decode(...)` returns
    /// nil: malformed JSON, missing `tokens` block (user message),
    /// zero-token rows.
    public static func decode(
        jsonBlob: Data,
        messageId: String,
        timestamp: Date,
        pricing: Pricing = .shared
    ) -> UsageRecord? {
        // JSON deserialization is the adapter caller's job — keep that
        // contract here so the adapter stays stateless + symmetric to
        // the legacy parser's "raw bytes in" surface.
        guard let message = try? JSONSerialization.jsonObject(with: jsonBlob) as? [String: Any] else {
            return nil
        }

        // Legacy drops rows that don't have a `tokens` block (user
        // messages). The adapter still emits an event for them, but
        // there's nothing to bill. Mirror the legacy drop bit-for-bit.
        guard message["tokens"] is [String: Any] else { return nil }

        // The adapter doesn't know the analytics session id — that's a
        // Clawdmeter concept, not an OpenCode one. Pass an empty string;
        // analytics doesn't read sessionId off the canonical event.
        let events = OpenCodeAdapter.translate(
            message: message,
            messageId: messageId,
            timestamp: timestamp,
            sessionId: "",
            sequenceStart: 0,
            providerInstanceId: nil,
            rawBytes: nil
        )

        // The legacy parser bills off `tokens.input / output / reasoning
        // / cache.{write, read}`. The adapter mirrors that contract by
        // emitting an `.assistantMessageCompleted` payload only for the
        // assistant branch (the only role with a tokens block in
        // practice). User-role rows with a tokens block are an
        // unrealistic shape but we mirror legacy: keep the `tokens
        // != nil` guard above and look for the assistant event.
        guard let usageEvent = events.first(where: { event in
            if case .assistantMessageCompleted = event.payload { return true }
            return false
        }) else {
            return nil
        }
        guard case let .assistantMessageCompleted(_, tokensIn, tokensOut) = usageEvent.payload else {
            return nil
        }

        // Pull the full token breakdown + embedded cost off the
        // canonical extension envelope. The adapter stashes them under
        // `providerExtensions["opencode"]` as a nested map; legacy
        // reads them directly off `tokens.*`. Defaulting to 0 matches
        // the legacy `(... as? Int) ?? 0` semantics.
        let opencodeExt: [String: ProviderRuntimeEvent.ExtensionField] = {
            guard let outer = usageEvent.providerExtensions?["opencode"],
                  case let .nested(inner) = outer else { return [:] }
            return inner
        }()

        let reasoningTokens = extensionInt(opencodeExt["reasoning_tokens"])
        let cacheWriteTokens = extensionInt(opencodeExt["cache_write_tokens"])
        let cacheReadTokens = extensionInt(opencodeExt["cache_read_tokens"])

        // Legacy drops zero-token rows. nonZero mirrors the legacy
        // computation bit-for-bit (input + output + reasoning + cache.{write, read}).
        let nonZero = tokensIn + tokensOut + reasoningTokens + cacheWriteTokens + cacheReadTokens
        guard nonZero > 0 else { return nil }

        let modelID = extensionString(opencodeExt["model_id"]) ?? ""
        let providerID = extensionString(opencodeExt["provider_id"]) ?? ""

        // Repo — legacy reads `path.cwd` and returns nil when missing
        // OR empty. Extension carries the same scalar.
        let cwd: String? = {
            guard let v = extensionString(opencodeExt["cwd"]), !v.isEmpty else { return nil }
            return v
        }()

        var tokens = TokenTotals(
            inputTokens: tokensIn,
            outputTokens: tokensOut,
            cacheCreationTokens: cacheWriteTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            requestCount: 1
        )

        // Cost resolution. Legacy prefers the embedded `cost` field when
        // > 0; otherwise falls through to `Pricing.cost()` with
        // provider-prefix + dot/dash normalization fallbacks. Mirror
        // both branches bit-for-bit.
        let embeddedCost: Double = {
            if case let .double(v) = opencodeExt["embedded_cost_usd"] { return v }
            return 0
        }()
        if embeddedCost > 0 {
            tokens.costUSD = Decimal(embeddedCost)
        } else {
            tokens.costUSD = resolveCost(
                modelID: modelID,
                providerID: providerID,
                tokens: tokens,
                pricing: pricing
            )
        }

        return UsageRecord(
            provider: .opencode,
            timestamp: timestamp,
            model: modelID,
            tokens: tokens,
            repo: cwd,
            dedupKey: messageId
        )
    }

    // MARK: - Cost resolution (mirrors OpencodeUsageParser exactly)

    /// Cost resolution with provider-prefix + dot/dash normalization
    /// fallbacks. Returns 0 if no rate variant matches; the aggregator
    /// then folds the row into `unpricedModelTokens`.
    private static func resolveCost(
        modelID: String,
        providerID: String,
        tokens: TokenTotals,
        pricing: Pricing
    ) -> Decimal {
        let candidates: [String] = {
            let normalized = modelID.replacingOccurrences(of: ".", with: "-")
            var out: [String] = []
            if !modelID.isEmpty { out.append(modelID) }
            if normalized != modelID { out.append(normalized) }
            if !providerID.isEmpty {
                if !modelID.isEmpty { out.append("\(providerID)/\(modelID)") }
                if normalized != modelID { out.append("\(providerID)/\(normalized)") }
            }
            return out
        }()
        for candidate in candidates {
            let cost = pricing.cost(for: candidate, tokens: tokens)
            if cost > 0 { return cost }
        }
        return 0
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
#endif
