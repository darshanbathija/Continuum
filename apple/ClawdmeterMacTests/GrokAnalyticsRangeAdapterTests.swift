import XCTest
@testable import Clawdmeter
import ClawdmeterShared

final class GrokAnalyticsRangeAdapterTests: XCTestCase {
    func test_grokProviderFlowsThroughRangeTotalsSeriesReposAndModelTokens() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let repo = "/tmp/continuum-grok-fixture"
        let tokens = TokenTotals(inputTokens: 50, outputTokens: 30, costUSD: Decimal(string: "1.23")!, requestCount: 1)
        let window = WindowTotals(totals: tokens, byRepo: [(repo: repo, totals: tokens)], restCount: 0)
        let grokTotals = ProviderTotals(
            today: window,
            past7d: window,
            past30d: window,
            past90d: window,
            allTime: window,
            byDay: [today: tokens]
        )
        let snapshot = UsageHistorySnapshot(
            byProvider: [.grok: grokTotals],
            computedAt: Date(),
            sequenceNumber: 1,
            sessionCount: 1,
            unpricedModelTokens: ["grok-build": tokens],
            tokensByModel: ["grok-build": tokens],
            byDayByModel: [today: ["grok-build": tokens]]
        )

        let range = AnalyticsRangeAdapter.rangeData(snapshot: snapshot, range: "7d")
        XCTAssertEqual(range.total.k, "$1.23")
        XCTAssertEqual(range.total.all, "$1.23")
        let lastPoint = try XCTUnwrap(range.series.last)
        XCTAssertEqual(lastPoint.k, 1.23, accuracy: 0.0001)
        let firstRepo = try XCTUnwrap(range.repos.first)
        XCTAssertEqual(firstRepo.k, 1.23, accuracy: 0.0001)

        let byModel = AnalyticsRangeAdapter.tokensByModel(snapshot: snapshot, range: "7d")
        XCTAssertEqual(byModel["grok-build"]?.totalTokens, 80)
        XCTAssertEqual(byModel["grok-build"]?.requestCount, 1)
    }
}
