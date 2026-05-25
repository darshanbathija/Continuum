import XCTest
@testable import ClawdmeterShared

@MainActor
final class ChatV2StoreCursorTests: XCTestCase {

    func test_cursorIsNotBroadcastCapableUntilTranscriptSupportExists() async {
        XCTAssertFalse(ChatV2Store.broadcastCapableProviders.contains(.cursor))
        XCTAssertFalse(ChatV2Store.defaultBroadcastProviderOrder.contains(.cursor))
    }

    func test_restoredCursorChatProviderFallsBackToClaude() async {
        let suiteName = "ChatV2StoreCursorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AgentKind.cursor.rawValue, forKey: "clawdmeter.chatv2.provider")
        defaults.set(AgentKind.cursor.rawValue, forKey: "clawdmeter.chatv2.replyProvider")
        defaults.set([AgentKind.cursor.rawValue], forKey: "clawdmeter.chatv2.broadcastProviders")

        let store = ChatV2Store(defaults: defaults)

        XCTAssertEqual(store.selectedProvider, .claude)
        XCTAssertEqual(store.selectedReplyProvider, .claude)
        XCTAssertEqual(store.broadcastProviders, Set([.claude, .codex]))
    }
}
