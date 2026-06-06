import XCTest
@testable import ClawdmeterShared

final class PromptPtySubmissionTests: XCTestCase {
    private let escStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    private let escEnd = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])

    func testSubmitIsAlwaysCarriageReturn() {
        for (text, followUp, chat) in [
            ("hi", false, false),
            ("hi", false, true),
            ("a\nb", false, true),
            (String(repeating: "x", count: 400), true, true),
        ] {
            let writes = PromptPtySubmission.writes(forText: text, isFollowUp: followUp, isChat: chat)
            XCTAssertEqual(writes.submit, Data([0x0d]), "submit must be CR for \(text)")
        }
    }

    func testChatClearsLineCodeDoesNot() {
        XCTAssertEqual(
            PromptPtySubmission.writes(forText: "hi", isFollowUp: false, isChat: true).clear,
            Data([0x15])
        )
        XCTAssertNil(
            PromptPtySubmission.writes(forText: "hi", isFollowUp: false, isChat: false).clear
        )
    }

    func testShortInputIsRawPayloadNoBracketedPaste() {
        let writes = PromptPtySubmission.writes(forText: "hi", isFollowUp: false, isChat: false)
        XCTAssertEqual(writes.payload, Data("hi".utf8))
        XCTAssertFalse(writes.payload.starts(with: escStart))
    }

    func testMultilineIsBracketedPasteWithoutSubmitNewline() {
        let writes = PromptPtySubmission.writes(forText: "line1\nline2", isFollowUp: false, isChat: true)
        XCTAssertEqual(writes.payload, escStart + Data("line1\nline2".utf8) + escEnd)
        XCTAssertNotEqual(writes.payload.last, 0x0a)
        XCTAssertEqual(writes.payload.suffix(escEnd.count), escEnd)
    }

    func testLongInputUsesBracketedPaste() {
        let text = String(repeating: "a", count: 300)
        let writes = PromptPtySubmission.writes(forText: text, isFollowUp: false, isChat: false)
        XCTAssertTrue(writes.payload.starts(with: escStart))
        XCTAssertTrue(writes.payload.suffix(escEnd.count) == escEnd)
    }

    func testFollowUpUsesBracketedPaste() {
        let writes = PromptPtySubmission.writes(forText: "retry", isFollowUp: true, isChat: true)
        XCTAssertEqual(writes.payload, escStart + Data("retry".utf8) + escEnd)
    }
}
