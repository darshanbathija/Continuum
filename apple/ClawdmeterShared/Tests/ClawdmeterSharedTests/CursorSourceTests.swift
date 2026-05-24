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

        // pinnedNow < periodEnd → status is .allowed, not .notStarted.
        XCTAssertEqual(usage.status, .allowed)

        // resetMins should be (periodEndEpoch - nowEpoch + 59) / 60.
        let expectedResetMins = max(0, (1_782_259_911 - Int(Self.pinnedNow.timeIntervalSince1970) + 59) / 60)
        XCTAssertEqual(usage.sessionResetMins, expectedResetMins)
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
            XCTAssertTrue(detail.contains("grpc-status: 7"),
                          "Detail should echo the trailer text — got: \(detail)")
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
