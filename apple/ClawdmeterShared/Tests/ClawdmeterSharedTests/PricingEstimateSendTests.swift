import XCTest
@testable import ClawdmeterShared

/// PR #31 chunk 4 — Pricing.estimateSend tests. Covers the composer
/// chip's "~$X / send" estimate. The estimator's contract:
///   - well-known model → returns > 0
///   - unknown model → returns 0 (same as Pricing.cost)
///   - longer prompts cost more
///   - estimateBroadcast = sum of estimateSend across the trio
final class PricingEstimateSendTests: XCTestCase {

    func test_estimateSend_knownClaudeModelIsNonZero() {
        let pricing = Pricing.shared
        let result = pricing.estimateSend(
            promptText: "Write me a function to reverse a linked list",
            agent: .claude,
            model: "claude-4-sonnet-20250514"
        )
        XCTAssertGreaterThan(result, 0, "claude-4-sonnet-20250514 must have a non-zero rate")
    }

    func test_estimateSend_unknownModelIsZero() {
        let pricing = Pricing.shared
        let result = pricing.estimateSend(
            promptText: "anything here",
            agent: .claude,
            model: "future-model-9000"
        )
        XCTAssertEqual(result, 0)
    }

    func test_estimateSend_emptyPromptStillCostsTheOutputBaseline() {
        // Even an empty prompt pays the notional 256 output tokens (the
        // estimator anchors on an "average reply" so the chip doesn't
        // flicker between $0.000 and $0.001 as the user starts typing).
        let pricing = Pricing.shared
        let result = pricing.estimateSend(
            promptText: "",
            agent: .claude,
            model: "claude-4-sonnet-20250514"
        )
        XCTAssertGreaterThan(result, 0)
    }

    func test_estimateSend_longerPromptCostsMore() {
        let pricing = Pricing.shared
        let short = pricing.estimateSend(
            promptText: "hi",
            agent: .claude,
            model: "claude-4-sonnet-20250514"
        )
        let long = pricing.estimateSend(
            promptText: String(repeating: "hi there friend ", count: 1000),
            agent: .claude,
            model: "claude-4-sonnet-20250514"
        )
        XCTAssertGreaterThan(long, short)
    }

    func test_estimateBroadcast_sumsAcrossModels() {
        let pricing = Pricing.shared
        let prompt = "Write me a function to reverse a linked list"
        let claude = pricing.estimateSend(promptText: prompt, agent: .claude, model: "claude-4-sonnet-20250514")
        let codex = pricing.estimateSend(promptText: prompt, agent: .codex, model: "gpt-4o")
        let sum = pricing.estimateBroadcast(
            promptText: prompt,
            agentModels: [(.claude, "claude-4-sonnet-20250514"), (.codex, "gpt-4o")]
        )
        XCTAssertEqual(sum, claude + codex,
            "estimateBroadcast must equal sum of per-pair estimateSend values")
    }

    func test_estimateBroadcast_emptyListIsZero() {
        let result = Pricing.shared.estimateBroadcast(promptText: "hi", agentModels: [])
        XCTAssertEqual(result, 0)
    }

    func test_estimateBroadcast_singleEntryEqualsEstimateSend() {
        let pricing = Pricing.shared
        let prompt = "test"
        let single = pricing.estimateSend(promptText: prompt, agent: .claude, model: "claude-4-sonnet-20250514")
        let broadcast = pricing.estimateBroadcast(
            promptText: prompt,
            agentModels: [(.claude, "claude-4-sonnet-20250514")]
        )
        XCTAssertEqual(broadcast, single)
    }
}
