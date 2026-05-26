import XCTest
@testable import ClawdmeterShared

/// Tests for the `BodyInvalidationCounter` utility — the measurement
/// primitive every A6 + A8 + A9 invalidation gate is built on.
///
/// Plan: A6 (Phase 2) — see .claude/plans/study-this-codebase-crystalline-shore.md
@MainActor
final class BodyInvalidationCounterTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        BodyInvalidationCounter.resetAll()
        BodyInvalidationCounter.enabled = true
    }

    override func tearDown() async throws {
        BodyInvalidationCounter.enabled = false
        BodyInvalidationCounter.resetAll()
        try await super.tearDown()
    }

    // MARK: - Core counter behavior

    func test_bumpIncrementsCount() {
        XCTAssertEqual(BodyInvalidationCounter.count(for: "X"), 0)
        BodyInvalidationCounter.bump("X")
        XCTAssertEqual(BodyInvalidationCounter.count(for: "X"), 1)
        BodyInvalidationCounter.bump("X")
        BodyInvalidationCounter.bump("X")
        XCTAssertEqual(BodyInvalidationCounter.count(for: "X"), 3)
    }

    func test_countsAreKeyedSeparately() {
        BodyInvalidationCounter.bump("Sidebar")
        BodyInvalidationCounter.bump("Sidebar")
        BodyInvalidationCounter.bump("Transcript")
        XCTAssertEqual(BodyInvalidationCounter.count(for: "Sidebar"), 2)
        XCTAssertEqual(BodyInvalidationCounter.count(for: "Transcript"), 1)
        XCTAssertEqual(BodyInvalidationCounter.count(for: "Composer"), 0)
    }

    func test_disabledBumpIsNoOp() {
        BodyInvalidationCounter.enabled = false
        BodyInvalidationCounter.bump("X")
        BodyInvalidationCounter.bump("X")
        XCTAssertEqual(BodyInvalidationCounter.count(for: "X"), 0)
    }

    func test_resetAllZeroes() {
        BodyInvalidationCounter.bump("A")
        BodyInvalidationCounter.bump("B")
        BodyInvalidationCounter.resetAll()
        XCTAssertEqual(BodyInvalidationCounter.count(for: "A"), 0)
        XCTAssertEqual(BodyInvalidationCounter.count(for: "B"), 0)
    }

    func test_resetSingleLeavesOthers() {
        BodyInvalidationCounter.bump("A")
        BodyInvalidationCounter.bump("B")
        BodyInvalidationCounter.reset("A")
        XCTAssertEqual(BodyInvalidationCounter.count(for: "A"), 0)
        XCTAssertEqual(BodyInvalidationCounter.count(for: "B"), 1)
    }

    func test_snapshotReturnsAllCounts() {
        BodyInvalidationCounter.bump("Sidebar")
        BodyInvalidationCounter.bump("Sidebar")
        BodyInvalidationCounter.bump("Transcript")
        let snap = BodyInvalidationCounter.snapshot()
        XCTAssertEqual(snap["Sidebar"], 2)
        XCTAssertEqual(snap["Transcript"], 1)
        XCTAssertEqual(snap.count, 2)
    }

    // MARK: - A6 acceptance pattern
    //
    // Demonstrates the invalidation-drop assertion shape downstream A6
    // follow-up PRs (and A8/A9) will use. The "view body" is faked here
    // as a closure — the real wiring is one `BodyInvalidationCounter.bump(_:)`
    // call in each `View.body` we want to instrument.

    func test_acceptancePattern_independentSlicesDoNotCrossInvalidate() {
        // Setup: two "sub-views" sharing nothing but the counter API.
        // SidebarSubView is invalidated when SidebarState changes.
        // TranscriptSubView is invalidated when TranscriptState changes.
        // After the A6 split they have NO common observed state — so
        // bumping one must not bump the other.
        let sidebarBody: () -> Void = { BodyInvalidationCounter.bump("SidebarSubView") }
        let transcriptBody: () -> Void = { BodyInvalidationCounter.bump("TranscriptSubView") }

        // Initial render.
        sidebarBody()
        transcriptBody()
        XCTAssertEqual(BodyInvalidationCounter.count(for: "SidebarSubView"), 1)
        XCTAssertEqual(BodyInvalidationCounter.count(for: "TranscriptSubView"), 1)

        let sidebarBefore = BodyInvalidationCounter.count(for: "SidebarSubView")
        let transcriptBefore = BodyInvalidationCounter.count(for: "TranscriptSubView")

        // Simulate the user typing in the sidebar search — SwiftUI
        // re-renders SidebarSubView. TranscriptSubView must NOT re-render
        // (that's the whole point of the split).
        for _ in 0..<10 { sidebarBody() }

        XCTAssertGreaterThan(
            BodyInvalidationCounter.count(for: "SidebarSubView"),
            sidebarBefore,
            "Sidebar should re-render when its own state changes"
        )
        XCTAssertEqual(
            BodyInvalidationCounter.count(for: "TranscriptSubView"),
            transcriptBefore,
            "A6 acceptance: TranscriptSubView must not re-render when sidebar state changes"
        )
    }

    func test_acceptancePattern_invalidationDropMeasurement() {
        // Demonstrates the ≥50% drop assertion shape. BEFORE the split,
        // a parent body change cascades to every child; AFTER the split,
        // only the parent re-renders.
        //
        // We simulate by counting how many times the "transcript body"
        // ran across 20 parent-body invalidations in each regime.

        // BEFORE: every parent invalidation cascades.
        for _ in 0..<20 { BodyInvalidationCounter.bump("TranscriptBefore") }
        let bodiesBeforeSplit = BodyInvalidationCounter.count(for: "TranscriptBefore")

        // AFTER: transcript owns its own state; parent body changes
        // never reach it. Only its own state mutations cause body calls.
        // For this demo, simulate 2 transcript-state-only mutations.
        for _ in 0..<2 { BodyInvalidationCounter.bump("TranscriptAfter") }
        let bodiesAfterSplit = BodyInvalidationCounter.count(for: "TranscriptAfter")

        let drop = 1.0 - Double(bodiesAfterSplit) / Double(bodiesBeforeSplit)
        XCTAssertGreaterThanOrEqual(
            drop, 0.5,
            "A6 acceptance gate: ≥50% body-invalidation drop vs A0 baseline. Got drop=\(drop)"
        )
    }
}
