import XCTest
@testable import ClawdmeterShared

/// F1d-wire parity tests: prove the `CursorAdapter`-routed analytics
/// path produces the same `UsageData` value as the polled-direct path
/// for every representative Cursor period snapshot.
///
/// **Why this matters.** The F1d-wire PR introduces the
/// `FeatureFlags.useCursorAdapter` strangler-fig flag. With the flag
/// OFF, the analytics consumer uses the polled `UsageData` directly.
/// With the flag ON, it calls
/// `CursorAdapterUsageBridge.project(usage:sessionId:sequenceNumber:)`,
/// which routes through `CursorAdapter.translate(...)` → canonical
/// `.sessionStarted` event → reprojected back into `UsageData`. Both
/// paths must return identical `UsageData` field-by-field. This suite
/// is the authoritative parity contract — failing it means the wire
/// has silently changed analytics output.
///
/// **Coverage.** Fixtures mirror every shape `CursorSource.poll()`
/// produces:
///   - Happy-path period (full % + reset + plan badge).
///   - Period without organizationID (free-tier, no badge).
///   - Period at boundary (resets in 0 minutes).
///   - Period with zero session_percent (fresh / unused).
///   - Period in `.notStarted` status (between periods).
///   - Period epoch transitions (sequence cursor resets per period).
///
/// **Plan:** F1d-wire (Phase 1; D23 strangler-fig) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
final class F1dParityTests: XCTestCase {

    private let pinnedNow = Date(timeIntervalSince1970: 1_715_000_000)

    // MARK: - Setup

    /// Helper: project the same `UsageData` through the bridge and
    /// assert field-by-field equality with the polled input. The flag
    /// override is reset after every call so tests can't leak state.
    private func assertParity(
        _ usage: UsageData,
        sessionId: String = "cursor-period-1",
        sequenceNumber: UInt64 = 0,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let projected = CursorAdapterUsageBridge.project(
            usage: usage,
            sessionId: sessionId,
            sequenceNumber: sequenceNumber
        ) else {
            XCTFail("CursorAdapterUsageBridge.project returned nil for input \(usage)",
                    file: file, line: line)
            return
        }
        // Field-by-field rather than `XCTAssertEqual(usage, projected)`
        // so a regression surfaces the offending field, not just
        // "not equal".
        XCTAssertEqual(usage.sessionPct, projected.sessionPct,
                       "sessionPct", file: file, line: line)
        XCTAssertEqual(usage.sessionResetMins, projected.sessionResetMins,
                       "sessionResetMins", file: file, line: line)
        XCTAssertEqual(usage.sessionEpoch, projected.sessionEpoch,
                       "sessionEpoch", file: file, line: line)
        XCTAssertEqual(usage.weeklyPct, projected.weeklyPct,
                       "weeklyPct", file: file, line: line)
        XCTAssertEqual(usage.weeklyResetMins, projected.weeklyResetMins,
                       "weeklyResetMins", file: file, line: line)
        XCTAssertEqual(usage.weeklyEpoch, projected.weeklyEpoch,
                       "weeklyEpoch", file: file, line: line)
        XCTAssertEqual(usage.status, projected.status,
                       "status", file: file, line: line)
        XCTAssertEqual(usage.representativeClaim, projected.representativeClaim,
                       "representativeClaim", file: file, line: line)
        // updatedAt round-trips through a Double (epoch seconds) so we
        // compare with millisecond tolerance to absorb any floating
        // round-trip noise. In practice `timeIntervalSince1970` is
        // exact for whole seconds, so this is mostly defensive.
        XCTAssertEqual(
            usage.updatedAt.timeIntervalSince1970,
            projected.updatedAt.timeIntervalSince1970,
            accuracy: 0.001,
            "updatedAt", file: file, line: line
        )
        XCTAssertEqual(usage.organizationID, projected.organizationID,
                       "organizationID", file: file, line: line)
        XCTAssertEqual(usage.cursorQuota, projected.cursorQuota,
                       "cursorQuota", file: file, line: line)
    }

    // MARK: - Happy paths

    func test_parity_fullPeriod_withPlanBadge() {
        let usage = UsageData(
            sessionPct: 42,
            sessionResetMins: 1234,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 42,
            weeklyResetMins: 1234,
            weeklyEpoch: 1_715_999_999,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: "200 included / period"
        )
        assertParity(usage)
    }

    func test_parity_freeFier_noOrganizationID() {
        let usage = UsageData(
            sessionPct: 12,
            sessionResetMins: 5000,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 12,
            weeklyResetMins: 5000,
            weeklyEpoch: 1_715_999_999,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: nil
        )
        assertParity(usage)
    }

