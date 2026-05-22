import Foundation

/// PR #31 chunk 4 — composer cost estimation. Surfaces the
/// "~$0.011 / send" chip on Mac + iOS chat composers.
///
/// The estimator composes existing `Pricing.cost(for:tokens:)` rates;
/// it doesn't introduce a parallel rate card. Token count uses a
/// simple character-count ÷ 4 heuristic — this is intentionally rough.
/// Per the plan: "char/4 heuristic (mark as TODO to upgrade to
/// model-specific tokenizer post-v1.0)". The chip's job is to give the
/// user an order-of-magnitude feel for "is this expensive?"; a fancy
/// tokenizer would be over-engineered for that read.
public extension Pricing {

    /// Estimate the cost (in USD) of sending `promptText` to a single
    /// provider. Returns 0 for unknown models — same behavior as
    /// `cost(for:tokens:)` so callers stay consistent.
    ///
    /// The composer chip on Mac + iOS chat surfaces calls this with
    /// the current draft text + the picked agent's default model.
    /// Broadcast mode sums the per-provider estimates via
    /// `estimateBroadcast(promptText:agentModels:)`.
    func estimateSend(promptText: String, agent: AgentKind, model: String) -> Decimal {
        // Character-count ÷ 4 ~ rough English-token approximation.
        // For mixed-language prompts the ratio drifts higher (CJK
        // tokenizes ~1:1) but the chip is an order-of-magnitude hint.
        let estimatedInputTokens = max(1, promptText.count / 4)
        // We bill a notional 256 output tokens as a typical first-turn
        // assistant reply length. This is wildly underspecified — many
        // turns produce 2000+ token replies — but anchoring the chip
        // to an "average reply" keeps the per-send estimate stable
        // instead of flickering with prompt size alone.
        let estimatedOutputTokens = 256
        let tokens = TokenTotals(
            inputTokens: estimatedInputTokens,
            outputTokens: estimatedOutputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            costUSD: 0,
            requestCount: 1
        )
        // OpenCode (and any future orchestrator-style agent) doesn't
        // bill under its own model name — the cost flows through to
        // whichever underlying provider the user authenticated with.
        // For the estimator we just look up the underlying model
        // (same string) and let Pricing.cost return 0 for unknowns.
        _ = agent  // agent reserved for future per-agent surcharges
        return cost(for: model, tokens: tokens)
    }

    /// Sum of `estimateSend` across multiple (agent, model) pairs.
    /// Used by the Mac Chat composer when broadcast mode is active:
    /// chip reads "~$0.033 / send" for 3 providers instead of the
    /// solo "~$0.011 / send".
    func estimateBroadcast(promptText: String, agentModels: [(AgentKind, String)]) -> Decimal {
        agentModels.reduce(Decimal(0)) { acc, pair in
            acc + estimateSend(promptText: promptText, agent: pair.0, model: pair.1)
        }
    }
}
