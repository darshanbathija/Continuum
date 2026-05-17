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

    // MARK: - Cross-platform parity invariant

    /// The whole point of SubmitToTmux is that Mac and Linux daemons produce
    /// byte-identical strategies for the same input. This test is the
    /// regression gate.
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
}
