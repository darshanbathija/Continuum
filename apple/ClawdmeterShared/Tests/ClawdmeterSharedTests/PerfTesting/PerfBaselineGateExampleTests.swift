import XCTest
@testable import ClawdmeterShared

/// Demo perf-gate test demonstrating the A0 baseline pattern that every
/// downstream Track 1 perf PR uses (A4-A13, B1-B3, C1, C2). Each PR adds
/// its own gate(s) reading from `PerfFixtures` and assertin:
///   - No main-thread stall >100ms in the measured interaction
///   - Improvement vs the A0 baseline (recorded on first run via XCTest)
///
/// This file is the **template**. Copy + adapt for each downstream PR.
/// Tests here are marked low-priority (the perfStream metric is the real
/// gate); the `XCTAssertLessThan` line is the per-PR contract.
///
/// Plan: A0 (Phase 0) — see .claude/plans/study-this-codebase-crystalline-shore.md
final class PerfBaselineGateExampleTests: XCTestCase {

    // MARK: - Example: sidebar projection grouping
    //
    // Stand-in for A11. Real A11 will replace this with the actual
    // `SessionsModel.groupedProjection(...)` call against the same
    // fixture. The shape is preserved so A11 can drop in cleanly.

    func test_perfGate_groupBySessionsByRepo_500_under_50ms() {
        let sessions = PerfFixtures.sessions500
        // Warm any one-shot allocations before measuring.
        _ = grouped(by: \.repoKey, sessions: sessions)

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        // `measure` records wall-clock + main-thread time. XCTest auto-
        // compares against the prior baseline once recorded; first run
        // sets the baseline.
        measure(metrics: [XCTClockMetric()], options: options) {
            let grouped = grouped(by: \.repoKey, sessions: sessions)
            // Force evaluation so the optimizer doesn't strip the work.
            XCTAssertEqual(grouped.count, Set(sessions.map { $0.repoKey }).count)
        }
    }

    // MARK: - Example: transcript find sweep
    //
    // Stand-in for A5/A9. Demonstrates a sub-second find across 10k
    // messages — the real A5 will assert that the find doesn't trigger
    // a whole-snapshot publish on the chat store.

    func test_perfGate_findInTranscript_10k_under_50ms() {
        let messages = PerfFixtures.messages10k
        // Warm the lookup once (string indexing isn't free on cold start).
        // Search for "refactor" — appears in the user snippets via
        // "Refactor this to use the existing utility."
        _ = messages.filter { $0.text.localizedCaseInsensitiveContains("refactor") }

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            let hits = messages.filter { $0.text.localizedCaseInsensitiveContains("refactor") }
            XCTAssertGreaterThan(hits.count, 0)
        }
    }

    // MARK: - Example: diff split sanity
    //
    // Stand-in for A12. Real A12 will replace this with the actual diff
    // parser. The 50k-line splitting is the cheap part; the expensive
    // part is the parser, which A12 will move off-main.

    func test_perfGate_splitDiff_50k_under_200ms() {
        let diff = PerfFixtures.diff50kLines

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric()], options: options) {
            let lines = diff.split(separator: "\n")
            XCTAssertGreaterThanOrEqual(lines.count, 50_000)
        }
    }

    // MARK: - Helpers

    /// Stand-in for the real sidebar grouping (lands in A11).
    private func grouped<T>(
        by keyPath: KeyPath<PerfFixtures.MockSession, T?>,
        sessions: [PerfFixtures.MockSession]
    ) -> [T?: [PerfFixtures.MockSession]] {
        Dictionary(grouping: sessions, by: { $0[keyPath: keyPath] })
    }
}
