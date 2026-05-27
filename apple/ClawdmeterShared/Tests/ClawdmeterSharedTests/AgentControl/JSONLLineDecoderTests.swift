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

    // MARK: - stripSystemContent

    func test_stripSystemContent_removesTaskNotification() {
        let raw = "<task-notification>\n<task-id>bywgnqlgg</task-id>\n<status>completed</status>\n</task-notification>"
        XCTAssertNil(JSONLLineDecoder.stripSystemContent(raw),
                     "A body that's only a task-notification should collapse to nil")
    }

    func test_stripSystemContent_removesSystemReminder() {
        let raw = "<system-reminder>The task tools haven't been used recently.</system-reminder>"
        XCTAssertNil(JSONLLineDecoder.stripSystemContent(raw))
    }

    func test_stripSystemContent_preservesUserTextAroundInjection() {
        let raw = "fix the auth bug\n<system-reminder>be careful</system-reminder>"
        XCTAssertEqual(JSONLLineDecoder.stripSystemContent(raw), "fix the auth bug")
    }

    func test_stripSystemContent_stripsMultipleConsecutiveInjections() {
        let raw = """
            <task-notification>x</task-notification>
            user text
            <system-reminder>y</system-reminder>
            """
        XCTAssertEqual(JSONLLineDecoder.stripSystemContent(raw), "user text")
    }

    func test_stripSystemContent_unterminatedTagDropsToEnd() {
        let raw = "real prompt <task-notification>unterminated everything after lost"
        XCTAssertEqual(JSONLLineDecoder.stripSystemContent(raw), "real prompt")
    }

    func test_cleanPrompt_dropsTaskNotificationOnlyBodies() {
        // Codex bug surface: task-notification injections were showing up
        // as full user-bubbles in the chat thread AND as sidebar labels.
        // Both paths route through this stripper now.
        XCTAssertNil(JSONLLineDecoder.cleanPrompt("<task-notification>x</task-notification>"))
    }

    func test_stripSystemContent_removesSystemInstructionAttachmentBlock() {
        // Claude Code wraps the "The user has attached these files. Read
        // them before proceeding" copy in `<system_instruction>` when an
        // image / PDF lands in the user turn. The wrapper is not user
        // intent; only the surviving text (or nothing) should reach the
        // chat bubble.
        let raw = """
            <system_instruction>
            The user has attached these files. Read them before proceeding.
            - .context/attachments/RNy3Zr/Screenshot 2026-05-27 at 9.56.07 pm.png (442.9 KB)
            </system_instruction>

            .context/attachments/RNy3Zr/Screenshot 2026-05-27 at 9.56.07 pm.png
            """
        XCTAssertEqual(
            JSONLLineDecoder.stripSystemContent(raw),
            ".context/attachments/RNy3Zr/Screenshot 2026-05-27 at 9.56.07 pm.png"
        )
    }

    func test_stripSystemContent_dropsSystemInstructionOnlyBody() {
        // When the entire user turn is just the harness-injected wrapper
        // (no user-typed text alongside), the bubble should collapse
        // entirely instead of rendering a stray empty pill.
        let raw = "<system_instruction>be careful</system_instruction>"
        XCTAssertNil(JSONLLineDecoder.stripSystemContent(raw))
    }

    func test_stripSystemContent_handlesUnderscoreAndHyphenVariants() {
        // Belt-and-suspenders: `<system-instruction>` (hyphen) is in the
        // strip list too in case Claude Code's wrapper ever flips style.
        let raw = "fix the auth bug<system-instruction>x</system-instruction>"
        XCTAssertEqual(JSONLLineDecoder.stripSystemContent(raw), "fix the auth bug")
    }
}
