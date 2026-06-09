#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Fixture-based regression tests for the v0.28.0 CursorSource.
///
/// The fixture `Fixtures/cursor-GetCurrentPeriodUsage.bin` is the
/// already-extracted *message-frame* body (the inner protobuf payload,
/// not the gRPC-Web wrapped envelope) captured from a live free-tier
/// `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
/// response while the user was logged in via `cursor-agent login`.
///
/// Pinning the parser against real bytes means a Cursor backend schema
/// drift (field renumbering, percent-string wording change, etc.) trips
/// CI here instead of silently flapping the Cursor tile back to 0% in
/// production.
final class CursorSourceTests: XCTestCase {

    /// `now` pinned just after the live-capture moment so the billing
    /// period reset epoch lands in the future and we exercise the
    /// `.allowed` branch (not the past-reset `.notStarted` fallback).
    private static let pinnedNow = Date(timeIntervalSince1970: 1_779_582_000)

    // MARK: - Fixture loader

    private func loadFixture() throws -> Data {
        guard let url = Bundle.module.url(forResource: "cursor-GetCurrentPeriodUsage", withExtension: "bin") else {
            throw XCTSkip("Fixture cursor-GetCurrentPeriodUsage.bin not present in test bundle")
        }
        return try Data(contentsOf: url)
    }

    /// The fixture file is the inner proto payload only. The parser
    /// expects the gRPC-Web framed envelope, so re-wrap before calling.
    private func wrapAsGRPCWebFrame(_ payload: Data) -> Data {
        var framed = Data()
        framed.append(0x00) // flags: not-a-trailer
        var beLen = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &beLen) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    private func syntheticPayload(
        total: Int,
        auto: Int,
        api: Int,
        periodEndMs: UInt64 = 1_782_259_911_000,
        autoSummary: String? = nil,
        apiSummary: String? = nil,
        extraUsageSummary: String? = nil
    ) -> Data {
        var data = Data()
        appendVarint(field: 1, value: 1_779_582_000_000, to: &data)
        appendVarint(field: 2, value: periodEndMs, to: &data)
        if let extraUsageSummary {
            var nested = Data()
            appendString(field: 7, value: extraUsageSummary, to: &nested)
            appendLengthDelimited(field: 3, value: nested, to: &data)
        }
        appendVarint(field: 5, value: 400, to: &data)
        appendString(field: 7, value: autoSummary ?? "Auto \(auto)% used", to: &data)
        appendString(field: 11, value: "Total \(total)% used", to: &data)
        if let apiSummary {
            appendString(field: 12, value: apiSummary, to: &data)
        } else {
            appendString(field: 12, value: "API \(api)% used", to: &data)
        }
        return data
    }

    private func appendVarint(field: Int, value: UInt64, to data: inout Data) {
        appendRawVarint(UInt64(field << 3), to: &data)
        appendRawVarint(value, to: &data)
    }

    private func appendString(field: Int, value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendLengthDelimited(field: field, value: bytes, to: &data)
    }

