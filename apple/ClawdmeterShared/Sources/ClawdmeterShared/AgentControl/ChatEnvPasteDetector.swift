import Foundation

/// One env var parsed from chat/composer text that matches a vendor template key.
public struct ChatEnvDetectedCandidate: Hashable, Sendable, Identifiable {
    public let key: String
    public let value: String
    public let vendorId: String

    public var id: String { "\(vendorId):\(key)" }

    public init(key: String, value: String, vendorId: String) {
        self.key = key
        self.value = value
        self.vendorId = vendorId
    }
}

/// Result of scanning a composer draft for vendor-scoped env vars.
public struct ChatEnvPasteDetection: Hashable, Sendable {
    public let vendorId: String
    public let vendorDisplayName: String
    public let candidates: [ChatEnvDetectedCandidate]

    public init(vendorId: String, vendorDisplayName: String, candidates: [ChatEnvDetectedCandidate]) {
        self.vendorId = vendorId
        self.vendorDisplayName = vendorDisplayName
        self.candidates = candidates
    }

    public var keys: Set<String> {
        Set(candidates.map(\.key))
    }
}

/// Detects vendor env variables pasted into the Code tab composer and resolves
/// which provisioning vendor they belong to using nearby chat context.
public enum ChatEnvPasteDetector {
    public static func detect(
        in composerText: String,
        contextHints: String = "",
        vendors: [VendorProvisioningVendor] = VendorProvisioningCatalog.vendors
    ) -> ChatEnvPasteDetection? {
        let parsed = parseAssignments(from: composerText)
        guard !parsed.isEmpty else { return nil }

        let keyOwners = keyOwnerIndex(vendors: vendors)
        var grouped: [String: [ChatEnvDetectedCandidate]] = [:]
        for (key, value) in parsed {
            guard let vendorIds = keyOwners[key], !value.isEmpty else { continue }
            for vendorId in vendorIds {
                let candidate = ChatEnvDetectedCandidate(key: key, value: value, vendorId: vendorId)
                grouped[vendorId, default: []].append(candidate)
            }
        }
        guard !grouped.isEmpty else { return nil }

        let ranked = grouped.keys.sorted { lhs, rhs in
            let lhsScore = vendorScore(
                vendorId: lhs,
                matchingKeys: Set(grouped[lhs]?.map(\.key) ?? []),
                contextHints: contextHints,
                vendors: vendors
            )
            let rhsScore = vendorScore(
                vendorId: rhs,
                matchingKeys: Set(grouped[rhs]?.map(\.key) ?? []),
                contextHints: contextHints,
                vendors: vendors
            )
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsCount = grouped[lhs]?.count ?? 0
            let rhsCount = grouped[rhs]?.count ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs < rhs
        }

        guard let vendorId = ranked.first,
              let vendor = vendors.first(where: { $0.id == vendorId }),
              let candidates = grouped[vendorId],
              !candidates.isEmpty
        else { return nil }

        let deduped = dedupeCandidates(candidates)
        return ChatEnvPasteDetection(
            vendorId: vendor.id,
            vendorDisplayName: vendor.displayName,
            candidates: deduped
        )
    }

    /// Removes env assignment lines from prompt text before sending to the model.
    public static func redactEnvLines(from text: String, keys: Set<String>) -> String {
        guard !keys.isEmpty else { return text }
        let upperKeys = Set(keys.map { $0.uppercased() })
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        kept.reserveCapacity(lines.count)

        for line in lines {
            guard let key = assignmentKey(in: line), upperKeys.contains(key) else {
                kept.append(line)
                continue
            }
        }

        while kept.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            kept.removeLast()
        }
        return kept.joined(separator: "\n")
    }

    public static func contextHints(from messages: [ChatMessage], limit: Int = 12) -> String {
        messages
            .suffix(limit)
            .map { [$0.title, $0.body, $0.detail ?? ""].joined(separator: " ") }
            .joined(separator: "\n")
    }

    // MARK: - Parsing

    private static func parseAssignments(from text: String) -> [(key: String, value: String)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [(String, String)] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }

            let body = trimmed.hasPrefix("export ")
                ? String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                : trimmed
            guard let eq = body.firstIndex(of: "=") else {
                index += 1
                continue
            }

            let rawKey = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
            let key = rawKey.uppercased()
            guard isValidKey(key) else {
                index += 1
                continue
            }

            var rawValue = String(body[body.index(after: eq)...])
            if let quote = rawValue.first, quote == "\"" || quote == "'" {
                while !hasClosingQuote(rawValue, quote: quote), index + 1 < lines.count {
                    index += 1
                    rawValue += "\n" + lines[index]
                }
            }

            let value = decodeValue(rawValue)
            if !value.isEmpty {
                result.append((key, value))
            }
            index += 1
        }

        return result
    }

    private static func assignmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let body = trimmed.hasPrefix("export ")
            ? String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            : trimmed
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let rawKey = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
        let key = rawKey.uppercased()
        return isValidKey(key) ? key : nil
    }

    private static func keyOwnerIndex(vendors: [VendorProvisioningVendor]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for vendor in vendors {
            for template in vendor.envTemplates {
                index[template.key.uppercased(), default: []].append(vendor.id)
            }
        }
        return index
    }

    private static func dedupeCandidates(_ candidates: [ChatEnvDetectedCandidate]) -> [ChatEnvDetectedCandidate] {
        var seen: Set<String> = []
        var result: [ChatEnvDetectedCandidate] = []
        for candidate in candidates {
            guard seen.insert(candidate.key).inserted else { continue }
            result.append(candidate)
        }
        return result.sorted { $0.key < $1.key }
    }

    private static func vendorScore(
        vendorId: String,
        matchingKeys: Set<String>,
        contextHints: String,
        vendors: [VendorProvisioningVendor]
    ) -> Int {
        guard let vendor = vendors.first(where: { $0.id == vendorId }) else { return 0 }
        let haystack = normalized(contextHints)
        var score = matchingKeys.count

        if haystack.contains(normalized(vendor.displayName)) {
            score += 10
        }
        if haystack.contains(normalized(vendor.id)) {
            score += 5
        }
        for alias in vendor.mcpAliases where haystack.contains(normalized(alias)) {
            score += 3
        }
        for cli in vendor.cliNames where haystack.contains(normalized(cli)) {
            score += 2
        }
        return score
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let firstOK = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_").contains(first)
        guard firstOK else { return false }
        return key.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789").contains($0)
        }
    }

    private static func hasClosingQuote(_ value: String, quote: Character) -> Bool {
        guard value.first == quote else { return true }
        var escaped = false
        for ch in value.dropFirst() {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == quote {
                return true
            }
        }
        return false
    }

    private static func decodeValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), let end = closingQuoteIndex(in: value, quote: "\"") {
            value = String(value[value.index(after: value.startIndex)..<end])
            return decodeDoubleQuoted(value)
        }
        if value.hasPrefix("'"), let end = closingQuoteIndex(in: value, quote: "'") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func closingQuoteIndex(in value: String, quote: Character) -> String.Index? {
        var escaped = false
        var idx = value.index(after: value.startIndex)
        while idx < value.endIndex {
            let ch = value[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == quote {
                return idx
            }
            idx = value.index(after: idx)
        }
        return nil
    }

    private static func decodeDoubleQuoted(_ value: String) -> String {
        var result = ""
        var escaped = false
        for ch in value {
            if escaped {
                result.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                result.append(ch)
            }
        }
        return result
    }
}
