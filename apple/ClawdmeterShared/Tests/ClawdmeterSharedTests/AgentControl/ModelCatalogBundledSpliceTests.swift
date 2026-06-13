import XCTest
@testable import ClawdmeterShared

/// `ensuringBundledModels(for:)` is what lets a just-connected bundled-model
/// provider render its model picker instantly instead of waiting on the slow
/// live probe refresh. These guard the splice that fixes the "~10s before the
/// Default model dropdown works after activating Antigravity" report.
final class ModelCatalogBundledSpliceTests: XCTestCase {
    /// Simulates the daemon's `/models` response captured while Antigravity was
    /// still disabled: `gemini` stripped to `[]` and absent from the filter.
    private func daemonCatalogWithoutGemini() -> ModelCatalog {
        ModelCatalog(
            claude: ModelCatalog.bundled.claude,
            codex: ModelCatalog.bundled.codex,
            gemini: [],
            enabledProviderIDs: ["claude", "codex"],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func test_restoresStrippedGeminiModelsOnConnect() {
        let spliced = daemonCatalogWithoutGemini().ensuringBundledModels(for: .gemini)
        XCTAssertEqual(spliced.gemini.map(\.id), ModelCatalog.bundled.gemini.map(\.id))
        // The Settings dropdown reads ChatVendor.antigravity.models(in:) == catalog.gemini.
        XCTAssertFalse(ChatVendor.antigravity.models(in: spliced).isEmpty)
    }

    func test_marksProviderEnabledInExistingFilter() {
        let spliced = daemonCatalogWithoutGemini().ensuringBundledModels(for: .gemini)
        XCTAssertEqual(spliced.enabledProviderIDs, ["claude", "codex", "gemini"])
        // entries(for:) honors the filter — gemini must now pass it.
        XCTAssertFalse(spliced.entries(for: .gemini).isEmpty)
    }

    func test_doesNotIntroduceFilterOnUnfilteredCatalog() {
        // The bundled catalog has enabledProviderIDs == nil (shows everything).
        // Splicing must not flip that to a one-element filter that hides the
        // other providers' rows.
        let spliced = ModelCatalog.bundled.ensuringBundledModels(for: .gemini)
        XCTAssertNil(spliced.enabledProviderIDs)
        XCTAssertEqual(spliced.gemini.map(\.id), ModelCatalog.bundled.gemini.map(\.id))
    }

    func test_doesNotClobberAlreadyPopulatedProviders() {
        let spliced = daemonCatalogWithoutGemini().ensuringBundledModels(for: .gemini)
        // Claude/codex arrays present before the splice must be untouched.
        XCTAssertEqual(spliced.claude.map(\.id), ModelCatalog.bundled.claude.map(\.id))
        XCTAssertEqual(spliced.codex.map(\.id), ModelCatalog.bundled.codex.map(\.id))
    }

    func test_dynamicProvidersAreLeftUntouched() {
        // OpenCode / OpenRouter model lists only exist after a live probe, so
        // there is nothing to splice — the catalog must come back unchanged.
        let base = daemonCatalogWithoutGemini()
        let spliced = base.ensuringBundledModels(for: .opencode)
        XCTAssertEqual(spliced.enabledProviderIDs, base.enabledProviderIDs)
        XCTAssertTrue(spliced.opencode.isEmpty)
    }

    func test_splicesClaudeCodexCursorGrok() {
        let empty = ModelCatalog(claude: [], codex: [], enabledProviderIDs: [], updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(empty.ensuringBundledModels(for: .claude).claude.isEmpty)
        XCTAssertFalse(empty.ensuringBundledModels(for: .codex).codex.isEmpty)
        XCTAssertFalse(empty.ensuringBundledModels(for: .cursor).cursor.isEmpty)
        XCTAssertFalse(empty.ensuringBundledModels(for: .grok).grok.isEmpty)
    }
}
