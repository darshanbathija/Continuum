import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import ClawdmeterShared

/// Guards the DESIGN.md motion contract the Code-tab revamp depends on: the new
/// interaction tokens exist with their spec'd durations, and every repeating /
/// infinite animation collapses to a static state (nil) under Reduce Motion.
///
/// Before this there were ZERO reduce-motion tests in the suite, yet DESIGN.md
/// §Motion mandates "honor accessibilityReduceMotion everywhere; collapse
/// infinite loops to one state change." This locks that in.
final class MotionTokensTests: XCTestCase {

    func test_interactionTokens_matchDesignSpec() {
        XCTAssertEqual(SessionsV2Theme.AnimationDuration.interaction, 0.12, accuracy: 0.0001)
        XCTAssertEqual(SessionsV2Theme.AnimationDuration.segmented, 0.16, accuracy: 0.0001)
        XCTAssertEqual(SessionsV2Theme.AnimationDuration.composerPulse, 1.8, accuracy: 0.0001)
        XCTAssertEqual(SessionsV2Theme.AnimationDuration.spinner, 0.9, accuracy: 0.0001)
        // `instant` is the Reduce-Motion collapse target and must stay ~0.
        XCTAssertLessThanOrEqual(SessionsV2Theme.AnimationDuration.instant, 0.03)
    }

    #if canImport(SwiftUI)
    func test_composerRimPulse_isStaticUnderReduceMotion() {
        // DESIGN.md: the composer rim must NOT breathe under Reduce Motion. The
        // helper returns nil so the caller renders a static rim.
        XCTAssertNil(SessionsV2Theme.composerRimPulse(reduceMotion: true))
        XCTAssertNotNil(SessionsV2Theme.composerRimPulse(reduceMotion: false))
    }

    func test_perAgentPulse_isStaticUnderReduceMotion() {
        XCTAssertNil(SessionsV2Theme.pulseAnimation(for: .claude, reduceMotion: true))
        XCTAssertNil(SessionsV2Theme.pulseAnimation(for: .codex, reduceMotion: true))
        XCTAssertNotNil(SessionsV2Theme.pulseAnimation(for: .claude, reduceMotion: false))
    }

    func test_pressAndSegmentedAndSwitch_resolveOnBothBranches() {
        // These return non-optional Animations; we can't introspect their
        // duration, but they must at least resolve on both Reduce-Motion
        // branches (a crash/precondition here would surface a token regression).
        _ = SessionsV2Theme.pressAnimation(reduceMotion: true)
        _ = SessionsV2Theme.pressAnimation(reduceMotion: false)
        _ = SessionsV2Theme.segmentedSelection(reduceMotion: true)
        _ = SessionsV2Theme.segmentedSelection(reduceMotion: false)
        _ = SessionsV2Theme.switchThumb(reduceMotion: true)
        _ = SessionsV2Theme.switchThumb(reduceMotion: false)
    }
    #endif
}
