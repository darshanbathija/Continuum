import XCTest
@testable import ClawdmeterShared

final class TokensByModelLeaderboardTests: XCTestCase {
    func testFmtCompactCounts() {
        XCTAssertEqual(TokensByModelLeaderboard.fmt(500), "500")
        XCTAssertEqual(TokensByModelLeaderboard.fmt(1_200), "1.2K")
        XCTAssertEqual(TokensByModelLeaderboard.fmt(824_800_000), "824.8M")
        XCTAssertEqual(TokensByModelLeaderboard.fmt(23_600_000_000), "23.6B")
    }

    func testSharePctFormatting() {
        XCTAssertEqual(TokensByModelLeaderboard.sharePct(23_600_000_000, total: 42_800_000_000), "55%")
        XCTAssertEqual(TokensByModelLeaderboard.sharePct(128_800_000, total: 42_800_000_000), "0.3%")
        XCTAssertEqual(TokensByModelLeaderboard.sharePct(34_200_000, total: 42_800_000_000), "<0.1%")
    }

    func testSubtitleCopy() {
        let subtitle = TokensByModelLeaderboard.subtitle(total: 42_800_000_000, range: "all", isEmpty: false)
        XCTAssertEqual(subtitle, "42.8B tokens all-time · ranked across all models")
    }

    func testRankedEntriesSortDescending() {
        let byModel: [String: TokenTotals] = [
            "gpt-5": TokenTotals(outputTokens: 897_600_000, requestCount: 1),
            "claude-opus-4-7": TokenTotals(outputTokens: 23_600_000_000, requestCount: 1),
        ]
        let ranked = TokensByModelLeaderboard.rankedEntries(from: byModel)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].id, "claude-opus-4-7")
        XCTAssertEqual(ranked[1].id, "gpt-5")
    }
}
