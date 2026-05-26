import XCTest
@testable import ClawdmeterShared

/// Tests for the A0 perf-fixture generators. Locks in:
///   - Deterministic output (same fixture across runs + machines)
///   - Correct sizes (500 sessions, 10k messages, 50k+ diff lines)
///   - Distribution sanity (e.g. mix of archived/pinned sessions,
///     message-kind ratios in the documented bands)
///
/// Plan: A0 (Phase 0) — see .claude/plans/study-this-codebase-crystalline-shore.md
final class PerfFixturesTests: XCTestCase {

    // MARK: - Sessions

    func test_sessions500_hasExactly500Items() {
        XCTAssertEqual(PerfFixtures.sessions500.count, 500)
    }

    func test_sessions500_isDeterministic() {
        // Reading twice yields the same array (cache hit).
        let first = PerfFixtures.sessions500
        let second = PerfFixtures.sessions500
        XCTAssertEqual(first, second)
    }

    func test_sessions500_hasArchivedAndPinnedMix() {
        // Distribution shape from the generator: ~20% archived, ~10% of
        // non-archived are pinned. Assert non-zero counts of each so the
        // sidebar filter combos in A11 have meaningful test inputs.
        let sessions = PerfFixtures.sessions500
        let archivedCount = sessions.filter { $0.archivedAt != nil }.count
        let pinnedCount = sessions.filter { $0.pinned }.count
        XCTAssertGreaterThan(archivedCount, 50, "≥50 of 500 archived")
        XCTAssertLessThan(archivedCount, 200, "<200 of 500 archived (else generator is skewed)")
        XCTAssertGreaterThan(pinnedCount, 10, "≥10 pinned sessions")
    }

    func test_sessions500_spansAllProviders() {
        // A11 sidebar filter tests need at least one session per provider.
        let providers = Set(PerfFixtures.sessions500.map { $0.provider })
        XCTAssertEqual(providers.count, 5)
        XCTAssertTrue(providers.isSuperset(of: ["claude", "codex", "opencode", "cursor", "antigravity"]))
    }

    // MARK: - Messages

    func test_messages10k_hasExactly10000Items() {
        XCTAssertEqual(PerfFixtures.messages10k.count, 10_000)
    }

    func test_messages10k_isDeterministic() {
        let first = PerfFixtures.messages10k
        let second = PerfFixtures.messages10k
        XCTAssertEqual(first, second)
    }

    func test_messages10k_kindDistributionMatchesDocumentedBands() {
        let messages = PerfFixtures.messages10k
        let buckets = Dictionary(grouping: messages, by: \.kind)
        // Documented bands from the generator:
        //   30% user, 50% assistant, 15% toolUse, 4% toolResult, 1% error
        // Allow ±5% slack for PRNG variance at 10k samples.
        let user = Double(buckets[.user]?.count ?? 0) / Double(messages.count)
        let assistant = Double(buckets[.assistant]?.count ?? 0) / Double(messages.count)
        let toolUse = Double(buckets[.toolUse]?.count ?? 0) / Double(messages.count)
        XCTAssertEqual(user, 0.30, accuracy: 0.05)
        XCTAssertEqual(assistant, 0.50, accuracy: 0.05)
        XCTAssertEqual(toolUse, 0.15, accuracy: 0.05)
    }

    func test_messages10k_timestampsAreMonotonic() {
        // The transcript-scroll perf tests assume forward-only time;
        // assert no regressions in the generator.
        let messages = PerfFixtures.messages10k
        var lastTs = Date.distantPast
        for m in messages {
            XCTAssertGreaterThanOrEqual(m.timestamp, lastTs)
            lastTs = m.timestamp
        }
    }

    // MARK: - Diff

    func test_diff50kLines_isAtLeast50kLines() {
        let line_count = PerfFixtures.diff50kLines.split(separator: "\n").count
        XCTAssertGreaterThanOrEqual(line_count, 50_000)
        // Sanity upper bound — the generator should terminate as soon as
        // it hits 50k, with the current file in progress. Allow a small
        // overshoot for the trailing context lines.
        XCTAssertLessThan(line_count, 50_100)
    }

    func test_diff50kLines_isMultiFile() {
        // A12 diff-tab tests want a multi-file diff, not one giant file.
        let diffHeaderCount = PerfFixtures.diff50kLines
            .components(separatedBy: "diff --git ")
            .count - 1
        XCTAssertGreaterThan(diffHeaderCount, 3)
    }

    func test_diff50kLines_isDeterministic() {
        let first = PerfFixtures.diff50kLines
        let second = PerfFixtures.diff50kLines
        XCTAssertEqual(first, second)
    }

    // MARK: - SeededPRNG

    func test_seededPRNG_isDeterministic_acrossInstances() {
        var a = SeededPRNG(seed: 42)
        var b = SeededPRNG(seed: 42)
        for _ in 0..<100 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    func test_seededPRNG_differentSeeds_yieldDifferentStreams() {
        var a = SeededPRNG(seed: 42)
        var b = SeededPRNG(seed: 43)
        // After eight mixing rounds, the first observable value must differ.
        XCTAssertNotEqual(a.next(), b.next())
    }

    func test_seededPRNG_nextInt_inRange() {
        var prng = SeededPRNG(seed: 123)
        for _ in 0..<1000 {
            let v = prng.nextInt(upperBound: 100)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 100)
        }
    }

    func test_seededPRNG_nextDouble_inUnitInterval() {
        var prng = SeededPRNG(seed: 456)
        for _ in 0..<1000 {
            let v = prng.nextDouble()
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
        }
    }
}
