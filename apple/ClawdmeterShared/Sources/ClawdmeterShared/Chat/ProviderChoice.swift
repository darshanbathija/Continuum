import Foundation

/// Unified picker abstraction for built-in chat vendors and user-configured
/// custom providers. Persisted via `"custom:<id>"` keys in provider defaults
/// and the Chat V2 vendor selection array.
public enum ProviderChoice: Hashable, Identifiable, Sendable {
    case builtin(ChatVendor)
    case custom(String)

    public var id: String {
        switch self {
        case .builtin(let vendor):
            return vendor.rawValue
        case .custom(let providerId):
            return "custom:\(providerId)"
        }
    }

    /// Lenient restore from persisted string keys.
    public static func decode(_ raw: String) -> ProviderChoice? {
        if raw.hasPrefix("custom:") {
            let providerId = String(raw.dropFirst("custom:".count))
            guard !providerId.isEmpty else { return nil }
            return .custom(providerId)
        }
        guard let vendor = ChatVendor(rawValue: raw) else { return nil }
        return .builtin(vendor)
    }

    public func displayName(in catalog: ModelCatalog) -> String {
        switch self {
        case .builtin(let vendor):
            return vendor.displayName
        case .custom(let providerId):
            return catalog.customProviders.first(where: { $0.id == providerId })?.label ?? providerId
        }
    }

    public func models(in catalog: ModelCatalog) -> [ModelCatalogEntry] {
        switch self {
        case .builtin(let vendor):
            return vendor.models(in: catalog)
        case .custom(let providerId):
            return catalog.customProviders.first(where: { $0.id == providerId })?.entries ?? []
        }
    }

    public func backingAgent(in catalog: ModelCatalog) -> AgentKind? {
        switch self {
        case .builtin(let vendor):
            return vendor.backingProvider
        case .custom(let providerId):
            guard let summary = catalog.customProviders.first(where: { $0.id == providerId }) else {
                return nil
            }
            switch summary.kind {
            case .anthropicCompatible: return .claude
            case .openAICompatible: return .codex
            }
        }
    }

    public func defaultModelId(in catalog: ModelCatalog) -> String? {
        switch self {
        case .builtin(let vendor):
            return vendor.defaultModelId(in: catalog)
        case .custom(let providerId):
            if let summary = catalog.customProviders.first(where: { $0.id == providerId }) {
                if let explicit = summary.defaultModelId, !explicit.isEmpty {
                    return explicit
                }
                return summary.entries.first?.id
            }
            return nil
        }
    }

    public var chatVendor: ChatVendor? {
        if case .builtin(let vendor) = self { return vendor }
        return nil
    }

    public var customProviderId: String? {
        if case .custom(let id) = self { return id }
        return nil
    }

    /// Analytics bucket used to read trailing-30d usage for rail ordering.
    public var usageProvider: UsageRecord.Provider? {
        guard case .builtin(let vendor) = self else { return nil }
        return ProviderDescriptor.byChatVendor[vendor]?.analyticsProvider
    }

    /// Fallback rail rank when 30d usage is tied or unavailable.
    public var modelPickerDefaultRank: Int {
        switch self {
        case .builtin(let vendor):
            return ProviderDescriptor.byChatVendor[vendor]?.modelPickerRank ?? Int.max
        case .custom:
            return ProviderDescriptor.all.count
        }
    }

    /// Provider rail + chip glyph for the composer's current model selection.
    /// Prefers the live `modelId` binding (which updates immediately on picker
    /// toggles) over `agent`, which can lag behind during provisioning or
    /// optimistic chip edits.
    public static func resolvedForDisplay(
        modelId: String?,
        customProviderId: String?,
        agent: AgentKind,
        catalog: ModelCatalog,
        enabledChoices: [ProviderChoice]
    ) -> ProviderChoice {
        if let trimmed = modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            if let customProviderId, !customProviderId.isEmpty,
               enabledChoices.contains(.custom(customProviderId)) {
                return .custom(customProviderId)
            }
            if let entry = catalog.entry(forId: trimmed, customProviderId: customProviderId),
               let vendor = ChatVendor.migrated(from: entry.provider),
               enabledChoices.contains(.builtin(vendor)) {
                return .builtin(vendor)
            }
        }
        if let customProviderId, !customProviderId.isEmpty,
           enabledChoices.contains(.custom(customProviderId)) {
            return .custom(customProviderId)
        }
        if let migrated = ChatVendor.migrated(from: agent),
           enabledChoices.contains(.builtin(migrated)) {
            return .builtin(migrated)
        }
        return enabledChoices.first ?? .builtin(.chatgpt)
    }
}
