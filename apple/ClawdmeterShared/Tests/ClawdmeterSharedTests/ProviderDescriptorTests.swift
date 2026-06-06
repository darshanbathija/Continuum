import XCTest
@testable import ClawdmeterShared

final class ProviderDescriptorTests: XCTestCase {
    @MainActor
    func test_descriptorCoversEverySelectableAgentAndSurfaceOrder() {
        let selectableAgents = Set(AgentKind.allCases)
        let describedAgents = Set(ProviderDescriptor.all.map(\.agent))
        XCTAssertEqual(describedAgents, selectableAgents)

        XCTAssertEqual(
            ProviderEnablement.allProviderIds,
            ["claude", "codex", "gemini", "cursor", "opencode", "grok"]
        )
        XCTAssertEqual(
            ChatV2Store.defaultChatVendorOrder,
            [.chatgpt, .claude, .antigravity, .cursor, .openrouter, .grok]
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
            XCTAssertEqual(ProviderDescriptor.byAgent[descriptor.agent]?.id, descriptor.id)
            XCTAssertEqual(ProviderDescriptor.byChatVendor[descriptor.chatVendor]?.id, descriptor.id)
            XCTAssertEqual(ProviderDescriptor.byAnalyticsProvider[descriptor.analyticsProvider]?.id, descriptor.id)
            XCTAssertEqual(AgentKindUI.displayName(for: descriptor.agent), descriptor.agentDisplayName)
            XCTAssertEqual(AgentKindUI.assetName(for: descriptor.agent), descriptor.assetName)
            XCTAssertEqual(AgentKindUI.isTemplate(for: descriptor.agent), descriptor.isTemplateAsset)
            XCTAssertEqual(AgentKindUI.displayName(for: descriptor.analyticsProvider), descriptor.agentDisplayName)
            XCTAssertEqual(AgentKindUI.assetName(for: descriptor.analyticsProvider), descriptor.assetName)
            XCTAssertEqual(AgentKindUI.isTemplate(for: descriptor.analyticsProvider), descriptor.isTemplateAsset)
        }

        XCTAssertEqual(AgentKindUI.displayName(for: .unknown), "Other agent")
        XCTAssertEqual(AgentKindUI.assetName(for: .unknown), "ClaudeLogo")
        XCTAssertTrue(AgentKindUI.isTemplate(for: .unknown))
    }
}
