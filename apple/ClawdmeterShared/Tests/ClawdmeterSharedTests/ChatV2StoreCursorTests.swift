import XCTest
@testable import ClawdmeterShared

final class ChatV2StoreCursorTests: XCTestCase {

    @MainActor
    func test_cursorAndOpenRouterAreSelectableChatVendors() async {
        XCTAssertTrue(ChatV2Store.defaultChatVendorOrder.contains(.cursor))
        XCTAssertTrue(ChatV2Store.defaultChatVendorOrder.contains(.openrouter))
        XCTAssertTrue(ChatV2Store.broadcastCapableProviders.contains(.cursor))
        XCTAssertTrue(ChatV2Store.broadcastCapableProviders.contains(.opencode))
    }

    @MainActor
    func test_restoredCursorAndOpenRouterVendorsPersist() async {
        let suiteName = "ChatV2StoreCursorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([ChatVendor.cursor.rawValue, ChatVendor.openrouter.rawValue], forKey: "clawdmeter.chatv2.vendors")
        defaults.set([
            ChatVendor.cursor.rawValue: CursorModelCatalog.autoModelId,
            ChatVendor.openrouter.rawValue: "anthropic/claude-sonnet-4.6",
        ], forKey: "clawdmeter.chatv2.modelByVendor")

        let store = ChatV2Store(defaults: defaults)

        XCTAssertEqual(store.selectedVendors, [.cursor, .openrouter])
        XCTAssertEqual(store.selectedProvider, .cursor)
        XCTAssertEqual(store.model(for: .cursor), CursorModelCatalog.autoModelId)
        XCTAssertEqual(store.model(for: .openrouter), "anthropic/claude-sonnet-4.6")
    }
}
