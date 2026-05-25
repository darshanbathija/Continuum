import XCTest
@testable import ClawdmeterShared

final class CursorModelCatalogTests: XCTestCase {
    func test_parseNoModelsFallsBackToAuto() {
        let entries = CursorModelCatalog.parseCLIOutput("No models available for this account.")
        XCTAssertEqual(entries.map(\.id), [CursorModelCatalog.autoModelId])
        XCTAssertEqual(entries.first?.displayName, "Cursor default / Auto")
    }

    func test_parseJSONModelsPrependsAutoAndDedupes() {
        let output = #"{"models":[{"id":"claude-4-sonnet"},{"model":"gpt-5"},{"name":"claude-4-sonnet"}]}"#
        let entries = CursorModelCatalog.parseCLIOutput(output)
        XCTAssertEqual(entries.map(\.id), [
            CursorModelCatalog.autoModelId,
            "claude-4-sonnet",
            "gpt-5",
        ])
    }

    func test_parseLineOrientedModelList() {
        let output = """
        Available models
        - claude-4-sonnet
        2. gpt-5
        * cursor-default
        """
        let entries = CursorModelCatalog.parseCLIOutput(output)
        XCTAssertEqual(entries.map(\.id), [
            CursorModelCatalog.autoModelId,
            "claude-4-sonnet",
            "gpt-5",
        ])
    }

    func test_parseCursorAgentListModelsFormat() {
        // v0.29.4 regression: cursor-agent 2026.05.20+ emits
        // `<id> - <Display Name>` per line. The parser previously kept the
        // whole line as the model id, so picking a model from Settings ->
        // Cursor sent invalid identifiers like
        // `composer-2.5 - Composer 2.5` to the CLI.
        let output = """
        Available models

        auto - Auto
        composer-2.5 - Composer 2.5
        composer-2.5-fast - Composer 2.5 Fast (default)
        gpt-5.5-high - GPT-5.5 1M High
        claude-opus-4-7-thinking-high - Opus 4.7 1M High Thinking
        """
        let entries = CursorModelCatalog.parseCLIOutput(output)
        XCTAssertEqual(entries.map(\.id), [
            CursorModelCatalog.autoModelId,
            "composer-2.5",
            "composer-2.5-fast",
            "gpt-5.5-high",
            "claude-opus-4-7-thinking-high",
        ])
    }

    func test_autoAliasesAreTreatedAsFallback() {
        XCTAssertTrue(CursorModelCatalog.isAutoModel(nil))
        XCTAssertTrue(CursorModelCatalog.isAutoModel("auto"))
        XCTAssertTrue(CursorModelCatalog.isAutoModel("cursor-default"))
        XCTAssertTrue(CursorModelCatalog.isAutoModel(CursorModelCatalog.autoModelId))
        XCTAssertFalse(CursorModelCatalog.isAutoModel("claude-4-sonnet"))
    }
}
