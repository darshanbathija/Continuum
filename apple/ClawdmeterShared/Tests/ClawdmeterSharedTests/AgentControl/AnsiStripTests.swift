import XCTest
@testable import ClawdmeterShared

final class AnsiStripTests: XCTestCase {

    func testStripsSGRColor() {
        // ESC[31m red ESC[0m
        let s = "\u{1b}[31mhello\u{1b}[0m"
        XCTAssertEqual(AnsiStrip.plain(s), "hello")
    }

    func testStripsCursorMove() {
        let s = "a\u{1b}[2Jb\u{1b}[10;5Hc"
        XCTAssertEqual(AnsiStrip.plain(s), "abc")
    }

    func testStripsOSCTitleBEL() {
        // ESC]0;some title BEL
        let s = "\u{1b}]0;window title\u{07}ready"
        XCTAssertEqual(AnsiStrip.plain(s), "ready")
    }

    func testStripsOSCTitleST() {
        // OSC terminated by ST (ESC \)
        let s = "\u{1b}]0;title\u{1b}\\ready"
        XCTAssertEqual(AnsiStrip.plain(s), "ready")
    }

    func testKeepsNewlinesAndTabs() {
        let s = "\u{1b}[1mline1\nline2\tcol\u{1b}[0m"
        XCTAssertEqual(AnsiStrip.plain(s), "line1\nline2\tcol")
    }

    func testReadinessMarkerSurvivesStripping() {
        // The real use: a ready marker buried in color codes is still findable.
        let raw = "\u{1b}[2K\u{1b}[38;5;208m? for shortcuts\u{1b}[0m"
        XCTAssertTrue(AnsiStrip.plain(raw).contains("? for shortcuts"))
    }

    func testDanglingEscAtEndDoesNotCrash() {
        XCTAssertEqual(AnsiStrip.plain("done\u{1b}"), "done")
        XCTAssertEqual(AnsiStrip.plain("done\u{1b}["), "done")
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(AnsiStrip.plain("trust this folder?"), "trust this folder?")
    }
}
