import XCTest
import ClawdmeterShared

/// v0.23 (Chat V2 — T15): ChatV2Store contract tests.
///
/// Verifies the composer's selection-state observable persists across
/// instantiations + the `firstSendKind()` helper builds the correct
/// SendKind for the V2 composer's first-send path. These are tested
/// against an isolated `UserDefaults(suiteName:)` so concurrent test
/// runs don't clobber each other's state OR the user's real picks.
@MainActor
final class ChatV2StoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "clawdmeter.chatv2.tests.\(UUID().uuidString)"

    override func setUp() async throws {
        try await super.setUp()
        // Each test runs against its own UserDefaults suite so the
        // restore-after-init assertions don't see persisted state from
        // a sibling test.
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Defaults

    func test_init_defaults_to_broadcast_and_claude_solo_provider() {
        let store = ChatV2Store(defaults: defaults)
        XCTAssertEqual(store.mode, .broadcast)
        XCTAssertEqual(store.selectedProvider, .claude)
        XCTAssertEqual(store.broadcastProviderOrder, [.claude, .codex, .gemini])
        XCTAssertTrue(store.broadcastReady)
        XCTAssertEqual(store.selectedReplyProvider, .claude)
        XCTAssertFalse(store.deepResearch)
        XCTAssertEqual(store.codexBackendPreference, .sdk)
        XCTAssertTrue(store.attachments.isEmpty)
    }

    func test_selectedModel_falls_back_to_bundled_catalog_first_entry() {
        let store = ChatV2Store(defaults: defaults)
        XCTAssertEqual(store.selectedModel, ModelCatalog.bundled.claude.first?.id)
        store.selectedProvider = .codex
        XCTAssertEqual(store.selectedModel, ModelCatalog.bundled.codex.first?.id)
        store.selectedProvider = .gemini
        XCTAssertEqual(store.selectedModel, ModelCatalog.bundled.gemini.first?.id)
    }

    // MARK: - Persistence

    func test_persist_then_reload_restores_picks() {
        let store = ChatV2Store(defaults: defaults)
        store.mode = .solo
        store.selectedProvider = .codex
        store.broadcastProviders = [.claude, .gemini]
        store.selectedReplyProvider = .gemini
        store.deepResearch = true
        store.selectedModelByProvider[.codex] = "gpt-5.5-custom"
        store.selectedEffortByProvider[.codex] = .high
        store.codexBackendPreference = .cli
        store.persist()

        let reloaded = ChatV2Store(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .solo)
        XCTAssertEqual(reloaded.selectedProvider, .codex)
        XCTAssertEqual(reloaded.broadcastProviderOrder, [.claude, .gemini])
        XCTAssertEqual(reloaded.selectedReplyProvider, .gemini)
        XCTAssertTrue(reloaded.deepResearch)
        XCTAssertEqual(reloaded.selectedModelByProvider[.codex], "gpt-5.5-custom")
        XCTAssertEqual(reloaded.selectedEffortByProvider[.codex], .high)
        XCTAssertEqual(reloaded.codexBackendPreference, .cli)
    }

    func test_broadcast_provider_toggle_keeps_two_supported_providers() {
        let store = ChatV2Store(defaults: defaults)

        store.toggleBroadcastProvider(.gemini)
        XCTAssertEqual(store.broadcastProviderOrder, [.claude, .codex])
        XCTAssertTrue(store.broadcastReady)

        store.toggleBroadcastProvider(.codex)
        XCTAssertEqual(store.broadcastProviderOrder, [.claude, .codex], "broadcast must keep at least two providers selected")

        store.toggleBroadcastProvider(.opencode)
        XCTAssertEqual(store.broadcastProviderOrder, [.claude, .codex], "OpenCode is not broadcast-capable in this pass")
    }

    func test_frontierSlots_carry_provider_model_effort_backend_and_deepResearch() {
        let store = ChatV2Store(defaults: defaults)
        store.broadcastProviders = [.claude, .codex]
        store.deepResearch = true
        store.selectedModelByProvider[.claude] = "claude-opus-test"
        store.selectedModelByProvider[.codex] = "gpt-5.5-test"
        store.selectedEffortByProvider[.codex] = .high
        store.codexBackendPreference = .cli

        let slots = store.frontierSlots()
        XCTAssertEqual(slots.map(\.provider), [.claude, .codex])
        XCTAssertEqual(slots[0].model, "claude-opus-test")
        XCTAssertNil(slots[0].codexChatBackend)
        XCTAssertEqual(slots[1].model, "gpt-5.5-test")
        XCTAssertEqual(slots[1].effort, .high)
        XCTAssertEqual(slots[1].codexChatBackend, .cli)
        XCTAssertTrue(slots.allSatisfy(\.deepResearch))
    }

    func test_chatOpenTarget_roundTrips_frontier_and_solo() throws {
        let soloId = UUID()
        let frontierId = UUID()
        let targets: [ChatOpenTarget] = [.solo(soloId), .frontier(frontierId)]

        let data = try JSONEncoder().encode(targets)
        let decoded = try JSONDecoder().decode([ChatOpenTarget].self, from: data)

        XCTAssertEqual(decoded, targets)
        XCTAssertEqual(decoded[0].id, soloId)
        XCTAssertEqual(decoded[1].id, frontierId)
        XCTAssertFalse(decoded[0].isFrontier)
        XCTAssertTrue(decoded[1].isFrontier)
    }

    // MARK: - firstSendKind

    func test_firstSendKind_carries_provider_model_effort_deepResearch() {
        let store = ChatV2Store(defaults: defaults)
        store.selectedProvider = .codex
        store.selectedModelByProvider[.codex] = "gpt-5.5"
        store.selectedEffortByProvider[.codex] = .max
        store.deepResearch = true
        store.codexBackendPreference = .sdk

        let kind = store.firstSendKind()
        guard case let .chatCreateV2(provider, model, effort, deepResearch, codexBackend) = kind else {
            XCTFail("expected .chatCreateV2, got \(kind)")
            return
        }
        XCTAssertEqual(provider, .codex)
        XCTAssertEqual(model, "gpt-5.5")
        XCTAssertEqual(effort, .max)
        XCTAssertTrue(deepResearch)
        XCTAssertEqual(codexBackend, .sdk)
    }

    func test_firstSendKind_omits_codexBackend_when_not_codex() {
        let store = ChatV2Store(defaults: defaults)
        store.selectedProvider = .claude
        let kind = store.firstSendKind()
        guard case let .chatCreateV2(_, _, _, _, codexBackend) = kind else {
            XCTFail("expected .chatCreateV2")
            return
        }
        XCTAssertNil(codexBackend, "non-Codex provider must not carry a codexBackend pick")
    }

    // MARK: - Attachments

    func test_addAttachment_appends_and_capped_at_ten() {
        let store = ChatV2Store(defaults: defaults)
        for i in 0..<15 {
            store.addAttachment(ChatV2Attachment(displayName: "file\(i).txt"))
        }
        XCTAssertEqual(store.attachments.count, 10, "attachment add must cap at 10")
    }

    func test_removeAttachment_by_id() {
        let store = ChatV2Store(defaults: defaults)
        let a = ChatV2Attachment(displayName: "a.txt")
        let b = ChatV2Attachment(displayName: "b.txt")
        store.addAttachment(a)
        store.addAttachment(b)
        store.removeAttachment(id: a.id)
        XCTAssertEqual(store.attachments.count, 1)
        XCTAssertEqual(store.attachments.first?.id, b.id)
    }

    func test_clearAttachments() {
        let store = ChatV2Store(defaults: defaults)
        store.addAttachment(ChatV2Attachment(displayName: "a.txt"))
        store.addAttachment(ChatV2Attachment(displayName: "b.txt"))
        store.clearAttachments()
        XCTAssertTrue(store.attachments.isEmpty)
    }
}
