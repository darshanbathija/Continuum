import XCTest
@testable import ClawdmeterShared

final class PricingTests: XCTestCase {

    private let pricing = Pricing()

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
}
