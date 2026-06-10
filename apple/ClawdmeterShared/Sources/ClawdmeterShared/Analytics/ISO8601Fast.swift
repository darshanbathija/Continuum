import Foundation

/// Lock-free fixed-format ISO-8601 timestamp parser for the JSONL hot paths.
///
/// `ISO8601DateFormatter.date(from:)` routes through CFDateFormatter → ICU
/// `SimpleDateFormat`, which serializes every call behind ICU's global
/// mutexes and rebuilds timezone/number sub-parsers per parse. Under the
/// analytics loader's N-way concurrent file parse that contention pegged
/// every cooperative-pool thread for the duration of a cold corpus reparse
/// (multi-GB of JSONL → hours of 3-core burn; the v0.31.17 energy bug).
///
/// This parser is pure integer math on the UTF-8 bytes — no ICU, no locks,
/// no allocation — and accepts the only shapes agent JSONLs actually emit:
///
///     YYYY-MM-DD[T ]HH:MM:SS[.fraction][Z|±HH[:MM]]
///
/// A missing offset is treated as UTC (lenient; JSONL timestamps always
/// carry `Z` in practice). Callers keep `ISO8601DateFormatter` as the
/// fallback for anything this declines, so behavior is strictly additive.
public enum ISO8601Fast {
    public static func parse(_ string: String) -> Date? {
        var copy = string
        return copy.withUTF8 { parse(bytes: $0) }
    }

    private static func parse(bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        let n = bytes.count
        guard n >= 19 else { return nil }

        @inline(__always) func digit(_ i: Int) -> Int? {
            let b = bytes[i]
            guard b >= 0x30, b <= 0x39 else { return nil }
            return Int(b - 0x30)
        }
        @inline(__always) func num(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for i in start..<(start + count) {
                guard let d = digit(i) else { return nil }
                value = value * 10 + d
            }
            return value
        }

        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: "t") || bytes[10] == UInt8(ascii: " "),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 60
        else { return nil }

        var i = 19
        var fraction = 0.0
        if i < n, bytes[i] == UInt8(ascii: ".") || bytes[i] == UInt8(ascii: ",") {
            i += 1
            var scale = 0.1
            var sawDigit = false
            while i < n, let d = digit(i) {
                fraction += Double(d) * scale
                scale *= 0.1
                sawDigit = true
                i += 1
            }
            guard sawDigit else { return nil }
        }

        var offsetSeconds = 0
        if i < n {
            switch bytes[i] {
            case UInt8(ascii: "Z"), UInt8(ascii: "z"):
                i += 1
            case UInt8(ascii: "+"), UInt8(ascii: "-"):
                let negative = bytes[i] == UInt8(ascii: "-")
                i += 1
                guard i + 2 <= n, let oh = num(i, 2) else { return nil }
                i += 2
                var om = 0
                if i < n, bytes[i] == UInt8(ascii: ":") { i += 1 }
                if i + 2 <= n, let m = num(i, 2) {
                    om = m
                    i += 2
                }
                offsetSeconds = (oh * 3600 + om * 60) * (negative ? -1 : 1)
            default:
                return nil
            }
        }
        guard i == n else { return nil }

        // Days since 1970-01-01 from a proleptic-Gregorian civil date
        // (Howard Hinnant's days_from_civil) — no Calendar, no TimeZone.
        var y = year
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468

        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}
