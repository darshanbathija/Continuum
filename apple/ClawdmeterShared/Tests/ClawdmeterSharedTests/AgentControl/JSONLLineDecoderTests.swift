import XCTest
@testable import ClawdmeterShared

/// Tests for the shared JSONL line decoder. Covers:
/// - Normal user prompts pass through cleaned + trimmed.
/// - `<system-reminder>` content stripped wholesale.
/// - `<command-name>` content kept (it IS the user-intended summary).
/// - tool_result-only user messages return nil.
/// - Long prompts truncate at word boundaries with `…`.
final class JSONLLineDecoderTests: XCTestCase {

    // MARK: - cleanPrompt

    func testCleanPromptNormalText() {
        XCTAssertEqual(JSONLLineDecoder.cleanPrompt("fix the auth bug"),
                       "fix the auth bug")
    }

    func testCleanPromptStripsSystemReminders() {
        let raw = "fix the auth bug<system-reminder>Project context: ...</system-reminder>"
        XCTAssertEqual(JSONLLineDecoder.cleanPrompt(raw), "fix the auth bug")
    }

    func testCleanPromptUnwrapsCommandName() {
        let raw = "<command-name>plan-eng-review</command-name><command-args>--scope reduced</command-args>"
        XCTAssertEqual(JSONLLineDecoder.cleanPrompt(raw), "plan-eng-review")
    }

    func testCleanPromptCollapsesWhitespace() {
        XCTAssertEqual(JSONLLineDecoder.cleanPrompt("hello\n\n  world\t\there"),
                       "hello world here")
    }

    func testCleanPromptTruncatesLongAtWordBoundary() {
        let long = String(repeating: "word ", count: 30)  // 150 chars
        let result = JSONLLineDecoder.cleanPrompt(long, maxLength: 80)
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.count, 81)  // 80 + …
        XCTAssertTrue(result!.hasSuffix("…"))
        XCTAssertFalse(result!.contains("wor…"))  // no mid-word break
    }

    func testCleanPromptEmptyReturnsNil() {
        XCTAssertNil(JSONLLineDecoder.cleanPrompt(""))
        XCTAssertNil(JSONLLineDecoder.cleanPrompt("   \n\t "))
        XCTAssertNil(JSONLLineDecoder.cleanPrompt("<system-reminder>only reminder</system-reminder>"))
    }

    // MARK: - decodeUserPrompt

    func testDecodeUserPromptStringContent() {
        let json: [String: Any] = [
            "type": "user",
            "message": ["content": "fix the auth bug"]
        ]
        XCTAssertEqual(JSONLLineDecoder.decodeUserPrompt(from: json), "fix the auth bug")
    }

    func testDecodeUserPromptArrayContent() {
        let json: [String: Any] = [
            "type": "user",
            "message": ["content": [
                ["type": "text", "text": "let's ship the perf overhaul"]
            ]]
        ]
        XCTAssertEqual(JSONLLineDecoder.decodeUserPrompt(from: json),
                       "let's ship the perf overhaul")
    }

    func testDecodeUserPromptIgnoresToolResultOnly() {
        let json: [String: Any] = [
            "type": "user",
            "message": ["content": [
                ["type": "tool_result", "tool_use_id": "x", "content": "ok"]
            ]]
        ]
        XCTAssertNil(JSONLLineDecoder.decodeUserPrompt(from: json))
    }

    func testDecodeUserPromptIgnoresWrongType() {
        let json: [String: Any] = [
            "type": "assistant",
            "message": ["content": "hello"]
        ]
        XCTAssertNil(JSONLLineDecoder.decodeUserPrompt(from: json))
    }

    // MARK: - decodeFirstUserLine (scheduled-task detection)

    func testDecodeFirstUserLineRegularPrompt() {
        let json: [String: Any] = [
            "type": "user",
            "message": ["content": "fix the auth bug"]
        ]
        let result = JSONLLineDecoder.decodeFirstUserLine(from: json)
        XCTAssertFalse(result.isScheduledTask)
        XCTAssertEqual(result.prompt, "fix the auth bug")
    }

    func testDecodeFirstUserLineScheduledTaskString() {
        let json: [String: Any] = [
            "type": "user",
            "message": [
                "content": #"<scheduled-task name="run-dashboard-health" cron="*/10 * * * *">Run health checks on the dashboard</scheduled-task>"#
            ]
        ]
        let result = JSONLLineDecoder.decodeFirstUserLine(from: json)
        XCTAssertTrue(result.isScheduledTask,
                      "first line wrapped in <scheduled-task> must be flagged")
        XCTAssertNil(result.prompt,
                     "scheduled-task sessions don't surface a prompt label")
    }

    func testDecodeFirstUserLineScheduledTaskArrayBlock() {
        let json: [String: Any] = [
            "type": "user",
            "message": [
                "content": [
                    ["type": "text",
                     "text": #"<scheduled-task name="cron-deploy">Deploy nightly</scheduled-task>"#]
                ]
            ]
        ]
        let result = JSONLLineDecoder.decodeFirstUserLine(from: json)
        XCTAssertTrue(result.isScheduledTask)
        XCTAssertNil(result.prompt)
    }

    func testDecodeFirstUserLineScheduledTaskWithLeadingWhitespace() {
        // Some agents prepend a newline; the detector trims first.
        let json: [String: Any] = [
            "type": "user",
            "message": ["content": "\n  <scheduled-task name=\"x\">work</scheduled-task>"]
        ]
        let result = JSONLLineDecoder.decodeFirstUserLine(from: json)
        XCTAssertTrue(result.isScheduledTask)
    }

    func testDecodeFirstUserLineNonUserTypeIsNeither() {
        let json: [String: Any] = ["type": "assistant", "message": ["content": "hi"]]
        let result = JSONLLineDecoder.decodeFirstUserLine(from: json)
        XCTAssertFalse(result.isScheduledTask)
        XCTAssertNil(result.prompt)
    }

    func testDecodeFirstUserLineToolResultOnlyIsNeither() {
        // tool_result-only user messages aren't prompts AND aren't
        // scheduled-tasks. They should return both nil/false.
        let json: [String: Any] = [
            "type": "user",
            "message": ["content": [
                ["type": "tool_result", "tool_use_id": "x", "content": "ok"]
            ]]
        ]
        let result = JSONLLineDecoder.decodeFirstUserLine(from: json)
        XCTAssertFalse(result.isScheduledTask)
        XCTAssertNil(result.prompt)
    }

    // MARK: - decodeJSON

    func testDecodeJSONValid() {
        let line = #"{"type":"user","message":{"content":"hi"}}"#.data(using: .utf8)!
        let decoded = JSONLLineDecoder.decodeJSON(line: line)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?["type"] as? String, "user")
    }

    func testDecodeJSONMalformedReturnsNil() {
        let line = #"{"type":"user","message":"#.data(using: .utf8)!
        XCTAssertNil(JSONLLineDecoder.decodeJSON(line: line))
    }

    func testDecodeJSONEmptyReturnsNil() {
        XCTAssertNil(JSONLLineDecoder.decodeJSON(line: Data()))
    }
}
