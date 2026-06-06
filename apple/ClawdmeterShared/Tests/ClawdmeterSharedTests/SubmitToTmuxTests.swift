import XCTest
@testable import ClawdmeterShared

final class SubmitToTmuxTests: XCTestCase {

    // MARK: - sendKeys path (short, no newline, not a follow-up)

    func testShortInputUsesSendKeys() {
        switch SubmitToTmux.strategy(forText: "hi", isFollowUp: false) {
        case .sendKeys(let bytes):
            XCTAssertEqual(String(data: bytes, encoding: .utf8), "hi")
        case .pasteBytes:
            XCTFail("short single-line input should use sendKeys, got pasteBytes")
        }
    }

    func test200ByteInputUsesSendKeys() {
        let text = String(repeating: "a", count: 200)
        switch SubmitToTmux.strategy(forText: text, isFollowUp: false) {
        case .sendKeys: break
        case .pasteBytes: XCTFail("200-byte input should use sendKeys")
        }
    }

    // MARK: - pasteBytes path

    func testLongInputUsesPasteBytes() {
        let text = String(repeating: "a", count: 300)
        switch SubmitToTmux.strategy(forText: text, isFollowUp: false) {
        case .pasteBytes(let bytes):
            // Bytes must end with newline for tmux paste-buffer to submit.
            XCTAssertEqual(bytes.last, 0x0A, "pasteBytes must end with \\n (paste-buffer submit pitfall)")
            XCTAssertEqual(bytes.count, 301, "300 'a' bytes + 1 trailing newline")
        case .sendKeys:
            XCTFail("300-byte input should use pasteBytes")
        }
    }

    func testNewlineInTextForcesPasteBytes() {
        switch SubmitToTmux.strategy(forText: "line1\nline2", isFollowUp: false) {
        case .pasteBytes(let bytes):
            XCTAssertEqual(bytes.last, 0x0A)
            // Original \n preserved + trailing \n appended
            XCTAssertEqual(String(data: bytes, encoding: .utf8), "line1\nline2\n")
        case .sendKeys:
            XCTFail("input with embedded \\n should use pasteBytes")
        }
    }

    func testFollowUpForcesPasteBytes() {
        switch SubmitToTmux.strategy(forText: "hi", isFollowUp: true) {
        case .pasteBytes(let bytes):
            XCTAssertEqual(String(data: bytes, encoding: .utf8), "hi\n")
        case .sendKeys:
            XCTFail("follow-up should use pasteBytes")
        }
    }

    func testAlreadyTrailingNewlineNotDoubled() {
        switch SubmitToTmux.strategy(forText: "hi\n", isFollowUp: false) {
        case .pasteBytes(let bytes):
            XCTAssertEqual(String(data: bytes, encoding: .utf8), "hi\n")
            XCTAssertEqual(bytes.count, 3, "shouldn't double-append newline")
        case .sendKeys:
            XCTFail("input ending in \\n should use pasteBytes")
        }
    }

    // MARK: - Determinism invariant

    /// The Mac daemon must produce byte-identical strategies for the same input.
    /// This test is the regression gate.
    func testStrategyIsDeterministicAcrossInputs() {
        let cases: [(text: String, followUp: Bool)] = [
            ("hello", false),
            ("hello world", false),
            ("a\nb", false),
            (String(repeating: "x", count: 500), false),
            ("retry", true),
        ]
        // Run twice; expect identical results (no clock/random in the path).
        for c in cases {
            let s1 = SubmitToTmux.strategy(forText: c.text, isFollowUp: c.followUp)
            let s2 = SubmitToTmux.strategy(forText: c.text, isFollowUp: c.followUp)
            XCTAssertEqual(s1, s2, "deterministic for \(c)")
        }
    }

    // MARK: - Raw-PTY rendering (Track A ClaudePtyHost)

    private let escStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]) // ESC[200~
    private let escEnd   = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]) // ESC[201~

    func testPredicateSharedByStrategyAndPty() {
        // The whole reason ptyWrites and strategy share `needsPaste`: identical
        // decisions at the threshold, so the two transports can't drift.
        for (text, followUp) in [("hi", false), ("a\nb", false),
                                 (String(repeating: "x", count: 300), false), ("retry", true)] {
            let pasteInStrategy: Bool
            switch SubmitToTmux.strategy(forText: text, isFollowUp: followUp) {
            case .pasteBytes: pasteInStrategy = true
            case .sendKeys: pasteInStrategy = false
            }
            XCTAssertEqual(pasteInStrategy,
                           SubmitToTmux.needsPaste(forText: text, isFollowUp: followUp),
                           "strategy and needsPaste must agree for \(text)")
        }
    }

    func testPtySubmitIsAlwaysCarriageReturn() {
        // The raw-PTY equivalent of the paste-buffer-needs-newline invariant:
        // submit is ALWAYS a CR, for every shape of input.
        for (text, fu, chat) in [("hi", false, false), ("hi", false, true),
                                 ("a\nb", false, true),
                                 (String(repeating: "x", count: 400), true, true)] {
            let w = SubmitToTmux.ptyWrites(forText: text, isFollowUp: fu, isChat: chat)
            XCTAssertEqual(w.submit, Data([0x0d]), "submit must be CR for \(text)")
        }
    }

    func testPtyChatClearsLineCodeDoesNot() {
        XCTAssertEqual(SubmitToTmux.ptyWrites(forText: "hi", isFollowUp: false, isChat: true).clear,
                       Data([0x15]), "chat must send C-u to clear the input line")
        XCTAssertNil(SubmitToTmux.ptyWrites(forText: "hi", isFollowUp: false, isChat: false).clear,
                     "code/first-turn must NOT send C-u")
    }

    func testPtyShortInputIsRawPayloadNoBracketedPaste() {
        let w = SubmitToTmux.ptyWrites(forText: "hi", isFollowUp: false, isChat: false)
        XCTAssertEqual(w.payload, Data("hi".utf8), "short input typed as-is")
        XCTAssertFalse(w.payload.starts(with: escStart), "short input must not be bracketed-pasted")
    }

    func testPtyMultilineIsBracketedPasteWithoutSubmitNewline() {
        let w = SubmitToTmux.ptyWrites(forText: "line1\nline2", isFollowUp: false, isChat: true)
        XCTAssertEqual(w.payload, escStart + Data("line1\nline2".utf8) + escEnd,
                       "multiline must be wrapped in bracketed-paste markers")
        // The embedded newline stays literal; the payload must NOT carry a
        // trailing submit \n (the separate CR submits) so paste doesn't add a blank line.
        XCTAssertNotEqual(w.payload.last, 0x0a, "bracketed payload must not end with a submit newline")
        XCTAssertEqual(w.payload.suffix(escEnd.count), escEnd)
    }

    func testPtyLongInputUsesBracketedPaste() {
        let text = String(repeating: "a", count: 300)
        let w = SubmitToTmux.ptyWrites(forText: text, isFollowUp: false, isChat: false)
        XCTAssertTrue(w.payload.starts(with: escStart), ">256 bytes must bracketed-paste")
        XCTAssertTrue(w.payload.suffix(escEnd.count) == escEnd)
    }
}
