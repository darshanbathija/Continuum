import XCTest
@testable import ClawdmeterShared

final class ToolActionSummaryTests: XCTestCase {

    func test_readLabelUsesLineCountFromResult() {
        let label = ToolActionSummary.primaryLabel(
            toolName: "Read",
            callBody: "/repo/App.swift",
            resultBody: "Read 80 lines."
        )
        XCTAssertEqual(label, "Read 80 lines")
    }

    func test_readLabelWithoutResultFallsBack() {
        XCTAssertEqual(
            ToolActionSummary.primaryLabel(toolName: "Read", callBody: "App.swift"),
            "Read"
        )
    }

    func test_grepLabelIncludesPattern() {
        XCTAssertEqual(
            ToolActionSummary.primaryLabel(toolName: "Grep", callBody: "needsReauth"),
            "grep needsReauth"
        )
    }

    func test_flatRowExcludesBashOnly() {
        XCTAssertTrue(ToolActionSummary.rendersFlatRow(toolName: "Read"))
        XCTAssertTrue(ToolActionSummary.rendersFlatRow(toolName: "Grep"))
        XCTAssertFalse(ToolActionSummary.rendersFlatRow(toolName: "Bash"))
    }

    func test_filePathForReadUsesCallBody() {
        XCTAssertEqual(
            ToolActionSummary.filePath(toolName: "Read", callBody: "/repo/App.swift"),
            "/repo/App.swift"
        )
    }
}
