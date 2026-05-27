import XCTest
@testable import ClawdmeterShared

final class MarkdownDocumentContentTests: XCTestCase {

    func test_parsesHeadingsParagraphLinksAndInlineCode() {
        let content = MarkdownDocumentContent.parse("""
        # Release Notes

        Ship `markdown` tabs from the [Code workbench](https://example.com).
        """)

        XCTAssertEqual(content.blocks, [
            .heading(level: 1, text: "Release Notes"),
            .paragraph("Ship markdown tabs from the Code workbench.")
        ])
    }

    func test_parsesListsAndTaskLists() {
        let content = MarkdownDocumentContent.parse("""
        - first
        - [x] done
        - [ ] waiting

        1. one
        2. two
        """)

        XCTAssertEqual(content.blocks.count, 2)
        guard case .list(false, let unordered) = content.blocks[0] else {
            return XCTFail("Expected unordered list")
        }
        XCTAssertEqual(unordered.map(\.text), ["first", "done", "waiting"])
        XCTAssertEqual(unordered.map(\.isTask), [false, true, true])
        XCTAssertEqual(unordered.map(\.isComplete), [false, true, false])

        guard case .list(true, let ordered) = content.blocks[1] else {
            return XCTFail("Expected ordered list")
        }
        XCTAssertEqual(ordered.map(\.text), ["one", "two"])
    }

    func test_parsesCodeFencesBlockQuotesAndThematicBreaks() {
        let content = MarkdownDocumentContent.parse("""
        ```swift
        let value = 42
        ```

        > quoted text

        ---
        """)

        XCTAssertEqual(content.blocks.count, 3)
        XCTAssertEqual(content.blocks[0], .codeBlock(language: "swift", code: "let value = 42\n"))
        XCTAssertEqual(content.blocks[1], .blockQuote([.paragraph("quoted text")]))
        XCTAssertEqual(content.blocks[2], .thematicBreak)
    }

    func test_unsupportedBlockFallsBackExplicitly() {
        let content = MarkdownDocumentContent.parse("<div>raw html</div>")

        XCTAssertEqual(content.blocks.count, 1)
        guard case .unsupported(let message) = content.blocks[0] else {
            return XCTFail("Expected unsupported fallback")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func test_malformedMarkdownStillProducesReadableContent() {
        let content = MarkdownDocumentContent.parse("""
        # Draft

        - [ broken
        """)

        XCTAssertEqual(content.blocks.first, .heading(level: 1, text: "Draft"))
        XCTAssertTrue(content.blocks.contains {
            if case .list = $0 { return true }
            return false
        })
    }
}
