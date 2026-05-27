import XCTest
@testable import Clawdmeter

/// Covers the pure-string transform behind the "Ran N commands"
/// running-step subtitle (`Running <tool> · <input>`). Lives under unit
/// tests, not UI tests, so it runs in milliseconds and doesn't need a
/// view host.
@MainActor
final class ChatItemRowSubtitleTests: XCTestCase {

    func test_emptyBody_rendersTrailingEllipsis() {
        XCTAssertEqual(
            ClawdmeterMac_runningStepSubtitle(forTool: "Bash", body: ""),
            "Running Bash…"
        )
    }

    func test_bodyMatchingTitle_rendersTrailingEllipsis() {
        // Some providers echo the tool name as the body when there's
        // nothing else to summarize — don't double-render.
        XCTAssertEqual(
            ClawdmeterMac_runningStepSubtitle(forTool: "Bash", body: "Bash"),
            "Running Bash…"
        )
    }

    func test_shortBody_rendersWithSeparator() {
        XCTAssertEqual(
            ClawdmeterMac_runningStepSubtitle(forTool: "Glob", body: "**/*.swift"),
            "Running Glob · **/*.swift"
        )
    }

    func test_multilineBody_collapsesToSingleLine() {
        XCTAssertEqual(
            ClawdmeterMac_runningStepSubtitle(forTool: "Bash", body: "echo hi\nls -la"),
            "Running Bash · echo hi ls -la"
        )
    }

    func test_longBody_clipsAt60CharsWithEllipsis() {
        let long = String(repeating: "a", count: 80)
        let result = ClawdmeterMac_runningStepSubtitle(forTool: "Read", body: long)
        // 60 a's + "…" appended, prefixed by "Running Read · "
        XCTAssertEqual(result, "Running Read · " + String(repeating: "a", count: 60) + "…")
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func test_bodyExactly60Chars_doesNotEllipsize() {
        let exact = String(repeating: "x", count: 60)
        let result = ClawdmeterMac_runningStepSubtitle(forTool: "Read", body: exact)
        XCTAssertEqual(result, "Running Read · " + exact)
        XCTAssertFalse(result.hasSuffix("…"))
    }

    func test_titleAndBodyWhitespace_isTrimmed() {
        XCTAssertEqual(
            ClawdmeterMac_runningStepSubtitle(forTool: "  Grep  ", body: "  pattern  "),
            "Running Grep · pattern"
        )
    }
}