    func test_parity_periodAtResetBoundary() {
        // Period ending now → resetMins == 0.
        let usage = UsageData(
            sessionPct: 73,
            sessionResetMins: 0,
            sessionEpoch: Int(pinnedNow.timeIntervalSince1970),
            weeklyPct: 73,
            weeklyResetMins: 0,
            weeklyEpoch: Int(pinnedNow.timeIntervalSince1970),
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: "200 included / period"
        )
        assertParity(usage)
    }

    func test_parity_freshUnusedAccount_zeroPercent() {
        let usage = UsageData(
            sessionPct: 0,
            sessionResetMins: 43_200,
            sessionEpoch: 1_716_999_999,
            weeklyPct: 0,
            weeklyResetMins: 43_200,
            weeklyEpoch: 1_716_999_999,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: "200 included / period"
        )
        assertParity(usage)
    }

    func test_parity_periodNotStartedStatus() {
        // Cursor sets .notStarted when the resets_at epoch is in the
        // past (defensive — happens around period rollover).
        let usage = UsageData(
            sessionPct: 100,
            sessionResetMins: 0,
            sessionEpoch: 1_714_000_000,  // in the past
            weeklyPct: 100,
            weeklyResetMins: 0,
            weeklyEpoch: 1_714_000_000,
            status: .notStarted,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: nil
        )
        assertParity(usage)
    }

    func test_parity_limitedStatus() {
        let usage = UsageData(
            sessionPct: 100,
            sessionResetMins: 60,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 100,
            weeklyResetMins: 60,
            weeklyEpoch: 1_715_999_999,
            status: .limited,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: "200 included / period"
        )
        assertParity(usage)
    }

    func test_parity_sevenDayBindingWindow() {
        // BindingWindow.sevenDay has rawValue "seven_day" but
        // String(describing:) == "sevenDay". The bridge must
        // round-trip the case-name form correctly.
        let usage = UsageData(
            sessionPct: 30,
            sessionResetMins: 7200,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 30,
            weeklyResetMins: 7200,
            weeklyEpoch: 1_715_999_999,
            status: .allowed,
            representativeClaim: .sevenDay,
            updatedAt: pinnedNow,
            organizationID: nil
        )
        assertParity(usage)
    }

    func test_parity_unknownBindingWindow() {
        let usage = UsageData(
            sessionPct: 50,
            sessionResetMins: 300,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 50,
            weeklyResetMins: 300,
            weeklyEpoch: 1_715_999_999,
            status: .allowed,
            representativeClaim: .unknown,
            updatedAt: pinnedNow,
            organizationID: nil
        )
        assertParity(usage)
    }

    func test_parity_unknownStatus() {
        let usage = UsageData(
            sessionPct: 50,
            sessionResetMins: 300,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 50,
            weeklyResetMins: 300,
            weeklyEpoch: 1_715_999_999,
            status: .unknown,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: nil
        )
        assertParity(usage)
    }

    // MARK: - Dedup contract

    /// Canonical event ids must be stable across multiple polls of the
    /// same billing period: same `sessionId` derived from
    /// `sessionEpoch` → same id prefix. Different sequence numbers
    /// guarantee uniqueness per poll. Downstream consumers (F2
    /// orchestration store, E6 push gateway) dedup on event id.
    func test_dedup_eventIdsUnique_perPollWithinSamePeriod() {
        let usage = UsageData(
            sessionPct: 10,
            sessionResetMins: 1000,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 10,
            weeklyResetMins: 1000,
            weeklyEpoch: 1_715_999_999,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: nil
        )
        let sid = CursorAdapterUsageBridge.sessionId(forPeriodEpoch: usage.sessionEpoch)
        let events1 = CursorAdapter.translate(usage: usage, sessionId: sid, sequenceNumber: 0)
        let events2 = CursorAdapter.translate(usage: usage, sessionId: sid, sequenceNumber: 1)
        let events3 = CursorAdapter.translate(usage: usage, sessionId: sid, sequenceNumber: 2)
        XCTAssertEqual(events1.count, 1)
        XCTAssertEqual(events2.count, 1)
        XCTAssertEqual(events3.count, 1)
        // Same prefix (period) but different sequence → unique ids.
        XCTAssertEqual(events1[0].id, "cursor-\(sid)-0")
        XCTAssertEqual(events2[0].id, "cursor-\(sid)-1")
        XCTAssertEqual(events3[0].id, "cursor-\(sid)-2")
        XCTAssertNotEqual(events1[0].id, events2[0].id)
        XCTAssertNotEqual(events2[0].id, events3[0].id)
    }

