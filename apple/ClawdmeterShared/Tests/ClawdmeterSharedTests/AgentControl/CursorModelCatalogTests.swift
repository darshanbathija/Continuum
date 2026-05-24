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

    func test_autoAliasesAreTreatedAsFallback() {
        XCTAssertTrue(CursorModelCatalog.isAutoModel(nil))
        XCTAssertTrue(CursorModelCatalog.isAutoModel("auto"))
        XCTAssertTrue(CursorModelCatalog.isAutoModel("cursor-default"))
        XCTAssertTrue(CursorModelCatalog.isAutoModel(CursorModelCatalog.autoModelId))
        XCTAssertFalse(CursorModelCatalog.isAutoModel("claude-4-sonnet"))
    }
}
