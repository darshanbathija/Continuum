import XCTest
@testable import ClawdmeterShared

/// E3 #4 regression test for `UsageHistorySnapshot.claude` / `.codex` /
/// `.gemini` compat getters.
///
/// The old API had `claude` and `codex` as stored properties. Plan
/// Section 1 (`byProvider: [Provider: ProviderTotals]` refactor) moved
/// them to a dict + retained the same-named computed properties for
/// back-compat with view code that calls `snapshot.claude.window(.past30d)`
/// throughout the analytics surface.
///
/// The failure mode this test guards: a future "cleanup" that drops a
/// compat getter, or a typo that crashes when the key is absent. View
/// code reads `snapshot.claude` unconditionally; if it threw on missing
/// keys, the very first launch (empty cache) would render a Swift crash.
final class UsageHistorySnapshotCompatGetterTests: XCTestCase {

    func test_emptySnapshot_compatGettersReturnEmpty_notCrash() {
        let snapshot = UsageHistorySnapshot.empty
        XCTAssertEqual(snapshot.claude, .empty, ".claude on empty snapshot must return .empty (not crash)")
        XCTAssertEqual(snapshot.codex,  .empty)
        XCTAssertEqual(snapshot.gemini, .empty)
    }

    func test_partialSnapshot_absentProvider_returnsEmpty() {
        let totals: ProviderTotals = .empty
        let snapshot = UsageHistorySnapshot(
            byProvider: [.claude: totals],
            computedAt: Date(),
            sequenceNumber: 1,
            sessionCount: 0,
            unpricedModelTokens: [:]
        )
        XCTAssertEqual(snapshot.claude, totals, "Present key returns its value")
        XCTAssertEqual(snapshot.codex,  .empty, "Absent codex returns .empty")
        XCTAssertEqual(snapshot.gemini, .empty, "Absent gemini returns .empty")
    }

    func test_totalsForProviderHelper_mirrorsCompatGetters() {
        let snapshot = UsageHistorySnapshot.empty
        XCTAssertEqual(snapshot.totals(for: .claude), snapshot.claude)
        XCTAssertEqual(snapshot.totals(for: .codex),  snapshot.codex)
        XCTAssertEqual(snapshot.totals(for: .gemini), snapshot.gemini)
    }

    /// Round-trip: a fresh `byProvider` snapshot encodes + decodes; the
    /// dropped-key safety remains. Specific legacy-v8-string-shape decode
    /// covered by `UsageHistoryLoader` integration tests.
    func test_roundTrip_preservesAbsentProviderSafety() throws {
        let original = UsageHistorySnapshot(
            byProvider: [.claude: .empty],
            computedAt: Date(timeIntervalSince1970: 1715000000),
            sequenceNumber: 1,
            sessionCount: 0,
            unpricedModelTokens: [:]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let round = try decoder.decode(UsageHistorySnapshot.self, from: data)
        XCTAssertEqual(round.claude, .empty)
        XCTAssertEqual(round.codex,  .empty, "Absent provider key in encoded dict must decode-to .empty, not crash")
        XCTAssertEqual(round.gemini, .empty)
    }
}
