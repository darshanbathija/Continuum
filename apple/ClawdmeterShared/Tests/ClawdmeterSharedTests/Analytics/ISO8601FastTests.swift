import XCTest
@testable import ClawdmeterShared

final class ISO8601FastTests: XCTestCase {
    private let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func testMatchesFoundationOnRepresentativeTimestamps() {
        // The shapes Claude / Codex / Cursor JSONLs actually emit.
        let samples = [
            "2026-06-11T04:19:49Z",
            "2026-06-11T04:19:49.123Z",
            "2026-01-01T00:00:00Z",
            "2025-12-31T23:59:59.999Z",
            "2024-02-29T12:00:00Z",          // leap day
            "1970-01-01T00:00:00Z",
            "2026-06-11T04:19:49+07:00",
            "2026-06-11T04:19:49.5-08:00",
            "2000-03-01T00:00:00Z",          // century leap-year boundary
        ]
        for s in samples {
            let expected = fractional.date(from: s) ?? plain.date(from: s)
            let got = ISO8601Fast.parse(s)
            XCTAssertNotNil(expected, "Foundation rejected sample \(s) — fix the test")
            XCTAssertNotNil(got, "ISO8601Fast rejected \(s)")
            XCTAssertEqual(
                got!.timeIntervalSince1970, expected!.timeIntervalSince1970,
                accuracy: 0.0005, "mismatch for \(s)"
            )
        }
    }

    func testFuzzRoundTripAgainstFoundation() {
        // 500 random instants across 1970…2100, formatted by Foundation,
        // must parse back to the same epoch second (+ fraction).
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let epoch = Double.random(in: 0...4_102_444_800, using: &generator) // → 2100
            let date = Date(timeIntervalSince1970: epoch.rounded())
            let s = plain.string(from: date)
            guard let got = ISO8601Fast.parse(s) else {
                return XCTFail("ISO8601Fast rejected Foundation output \(s)")
            }
            XCTAssertEqual(got.timeIntervalSince1970, date.timeIntervalSince1970,
                           accuracy: 0.0005, "mismatch for \(s)")
        }
    }

    func testLenientVariantsAcceptedAsUTC() {
        // Space separator, lowercase z/t, comma fraction, missing offset →
        // all treated as the same UTC instant.
        let expected = ISO8601Fast.parse("2026-06-11T04:19:49Z")!
        for s in [
            "2026-06-11 04:19:49Z",
            "2026-06-11t04:19:49z",
            "2026-06-11T04:19:49",
            "2026-06-11T04:19:49,000Z",
        ] {
            guard let got = ISO8601Fast.parse(s) else {
                return XCTFail("rejected lenient variant \(s)")
            }
            XCTAssertEqual(got.timeIntervalSince1970, expected.timeIntervalSince1970,
                           accuracy: 0.0005, "mismatch for \(s)")
        }
    }

    func testCompactNumericOffset() {
        // ±HHMM without the colon.
        let a = ISO8601Fast.parse("2026-06-11T04:19:49+0700")
        let b = ISO8601Fast.parse("2026-06-11T04:19:49+07:00")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testRejectsMalformedInput() {
        let bad = [
            "", "not a date", "2026-06-11", "2026-06-11T04:19",
            "2026:06:11T04:19:49Z", "2026-13-11T04:19:49Z",
            "2026-06-32T04:19:49Z", "2026-06-11T24:19:49Z",
            "2026-06-11T04:19:49.Z",        // dot with no digits
            "2026-06-11T04:19:49Zjunk",     // trailing garbage
            "2026-06-11T04:19:49X",         // bogus zone designator
        ]
        for s in bad {
            XCTAssertNil(ISO8601Fast.parse(s), "should reject \(s)")
        }
    }
}
