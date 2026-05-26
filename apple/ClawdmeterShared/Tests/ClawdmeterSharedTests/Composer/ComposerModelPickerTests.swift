// v0.29.8 — composer model picker contract tests.
//
// The picker view itself lives in ClawdmeterMac; these tests cover the
// pieces that the picker leans on from ClawdmeterShared:
//   1. ProviderDefaultsStore favorite toggle round-trips through
//      UserDefaults across instances.
//   2. ProviderModelPickerSupport.entries returns cross-provider matches
//      when the picker fans the search query across every enabled vendor.
//   3. The Nth row of a vendor's filtered list (which ⌘N binds to in the
//      picker) is stable for the bundled catalog.
//   4. Rail-dimming heuristic: a provider is dimmed iff its filtered list
//      for the current query is empty.

import XCTest
@testable import ClawdmeterShared

final class ComposerModelPickerTests: XCTestCase {

    // MARK: - Fixtures

    /// Fresh UserDefaults suite for each test so favorites don't leak.
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suiteName = "test.composer-picker.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        return d
    }

    // MARK: - 1. Favorite persistence

    func test_toggleFavoriteModel_addsThenRemoves() {
        let defaults = makeIsolatedDefaults()
        let store = ProviderDefaultsStore(defaults: defaults)

        XCTAssertEqual(store.favoriteModelIds(for: .chatgpt), [])

        _ = store.toggleFavoriteModel("gpt-5.4", for: .chatgpt)
        XCTAssertEqual(store.favoriteModelIds(for: .chatgpt), ["gpt-5.4"])
        XCTAssertTrue(store.isFavorite(modelId: "gpt-5.4", vendor: .chatgpt))

        _ = store.toggleFavoriteModel("gpt-5.5", for: .chatgpt)
        // Newest-first insertion.
        XCTAssertEqual(store.favoriteModelIds(for: .chatgpt), ["gpt-5.5", "gpt-5.4"])

        _ = store.toggleFavoriteModel("gpt-5.4", for: .chatgpt)
        XCTAssertEqual(store.favoriteModelIds(for: .chatgpt), ["gpt-5.5"])
        XCTAssertFalse(store.isFavorite(modelId: "gpt-5.4", vendor: .chatgpt))
    }

    func test_toggleFavoriteModel_persistsAcrossInstances() {
        let defaults = makeIsolatedDefaults()
        do {
            let store = ProviderDefaultsStore(defaults: defaults)
            _ = store.toggleFavoriteModel("claude-opus-4-7", for: .claude)
            _ = store.toggleFavoriteModel("gpt-5.5", for: .chatgpt)
        }
        // New instance reading the same UserDefaults should see the stars.
        let reopened = ProviderDefaultsStore(defaults: defaults)
        XCTAssertEqual(reopened.favoriteModelIds(for: .claude), ["claude-opus-4-7"])
        XCTAssertEqual(reopened.favoriteModelIds(for: .chatgpt), ["gpt-5.5"])
        XCTAssertEqual(reopened.favoriteModelIds(for: .cursor), [])
    }

    func test_toggleFavoriteModel_ignoresEmptyIds() {
        let store = ProviderDefaultsStore(defaults: makeIsolatedDefaults())
        _ = store.toggleFavoriteModel("", for: .chatgpt)
        _ = store.toggleFavoriteModel("   ", for: .chatgpt)
        XCTAssertEqual(store.favoriteModelIds(for: .chatgpt), [])
    }

    // MARK: - 2. Cross-provider search

    func test_searchFiltersAcrossAllProviders() {
        // The picker treats search as cross-provider: when query is non-empty
        // it fans the query across every enabled vendor and concatenates
        // matches. "Opus" should hit Claude entries; "GPT" should hit Codex
        // entries; "Gemini" should hit Antigravity entries.
        let catalog = ModelCatalog.bundled

        let opusHits = ChatVendor.allCases.flatMap { vendor in
            ProviderModelPickerSupport.entries(for: vendor, catalog: catalog, query: "Opus")
        }
        XCTAssertFalse(opusHits.isEmpty, "Expected Opus matches in cross-provider search")
        XCTAssertTrue(opusHits.allSatisfy { $0.displayName.lowercased().contains("opus") })

        let gptHits = ChatVendor.allCases.flatMap { vendor in
            ProviderModelPickerSupport.entries(for: vendor, catalog: catalog, query: "GPT")
        }
        XCTAssertFalse(gptHits.isEmpty)
        // GPT hits should be primarily codex, but openrouter also surfaces an
        // "OpenRouter · GPT-5.5" entry — both are valid cross-provider matches.
        let gptProviders = Set(gptHits.map(\.provider))
        XCTAssertTrue(gptProviders.contains(.codex))
    }

    // MARK: - 3. ⌘N → top-N row for the active provider

    func test_commandDigitMapsToTopNthEntry() {
        // The picker binds ⌘1…⌘9 to the first nine rows of the active
        // rail entry's filtered list, in order. Verify the bundled Codex
        // list places GPT-5.5 at row 1 (⌘1) and GPT-5.4 at row 2 (⌘2),
        // matching the mockup.
        let codex = ProviderModelPickerSupport.entries(
            for: .chatgpt,
            catalog: .bundled,
            query: ""
        )
        XCTAssertGreaterThanOrEqual(codex.count, 2)
        XCTAssertEqual(codex[0].id, "gpt-5.5")  // ⌘1
        XCTAssertEqual(codex[1].id, "gpt-5.4")  // ⌘2

        // Under a narrowing query, ⌘N walks the filtered list, not the
        // unfiltered one.
        let codexFiltered = ProviderModelPickerSupport.entries(
            for: .chatgpt,
            catalog: .bundled,
            query: "Spark"
        )
        XCTAssertEqual(codexFiltered.count, 1)
        XCTAssertEqual(codexFiltered[0].id, "gpt-5.3-codex-spark")  // ⌘1
    }

    // MARK: - 4. Rail dimming

    func test_railDimming_dimsProvidersWithNoMatches() {
        // The picker's rail-dimming rule: a vendor's rail row dims when
        // the current non-empty query has zero matches in that vendor's
        // model list.
        let catalog = ModelCatalog.bundled
        let query = "Opus"

        let claudeMatches = ProviderModelPickerSupport.entries(
            for: .claude,
            catalog: catalog,
            query: query
        )
        let geminiMatches = ProviderModelPickerSupport.entries(
            for: .antigravity,
            catalog: catalog,
            query: query
        )
        XCTAssertFalse(claudeMatches.isEmpty, "Claude should match 'Opus'")
        XCTAssertTrue(geminiMatches.isEmpty, "Gemini should not match 'Opus'")
    }
}
