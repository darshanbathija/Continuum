import Foundation

/// Helpers for authenticated OpenCode upstream partners (Anthropic, OpenAI,
/// Ambient, …) that route through `opencode serve` — distinct from OpenCode Go
/// and OpenRouter, which already have their own top-level provider rows.
public enum OpenCodePartnerSupport {
    public static let enablementPrefix = "opencode-partner:"

    /// Provider ids in auth.json that already have dedicated top-level rows.
    public static let reservedAuthProviderIDs: Set<String> = [
        "openrouter",
        "opencode-go",
        "opencode",
    ]

    public static func enablementId(for partnerId: String) -> String {
        enablementPrefix + partnerId
    }

    public static func partnerId(fromEnablementId id: String) -> String? {
        guard id.hasPrefix(enablementPrefix) else { return nil }
        let partner = String(id.dropFirst(enablementPrefix.count))
        return partner.isEmpty ? nil : partner
    }

    public static func isUpstreamPartnerAuthId(_ providerId: String) -> Bool {
        !reservedAuthProviderIDs.contains(providerId.lowercased())
    }

    public static func displayName(for partnerId: String) -> String {
        switch partnerId.lowercased() {
        case "opencode-go", "opencode": return "OpenCode Go"
        case "openrouter": return "OpenRouter"
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "google": return "Google AI Studio"
        case "amazon-bedrock": return "Amazon Bedrock"
        case "ambient": return "Ambient"
        case "mistral": return "Mistral"
        case "groq": return "Groq"
        case "xai": return "xAI"
        case "deepseek": return "DeepSeek"
        case "github-copilot": return "GitHub Copilot"
        default:
            return partnerId
                .split(separator: "-")
                .map { part -> String in
                    let s = String(part)
                    guard !s.isEmpty else { return s }
                    return s.prefix(1).uppercased() + s.dropFirst()
                }
                .joined(separator: " ")
        }
    }
}

public struct OpenCodePartnerWireSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let enabled: Bool
    public let entries: [ModelCatalogEntry]

    public init(
        id: String,
        label: String,
        enabled: Bool = true,
        entries: [ModelCatalogEntry] = []
    ) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.entries = entries
    }
}
