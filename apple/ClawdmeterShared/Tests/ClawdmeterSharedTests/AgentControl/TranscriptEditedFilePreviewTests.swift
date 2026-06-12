import XCTest
@testable import ClawdmeterShared

final class TranscriptEditedFilePreviewSlicerTests: XCTestCase {
    func test_sliceApplyPatchExtractsMatchingFileSection() {
        let patch = """
        *** Update File: Views/A.swift
        @@
        -old
        +new
        *** Add File: Views/B.swift
        +line 1
        """

        let sliced = TranscriptEditedFilePreviewSlicer.slice(preview: patch, filePath: "Views/B.swift")

        XCTAssertTrue(sliced.contains("*** Add File: Views/B.swift"))
        XCTAssertTrue(sliced.contains("+line 1"))
        XCTAssertFalse(sliced.contains("Views/A.swift"))
    }

    func test_sliceUnifiedDiffExtractsMatchingFileSection() {
        let patch = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1 +1 @@
        -a
        +b
        diff --git a/Sources/B.swift b/Sources/B.swift
        --- a/Sources/B.swift
        +++ b/Sources/B.swift
        @@ -1 +1 @@
        -c
        +d
        """

        let sliced = TranscriptEditedFilePreviewSlicer.slice(preview: patch, filePath: "Sources/B.swift")

        XCTAssertTrue(sliced.contains("Sources/B.swift"))
        XCTAssertTrue(sliced.contains("+d"))
        XCTAssertFalse(sliced.contains("Sources/A.swift"))
    }
}

#if canImport(SwiftUI)
final class EditDiffHoverPreviewModelTests: XCTestCase {
    func test_displayLinesAssignLineNumbersForUnifiedDiff() {
        let rows = EditDiffHoverPreviewModel.displayLines(from: """
        @@ -4,1 +4,1 @@
        -TranscriptEditedFileChipStripView(turn, density: density)
        +TranscriptEditedFileChipStripView(turn)
        """, lineLimit: nil)

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].kind, .header)
        XCTAssertEqual(rows[1].kind, .deletion)
        XCTAssertEqual(rows[1].oldLineNumber, 4)
        XCTAssertNil(rows[1].newLineNumber)
        XCTAssertEqual(rows[2].kind, .addition)
        XCTAssertEqual(rows[2].newLineNumber, 4)
        XCTAssertNil(rows[2].oldLineNumber)
    }
}
#endif
