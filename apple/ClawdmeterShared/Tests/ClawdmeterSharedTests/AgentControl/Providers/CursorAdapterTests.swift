import XCTest
@testable import ClawdmeterShared

/// Parity tests for the F1d `CursorAdapter`. Cursor is the "period
/// summary" provider — each poll yields one `.sessionStarted` event with
/// the period state in extensions.
///
/// Plan: F1d (Phase 1; D23) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`
final class CursorAdapterTests: XCTestCase {

    private let timestamp = Date(timeIntervalSince1970: 1_715_000_000)

    private func makeUsage(
        sessionPct: Int = 42,
        sessionResetMins: Int = 60_000,
        organizationID: String? = "200 included / period",
        status: UsageData.Status = .allowed
    ) -> UsageData {
        UsageData(
            sessionPct: sessionPct,
            sessionResetMins: sessionResetMins,
            sessionEpoch: 1_715_999_999,
            weeklyPct: sessionPct,
            weeklyResetMins: sessionResetMins,
            weeklyEpoch: 1_715_999_999,
            status: status,
            representativeClaim: .fiveHour,
            updatedAt: timestamp,
            organizationID: organizationID
        )
    }

    func test_translate_emitsSingleSessionStartedEvent() {
        let usage = makeUsage()
        let events = CursorAdapter.translate(
            usage: usage,
            sessionId: "period-2026-05",
            sequenceNumber: 0
        )
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.providerKind, .cursor)
        XCTAssertEqual(event.id, "cursor-period-2026-05-0")
        XCTAssertEqual(event.sequenceNumber, 0)
    }

    func test_translate_settingsCarryPercentAndResetMins() {
        let usage = makeUsage(sessionPct: 73, sessionResetMins: 1234)
        let events = CursorAdapter.translate(
            usage: usage, sessionId: "p1", sequenceNumber: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .sessionStarted(let model, let settings) = events[0].payload else {
            return XCTFail("Expected .sessionStarted")
        }
        XCTAssertEqual(model, "cursor")
        XCTAssertEqual(settings["session_percent_used"], "73")
        XCTAssertEqual(settings["session_reset_mins"], "1234")
        XCTAssertEqual(settings["plan_badge"], "200 included / period")
    }

    func test_translate_extensionsCarryFullPeriodState() {
        let usage = makeUsage(sessionPct: 73)
        let events = CursorAdapter.translate(
            usage: usage, sessionId: "p1", sequenceNumber: 5
        )
        XCTAssertEqual(events.count, 1)
        guard let ext = events[0].providerExtensions,
              case .nested(let cursor) = ext["cursor"] else {
            return XCTFail("Expected cursor extension fields")
        }
        XCTAssertEqual(cursor["session_percent"], .int(73))
        XCTAssertEqual(cursor["session_epoch"], .int(1_715_999_999))
        XCTAssertEqual(cursor["plan_badge"], .string("200 included / period"))
        XCTAssertNotNil(cursor["status"])
        XCTAssertNotNil(cursor["representative_claim"])
    }

    func test_translate_noPlanBadge_omitted() {
        let usage = makeUsage(organizationID: nil)
        let events = CursorAdapter.translate(
            usage: usage, sessionId: "p1", sequenceNumber: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .sessionStarted(_, let settings) = events[0].payload else {
            return XCTFail("Expected .sessionStarted")
        }
        XCTAssertNil(settings["plan_badge"])
    }

    func test_translate_providerInstanceIdAndRawBytes_propagate() {
        let usage = makeUsage()
        let bytes = Data([0x00, 0x01, 0x02])
        let events = CursorAdapter.translate(
            usage: usage,
            sessionId: "p1",
            sequenceNumber: 0,
            providerInstanceId: "cursor_pro",
            rawBytes: bytes
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].providerInstanceId, "cursor_pro")
        XCTAssertEqual(events[0].rawProviderPayload, bytes)
    }

    func test_translate_usesUsageUpdatedAtAsEmittedAt() {
        let custom = Date(timeIntervalSince1970: 1_716_500_000)
        let usage = UsageData(
            sessionPct: 0, sessionResetMins: 0, sessionEpoch: 0,
            weeklyPct: 0, weeklyResetMins: 0, weeklyEpoch: 0,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: custom,
            organizationID: nil
        )
        let events = CursorAdapter.translate(
            usage: usage, sessionId: "p1", sequenceNumber: 0
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].emittedAt, custom)
    }
}
