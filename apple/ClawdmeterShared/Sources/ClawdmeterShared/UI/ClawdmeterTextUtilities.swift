import Foundation

public enum ClawdmeterTextUtilities {
    public static func stripANSI(_ text: String) -> String {
        AnsiStrip.plain(text)
    }

    public static func stableContentHash(_ text: String) -> String {
        let scalars = text.unicodeScalars.reduce(UInt64(1469598103934665603)) { hash, scalar in
            (hash ^ UInt64(scalar.value)) &* 1099511628211
        }
        return String(scalars, radix: 16)
    }

    public static func collapsedWhitespacePreview(_ text: String, limit: Int = 80) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        let idx = cleaned.index(cleaned.startIndex, offsetBy: max(limit - 1, 1))
        return String(cleaned[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
