import Foundation

// MARK: - Custom provider wire DTOs (wire v28)

/// Which OpenAI/Anthropic-compatible API surface a user-configured endpoint speaks.
public enum CustomProviderKind: String, Codable, Hashable, Sendable, CaseIterable {
    case openAICompatible = "openAICompatible"
    case anthropicCompatible = "anthropicCompatible"

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropicCompatible: return "Anthropic-compatible"
        }
    }

    /// Lenient decoder: unknown raw values fold to `.openAICompatible`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = CustomProviderKind(rawValue: raw) ?? .openAICompatible
    }
}

/// Where the daemon resolves the API key — never serialized on the wire.
public enum CustomProviderKeySource: Codable, Hashable, Sendable {
    case keychain
    case environmentVariable(name: String)

    private enum Discriminator: String, Codable {
        case keychain
        case environmentVariable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(Discriminator.self, forKey: .type)
        switch type {
        case .keychain:
            self = .keychain
        case .environmentVariable:
            let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            self = .environmentVariable(name: name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keychain:
            try c.encode(Discriminator.keychain, forKey: .type)
        case .environmentVariable(let name):
            try c.encode(Discriminator.environmentVariable, forKey: .type)
            try c.encode(name, forKey: .name)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, name
    }
}

/// One custom provider as exposed on the wire (no secrets).
public struct CustomProviderWireSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let kind: CustomProviderKind
    public let baseURL: String
    public let defaultModelId: String?
    public let enabled: Bool
    public let entries: [ModelCatalogEntry]

    public init(
        id: String,
        label: String,
        kind: CustomProviderKind,
        baseURL: String,
        defaultModelId: String? = nil,
        enabled: Bool = true,
        entries: [ModelCatalogEntry] = []
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.baseURL = baseURL
        self.defaultModelId = defaultModelId
        self.enabled = enabled
        self.entries = entries
    }
}

/// One row in `GET /chat-providers` for a custom provider.
public struct CustomChatProviderEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let kind: CustomProviderKind
    public let available: Bool
    public let reason: String?
    public let lastProbedAt: Date?

    public init(
        id: String,
        label: String,
        kind: CustomProviderKind,
        available: Bool,
        reason: String? = nil,
        lastProbedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.available = available
        self.reason = reason
        self.lastProbedAt = lastProbedAt
    }
}
