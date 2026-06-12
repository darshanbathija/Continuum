import XCTest
@testable import ClawdmeterShared

final class TranscriptEditedFileFormattingTests: XCTestCase {
    func testDeltaLabelAlwaysShowsBothHalves() {
        XCTAssertEqual(
            TranscriptEditedFileFormatting.deltaLabel(additions: 2, deletions: 0),
            "+2 -0"
        )
        XCTAssertEqual(
            TranscriptEditedFileFormatting.deltaLabel(additions: 0, deletions: 3),
            "+0 -3"
        )
        XCTAssertEqual(
            TranscriptEditedFileFormatting.deltaLabel(additions: 0, deletions: 0),
            "+0 -0"
        )
    }
}