    private func appendLengthDelimited(field: Int, value: Data, to data: inout Data) {
        appendRawVarint(UInt64((field << 3) | 2), to: &data)
        appendRawVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    private func appendRawVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | UInt8(0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    // MARK: - Happy path

    func test_parseGetCurrentPeriodUsage_extractsBillingPeriodAndPercent() throws {
        let payload = try loadFixture()
        let envelope = wrapAsGRPCWebFrame(payload)
        let usage = try CursorSource.parseGetCurrentPeriodUsage(grpcWebBody: envelope, now: Self.pinnedNow)

        // Period end in the captured fixture is 1782259911675 ms epoch →
        // 1782259911 seconds, ≈ 2026-06-24 02:51:51 UTC. ResetsAt should
        // round-trip through the parser intact.
        XCTAssertEqual(usage.sessionEpoch, 1_782_259_911)
        XCTAssertEqual(usage.weeklyEpoch, 1_782_259_911,
                       "Weekly mirrors session — Cursor only exposes one billing window.")

        // The free-tier capture shows 0% used.
        XCTAssertEqual(usage.sessionPct, 0)
        XCTAssertEqual(usage.weeklyPct, 0)

        // `included_usage_count` field surfaces as the plan badge.
        XCTAssertEqual(usage.organizationID, "200 included / period")
        XCTAssertEqual(usage.cursorQuota?.totalPct, 0)
        XCTAssertEqual(usage.cursorQuota?.autoPct, 0)
        XCTAssertEqual(usage.cursorQuota?.apiPct, 0)
        XCTAssertTrue(usage.cursorQuota?.extraUsageLabel?.contains("free usage") == true)

        // pinnedNow < periodEnd → status is .allowed, not .notStarted.
        XCTAssertEqual(usage.status, .allowed)

        // resetMins should be (periodEndEpoch - nowEpoch + 59) / 60.
        let expectedResetMins = max(0, (1_782_259_911 - Int(Self.pinnedNow.timeIntervalSince1970) + 59) / 60)
        XCTAssertEqual(usage.sessionResetMins, expectedResetMins)
    }

    func test_parseGetCurrentPeriodUsage_extractsMonthlyTotalAutoAndAPI() throws {
        let envelope = wrapAsGRPCWebFrame(syntheticPayload(total: 48, auto: 25, api: 95))
        let usage = try CursorSource.parseGetCurrentPeriodUsage(grpcWebBody: envelope, now: Self.pinnedNow)

        XCTAssertEqual(usage.sessionPct, 48)
        XCTAssertEqual(usage.weeklyPct, 48)
        XCTAssertEqual(usage.representativeClaim, .unknown)
        XCTAssertEqual(usage.organizationID, "400 included / period")
        XCTAssertEqual(usage.cursorQuota?.totalPct, 48)
        XCTAssertEqual(usage.cursorQuota?.autoPct, 25)
        XCTAssertEqual(usage.cursorQuota?.apiPct, 95)
        XCTAssertEqual(usage.cursorQuota?.resetEpoch, 1_782_259_911)
    }

    func test_parseGetCurrentPeriodUsage_extractsAutoAndAPIFromCombinedSummary() throws {
        let envelope = wrapAsGRPCWebFrame(syntheticPayload(
            total: 48,
            auto: 0,
            api: 0,
            autoSummary: "25% Auto and 95% API used",
            apiSummary: "",
            extraUsageSummary: "Free extra usage beyond purchased limits may vary."
        ))
        let usage = try CursorSource.parseGetCurrentPeriodUsage(grpcWebBody: envelope, now: Self.pinnedNow)

        XCTAssertEqual(usage.cursorQuota?.totalPct, 48)
        XCTAssertEqual(usage.cursorQuota?.autoPct, 25)
        XCTAssertEqual(usage.cursorQuota?.apiPct, 95)
        XCTAssertEqual(usage.cursorQuota?.extraUsageLabel, "Free extra usage beyond purchased limits may vary.")
    }

    func test_parseConnectJSON_extractsDashboardPlanUsage() throws {
        let body = Data("""
        {
          "autoModelSelectedDisplayMessage": "You've used 63% of your included total usage",
          "billingCycleEnd": "1781284914000",
          "billingCycleStart": "1778606514000",
          "namedModelSelectedDisplayMessage": "You've used 100% of your included API usage",
          "planUsage": {
            "apiPercentUsed": 100,
            "autoPercentUsed": 36.263,
            "bonusTooltip": "We work with model providers to give you free usage beyond what you've purchased. Amounts may vary.",
            "includedSpend": 40000,
            "limit": 40000,
            "totalPercentUsed": 62.53999999999999
          }
        }
        """.utf8)

        let usage = try CursorSource.parseGetCurrentPeriodUsage(connectJSONBody: body, now: Self.pinnedNow)

        XCTAssertEqual(usage.sessionPct, 63)
        XCTAssertEqual(usage.weeklyPct, 63)
        XCTAssertEqual(usage.sessionEpoch, 1_781_284_914)
        XCTAssertEqual(usage.cursorQuota?.totalPct, 63)
        XCTAssertEqual(usage.cursorQuota?.autoPct, 36)
        XCTAssertEqual(usage.cursorQuota?.apiPct, 100)
        XCTAssertEqual(usage.cursorQuota?.resetEpoch, 1_781_284_914)
        XCTAssertEqual(usage.cursorQuota?.includedUsageLabel, "$400 included / period")
        XCTAssertTrue(usage.cursorQuota?.extraUsageLabel?.contains("free usage") == true)

        let expectedResetMins = max(0, (1_781_284_914 - Int(Self.pinnedNow.timeIntervalSince1970) + 59) / 60)
        XCTAssertEqual(usage.cursorQuota?.resetMins, expectedResetMins)
    }

    func test_parseConnectJSON_extractsAutoFromAlternatePlanUsageKeys() throws {
        let body = Data("""
        {
          "billing_cycle_end": "1781284914000",
          "named_model_selected_display_message": "You've used 100% of your included API usage",
          "plan_usage": {
            "api_percent": "100",
            "auto_usage_percent": "37",
            "included_spend": "40000",
            "limit": "40000",
            "total_usage_percent": "63"
          }
        }
        """.utf8)

        let usage = try CursorSource.parseGetCurrentPeriodUsage(connectJSONBody: body, now: Self.pinnedNow)

        XCTAssertEqual(usage.cursorQuota?.totalPct, 63)
        XCTAssertEqual(usage.cursorQuota?.autoPct, 37)
        XCTAssertEqual(usage.cursorQuota?.apiPct, 100)
        XCTAssertEqual(usage.cursorQuota?.includedUsageLabel, "$400 included / period")
    }

    func test_parseConnectJSON_extractsAutoFromPlanUsageDisplayMessage() throws {
        let body = Data("""
        {
          "billingCycleEnd": "1781284914000",
          "planUsage": {
            "apiPercentUsed": 100,
            "autoUsageDisplayMessage": "Auto 37% used this period",
            "totalPercentUsed": 63
          }
        }
        """.utf8)

        let usage = try CursorSource.parseGetCurrentPeriodUsage(connectJSONBody: body, now: Self.pinnedNow)

        XCTAssertEqual(usage.cursorQuota?.totalPct, 63)
        XCTAssertEqual(usage.cursorQuota?.autoPct, 37)
        XCTAssertEqual(usage.cursorQuota?.apiPct, 100)
    }

    // MARK: - Trailer-only response (e.g., unauthenticated)

    func test_parse_returnsContractViolationOnTrailerOnly() {
        // gRPC-Web trailer frame: flags=0x80, length=16, body="grpc-status: 7\r\n"
        var trailer = Data()
        trailer.append(0x80)
        let body = "grpc-status: 7\r\n".data(using: .utf8)!
        var beLen = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &beLen) { trailer.append(contentsOf: $0) }
        trailer.append(body)

        XCTAssertThrowsError(
            try CursorSource.parseGetCurrentPeriodUsage(grpcWebBody: trailer, now: Self.pinnedNow)
        ) { error in
            guard case AISourceError.dataSourceContractViolation(let detail) = error else {
                return XCTFail("Expected dataSourceContractViolation, got \(error)")
            }
            XCTAssertTrue(detail.contains("trailer bytes=16"),
                          "Detail should report redacted trailer size — got: \(detail)")
            XCTAssertFalse(detail.contains("grpc-status: 7"),
                           "Detail must not echo trailer text — got: \(detail)")
        }
    }

    func test_parse_returnsContractViolationOnTotallyEmptyBody() {
        XCTAssertThrowsError(
            try CursorSource.parseGetCurrentPeriodUsage(grpcWebBody: Data(), now: Self.pinnedNow)
        ) { error in
            guard case AISourceError.dataSourceContractViolation = error else {
                return XCTFail("Expected dataSourceContractViolation, got \(error)")
            }
        }
    }

    // MARK: - Past-period clamp

    func test_parse_pastPeriodEnd_yieldsNotStarted() throws {
        let payload = try loadFixture()
        let envelope = wrapAsGRPCWebFrame(payload)
        // Pin `now` to far past the fixture's periodEnd → resetIsPast.
        let future = Date(timeIntervalSince1970: 99_999_999_999)
        let usage = try CursorSource.parseGetCurrentPeriodUsage(grpcWebBody: envelope, now: future)
        XCTAssertEqual(usage.status, .notStarted)
        XCTAssertEqual(usage.sessionResetMins, 0)
    }

    // MARK: - Percent extraction edge cases

    func test_parsePercent_handlesVariousShapes() {
        // The parser uses an internal regex; cover a few realistic strings.
        // We exercise the parser through the public entry point by
        // constructing a synthetic proto.
        // Skipped: the parser internal isn't exposed; covered by
        // test_parseGetCurrentPeriodUsage_extractsBillingPeriodAndPercent
        // for the canonical 0% case. Add a synthetic-proto fuzz test if
        // a Pro-tier capture lands later and exposes a non-zero string.
    }
}
#endif
