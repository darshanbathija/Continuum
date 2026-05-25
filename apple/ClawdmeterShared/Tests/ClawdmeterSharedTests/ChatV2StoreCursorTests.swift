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

    @MainActor
    func test_providerDefaultsStoreMigratesLegacyChatV2MapsWithoutOverwritingExplicitDefaults() async {
        let suiteName = "ProviderDefaultsMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([
            ChatVendor.openrouter.rawValue: "anthropic/claude-sonnet-4.6",
            ChatVendor.cursor.rawValue: CursorModelCatalog.autoModelId,
        ], forKey: "clawdmeter.chatv2.modelByVendor")
        defaults.set([
            ChatVendor.openrouter.rawValue: ReasoningEffort.high.rawValue,
            ChatVendor.cursor.rawValue: ReasoningEffort.high.rawValue,
        ], forKey: "clawdmeter.chatv2.effortByVendor")
        defaults.set([
            ChatVendor.openrouter.rawValue: "openai/gpt-5.5",
        ], forKey: "clawdmeter.providerDefaults.modelByVendor")

        let store = ProviderDefaultsStore(defaults: defaults)

        XCTAssertEqual(store.snapshot.modelByVendor[ChatVendor.openrouter.rawValue], "openai/gpt-5.5")
        XCTAssertEqual(store.snapshot.modelByVendor[ChatVendor.cursor.rawValue], CursorModelCatalog.autoModelId)
        XCTAssertEqual(store.snapshot.effortByVendor[ChatVendor.openrouter.rawValue], ReasoningEffort.high.rawValue)
        XCTAssertEqual(store.snapshot.effortByVendor[ChatVendor.cursor.rawValue], ReasoningEffort.high.rawValue)
    }

    @MainActor
    func test_chatV2StoreUsesProviderDefaultsBeforeCatalogFallback() async {
        let suiteName = "ChatV2ProviderDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([
            ChatVendor.openrouter.rawValue: "anthropic/claude-sonnet-4.6",
            ChatVendor.cursor.rawValue: CursorModelCatalog.autoModelId,
        ], forKey: "clawdmeter.providerDefaults.modelByVendor")
        defaults.set([
            ChatVendor.openrouter.rawValue: ReasoningEffort.high.rawValue,
        ], forKey: "clawdmeter.providerDefaults.effortByVendor")

        let store = ChatV2Store(defaults: defaults)

        XCTAssertEqual(store.model(for: .openrouter), "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(store.effort(for: .openrouter), .high)
        XCTAssertEqual(store.model(for: .cursor), CursorModelCatalog.autoModelId)
        XCTAssertNil(store.effort(for: .cursor))
    }

    @MainActor
    func test_chatV2StoreAppliesPairedProviderDefaultsSnapshot() async {
        let suiteName = "ChatV2ProviderDefaultsApply.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = ModelCatalog.bundled
            .replacingOpenRouter([
                ModelCatalogEntry(
                    id: "openrouter/live-reasoning",
                    provider: .opencode,
                    displayName: "OpenRouter Live Reasoning",
                    supportsThinking: true,
                    supportsEffort: true
                )
            ])
            .replacingCursor([
                CursorModelCatalog.autoEntry,
                ModelCatalogEntry(
                    id: "cursor-account-auto",
                    provider: .cursor,
                    displayName: "Cursor Account Auto",
                    supportsThinking: true,
                    supportsEffort: false
                )
            ])
        let snapshot = ProviderDefaultsSnapshot(
            modelByVendor: [
                ChatVendor.openrouter.rawValue: "openrouter/live-reasoning",
                ChatVendor.cursor.rawValue: "cursor-account-auto",
            ],
            effortByVendor: [
                ChatVendor.openrouter.rawValue: ReasoningEffort.high.rawValue,
                ChatVendor.cursor.rawValue: ReasoningEffort.high.rawValue,
            ]
        )
        let store = ChatV2Store(defaults: defaults)

        store.applyProviderDefaults(snapshot, catalog: catalog)

        XCTAssertEqual(store.model(for: .openrouter, catalog: catalog), "openrouter/live-reasoning")
        XCTAssertEqual(store.effort(for: .openrouter, catalog: catalog), .high)
        XCTAssertEqual(store.model(for: .cursor, catalog: catalog), "cursor-account-auto")
        XCTAssertNil(store.effort(for: .cursor, catalog: catalog))
        XCTAssertEqual(ProviderDefaultsStore(defaults: defaults).snapshot.modelByVendor[ChatVendor.openrouter.rawValue], "openrouter/live-reasoning")
    }

    @MainActor
    func test_cursorEffortIsDisabledUntilCatalogEntrySupportsEffort() async {
        let suiteName = "CursorEffortDisabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ChatV2Store(defaults: defaults)

        store.selectModel(CursorModelCatalog.autoModelId, for: .cursor)
        store.selectEffort(.high, for: .cursor)

        XCTAssertNil(store.effort(for: .cursor))
        let persisted = ProviderDefaultsStore(defaults: defaults)
        XCTAssertNil(persisted.snapshot.effort(for: .cursor))
    }

    @MainActor
    func test_openRouterEffortClearsWhenSelectedModelDoesNotSupportIt() async {
        let suiteName = "OpenRouterUnsupportedEffort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = ModelCatalog.bundled.replacingOpenRouter([
            ModelCatalogEntry(
                id: "google/gemini-3-pro",
                provider: .opencode,
                displayName: "OpenRouter · Gemini 3 Pro",
                supportsThinking: true,
                supportsEffort: false,
                contextWindow: 2_000_000
            )
        ])
        let providerDefaults = ProviderDefaultsStore(defaults: defaults)

        providerDefaults.setDefault(
            for: .openrouter,
            model: "google/gemini-3-pro",
            effort: .high,
            catalog: catalog
        )

        XCTAssertEqual(providerDefaults.snapshot.modelByVendor[ChatVendor.openrouter.rawValue], "google/gemini-3-pro")
        XCTAssertNil(providerDefaults.snapshot.effort(for: .openrouter))
        XCTAssertNil(providerDefaults.effort(for: .openrouter, catalog: catalog))
    }
}
