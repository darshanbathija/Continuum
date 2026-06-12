import Foundation

/// Canonical provider metadata shared by Settings, Chat, analytics, and
/// cross-platform chrome. Raw ids remain the compatibility contract; ranks
/// let each surface keep its current ordering without maintaining duplicate
/// provider lists.
public struct ProviderDescriptor: Sendable, Identifiable {
    public let id: String
    public let agent: AgentKind
    public let chatVendor: ChatVendor
    public let analyticsProvider: UsageRecord.Provider
    public let agentDisplayName: String
    public let assetName: String
    public let isTemplateAsset: Bool
    public let accentRGB: (r: Int, g: Int, b: Int)
    public let settingsRank: Int
    public let chatRank: Int
    /// Code/Chat model-picker rail fallback when 30d usage is tied or absent.
    public let modelPickerRank: Int
    public let analyticsRank: Int
    public let costStackRank: Int?

    public static let all: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: "claude",
            agent: .claude,
            chatVendor: .claude,
            analyticsProvider: .claude,
            agentDisplayName: "Claude",
            assetName: "ClaudeLogo",
            isTemplateAsset: false,
            accentRGB: (0xD9, 0x77, 0x57),
            settingsRank: 0,
            chatRank: 1,
            modelPickerRank: 0,
            analyticsRank: 0,
            costStackRank: 0
        ),
        ProviderDescriptor(
            id: "codex",
            agent: .codex,
            chatVendor: .chatgpt,
            analyticsProvider: .codex,
            agentDisplayName: "Codex",
            assetName: "CodexLogo",
            isTemplateAsset: true,
            accentRGB: (0x8A, 0x90, 0x99),
            settingsRank: 1,
            chatRank: 0,
            modelPickerRank: 1,
            analyticsRank: 1,
            costStackRank: 1
        ),
        ProviderDescriptor(
            id: "gemini",
            agent: .gemini,
            chatVendor: .antigravity,
            analyticsProvider: .gemini,
            agentDisplayName: "Gemini",
            assetName: "GeminiLogo",
            isTemplateAsset: true,
            accentRGB: (0x5C, 0x9D, 0xFF),
            settingsRank: 2,
            chatRank: 2,
            modelPickerRank: 6,
            analyticsRank: 2,
            costStackRank: nil
        ),
        ProviderDescriptor(
            id: "cursor",
            agent: .cursor,
            chatVendor: .cursor,
            analyticsProvider: .cursor,
            agentDisplayName: "Cursor",
            assetName: "CursorLogo",
            isTemplateAsset: true,
            accentRGB: (0x7F, 0xA8, 0xB5),
            settingsRank: 3,
            chatRank: 3,
            modelPickerRank: 2,
            analyticsRank: 4,
            costStackRank: 3
        ),
        ProviderDescriptor(
            id: "opencode",
            agent: .opencode,
            chatVendor: .opencode,
            analyticsProvider: .opencode,
            agentDisplayName: "OpenCode",
            assetName: "OpencodeLogo",
            isTemplateAsset: true,
            accentRGB: (0x9B, 0x87, 0xD4),
            settingsRank: 4,
            chatRank: 4,
            modelPickerRank: 3,
            analyticsRank: 3,
            costStackRank: 2
        ),
        ProviderDescriptor(
            id: "openrouter",
            agent: .opencode,
            chatVendor: .openrouter,
            analyticsProvider: .opencode,
            agentDisplayName: "OpenRouter",
            assetName: "OpenRouterLogo",
            isTemplateAsset: true,
            accentRGB: (0x6B, 0x8A, 0xFF),
            settingsRank: 5,
            chatRank: 5,
            modelPickerRank: 4,
            analyticsRank: 3,
            costStackRank: nil
        ),
        ProviderDescriptor(
            id: "grok",
            agent: .grok,
            chatVendor: .grok,
            analyticsProvider: .grok,
            agentDisplayName: "Grok",
            assetName: "GrokLogo",
            isTemplateAsset: true,
            accentRGB: (0x70, 0x74, 0x7C),
            settingsRank: 6,
            chatRank: 6,
            modelPickerRank: 5,
            analyticsRank: 5,
            costStackRank: 4
        ),
    ]

    public static let byId: [String: ProviderDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Primary descriptor per agent kind. OpenRouter also routes through
    /// `AgentKind.opencode` but is addressed via its own provider id.
    public static let byAgent: [AgentKind: ProviderDescriptor] =
        Dictionary(uniqueKeysWithValues: all.compactMap { descriptor in
            guard descriptor.id == descriptor.agent.rawValue else { return nil }
            return (descriptor.agent, descriptor)
        })

    public static let byChatVendor: [ChatVendor: ProviderDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.chatVendor, $0) })

    public static let byAnalyticsProvider: [UsageRecord.Provider: ProviderDescriptor] =
        Dictionary(uniqueKeysWithValues: all.compactMap { descriptor in
            guard descriptor.id == descriptor.analyticsProvider.rawValue else { return nil }
            return (descriptor.analyticsProvider, descriptor)
        })

    public static var settingsOrder: [ProviderDescriptor] {
        all.sorted { $0.settingsRank < $1.settingsRank }
    }

    public static var chatOrder: [ChatVendor] {
        all.sorted { $0.chatRank < $1.chatRank }.map(\.chatVendor)
    }

    public static var modelPickerOrder: [ChatVendor] {
        all.sorted { $0.modelPickerRank < $1.modelPickerRank }.map(\.chatVendor)
    }

    public static var analyticsDisplayOrder: [UsageRecord.Provider] {
        var seen = Set<UsageRecord.Provider>()
        return all
            .sorted { $0.analyticsRank < $1.analyticsRank }
            .compactMap { descriptor in
                seen.insert(descriptor.analyticsProvider).inserted ? descriptor.analyticsProvider : nil
            }
    }

    public static var analyticsCostStackOrder: [UsageRecord.Provider] {
        all
            .compactMap { descriptor -> (rank: Int, provider: UsageRecord.Provider)? in
                guard let rank = descriptor.costStackRank else { return nil }
                return (rank, descriptor.analyticsProvider)
            }
            .sorted { $0.rank < $1.rank }
            .map(\.provider)
    }
}
