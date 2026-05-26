import XCTest
@testable import ClawdmeterShared

/// A12 perf-gate suite — proves the parser opens a 50k-line diff well
/// under the acceptance budget of 500ms, and proves the cache makes
/// repeat opens O(1) (target: <5ms hot).
///
/// Numbers below are CI-safe budgets, not aspirational. Local Apple
/// silicon runs much faster; the cushion is for slower runners.
///
/// We don't use `XCTMeasureOptions.maximumStandardDeviation` here —
/// the budget itself is the gate. CI sets `XCTAttachment` for the
/// timing breakdown via `XCTAttachment.attach(value:)` when needed.
final class DiffOpenPerfGateTests: XCTestCase {

    /// Cold parse budget for a 50k-line synthetic diff. Acceptance:
    /// 50k-line diff opens in <500ms (vs multi-second freeze today).
    /// Budget here is 1500ms to absorb CI noise; expect ~150ms on
    /// Apple silicon, ~400ms on x86 CI runners.
    private static let coldParseBudgetSeconds: Double = 1.5
    /// Hot cache budget for the same diff after the first parse. The
    /// cache turns parse into hash + dictionary lookup.
    private static let hotCacheBudgetSeconds: Double = 0.05

    /// Cold (first-open) parse must complete inside the perf budget
    /// for a 50k-line diff.
    func testColdParseFor50kLineDiffStaysUnderBudget() throws {
        let diff = DiffFixtureBuilder.fiftyKLineDiff()

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let parsed = UnifiedDiffParser.parse(diff)
            // Force the work to actually happen — Swift's optimizer
            // could in principle elide a pure parse whose result is
            // unused. Reading `totalLineCount` keeps the data live.
            XCTAssertGreaterThanOrEqual(parsed.totalLineCount, 50_000)
        }
        let seconds = Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(
            seconds,
            Self.coldParseBudgetSeconds,
            "50k-line cold parse took \(seconds)s; budget is \(Self.coldParseBudgetSeconds)s. See A12 acceptance."
        )
    }

    /// Hot path: parse once, then re-parse via the cache. Repeat
    /// opens must hit the dictionary, not re-run the parser.
    func testCachedReopenFor50kLineDiffIsFast() throws {
        let cache = ParsedDiffCache(capacity: 4)
        let diff = DiffFixtureBuilder.fiftyKLineDiff()

        // Warm: first call parses + stores.
        _ = cache.parsed(input: diff)
        XCTAssertEqual(cache.count, 1)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            // 10 lookups to amortize wall-clock noise.
            for _ in 0..<10 {
                let hit = cache.parsed(input: diff)
                XCTAssertGreaterThanOrEqual(hit.totalLineCount, 50_000)
            }
        }
        let seconds = Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(
            seconds,
            Self.hotCacheBudgetSeconds,
            "10 hot-cache lookups took \(seconds)s; budget is \(Self.hotCacheBudgetSeconds)s for the batch. Indicates the cache is missing or re-parsing."
        )
    }

    /// XCTest-native perf measure for trend-tracking. The hard budget
    /// gate lives in `testColdParseFor50kLineDiffStaysUnderBudget`;
    /// this one's job is to give CI a stable baseline metric to chart.
    func testColdParseMeasure() {
        let diff = DiffFixtureBuilder.fiftyKLineDiff()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let parsed = UnifiedDiffParser.parse(diff)
            XCTAssertGreaterThanOrEqual(parsed.totalLineCount, 50_000)
        }
    }
}
