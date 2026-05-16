import XCTest
@testable import ClawdmeterShared

/// Tests for Phase 8 pre-flight wire types. The math itself lives in
/// Mac-side `LiveCostCalculator` (no Mac test target today); these
/// cover the shared DTOs that cross the wire so the soft-warn cost
/// banner on iOS can decode whatever the daemon emits.
final class PreflightTests: XCTestCase {

    func test_preflight_query_roundtrip() throws {
        let q = PreflightQuery(
            repoKey: "/Users/x/Code/my-repo",
            agent: .claude,
            model: "claude-opus-4-7",
            effort: .high,
            goalLength: 142
        )
        let enc = JSONEncoder()
        let data = try enc.encode(q)
        let dec = JSONDecoder()
        let q2 = try dec.decode(PreflightQuery.self, from: data)
        XCTAssertEqual(q2.repoKey, q.repoKey)
        XCTAssertEqual(q2.agent, q.agent)
        XCTAssertEqual(q2.model, q.model)
        XCTAssertEqual(q2.effort, q.effort)
        XCTAssertEqual(q2.goalLength, q.goalLength)
    }

    func test_preflight_query_handles_nil_effort() throws {
        let q = PreflightQuery(
            repoKey: "/repo", agent: .codex, model: "gpt-5.5",
            effort: nil, goalLength: 0
        )
        let data = try JSONEncoder().encode(q)
        let q2 = try JSONDecoder().decode(PreflightQuery.self, from: data)
        XCTAssertNil(q2.effort)
        XCTAssertEqual(q2.goalLength, 0)
    }

    func test_preflight_response_with_full_data() throws {
        let r = PreflightResponse(
            estimatedCostUSD: 0.43,
            weeklyCapPct: 0.28,
            wouldCap: false,
            suggestedSwap: nil,
            staleData: false
        )
        let data = try JSONEncoder().encode(r)
        let r2 = try JSONDecoder().decode(PreflightResponse.self, from: data)
        XCTAssertEqual(r2.estimatedCostUSD, 0.43)
        XCTAssertEqual(r2.weeklyCapPct, 0.28)
        XCTAssertFalse(r2.wouldCap)
        XCTAssertNil(r2.suggestedSwap)
        XCTAssertFalse(r2.staleData)
    }

    func test_preflight_response_with_would_cap_and_swap() throws {
        let r = PreflightResponse(
            estimatedCostUSD: 4.87,
            weeklyCapPct: 0.98,
            wouldCap: true,
            suggestedSwap: "claude-sonnet-4-6",
            staleData: false
        )
        let data = try JSONEncoder().encode(r)
        let r2 = try JSONDecoder().decode(PreflightResponse.self, from: data)
        XCTAssertTrue(r2.wouldCap)
        XCTAssertEqual(r2.suggestedSwap, "claude-sonnet-4-6")
    }

    func test_preflight_response_with_no_history() throws {
        // New repo, no past usage — daemon returns nil estimates so the
        // UI can render "No history yet".
        let r = PreflightResponse(
            estimatedCostUSD: nil,
            weeklyCapPct: nil,
            wouldCap: false,
            suggestedSwap: nil,
            staleData: false
        )
        let data = try JSONEncoder().encode(r)
        let r2 = try JSONDecoder().decode(PreflightResponse.self, from: data)
        XCTAssertNil(r2.estimatedCostUSD)
        XCTAssertNil(r2.weeklyCapPct)
        XCTAssertFalse(r2.wouldCap)
    }

    func test_preflight_response_stale_flag() throws {
        // staleData true → snapshot older than 1hr; iOS shows a footer
        // hint.
        let r = PreflightResponse(
            estimatedCostUSD: 0.10,
            weeklyCapPct: 0.05,
            wouldCap: false,
            suggestedSwap: nil,
            staleData: true
        )
        let data = try JSONEncoder().encode(r)
        let r2 = try JSONDecoder().decode(PreflightResponse.self, from: data)
        XCTAssertTrue(r2.staleData)
    }
}
