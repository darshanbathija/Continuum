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

    func test_init_defaults_to_claude_provider_and_no_deepResearch() {
        let store = ChatV2Store(defaults: defaults)
        XCTAssertEqual(store.selectedProvider, .claude)
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
        store.selectedProvider = .codex
        store.deepResearch = true
        store.selectedModelByProvider[.codex] = "gpt-5.5-custom"
        store.selectedEffortByProvider[.codex] = .high
        store.codexBackendPreference = .cli
        store.persist()

        let reloaded = ChatV2Store(defaults: defaults)
        XCTAssertEqual(reloaded.selectedProvider, .codex)
        XCTAssertTrue(reloaded.deepResearch)
        XCTAssertEqual(reloaded.selectedModelByProvider[.codex], "gpt-5.5-custom")
        XCTAssertEqual(reloaded.selectedEffortByProvider[.codex], .high)
        XCTAssertEqual(reloaded.codexBackendPreference, .cli)
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
