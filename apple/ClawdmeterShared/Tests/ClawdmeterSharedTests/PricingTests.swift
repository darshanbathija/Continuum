import XCTest
@testable import ClawdmeterShared

final class PricingTests: XCTestCase {

    private let pricing = Pricing()

    override func setUp() {
        super.setUp()
        // B3 cache may carry state across tests if test methods share
        // a Pricing instance. Reset Pricing.shared just in case
        // downstream callers consult it via the singleton.
        Pricing.shared._resetResolutionCacheForTesting()
    }

    // MARK: - B3 LRU cache

    func test_b3_cacheHit_returnsConsistentRates() {
        // Cold path: first call resolves via prefix scan.
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 500)
        let cost1 = pricing.cost(for: "claude-sonnet-4-5", tokens: tokens)
        // Warm path: second call returns cached resolution. Must equal
        // the first call to the cent — no precision drift.
        let cost2 = pricing.cost(for: "claude-sonnet-4-5", tokens: tokens)
        XCTAssertEqual(cost1, cost2)
    }

    func test_b3_unknownModel_cachedAsNil_returnsZeroEachTime() {
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 500)
        let cost1 = pricing.cost(for: "definitely-not-a-real-model-1234", tokens: tokens)
        let cost2 = pricing.cost(for: "definitely-not-a-real-model-1234", tokens: tokens)
        XCTAssertEqual(cost1, 0)
        XCTAssertEqual(cost2, 0)
        XCTAssertFalse(pricing.isPriced("definitely-not-a-real-model-1234"))
        // Confirm subsequent isPriced() also returns false (cache hit).
        XCTAssertFalse(pricing.isPriced("definitely-not-a-real-model-1234"))
    }

    func test_b3_resetCacheForTesting_dropsCache() {
        let tokens = TokenTotals(inputTokens: 1_000, outputTokens: 500)
        _ = pricing.cost(for: "claude-sonnet-4-5", tokens: tokens)
        // After reset, the next call cold-resolves but must produce the
        // same answer.
        pricing._resetResolutionCacheForTesting()
        let postReset = pricing.cost(for: "claude-sonnet-4-5", tokens: tokens)
        XCTAssertGreaterThan((postReset as NSDecimalNumber).doubleValue, 0)
    }

    // MARK: - Existing tests

    func test_claudeBelow200k() {
        // 100k input @ $3/M = $0.30; 50k output @ $15/M = $0.75; total = $1.05
        let tokens = TokenTotals(inputTokens: 100_000, outputTokens: 50_000)
        let cost = pricing.cost(for: "claude-sonnet-4-5", tokens: tokens)
        XCTAssertEqual((cost as NSDecimalNumber).doubleValue, 1.05, accuracy: 0.001)
    }

    func test_claudeAbove200kTiering() {
        // 250k input: first 200k @ $3/M = $0.60, next 50k @ $6/M = $0.30,
        // total input = $0.90. No output → cost = $0.90.
        // But because we crossed the boundary, all rates flip — input above
        // boundary applies to overflow.
        let tokens = TokenTotals(inputTokens: 250_000, outputTokens: 0)
        let cost = pricing.cost(for: "claude-sonnet-4-5", tokens: tokens)
        XCTAssertEqual((cost as NSDecimalNumber).doubleValue, 0.90, accuracy: 0.001)
    }

    func test_codexExactKey() {
        // gpt-5-codex exists directly in LiteLLM as of refresh.
        let tokens = TokenTotals(inputTokens: 1000, outputTokens: 1000)
        let cost = pricing.cost(for: "gpt-5-codex", tokens: tokens)
        XCTAssertGreaterThan((cost as NSDecimalNumber).doubleValue, 0)
        XCTAssertTrue(pricing.isPriced("gpt-5-codex"))
    }

    func test_unknownModelReturnsZero() {
        let tokens = TokenTotals(inputTokens: 1_000_000, outputTokens: 1_000_000)
        let cost = pricing.cost(for: "completely-made-up-model-xyz", tokens: tokens)
        XCTAssertEqual(cost, 0)
        XCTAssertFalse(pricing.isPriced("completely-made-up-model-xyz"))
    }

    // v0.23.8: pin the new Gemini frontier-Pro entry. Until this
    // commit, M134 → "gemini-3.1-pro" fell through as unpriced and
    // any Antigravity session on the Pro model contributed $0.
    func test_gemini31Pro_pricesBelow200kAtIOLaunchRates() {
        // 100K input @ $2/M = $0.20; 50K output @ $12/M = $0.60; total $0.80.
        let tokens = TokenTotals(inputTokens: 100_000, outputTokens: 50_000)
        let cost = pricing.cost(for: "gemini-3.1-pro", tokens: tokens)
        XCTAssertEqual((cost as NSDecimalNumber).doubleValue, 0.80, accuracy: 0.001)
        XCTAssertTrue(pricing.isPriced("gemini-3.1-pro"))
    }

    func test_gemini35Flash_pricesAtIO2026Rates() {
        // 100K input @ $1.50/M = $0.15; 50K output @ $9/M = $0.45; total $0.60.
        let tokens = TokenTotals(inputTokens: 100_000, outputTokens: 50_000)
        let cost = pricing.cost(for: "gemini-3.5-flash", tokens: tokens)
        XCTAssertEqual((cost as NSDecimalNumber).doubleValue, 0.60, accuracy: 0.001)
        XCTAssertTrue(pricing.isPriced("gemini-3.5-flash"))
    }

    func test_claudeModelPrefixMatch() {
        // claude-sonnet-4-5-20250929 is in the snapshot directly, but a
        // hypothetical future-date variant should fall back via prefix match.
        let tokens = TokenTotals(inputTokens: 100, outputTokens: 100)
        let cost = pricing.cost(for: "claude-sonnet-4-5-99999999", tokens: tokens)
        XCTAssertGreaterThan(cost, 0)
    }

    func test_costIsZeroForZeroTokens() {
        XCTAssertEqual(pricing.cost(for: "claude-sonnet-4-5", tokens: .zero), 0)
    }

    // MARK: - Above-boundary input bug (regression guard)

    func test_untieredModelChargesAllInputTokensAtBaseRate() {
        // Bug fixed in this commit: for models without an
        // `*_above_200k_tokens` rate set, `Pricing.cost` previously
        // capped the input at the 200K boundary and silently dropped
        // every token past it. A 1M-token input session on a non-tiered
        // model was reading $0.60 instead of $3.00 (5x undercount).
        let tokens = TokenTotals(inputTokens: 1_000_000)
        let cost = pricing.cost(for: "gpt-5", tokens: tokens)
        let dbl = (cost as NSDecimalNumber).doubleValue
        // gpt-5 input is in the snapshot at a stable rate. The full
        // 1M tokens should be charged, not just the first 200K. Use a
        // generous lower bound that's > 5x what the buggy path would
        // return.
        XCTAssertGreaterThan(dbl, 1.0,
                             "expected ~$1.25+ for 1M gpt-5 input tokens; got $\(dbl)")
    }

    func test_untieredModelCostScalesLinearlyPast200kBoundary() {
        // Belt-and-suspenders: a 5M-token input should cost roughly 5x
        // what a 1M-token input does, on a model without tier rates.
        let small = pricing.cost(for: "gpt-5", tokens: TokenTotals(inputTokens: 1_000_000))
        let big = pricing.cost(for: "gpt-5", tokens: TokenTotals(inputTokens: 5_000_000))
        let smallD = (small as NSDecimalNumber).doubleValue
        let bigD = (big as NSDecimalNumber).doubleValue
        XCTAssertEqual(bigD / smallD, 5.0, accuracy: 0.01,
                       "5M tokens should cost exactly 5x 1M tokens on a flat-rate model")
    }

    // MARK: - SessionActivityStrip cost-estimator path (regression guard)

    func test_opusSessionWithRealisticCacheMixIsRoughlyAccurate() {
        // Regression: a 915M-token Opus-4-7 session was reading $34.56
        // when the true Opus cost was ~$721, because the chat-store
        // conflated all input + cache_creation + cache_read into a
        // single `inputTokens` value AND used a hardcoded Sonnet model.
        //
        // With the four-category split + correct model hint, the cost
        // should land in the same ballpark as the manual calculation:
        //   input         5,769 × $5/MTok   = $0.03
        //   cache_create 13.1M × $6.25/MTok = $82.15
        //   cache_read   1.13B × $0.50/MTok = $563.0
        //   output       3.05M × $25/MTok   = $76.25
        //   TOTAL                          ≈ $721
        let tokens = TokenTotals(
            inputTokens: 5_769,
            outputTokens: 3_050_822,
            cacheCreationTokens: 13_144_300,
            cacheReadTokens: 1_125_971_605
        )
        let cost = pricing.cost(for: "claude-opus-4-7", tokens: tokens)
        let dbl = (cost as NSDecimalNumber).doubleValue
        // Allow ±15% wiggle for rate snapshot updates.
        XCTAssertGreaterThan(dbl, 600, "expected ~$721 for the Opus session, got $\(dbl)")
        XCTAssertLessThan(dbl, 850, "expected ~$721 for the Opus session, got $\(dbl)")
    }
}
