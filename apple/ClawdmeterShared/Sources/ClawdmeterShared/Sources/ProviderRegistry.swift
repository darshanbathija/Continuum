import Foundation

public enum ProviderCapability: String, Sendable, Hashable, CaseIterable {
    case chat
    case code
    case liveUsage
    case historicalUsage
    case menuBar
    case mobileMirror
    case widget
}

public extension ProviderDescriptor {
    var displayName: String { agentDisplayName }
    var agentKind: AgentKind? { agent }
    var usageProvider: UsageRecord.Provider? { analyticsProvider }

    var capabilities: Set<ProviderCapability> {
        // OpenCode Go is now a full live-usage provider, identical to every
        // other kind — no per-id divergence to special-case.
        [.chat, .code, .liveUsage, .historicalUsage, .menuBar, .mobileMirror, .widget]
    }
}

public enum ProviderRegistry {
    public static var descriptors: [ProviderDescriptor] {
        ProviderDescriptor.settingsOrder
    }

    public static var allProviderIDs: [String] {
        descriptors.map(\.id)
    }

    public static func descriptor(id: String) -> ProviderDescriptor? {
        ProviderDescriptor.byId[rootProviderID(for: id)]
    }

    public static func descriptor(chatVendor: ChatVendor) -> ProviderDescriptor? {
        ProviderDescriptor.byChatVendor[chatVendor]
    }

    public static func descriptor(agentKind: AgentKind) -> ProviderDescriptor? {
        ProviderDescriptor.byAgent[agentKind]
    }

    public static func descriptor(usageProvider: UsageRecord.Provider) -> ProviderDescriptor? {
        ProviderDescriptor.byAnalyticsProvider[usageProvider]
    }

    public static func rootProviderID(for id: String) -> String {
        if let slash = id.firstIndex(of: "/") {
            return String(id[..<slash])
        }
        if id == "antigravity" { return "gemini" }
        if id == "openrouter" { return "opencode" }
        return id
    }

    public static func enabledProviders(for capability: ProviderCapability) -> [ProviderDescriptor] {
        descriptors.filter { $0.capabilities.contains(capability) && ProviderEnablement.isEnabled($0.id) }
    }

    public static func firstEnabledProvider(for capability: ProviderCapability) -> ProviderDescriptor? {
        enabledProviders(for: capability).first
    }

    public static func isVisible(id: String, capability: ProviderCapability) -> Bool {
        guard let descriptor = descriptor(id: id),
              descriptor.capabilities.contains(capability)
        else { return false }
        return ProviderEnablement.isEnabled(descriptor.id)
    }

    public static func enabledAgentKinds(for capability: ProviderCapability) -> [AgentKind] {
        enabledProviders(for: capability).map(\.agent)
    }

    public static func enabledChatVendors() -> [ChatVendor] {
        enabledProviders(for: .chat).map(\.chatVendor)
    }

    public static func enabledUsageProviders() -> [UsageRecord.Provider] {
        enabledProviders(for: .historicalUsage).map(\.analyticsProvider)
    }

    public static func isEnabled(agentKind: AgentKind) -> Bool {
        guard let descriptor = descriptor(agentKind: agentKind) else { return false }
        return ProviderEnablement.isEnabled(descriptor.id)
    }

    public static func isEnabled(chatVendor: ChatVendor) -> Bool {
        guard let descriptor = descriptor(chatVendor: chatVendor) else { return false }
        return ProviderEnablement.isEnabled(descriptor.id)
    }

    public static func isEnabled(usageProvider: UsageRecord.Provider) -> Bool {
        guard let descriptor = descriptor(usageProvider: usageProvider) else { return false }
        return ProviderEnablement.isEnabled(descriptor.id)
    }

    /// Parse a custom provider id from a wire namespace id (`custom/<id>`).
    public static func customProviderId(from wireId: String) -> String? {
        let prefix = "custom/"
        guard wireId.hasPrefix(prefix) else { return nil }
        let id = String(wireId.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Wire namespace id for a custom provider record.
    public static func wireId(forCustomProviderId id: String) -> String {
        "custom/\(id)"
    }
}
