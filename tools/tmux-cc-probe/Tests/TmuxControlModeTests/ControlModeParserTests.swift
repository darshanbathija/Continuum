import XCTest
@testable import TmuxControlMode

final class ControlModeParserTests: XCTestCase {

    // MARK: - Header parsing

    func testBeginEndError() {
        var p = ControlModeParser()
        p.feed("%begin 1747327891 17 1\n".utf8)
        p.feed("%end 1747327891 17 1\n".utf8)
        p.feed("%error 1747327892 18 1\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0], .begin(timestamp: 1747327891, number: 17, flags: 1))
        XCTAssertEqual(frames[1], .end(timestamp: 1747327891, number: 17, flags: 1))
        XCTAssertEqual(frames[2], .error(timestamp: 1747327892, number: 18, flags: 1))
    }

    func testCommandResponseBodyLinesArePreserved() {
        var p = ControlModeParser()
        p.feed("%begin 1747327891 17 1\n".utf8)
        p.feed("@12\n".utf8)
        p.feed("%end 1747327891 17 1\n".utf8)
        XCTAssertEqual(
            p.drainFrames(),
            [
                .begin(timestamp: 1747327891, number: 17, flags: 1),
                .body(line: "@12"),
                .end(timestamp: 1747327891, number: 17, flags: 1),
            ]
        )
    }

    // MARK: - Octal-escape decoding (Phase 0 criterion #3 + #4)

    func testOctalDecodeBackslash() {
        let bytes = ControlModeParser.decodeOctalEscapes(#"hello\134world"#)
        // \134 is octal 0134 = 0x5C = '\'
        XCTAssertEqual(bytes, Data([0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x5C, 0x77, 0x6F, 0x72, 0x6C, 0x64]))
    }

    func testOctalDecodeNewline() {
        // \012 = 0x0A = '\n'
        let bytes = ControlModeParser.decodeOctalEscapes(#"a\012b"#)
        XCTAssertEqual(bytes, Data([0x61, 0x0A, 0x62]))
    }

    func testOctalDecodeBackslashEscaped() {
        // Per tmux source, "\\\\" represents the byte 0x5C (one backslash).
        let bytes = ControlModeParser.decodeOctalEscapes(#"\\"#)
        XCTAssertEqual(bytes, Data([0x5C]))
    }

    func testOctalDecodeUTF8Emoji() {
        // U+1F600 GRINNING FACE = F0 9F 98 80 in UTF-8.
        // tmux octal-escapes each byte: \360\237\230\200
        let bytes = ControlModeParser.decodeOctalEscapes(#"\360\237\230\200"#)
        XCTAssertEqual(bytes, Data([0xF0, 0x9F, 0x98, 0x80]))
        // Decoded as UTF-8 should be the emoji
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "😀")
    }

    func testOctalDecodeMalformedFallsBack() {
        // Malformed octal (only 2 digits): should not crash, preserve raw bytes
        let bytes = ControlModeParser.decodeOctalEscapes(#"abc\12"#)
        // Falls back to emitting the backslash literal then proceeding
        XCTAssertGreaterThan(bytes.count, 0)
    }

    // MARK: - %output framing (criterion #3 reassembly)

    func testOutputFrame() {
        var p = ControlModeParser()
        p.feed("%output %3 hello\\012world\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames.count, 1)
        if case .output(let paneId, let bytes) = frames[0] {
            XCTAssertEqual(paneId, "3")
            XCTAssertEqual(bytes, Data([0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0A, 0x77, 0x6F, 0x72, 0x6C, 0x64]))
        } else {
            XCTFail("Expected .output frame")
        }
    }

    func testEmptyOutputFrame() {
        var p = ControlModeParser()
        p.feed("%output %5 \n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames.count, 1)
        if case .output(let paneId, let bytes) = frames[0] {
            XCTAssertEqual(paneId, "5")
            XCTAssertEqual(bytes, Data())
        } else {
            XCTFail("Expected .output frame")
        }
    }

    func testOutputFrameLargeReassembly() {
        // Criterion #3: 1MB of 'a' bytes survives octal-escape round-trip.
        // tmux only escapes non-printable/high-bit bytes, so plain 'a' is
        // passed through unescaped.
        let payload = String(repeating: "a", count: 1_000_000)
        var p = ControlModeParser()
        p.feed("%output %1 \(payload)\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames.count, 1)
        if case .output(_, let bytes) = frames[0] {
            XCTAssertEqual(bytes.count, 1_000_000)
            XCTAssertEqual(bytes.first, 0x61)
        } else {
            XCTFail()
        }
    }

    // MARK: - Window + session events

    func testWindowAddClose() {
        var p = ControlModeParser()
        p.feed("%window-add @4\n".utf8)
        p.feed("%window-close @4\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames, [.windowAdd(windowId: "@4"), .windowClose(windowId: "@4")])
    }

    func testLayoutChange() {
        var p = ControlModeParser()
        p.feed("%layout-change @3 5e1f,80x24,0,0,3\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames, [.layoutChange(windowId: "@3", layout: "5e1f,80x24,0,0,3")])
    }

    func testSessionChanged() {
        var p = ControlModeParser()
        p.feed("%session-changed $0 main\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames, [.sessionChanged(sessionId: "$0", name: "main")])
    }

    // MARK: - Flow control + exit

    func testPauseContinue() {
        var p = ControlModeParser()
        p.feed("%pause %3\n".utf8)
        p.feed("%continue %3\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames, [.pause(paneId: "%3"), .continueOutput(paneId: "%3")])
    }

    func testExitBare() {
        var p = ControlModeParser()
        p.feed("%exit\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames, [.exit(reason: nil)])
    }

    func testExitWithReason() {
        var p = ControlModeParser()
        p.feed("%exit dead\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames, [.exit(reason: "dead")])
    }

    // MARK: - Unknown frames don't crash

    func testUnknownFrame() {
        var p = ControlModeParser()
        p.feed("%subscribe-changed @3 hello\n".utf8)  // tmux 3.4+ directive
        let frames = p.drainFrames()
        XCTAssertEqual(frames.count, 1)
        if case .unknown(let raw) = frames[0] {
            XCTAssertEqual(raw, "%subscribe-changed @3 hello")
        } else {
            XCTFail()
        }
    }

    // MARK: - Streaming: partial line buffering

    func testStreamingPartialLine() {
        var p = ControlModeParser()
        p.feed("%output %1 ".utf8)  // partial — no newline yet
        XCTAssertEqual(p.drainFrames().count, 0)
        p.feed("hello\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames.count, 1)
        if case .output(_, let bytes) = frames[0] {
            XCTAssertEqual(String(data: bytes, encoding: .utf8), "hello")
        } else {
            XCTFail()
        }
    }

    func testStreamingByteAtATime() {
        let raw = "%output %1 hi\\012\n%window-close @2\n"
        var p = ControlModeParser()
        for byte in raw.utf8 {
            p.feed(byte)
        }
        let frames = p.drainFrames()
        XCTAssertEqual(frames.count, 2)
        if case .output(let pane, let bytes) = frames[0] {
            XCTAssertEqual(pane, "1")
            XCTAssertEqual(bytes, Data([0x68, 0x69, 0x0A]))
        } else {
            XCTFail()
        }
        XCTAssertEqual(frames[1], .windowClose(windowId: "@2"))
    }

    // MARK: - UTF-8 boundary across two %output frames (criterion #4)

    func testUTF8SplitAcrossOutputFrames() {
        // U+1F600 = F0 9F 98 80. tmux escapes each byte.
        // Frame A: \360\237   Frame B: \230\200
        var p = ControlModeParser()
        p.feed("%output %1 \\360\\237\n".utf8)
        p.feed("%output %1 \\230\\200\n".utf8)
        let frames = p.drainFrames()
        XCTAssertEqual(frames.count, 2)
        if case .output(_, let bytesA) = frames[0],
           case .output(_, let bytesB) = frames[1] {
            let combined = bytesA + bytesB
            XCTAssertEqual(String(data: combined, encoding: .utf8), "😀")
        } else {
            XCTFail("Expected two .output frames")
        }
    }
}
