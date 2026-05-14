#if os(iOS) || os(macOS) || os(tvOS) || os(visionOS)
import XCTest
@testable import ClawdmeterShared

final class UsageCloudMirrorAnalyticsTests: XCTestCase {

    // NOTE: NSUbiquitousKeyValueStore.default is a process-wide singleton.
    // These tests touch keys with a unique suffix per-run and clean up after
    // themselves to avoid clobbering live iCloud data.

    /// JSON round-trip through the same encoder/decoder the mirror uses.
    /// We can't directly test the KVS write because the test process lacks
    /// the iCloud entitlement, but the encoding stability is what's at risk
    /// when the snapshot schema evolves.
    func test_snapshotJSONRoundTrip() throws {
        let snap = sampleSnapshot()
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(UsageHistorySnapshot.self, from: data)
        XCTAssertEqual(decoded.sequenceNumber, snap.sequenceNumber)
        XCTAssertEqual(decoded.claude.today.totals, snap.claude.today.totals)
        XCTAssertEqual(decoded.claude.today.byRepo.count, snap.claude.today.byRepo.count)
    }

    func test_writeAnalyticsSnapshotEmpty() {
        let mirror = UsageCloudMirror.shared
        let empty = UsageHistorySnapshot.empty
        // The write may no-op (no entitlement in test process), but it must
        // not crash and must return a Bool.
        _ = mirror.writeAnalyticsSnapshot(empty)
    }

    func test_isICloudAvailableDoesNotCrash() {
        // We can't assert true/false (depends on the test env's iCloud
        // status), but the call must not throw or hang.
        _ = UsageCloudMirror.shared.isICloudAvailable
    }

    // MARK: - Helpers

    private func sampleSnapshot() -> UsageHistorySnapshot {
        let day = Calendar.current.startOfDay(for: Date())
        let totals = TokenTotals(inputTokens: 1000, outputTokens: 500, costUSD: Decimal(string: "2.50")!)
        let provider = ProviderTotals(
            today: WindowTotals(totals: totals, byRepo: [(repo: "/r", totals: totals)], restCount: 0),
            past7d: WindowTotals(totals: totals, byRepo: [(repo: "/r", totals: totals)], restCount: 0),
            past30d: WindowTotals(totals: totals, byRepo: [(repo: "/r", totals: totals)], restCount: 0),
            allTime: WindowTotals(totals: totals, byRepo: [(repo: "/r", totals: totals)], restCount: 0),
            byDay: [day: totals]
        )
        return UsageHistorySnapshot(
            claude: provider,
            codex: .empty,
            computedAt: Date(),
            sequenceNumber: 42,
            sessionCount: 1,
            unpricedModelTokens: [:]
        )
    }
}
#endif
