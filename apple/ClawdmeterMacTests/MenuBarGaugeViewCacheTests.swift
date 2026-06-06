import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class MenuBarGaugeViewCacheTests: XCTestCase {

    override func tearDown() {
        MenuBarGaugeView.resetCachesForTesting()
        super.tearDown()
    }

    func test_labelCacheIsBounded() {
        MenuBarGaugeView.resetCachesForTesting()

        for i in 0..<400 {
            let usage = UsageData(
                sessionPct: i % 101,
                sessionResetMins: i,
                sessionEpoch: 1_000 + i,
                weeklyPct: (i * 3) % 101,
                weeklyResetMins: 10_000 + i,
                weeklyEpoch: 20_000 + i,
                status: .allowed,
                representativeClaim: .fiveHour,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(i))
            )
            _ = MenuBarGaugeView.renderLabel(
                for: usage,
                assetName: "ClaudeLogo",
                template: true,
                hasWeekly: true
            )
        }

        XCTAssertLessThanOrEqual(MenuBarGaugeView.labelCacheCountForTesting, 240)
    }

    func test_imageCacheIsBounded() {
        MenuBarGaugeView.resetCachesForTesting()

        for i in 0..<260 {
            _ = MenuBarGaugeView.providerBadgeImage(
                assetName: "MissingAsset\(i)",
                size: CGFloat(12 + i),
                template: i.isMultiple(of: 2)
            )
        }

        XCTAssertLessThanOrEqual(MenuBarGaugeView.imageCacheCountForTesting, 160)
    }
}
