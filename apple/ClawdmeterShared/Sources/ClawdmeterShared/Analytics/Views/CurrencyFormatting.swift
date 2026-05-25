#if !os(watchOS)
import Foundation

/// Adaptive USD formatting per plan A16: 2 decimals when ≥ $0.01, 4 decimals
/// when between 0 and $0.01, "$0" when exactly zero. Decimal-based so we
/// don't smear tiny Codex costs into "$0.00".
public enum AnalyticsCurrencyFormatter {

    public static func format(_ amount: Decimal) -> String {
        if amount == 0 { return "$0" }
        let fractionDigits: Int = {
            // < $0.01 → show 4 decimals so the user can see the actual cost
            // (a typical Codex prompt rounds to fractions of a cent).
            if abs(amount) < Decimal(string: "0.01") ?? 0 { return 4 }
            return 2
        }()
        #if os(Linux)
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return String(format: "$%.\(fractionDigits)f", value)
        #else
        // Force the US locale's "$" symbol; en_US_POSIX dodges the regional
        // "US$" prefix some locales apply for USD.
        let style = Decimal.FormatStyle.Currency(code: "USD")
            .precision(.fractionLength(fractionDigits))
            .locale(Locale(identifier: "en_US"))
        return amount.formatted(style)
        #endif
    }
}

/// Compact-name token count formatting per plan A6 + A5: "1.2M", "8.7K",
/// "312". Matches how ccusage displays counts.
public enum AnalyticsTokenFormatter {

    public static func format(_ count: Int) -> String {
        #if os(Linux)
        if count >= 1_000_000 {
            return compact(count, divisor: 1_000_000, suffix: "M")
        }
        if count >= 1_000 {
            return compact(count, divisor: 1_000, suffix: "K")
        }
        return String(count)
        #else
        let n = Int64(count)
        if count >= 1000 {
            return n.formatted(.number.notation(.compactName))
        }
        return n.formatted(.number)
        #endif
    }

    #if os(Linux)
    private static func compact(_ count: Int, divisor: Int, suffix: String) -> String {
        let roundedTenths = (Double(count) / Double(divisor) * 10).rounded() / 10
        if roundedTenths.rounded() == roundedTenths {
            return "\(Int(roundedTenths))\(suffix)"
        }
        return String(format: "%.1f%@", roundedTenths, suffix)
    }
    #endif
}
#endif
