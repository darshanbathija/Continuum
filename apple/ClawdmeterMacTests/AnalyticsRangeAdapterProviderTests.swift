import XCTest
import ClawdmeterShared
@testable import Clawdmeter

final class AnalyticsRangeAdapterProviderTests: XCTestCase {
    func test_rangeData_includesCursorCostInTotalsSeriesAndRepos() {
        let today = Calendar.current.startOfDay(for: Date())
        let cursorCost = Decimal(string: "3.25")!
        let cursorTotals = TokenTotals(inputTokens: 100, outputTokens: 50, costUSD: cursorCost)
        let window = WindowTotals(
            totals: cursorTotals,
            byRepo: [(repo: "/Users/dev/cursor-repo", totals: cursorTotals)],
            restCount: 0
        )
        let provider = ProviderTotals(
            today: window,
            past7d: window,
            past30d: window,
            past90d: window,
            allTime: window,
            byDay: [today: cursorTotals]
        )
        let snapshot = UsageHistorySnapshot(
            byProvider: [.cursor: provider],
            computedAt: Date(),
            sequenceNumber: 1,
            sessionCount: 1,
            unpricedModelTokens: [:]
        )

        let data = AnalyticsRangeAdapter.rangeData(snapshot: snapshot, range: "today")

        XCTAssertEqual(data.series.first?.r ?? 0, 3.25, accuracy: 0.001)
        XCTAssertEqual(data.total.r, "$3.25")
        XCTAssertEqual(data.total.all, "$3.25")
        XCTAssertEqual(data.repos.first?.r ?? 0, 3.25, accuracy: 0.001)
        XCTAssertEqual(data.repos.first?.c ?? -1, 0, accuracy: 0.001)
    }
}
