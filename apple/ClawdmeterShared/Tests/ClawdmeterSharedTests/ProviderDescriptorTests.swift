import XCTest
@testable import ClawdmeterShared

final class ProviderDescriptorTests: XCTestCase {
    @MainActor
    func test_descriptorCoversEverySelectableAgentAndSurfaceOrder() {
        let selectableAgents = Set(AgentKind.allCases.filter { $0 != .unknown })
        let describedAgents = Set(ProviderDescriptor.all.map(\.agent))
        XCTAssertTrue(describedAgents.isSuperset(of: selectableAgents))

        XCTAssertEqual(
            ProviderEnablement.allProviderIds,
            ["claude", "codex", "gemini", "cursor", "opencode", "openrouter", "grok"]
        )
        XCTAssertEqual(
            ChatV2Store.defaultChatVendorOrder,
            [.chatgpt, .claude, .antigravity, .cursor, .opencode, .openrouter, .grok]
        )
        XCTAssertEqual(
            ProviderDescriptor.modelPickerOrder,
            [.claude, .chatgpt, .cursor, .opencode, .openrouter, .grok, .antigravity]
        )
        XCTAssertEqual(
            UsageRecord.Provider.analyticsDisplayOrder,
            [.claude, .codex, .gemini, .opencode, .cursor, .grok]
        )
        XCTAssertEqual(
            UsageRecord.Provider.analyticsCostStackOrder,
            [.claude, .codex, .opencode, .cursor, .grok]
        )
    }

    func test_descriptorDrivesAgentAndAnalyticsMetadata() throws {
        for descriptor in ProviderDescriptor.all {
            XCTAssertEqual(ProviderDescriptor.byId[descriptor.id]?.agent, descriptor.agent)
            if descriptor.id == descriptor.agent.rawValue {
                XCTAssertEqual(ProviderDescriptor.byAgent[descriptor.agent]?.id, descriptor.id)
            }
            XCTAssertEqual(ProviderDescriptor.byChatVendor[descriptor.chatVendor]?.id, descriptor.id)
            if descriptor.id == descriptor.analyticsProvider.rawValue {
                XCTAssertEqual(ProviderDescriptor.byAnalyticsProvider[descriptor.analyticsProvider]?.id, descriptor.id)
                XCTAssertEqual(AgentKindUI.displayName(for: descriptor.analyticsProvider), descriptor.agentDisplayName)
                XCTAssertEqual(AgentKindUI.assetName(for: descriptor.analyticsProvider), descriptor.assetName)
                XCTAssertEqual(AgentKindUI.isTemplate(for: descriptor.analyticsProvider), descriptor.isTemplateAsset)
            }
            if descriptor.id == descriptor.agent.rawValue {
                XCTAssertEqual(AgentKindUI.displayName(for: descriptor.agent), descriptor.agentDisplayName)
                XCTAssertEqual(AgentKindUI.assetName(for: descriptor.agent), descriptor.assetName)
                XCTAssertEqual(AgentKindUI.isTemplate(for: descriptor.agent), descriptor.isTemplateAsset)
            }
        }

        XCTAssertEqual(ProviderDescriptor.byId["openrouter"]?.assetName, "OpenRouterLogo")
        XCTAssertEqual(ChatVendor.openrouter.tahoeProvider, .openrouter)
        XCTAssertEqual(TahoeProvider.openrouter.logoAssetName, "tahoe-openrouter-mark")
        XCTAssertEqual(AgentKindUI.displayName(for: .unknown), "Other agent")
        XCTAssertEqual(AgentKindUI.assetName(for: .unknown), "ClaudeLogo")
        XCTAssertTrue(AgentKindUI.isTemplate(for: .unknown))
    }
}
