import XCTest
@testable import ClawdmeterShared

/// PR #31 chunk 3 — OpencodeUsageMapper tests. Covers the pure mapper
/// surface: opencode `usage` event properties → UsageRecord. Cost
/// resolution against Pricing.shared is exercised in PricingTests; here
/// we focus on:
///   - happy path: well-formed event maps to a record with the right
///     provider tag + token totals
///   - lenient numeric reader: Int / Double / NSNumber values all parse
///   - missing model → nil (skip rather than $0 phantom row)
///   - all-zero tokens → nil (skip rather than $0 phantom row)
///   - unknown model → record with $0 cost (don't drop tokens, surface
///     via unpriced-model attribution)
final class OpencodeUsageMapperTests: XCTestCase {

    func test_mapEvent_happyPath() {
        let properties: [String: Any] = [
            "sessionID": "ses_abc",
            "model": "claude-3-5-sonnet",
            "inputTokens": 1234,
            "outputTokens": 567,
            "cacheReadTokens": 0,
            "cacheCreationTokens": 0,
        ]
        let record = OpencodeUsageMapper.mapEvent(properties: properties, repo: "/Users/test/repo")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.provider, .opencode)
        XCTAssertEqual(record?.model, "claude-3-5-sonnet")
        XCTAssertEqual(record?.tokens.inputTokens, 1234)
        XCTAssertEqual(record?.tokens.outputTokens, 567)
        XCTAssertEqual(record?.repo, "/Users/test/repo")
        XCTAssertNil(record?.dedupKey)
    }

    func test_mapEvent_nilRepoTagsCorrectly() {
        let properties: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "inputTokens": 100,
            "outputTokens": 50,
        ]
        let record = OpencodeUsageMapper.mapEvent(properties: properties, repo: nil)
        XCTAssertNotNil(record)
        XCTAssertNil(record?.repo)
    }

    func test_mapEvent_missingModelReturnsNil() {
        let properties: [String: Any] = [
            "inputTokens": 100,
            "outputTokens": 50,
        ]
        XCTAssertNil(OpencodeUsageMapper.mapEvent(properties: properties, repo: nil))
    }

    func test_mapEvent_emptyModelReturnsNil() {
        let properties: [String: Any] = [
            "model": "",
            "inputTokens": 100,
            "outputTokens": 50,
        ]
        XCTAssertNil(OpencodeUsageMapper.mapEvent(properties: properties, repo: nil))
    }

    func test_mapEvent_allZeroTokensReturnsNil() {
        // Skip events that carry no actual usage — common during
        // opencode's tool-call orchestration where individual sub-events
        // ping the usage stream with zero tokens.
        let properties: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "inputTokens": 0,
            "outputTokens": 0,
            "cacheReadTokens": 0,
            "cacheCreationTokens": 0,
        ]
        XCTAssertNil(OpencodeUsageMapper.mapEvent(properties: properties, repo: nil))
    }

    func test_mapEvent_doubleTypedTokenCounts() {
        // JSONSerialization can decode `1234` as Double if the source
        // text wrote it as `1234.0`. The lenient reader handles both
        // branches.
        let properties: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "inputTokens": 1234.0 as Double,
            "outputTokens": 567.0 as Double,
        ]
        let record = OpencodeUsageMapper.mapEvent(properties: properties, repo: nil)
        XCTAssertEqual(record?.tokens.inputTokens, 1234)
        XCTAssertEqual(record?.tokens.outputTokens, 567)
    }

    func test_mapEvent_unknownModelStillReturnsRecord() {
        // Pricing.cost(for:) returns 0 for unknown models per its
        // contract. The mapper still emits a record so the tokens
        // attribute to the unpriced-model bucket downstream — drops
        // would silently hide real usage.
        let properties: [String: Any] = [
            "model": "future-model-9000",
            "inputTokens": 100,
            "outputTokens": 50,
        ]
        let record = OpencodeUsageMapper.mapEvent(properties: properties, repo: nil)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.model, "future-model-9000")
        XCTAssertEqual(record?.tokens.inputTokens, 100)
        XCTAssertEqual(record?.tokens.costUSD, 0)
    }

    func test_mapEvent_propagatesReasoningTokens() {
        // Some opencode model variants emit reasoning tokens (similar to
        // Codex). The mapper must propagate them so they hit the cost
        // calculation + analytics aggregation.
        let properties: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "inputTokens": 100,
            "outputTokens": 50,
            "reasoningTokens": 200,
        ]
        let record = OpencodeUsageMapper.mapEvent(properties: properties, repo: nil)
        XCTAssertEqual(record?.tokens.reasoningTokens, 200)
    }

    func test_mapEvent_setsRequestCountToOne() {
        // Each opencode usage event is one round-trip; analytics
        // sums requestCount across records to surface "X requests
        // made today" elsewhere.
        let properties: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "inputTokens": 100,
            "outputTokens": 50,
        ]
        let record = OpencodeUsageMapper.mapEvent(properties: properties, repo: nil)
        XCTAssertEqual(record?.tokens.requestCount, 1)
    }
}
