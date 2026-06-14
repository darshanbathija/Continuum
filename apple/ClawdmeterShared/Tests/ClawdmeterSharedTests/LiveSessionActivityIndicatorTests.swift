import XCTest

#if canImport(SwiftUI)
@testable import ClawdmeterShared

final class LiveSessionActivityIndicatorTests: XCTestCase {
    func test_streamingRecentEventShowsTimeline() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(LiveSessionActivityIndicator.shouldShowTimeline(
            lastEventAt: now.addingTimeInterval(-1),
            activityWindow: 30,
            now: now,
            turnState: .streaming
        ))
    }

    func test_completedRecentEventHidesTimelineImmediately() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(LiveSessionActivityIndicator.shouldShowTimeline(
            lastEventAt: now.addingTimeInterval(-1),
            activityWindow: 30,
            now: now,
            turnState: .completed
        ))
    }

    func test_nonStreamingStatesHideTimelineEvenInsideActivityWindow() {
        let now = Date(timeIntervalSince1970: 100)
        let recent = now.addingTimeInterval(-1)

        XCTAssertFalse(LiveSessionActivityIndicator.shouldShowTimeline(
            lastEventAt: recent,
            activityWindow: 30,
            now: now,
            turnState: .idle
        ))
        XCTAssertFalse(LiveSessionActivityIndicator.shouldShowTimeline(
            lastEventAt: recent,
            activityWindow: 30,
            now: now,
            turnState: .interrupted
        ))
    }

    func test_legacyUngatedModeStillUsesActivityWindow() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(LiveSessionActivityIndicator.shouldShowTimeline(
            lastEventAt: now.addingTimeInterval(-1),
            activityWindow: 30,
            now: now,
            turnState: nil
        ))
        XCTAssertFalse(LiveSessionActivityIndicator.shouldShowTimeline(
            lastEventAt: now.addingTimeInterval(-31),
            activityWindow: 30,
            now: now,
            turnState: nil
        ))
    }
}
#endif
