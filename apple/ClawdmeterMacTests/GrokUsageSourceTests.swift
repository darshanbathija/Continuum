import XCTest
@testable import Clawdmeter

final class GrokUsageSourceTests: XCTestCase {
    func test_parseUsageShow_mapsCreditsUsedIntoUsageData() throws {
        let now = Date(timeIntervalSince1970: 1_780_701_600) // 2026-06-06 00:00:00 UTC
        let output = """
        \u{1B}[2KCredits used: 14%
        Resets: Jun 30, 16:00 PT
        Pay as you go: disabled
        """

        let usage = try GrokUsageSource.parseUsageShow(output, now: now)

        XCTAssertEqual(usage.sessionPct, 14)
        XCTAssertEqual(usage.weeklyPct, 14)
        XCTAssertEqual(usage.status, .allowed)
        XCTAssertGreaterThan(usage.sessionResetMins, 0)
        XCTAssertEqual(usage.sessionEpoch, usage.weeklyEpoch)
    }

    func test_parseUsageShow_capsPercentAndMarksLimitedAtFullUsage() throws {
        let now = Date(timeIntervalSince1970: 1_780_701_600)
        let output = """
        Credits used: 143%
        Resets: Jun 30, 16:00 PT
        """

        let usage = try GrokUsageSource.parseUsageShow(output, now: now)

        XCTAssertEqual(usage.sessionPct, 100)
        XCTAssertEqual(usage.weeklyPct, 100)
        XCTAssertEqual(usage.status, .limited)
    }
}
