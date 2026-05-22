import Foundation

/// Maps OpenCode `usage` SSE event payloads into `UsageRecord` rows
/// for the analytics pipeline. PR #31 chunk 3.
///
/// OpenCode's wire shape (captured 2026-05-22 against opencode v1.15.x):
///   data: {
///     "type": "usage",
///     "properties": {
///       "sessionID": "ses_abc",
///       "model": "claude-3-5-sonnet",
///       "inputTokens": 1234,
///       "outputTokens": 567,
///       "cacheReadTokens": 0,
///       "cacheCreationTokens": 0
///     }
///   }
///
/// Cost is computed via `Pricing.cost(for:tokens:)` against the
/// underlying provider model (Anthropic, OpenAI, Google) — OpenCode
/// is an orchestrator and the cost flows through to whichever provider
/// the user signed in with. Analytics tags the slice under
/// `UsageRecord.Provider.opencode` so users see OpenCode-attributed
/// spend separately even when the underlying model is identical to
/// what they'd hit via Claude/Codex directly.
///
/// Unknown models log a warning and skip the record (no phantom $0
/// rows polluting analytics). Known-but-newer model names that
/// haven't made it into `pricing.json` yet land as $0 cost with
/// non-zero tokens — these are surfaced via
/// `UsageHistorySnapshot.unpricedModelTokens` so the user sees
/// "unpriced model" attribution rather than thinking OpenCode is free.
public enum OpencodeUsageMapper {

    /// Pure mapper: turns an opencode usage event's `properties` dict
    /// into a `UsageRecord`. Returns nil for malformed payloads
    /// (missing model or tokens) so the caller can log + skip.
    ///
    /// `repo` is opaque — opencode doesn't tell us the cwd on the
    /// usage event itself (the SessionEventEnvelope carries it at
    /// session granularity). Callers pass the repo path the
    /// Clawdmeter-side session was created against; analytics buckets
    /// nil under the literal repo key `"(unknown)"`.
    public static func mapEvent(
        properties: [String: Any],
        repo: String?,
        pricing: Pricing = .shared,
        at timestamp: Date = Date()
    ) -> UsageRecord? {
        guard let model = properties["model"] as? String,
              !model.isEmpty else {
            return nil
        }

        // Token counts: tolerate missing keys (some opencode versions
        // omit cache fields). The mapper accepts both Int and Double
        // because JSONSerialization decodes numeric literals as NSNumber
        // and Swift `as? Int` only succeeds for integral NSNumbers — a
        // value like 0.0 in the wire payload would fail Int casting.
        let input = readInt(properties["inputTokens"])
        let output = readInt(properties["outputTokens"])
        let cacheRead = readInt(properties["cacheReadTokens"])
        let cacheCreate = readInt(properties["cacheCreationTokens"])
        let reasoning = readInt(properties["reasoningTokens"])
        // No usable token data → skip rather than produce a $0 record.
        guard (input + output + cacheRead + cacheCreate + reasoning) > 0 else {
            return nil
        }

        let tokensWithoutCost = TokenTotals(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            costUSD: 0,
            requestCount: 1
        )
        let cost = pricing.cost(for: model, tokens: tokensWithoutCost)
        let tokens = TokenTotals(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            costUSD: cost,
            requestCount: 1
        )

        return UsageRecord(
            provider: .opencode,
            timestamp: timestamp,
            model: model,
            tokens: tokens,
            repo: repo,
            dedupKey: nil  // opencode doesn't expose a stable cross-event id
        )
    }

    /// Lenient numeric reader. NSNumber bridging from JSONSerialization
    /// makes `as? Int` fail for floating-point values that happen to be
    /// integers (e.g. `1234.0`). This handles both branches.
    private static func readInt(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d.rounded()) }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }
}
