import Foundation

/// Shared markdown-bullet parser for `AgentSession.planText`. Splits on
/// newlines, strips list prefixes (`- `, `* `, Unicode bullet, `1. `..`999. `),
/// drops empty lines, caps at `cap` entries.
///
/// This lives outside the SwiftUI-gated Tahoe bindings because daemon-side
/// shared-package code also uses it.
public enum TahoePlanParser {
    public static func steps(from raw: String, cap: Int) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = trimmed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                var s = String(line).trimmingCharacters(in: .whitespaces)
                for prefix in ["- ", "* ", "\u{2022} "] {
                    if s.hasPrefix(prefix) {
                        s = String(s.dropFirst(prefix.count))
                        return s.isEmpty ? nil : s
                    }
                }
                if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }),
                   dot != s.startIndex {
                    let head = s[s.startIndex..<dot]
                    if head.count <= 3, head.allSatisfy({ $0.isNumber }) {
                        let after = s.index(after: dot)
                        if after < s.endIndex, s[after] == " " {
                            s = String(s[s.index(after: after)..<s.endIndex])
                            return s.isEmpty ? nil : s
                        }
                    }
                }
                return s.isEmpty ? nil : s
            }
        return Array(parsed.prefix(cap))
    }
}
