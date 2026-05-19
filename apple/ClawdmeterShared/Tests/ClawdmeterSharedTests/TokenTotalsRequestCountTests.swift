import XCTest
@testable import ClawdmeterShared

/// X2 regression test (Codex outside-voice). Plan ships `requestCount: Int
/// = 0` on `TokenTotals` to carry Gemini per-request analytics. Codex
/// caught that a *Swift property default* doesn't make `Codable`'s
/// synthesized decoder tolerate missing keys — it still throws
/// `keyNotFound`.
///
/// Fix: custom `init(from:)` uses `decodeIfPresent(Int.self) ?? 0`. This
/// test asserts that an existing cache blob written before `requestCount`
/// existed decodes cleanly with `requestCount = 0` — the real failure
/// case, NOT the trivial "fresh init defaults to 0" case.
final class TokenTotalsRequestCountTests: XCTestCase {

    /// Pre-X2 JSON (without `requestCount` field) must decode to 0.
    /// Modeled after the on-disk cache JSON shape: explicit input/output/
    /// cache fields, no `requestCount`.
    func test_legacyBlob_withoutRequestCountField_decodesAsZero() throws {
        let legacyJSON = """
        {
            "inputTokens": 1234,
            "outputTokens": 5678,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "reasoningTokens": 0,
            "costUSD": 1.25
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TokenTotals.self, from: legacyJSON)
        XCTAssertEqual(decoded.inputTokens, 1234)
        XCTAssertEqual(decoded.outputTokens, 5678)
        XCTAssertEqual(decoded.requestCount, 0, "Missing requestCount key must decode-to 0, not throw keyNotFound")
    }

    /// New blob with `requestCount` decodes to the persisted value.
    func test_newBlob_withRequestCountField_decodesValue() throws {
        let json = """
        {
            "inputTokens": 0,
            "outputTokens": 0,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "reasoningTokens": 0,
            "costUSD": 0,
            "requestCount": 42
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TokenTotals.self, from: json)
        XCTAssertEqual(decoded.requestCount, 42)
    }

    /// Round-trip: encode + decode preserves `requestCount`.
    func test_roundTrip_preservesRequestCount() throws {
        let original = TokenTotals(
            inputTokens: 1,
            outputTokens: 2,
            cacheCreationTokens: 3,
            cacheReadTokens: 4,
            reasoningTokens: 5,
            costUSD: 0.01,
            requestCount: 99
        )
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(TokenTotals.self, from: data)
        XCTAssertEqual(round.requestCount, 99)
        XCTAssertEqual(round.inputTokens, 1)
        XCTAssertEqual(round.costUSD, Decimal(0.01))
    }

    /// Addition merges `requestCount` so Gemini-only repos accumulate
    /// per-window via the existing `+` operator that `UsageHistoryLoader`
    /// uses.
    func test_addition_mergesRequestCount() {
        let a = TokenTotals(inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0, costUSD: 0, requestCount: 3)
        let b = TokenTotals(inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0, costUSD: 0, requestCount: 5)
        let sum = a + b
        XCTAssertEqual(sum.requestCount, 8)
    }
}
