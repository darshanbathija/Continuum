import AppKit
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

    func test_cursorSplitLabelCachesDistinctAutoAndApiValues() {
        MenuBarGaugeView.resetCachesForTesting()

        let base = UsageData(
            sessionPct: 48,
            sessionResetMins: 120,
            sessionEpoch: 1_000,
            weeklyPct: 48,
            weeklyResetMins: 120,
            weeklyEpoch: 1_000,
            status: .allowed,
            representativeClaim: .unknown,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let first = UsageData(
            sessionPct: 48,
            sessionResetMins: 120,
            sessionEpoch: 1_000,
            weeklyPct: 48,
            weeklyResetMins: 120,
            weeklyEpoch: 1_000,
            status: .allowed,
            representativeClaim: .unknown,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            cursorQuota: UsageData.CursorQuota(
                totalPct: 48,
                autoPct: 25,
                apiPct: 95,
                resetMins: 120,
                resetEpoch: 1_000
            )
        )
        let second = UsageData(
            sessionPct: 48,
            sessionResetMins: 120,
            sessionEpoch: 1_000,
            weeklyPct: 48,
            weeklyResetMins: 120,
            weeklyEpoch: 1_000,
            status: .allowed,
            representativeClaim: .unknown,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            cursorQuota: UsageData.CursorQuota(
                totalPct: 48,
                autoPct: 30,
                apiPct: 95,
                resetMins: 120,
                resetEpoch: 1_000
            )
        )

        let firstImage = MenuBarGaugeView.renderLabel(
            for: first,
            assetName: "CursorLogo",
            template: true,
            hasWeekly: false
        )
        let firstCachedAgain = MenuBarGaugeView.renderLabel(
            for: first,
            assetName: "CursorLogo",
            template: true,
            hasWeekly: false
        )
        let secondImage = MenuBarGaugeView.renderLabel(
            for: second,
            assetName: "CursorLogo",
            template: true,
            hasWeekly: false
        )
        let nonCursorImage = MenuBarGaugeView.renderLabel(
            for: base,
            assetName: "CursorLogo",
            template: true,
            hasWeekly: false
        )

        XCTAssertTrue(firstImage === firstCachedAgain)
        XCTAssertFalse(firstImage === secondImage)
        XCTAssertFalse(firstImage === nonCursorImage)
    }

    func test_providerBadgeImagePreservesAspectRatio() throws {
        MenuBarGaugeView.resetCachesForTesting()

        let badge = MenuBarGaugeView.providerBadgeImage(
            assetName: "CursorLogo",
            size: 18,
            template: true
        )
        let bounds = try XCTUnwrap(alphaBounds(of: badge))
        let aspect = bounds.width / bounds.height
        // CursorLogo.svg viewBox is 466.73 × 532.09 (taller than wide).
        XCTAssertEqual(aspect, 466.73 / 532.09, accuracy: 0.05)
    }

    private func alphaBounds(of image: NSImage) -> CGRect? {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var found = false

        for y in 0..<height {
            for x in 0..<width {
                guard bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.01 else { continue }
                found = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard found else { return nil }
        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )
    }
}
