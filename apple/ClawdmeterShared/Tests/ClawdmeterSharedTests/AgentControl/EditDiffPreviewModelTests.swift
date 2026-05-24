import XCTest
@testable import ClawdmeterShared

#if canImport(SwiftUI)
final class EditDiffPreviewModelTests: XCTestCase {
    func test_linesSplitUnifiedDiffIntoSideBySideRows() {
        let rows = EditDiffPreviewModel.lines(from: """
        @@ -1,2 +1,2 @@
        -let old = 1
        +let new = 2
         return new
        """)

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].kind, .header)
        XCTAssertEqual(rows[1].oldText, "let old = 1")
        XCTAssertNil(rows[1].newText)
        XCTAssertEqual(rows[2].newText, "let new = 2")
        XCTAssertNil(rows[2].oldText)
        XCTAssertEqual(rows[3].oldText, "return new")
        XCTAssertEqual(rows[3].newText, "return new")
        XCTAssertTrue(EditDiffPreviewModel.hasSideBySideChanges(rows))
    }
}
#endif