    /// A new billing period (different `sessionEpoch`) must produce a
    /// different `sessionId`, so the canonical id space restarts. The
    /// wire's sequence cursor resets to 0 on period change — this
    /// test pins the sessionId derivation that the wire relies on.
    func test_dedup_periodEpochChange_yieldsNewSessionId() {
        let oldEpoch = 1_715_999_999
        let newEpoch = 1_716_999_999
        let oldSid = CursorAdapterUsageBridge.sessionId(forPeriodEpoch: oldEpoch)
        let newSid = CursorAdapterUsageBridge.sessionId(forPeriodEpoch: newEpoch)
        XCTAssertNotEqual(oldSid, newSid)
        XCTAssertEqual(oldSid, "cursor-period-1715999999")
        XCTAssertEqual(newSid, "cursor-period-1716999999")
    }

    // MARK: - Provider instance id + raw bytes propagation

    /// F3-ready: providerInstanceId + rawBytes pass through the bridge
    /// unchanged. The bridge doesn't read them — they're carried for
    /// the orchestration store's retention path — but the wire must
    /// not accidentally drop them on the strangler-fig branch.
    func test_propagation_providerInstanceIdAndRawBytes_reachAdapter() {
        let usage = UsageData(
            sessionPct: 10,
            sessionResetMins: 100,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 10,
            weeklyResetMins: 100,
            weeklyEpoch: 1_715_999_999,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: nil
        )
        let rawBytes = Data([0x01, 0x02, 0x03])
        // Project doesn't return the event, but the canonical event
        // is the data carrier. Run translate directly with the same
        // args and verify propagation.
        let events = CursorAdapter.translate(
            usage: usage,
            sessionId: "cursor-period-1715999999",
            sequenceNumber: 0,
            providerInstanceId: "cursor_pro",
            rawBytes: rawBytes
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].providerInstanceId, "cursor_pro")
        XCTAssertEqual(events[0].rawProviderPayload, rawBytes)
    }

    // MARK: - Flag-off vs flag-on at the FeatureFlags boundary

    /// Driving the flag in both states must yield the same downstream
    /// view of `UsageData`. With the flag off, the consumer reads
    /// `polled` directly; with the flag on, it reads
    /// `bridge.project(polled)`. This test pins that the two values
    /// are field-for-field equal so the AppModel-level wire is a
    /// behavioral identity.
    func test_parity_flagOffEqualsFlagOn() {
        let polled = UsageData(
            sessionPct: 42,
            sessionResetMins: 1234,
            sessionEpoch: 1_715_999_999,
            weeklyPct: 42,
            weeklyResetMins: 1234,
            weeklyEpoch: 1_715_999_999,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: pinnedNow,
            organizationID: "200 included / period"
        )

        // Flag off — consumer reads polled directly.
        FeatureFlags.useCursorAdapterOverride = false
        defer { FeatureFlags.useCursorAdapterOverride = nil }
        let off = simulateAnalyticsRead(polled: polled)

        // Flag on — consumer reads bridge.project(polled).
        FeatureFlags.useCursorAdapterOverride = true
        let on = simulateAnalyticsRead(polled: polled)

        XCTAssertEqual(off.sessionPct, on.sessionPct, "sessionPct must match across the flag")
        XCTAssertEqual(off.sessionResetMins, on.sessionResetMins, "sessionResetMins must match across the flag")
        XCTAssertEqual(off.sessionEpoch, on.sessionEpoch, "sessionEpoch must match across the flag")
        XCTAssertEqual(off.weeklyPct, on.weeklyPct, "weeklyPct must match across the flag")
        XCTAssertEqual(off.weeklyResetMins, on.weeklyResetMins, "weeklyResetMins must match across the flag")
        XCTAssertEqual(off.weeklyEpoch, on.weeklyEpoch, "weeklyEpoch must match across the flag")
        XCTAssertEqual(off.status, on.status, "status must match across the flag")
        XCTAssertEqual(off.representativeClaim, on.representativeClaim, "representativeClaim must match across the flag")
        XCTAssertEqual(off.organizationID, on.organizationID, "organizationID must match across the flag")
    }

    /// Mirrors what `AppModel.consume(_:)` does for Cursor: read the
    /// flag, route through the bridge when on, return polled
    /// otherwise. Keeps the parity test fixture free of Mac-target
    /// types so it runs in the Shared test bundle.
    private func simulateAnalyticsRead(polled: UsageData) -> UsageData {
        guard FeatureFlags.useCursorAdapter else { return polled }
        let sid = CursorAdapterUsageBridge.sessionId(forPeriodEpoch: polled.sessionEpoch)
        return CursorAdapterUsageBridge.project(
            usage: polled,
            sessionId: sid,
            sequenceNumber: 0
        ) ?? polled
    }
}
