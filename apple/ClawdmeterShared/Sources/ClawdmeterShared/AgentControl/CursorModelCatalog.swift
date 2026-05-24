import Foundation

/// Cursor's visible model list is account-scoped, so Clawdmeter treats the
/// bundled catalog as a conservative fallback and replaces it with a live CLI
/// probe whenever the Mac can authenticate.
public enum CursorModelCatalog {
    public static let autoModelId = "cursor-auto"

    public static var autoEntry: ModelCatalogEntry {
        ModelCatalogEntry(
            id: autoModelId,
            provider: .cursor,
            displayName: "Cursor default / Auto",
            cliAlias: nil,
            supportsThinking: true,
            supportsEffort: false,
            contextWindow: nil,
            recommendedFor: "Cursor account default",
            badge: "Auto"
        )
    }

    public static func isAutoModel(_ model: String?) -> Bool {
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return true
        }
        let normalized = trimmed.lowercased()
        return normalized == autoModelId || normalized == "auto" || normalized == "cursor-default"
    }

    public static func entries(fromVisibleModels models: [String]) -> [ModelCatalogEntry] {
        let uniqueModels = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { acc, model in
                if !acc.contains(model) { acc.append(model) }
            }

        let probed = uniqueModels
            .filter { !isAutoModel($0) }
            .map { model in
                ModelCatalogEntry(
                    id: model,
                    provider: .cursor,
                    displayName: displayName(for: model),
                    cliAlias: model,
                    supportsThinking: model.lowercased().contains("thinking"),
                    supportsEffort: false,
                    contextWindow: nil,
                    recommendedFor: nil,
                    badge: nil
                )
            }

        return [autoEntry] + probed
    }

    public static func parseCLIOutput(_ output: String) -> [ModelCatalogEntry] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [autoEntry] }
        if trimmed.localizedCaseInsensitiveContains("no models available") {
            return [autoEntry]
        }

        if let jsonModels = parseJSONModels(trimmed), !jsonModels.isEmpty {
            return entries(fromVisibleModels: jsonModels)
        }

        let textModels = trimmed
            .split(whereSeparator: \.isNewline)
            .map { normalizeTextLine(String($0)) }
            .filter { candidate in
                guard !candidate.isEmpty else { return false }
                let lower = candidate.lowercased()
                if lower.contains("available models") { return false }
                if lower.hasPrefix("usage:") { return false }
                if lower.hasPrefix("model ") { return false }
                return true
            }
        return entries(fromVisibleModels: textModels)
    }

    private static func parseJSONModels(_ output: String) -> [String]? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let strings = json as? [String] {
            return strings
        }
        if let array = json as? [[String: Any]] {
            return array.compactMap { object in
                (object["id"] as? String)
                    ?? (object["model"] as? String)
                    ?? (object["name"] as? String)
            }
        }
        if let object = json as? [String: Any] {
            if let models = object["models"] as? [String] {
                return models
            }
            if let models = object["models"] as? [[String: Any]] {
                return models.compactMap { item in
                    (item["id"] as? String)
                        ?? (item["model"] as? String)
                        ?? (item["name"] as? String)
                }
            }
        }
        return nil
    }

    private static func normalizeTextLine(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = value.first, ["-", "*"].contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let dot = value.firstIndex(of: ".") {
            let prefix = value[..<dot]
            if !prefix.isEmpty && prefix.allSatisfy(\.isNumber) {
                value = String(value[value.index(after: dot)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let separator = value.range(of: "  ") ?? value.range(of: "\t") {
            value = String(value[..<separator.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayName(for model: String) -> String {
        model
            .split(separator: "-")
            .map { part in
                let lower = part.lowercased()
                switch lower {
                case "gpt": return "GPT"
                case "claude": return "Claude"
                case "sonnet": return "Sonnet"
                case "opus": return "Opus"
                case "haiku": return "Haiku"
                case "thinking": return "Thinking"
                default:
                    return lower.prefix(1).uppercased() + lower.dropFirst()
                }
            }
            .joined(separator: " ")
    }
}
