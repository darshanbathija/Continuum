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
    private var savedEnablement: [String: Bool] = [:]

    override func setUp() async throws {
        try await super.setUp()
        // Each test runs against its own UserDefaults suite so the
        // restore-after-init assertions don't see persisted state from
        // a sibling test.
        defaults = UserDefaults(suiteName: suiteName)!
        // ChatV2Store derives its default vendor from GLOBAL ProviderEnablement
        // (opt-in onboarding contract: default = first-enabled chat provider),
        // which the injected `defaults` suite can't isolate. Snapshot the
        // machine's real enablement and start every test from a known
        // all-disabled baseline so each test can enable exactly the providers
        // it needs and the "default = first-enabled" assertions are
        // deterministic on any machine (not just a CI box with nothing enabled).
        savedEnablement = Dictionary(uniqueKeysWithValues:
            ProviderRegistry.allProviderIDs.map { ($0, ProviderEnablement.isEnabled($0)) })
        for id in ProviderRegistry.allProviderIDs { ProviderEnablement.setEnabled(id, false) }
    }

    override func tearDown() async throws {
        for (id, on) in savedEnablement { ProviderEnablement.setEnabled(id, on) }
        savedEnablement = [:]
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// Enable specific chat vendors (by their backing provider) so the
    /// opt-in default + choice-normalization logic keeps them.
    private func enable(_ vendors: ChatVendor...) {
        for vendor in vendors { ProviderEnablement.setEnabled(vendor.backingProvider.rawValue, true) }
    }

    // MARK: - Defaults

    func test_init_defaultsToFirstEnabledVendor_chatgpt() {
        // Opt-in contract: with ChatGPT the only enabled chat provider, a
        // fresh store defaults to it (no persisted picks).
        enable(.chatgpt)
        let store = ChatV2Store(defaults: defaults)
        XCTAssertEqual(store.selectedVendors, [.chatgpt])
        XCTAssertEqual(store.selectedProvider, .codex)
        XCTAssertEqual(store.selectedVendorCount, 1)
        XCTAssertFalse(store.broadcastReady)
        XCTAssertEqual(store.selectedReplyProvider, .codex)
        XCTAssertEqual(store.selectedModel, ModelCatalog.bundled.codex.first?.id)
        XCTAssertEqual(store.selectedEffort, .high)
        XCTAssertFalse(store.deepResearch)
        XCTAssertTrue(store.attachments.isEmpty)
    }

    func test_init_defaultsToFirstEnabledVendor_claude() {
        // Same contract, different enabled provider: the default tracks
        // whichever chat provider is enabled, not a hardcoded vendor.
        enable(.claude)
        let store = ChatV2Store(defaults: defaults)
        XCTAssertEqual(store.selectedVendors, [.claude])
        XCTAssertEqual(store.selectedProvider, .claude)
        XCTAssertEqual(store.selectedVendorCount, 1)
        XCTAssertEqual(store.selectedReplyProvider, .claude)
        XCTAssertEqual(store.selectedModel, ModelCatalog.bundled.claude.first?.id)
    }

    func test_selectedModel_falls_back_to_bundled_catalog_first_entry() {
        let store = ChatV2Store(defaults: defaults)
        XCTAssertEqual(store.model(for: .chatgpt), ModelCatalog.bundled.codex.first?.id)
        XCTAssertEqual(store.model(for: .claude), ModelCatalog.bundled.claude.first?.id)
        XCTAssertEqual(store.model(for: .antigravity), ModelCatalog.bundled.gemini.first?.id)
        XCTAssertEqual(store.model(for: .cursor), ModelCatalog.bundled.cursor.first?.id)
        XCTAssertEqual(store.model(for: .openrouter), ModelCatalog.bundled.openrouter.first?.id)
    }

    // MARK: - Persistence

    func test_persist_then_reload_restores_picks() {
        // All three vendors must be enabled or choice-normalization drops the
        // not-enabled ones on persist/reload.
        enable(.chatgpt, .claude, .openrouter)
        let store = ChatV2Store(defaults: defaults)
        store.selectedChoices = [.builtin(.chatgpt), .builtin(.claude), .builtin(.openrouter)]
        store.selectedReplyProvider = .claude
        store.deepResearch = true
        store.selectModel("gpt-5.5-custom", for: .chatgpt)
        store.selectEffort(.high, for: .chatgpt)
        store.selectModel("anthropic/claude-sonnet-4.6", for: .openrouter)
        store.persist()

        let reloaded = ChatV2Store(defaults: defaults)
        XCTAssertEqual(reloaded.selectedVendors, [.chatgpt, .claude, .openrouter])
        XCTAssertEqual(reloaded.selectedProvider, .codex)
        XCTAssertEqual(reloaded.selectedReplyProvider, .claude)
        XCTAssertTrue(reloaded.deepResearch)
        XCTAssertEqual(reloaded.selectedModelByVendor[.chatgpt], "gpt-5.5-custom")
        XCTAssertEqual(reloaded.selectedEffortByVendor[.chatgpt], .high)
        XCTAssertEqual(reloaded.selectedModelByVendor[.openrouter], "anthropic/claude-sonnet-4.6")
    }

    func test_legacyProviderDefaults_doNotOverrideEnabledDefault() {
        // Legacy single-provider keys (pre-vendors schema) must not override
        // the opt-in default. With only ChatGPT enabled, the default stays
        // ChatGPT even though legacy keys name Claude.
        enable(.chatgpt)
        defaults.set(ChatV2Mode.solo.rawValue, forKey: "clawdmeter.chatv2.mode")
        defaults.set(AgentKind.claude.rawValue, forKey: "clawdmeter.chatv2.provider")
        defaults.set([AgentKind.claude.rawValue: "claude-opus-4-7-1m"], forKey: "clawdmeter.chatv2.modelByProvider")

        let store = ChatV2Store(defaults: defaults)

        XCTAssertEqual(store.selectedVendors, [.chatgpt])
        XCTAssertEqual(store.selectedProvider, .codex)
        XCTAssertEqual(store.selectedModel, ModelCatalog.bundled.codex.first?.id)
        XCTAssertEqual(store.selectedEffort, .high)
    }

    func test_vendor_toggle_allows_one_to_three_only() {
        // Init with only ChatGPT enabled so the starting default is [chatgpt],
        // then enable the toggle targets so they survive normalization (the
        // already-initialized store keeps its [chatgpt] selection).
        enable(.chatgpt)
        let store = ChatV2Store(defaults: defaults)
        enable(.claude, .antigravity, .cursor)

        store.toggleVendor(.claude)
        XCTAssertEqual(store.selectedVendors, [.chatgpt, .claude])
        XCTAssertTrue(store.broadcastReady)

        store.toggleVendor(.antigravity)
        XCTAssertEqual(store.selectedVendors, [.chatgpt, .claude, .antigravity])

        store.toggleVendor(.cursor)
        XCTAssertEqual(store.selectedVendors, [.chatgpt, .claude, .antigravity], "selection must cap at three vendors")

        store.toggleVendor(.antigravity)
        store.toggleVendor(.claude)
        XCTAssertEqual(store.selectedVendors, [.chatgpt], "selection may shrink to one vendor")

        store.toggleVendor(.chatgpt)
        XCTAssertEqual(store.selectedVendors, [.chatgpt], "selection must keep at least one vendor")
    }

    func test_frontierSlots_carry_provider_model_effort_backend_and_deepResearch() {
        // All three vendors enabled so none is filtered out of the slots.
        enable(.claude, .chatgpt, .openrouter)
        let store = ChatV2Store(defaults: defaults)
        store.selectedChoices = [.builtin(.claude), .builtin(.chatgpt), .builtin(.openrouter)]
        store.deepResearch = true
        store.selectModel("claude-opus-test", for: .claude)
        store.selectModel("gpt-5.5-test", for: .chatgpt)
        store.selectEffort(.high, for: .chatgpt)
        store.selectModel("anthropic/claude-sonnet-4.6", for: .openrouter)

        let slots = store.frontierSlots()
        XCTAssertEqual(slots.map(\.provider), [.claude, .codex, .opencode])
        XCTAssertEqual(slots.map(\.chatVendor), [.claude, .chatgpt, .openrouter])
        XCTAssertEqual(slots[0].model, "claude-opus-test")
        XCTAssertNil(slots[0].codexChatBackend)
        XCTAssertEqual(slots[1].model, "gpt-5.5-test")
        XCTAssertEqual(slots[1].effort, .high)
        XCTAssertNil(slots[1].codexChatBackend)
        XCTAssertEqual(slots[2].model, "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(slots[2].billingProvider, "openrouter")
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
        store.selectedChoices = [.builtin(.chatgpt)]
        store.selectModel("gpt-5.5", for: .chatgpt)
        store.selectEffort(.max, for: .chatgpt)
        store.deepResearch = true

        let kind = store.firstSendKind()
        guard case let .chatCreateV2(provider, model, effort, deepResearch, codexBackend, customProviderId) = kind else {
            XCTFail("expected .chatCreateV2, got \(kind)")
            return
        }
        XCTAssertEqual(provider, .codex)
        XCTAssertEqual(model, "gpt-5.5")
        XCTAssertEqual(effort, .max)
        XCTAssertTrue(deepResearch)
        XCTAssertNil(codexBackend)
    }

    func test_firstSendKind_omits_codexBackend_when_not_codex() {
        let store = ChatV2Store(defaults: defaults)
        store.selectedChoices = [.builtin(.claude)]
        let kind = store.firstSendKind()
        guard case let .chatCreateV2(_, _, _, _, codexBackend, _) = kind else {
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
