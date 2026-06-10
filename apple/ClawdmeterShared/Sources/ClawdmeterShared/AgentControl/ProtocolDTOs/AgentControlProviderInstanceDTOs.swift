import Foundation

// MARK: - Multi-account provider instances (wire v28)

/// One configured account in `GET /provider-instances`. Deliberately
/// path-free: the configRoot is Mac-local state and never crosses the
/// wire (the iPhone has no business knowing the Mac's filesystem
/// layout; it only needs a stable id + a label).
public struct ProviderInstanceDTO: Codable, Sendable, Equatable, Identifiable {
    /// `ProviderInstanceId.wireId` — the value clients send back as
    /// `providerInstanceId` on session/chat creation.
    public let wireId: String
    public let kind: AgentKind
    /// The user's slug ("work", "personal"). `__primary__` for the
    /// default account — render via `displayName`, not raw.
    public let name: String
    public let isPrimary: Bool
    /// Picker label: "Default" for the primary, else the slug.
    public let displayName: String

    public var id: String { wireId }

    public init(wireId: String, kind: AgentKind, name: String, isPrimary: Bool, displayName: String) {
        self.wireId = wireId
        self.kind = kind
        self.name = name
        self.isPrimary = isPrimary
        self.displayName = displayName
    }

    public init(instance: ProviderInstanceId) {
        self.init(
            wireId: instance.wireId,
            kind: instance.kind,
            name: instance.name,
            isPrimary: instance.isPrimary,
            displayName: instance.isPrimary ? "Default" : instance.name
        )
    }
}

/// `GET /provider-instances` response. Always carries at least the
/// primary instance per supported kind; account pickers render only
/// when a kind has ≥ 2 entries.
public struct ProviderInstanceListResponse: Codable, Sendable, Equatable {
    public let instances: [ProviderInstanceDTO]

    public init(instances: [ProviderInstanceDTO]) {
        self.instances = instances
    }

    public func instances(for kind: AgentKind) -> [ProviderInstanceDTO] {
        instances.filter { $0.kind == kind }
    }
}
