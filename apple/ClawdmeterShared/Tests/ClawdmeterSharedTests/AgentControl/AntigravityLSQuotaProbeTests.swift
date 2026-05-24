#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Fixture-based tests for the v0.26.6 Tier-1 LS-local quota probe.
///
/// The fixture `Fixtures/antigravity-GetUserStatus.bin` is the
/// already-gunzipped body of one real `GetUserStatus` response captured
/// from a live Antigravity 2.0.6 language_server (see
/// `AntigravityLSQuotaProbeIntegrationTests` for the capture rig). Pinning
/// the parse against bytes from the wire means a future LSP schema change
/// (Antigravity 2 renumbering a field, swapping a wire type, etc.) trips
/// CI here instead of silently dropping the Antigravity tile back to 0%.
final class AntigravityLSQuotaProbeTests: XCTestCase {

    /// `now` pinned to the moment of capture so `resets_at` math is stable.
    /// The fixture's `resets_at` epoch = 1779604505 (≈ 2026-05-24 08:34Z); we
    /// pin `now` an hour before so the window is "still active" and we exercise
    /// the .allowed branch.
    private static let pinnedNow = Date(timeIntervalSince1970: 1779_600_000)

    private func loadFixture() throws -> Data {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "antigravity-GetUserStatus", withExtension: "bin") else {
            throw XCTSkip("Fixture antigravity-GetUserStatus.bin not present in test bundle")
        }
        return try Data(contentsOf: url)
    }

    func test_parseGetUserStatus_returnsSnapshotForLiveCapture() throws {
        let bytes = try loadFixture()
        guard let usage = AntigravityLSQuotaProbe.parseGetUserStatus(bytes, now: Self.pinnedNow) else {
            return XCTFail("Parser returned nil for valid fixture")
        }
        // Plan name should land in organizationID slot — captured fixture has "Pro".
        XCTAssertEqual(usage.organizationID, "Pro")
        // Resets_at field on the captured fixture is 1779604505 (2026-05-24 08:34Z).
        XCTAssertEqual(usage.sessionEpoch, 1779604505)
        XCTAssertEqual(usage.weeklyEpoch, 1779604505)
        // pinnedNow is ~1h before resets_at, so the window is still active → .allowed.
        XCTAssertEqual(usage.status, .allowed)
        // Captured fixture: used=500 remaining=100 → 500/600 = 83% session.
        // (If this assertion ever fails because schema interpretation changes,
        // see CHANGELOG v0.26.6 for the field-mapping rationale and re-validate
        // by running CLAWDMETER_PROBE_LS=1 swift test --filter
        // AntigravityLSQuotaProbeIntegrationTests against a live LSP.)
        XCTAssertEqual(usage.sessionPct, 83, "Used/total should compute to 83% on the captured fixture")
        XCTAssertEqual(usage.weeklyPct, 83, "Weekly mirrors session — LSP only exposes one window")
    }

    func test_decompressIfGzip_passesThroughNonGzipInput() {
        let raw = Data([0x08, 0x96, 0x01]) // a bare protobuf varint
        let out = AntigravityLSQuotaProbe.decompressIfGzip(raw)
        XCTAssertEqual(out, raw, "Non-gzip input should be returned unchanged")
    }

    func test_decompressIfGzip_returnsNilOnMalformedGzip() {
        // Magic bytes present but everything after them is junk.
        let bad = Data([0x1f, 0x8b, 0x08, 0x00] + Array(repeating: UInt8(0xff), count: 20))
        let out = AntigravityLSQuotaProbe.decompressIfGzip(bad)
        XCTAssertNil(out, "Malformed gzip should return nil so the caller surfaces the parse failure")
    }

    /// Empty quota = LSP responded but user is not signed in / has no plan.
    /// The probe must return nil so the caller falls through to Tier 2.
    func test_parseGetUserStatus_returnsNilWhenQuotaIsEmpty() {
        // Build a minimal valid proto: field 1 (length-delimited) wrapping
        // field 13 (length-delimited) wrapping nothing.
        let emptyQuota = Data([
            // Outer: field 1, wire-type 2, length 2
            0x0a, 0x02,
            // Inner: field 13, wire-type 2, length 0
            0x6a, 0x00,
        ])
        let usage = AntigravityLSQuotaProbe.parseGetUserStatus(emptyQuota, now: Self.pinnedNow)
        XCTAssertNil(usage, "Empty quota (used=0, remaining=0) should yield nil")
    }
}
#endif
