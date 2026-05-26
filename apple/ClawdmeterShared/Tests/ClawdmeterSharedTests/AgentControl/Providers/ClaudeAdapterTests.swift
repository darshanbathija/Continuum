import XCTest
@testable import ClawdmeterShared

/// Parity tests for the F1a `ClaudeAdapter`. Each test asserts that a
/// representative Claude JSONL shape translates to the expected
/// `ProviderRuntimeEvent`(s).
///
/// Coverage:
///   - System / session-start lines → `.sessionStarted`
///   - User text + content-block shapes → `.userMessage`
///   - Assistant text + tool_use + thinking blocks → `.assistantTokenDelta`
///     and `.toolUse` and `.assistantMessageCompleted` (with usage)
///   - Tool result delivered as top-level `role:"tool"` or embedded
///     content block → `.toolResult`
///   - Unknown role / content block → `.unknown(name:)` forward-compat
///   - Raw payload retention + Claude-specific extension fields
///   - Sequence numbers monotonically increment across multi-event lines
///
/// Plan: F1a (Phase 1; D23 strangler-fig) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`
final class ClaudeAdapterTests: XCTestCase {

    // MARK: - Fixtures

    private let sessionId = "session-1"
    private let baseTimestamp = "2026-05-15T10:00:00Z"

    private func parse(_ json: String) -> [String: Any] {
        let data = json.data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - User message

    func test_userMessage_plainString() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "requestId": "req_1",
          "sessionId": "session-claude-internal",
          "cwd": "/Users/x/myrepo",
          "message": {
            "role": "user",
            "content": "Refactor SessionWorkspaceView"
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line,
            sessionId: sessionId,
            sequenceStart: 7
        )
        XCTAssertEqual(events.count, 1)
        guard case .userMessage(let text, let attachments) = events[0].payload else {
            return XCTFail("Expected .userMessage, got \(events[0].payload)")
        }
        XCTAssertEqual(text, "Refactor SessionWorkspaceView")
        XCTAssertEqual(attachments, [])
        XCTAssertEqual(events[0].sequenceNumber, 7)
        XCTAssertEqual(events[0].providerKind, .claude)
    }

    func test_userMessage_contentBlocksWithToolResult() {
        // User content block array with an embedded tool_result block.
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "role": "user",
            "content": [
              { "type": "text", "text": "Here's the file:" },
              { "type": "tool_result", "tool_use_id": "tu_1", "content": "100 lines read" }
            ]
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .userMessage(let text, _) = events[0].payload else {
            return XCTFail("Expected .userMessage")
        }
        XCTAssertTrue(text.contains("Here's the file:"))
        XCTAssertTrue(text.contains("100 lines read"))
    }

    // MARK: - Assistant turn

    func test_assistantMessage_textOnly_withUsage_emitsCompleted() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "requestId": "req_1",
          "message": {
            "id": "msg_1",
            "role": "assistant",
            "model": "claude-sonnet-4-5",
            "content": [
              { "type": "text", "text": "Done — here's the diff." }
            ],
            "usage": {
              "input_tokens": 1500,
              "output_tokens": 320,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 3200
            }
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 10
        )
        XCTAssertEqual(events.count, 1)
        guard case .assistantMessageCompleted(let text, let tokensIn, let tokensOut) = events[0].payload else {
            return XCTFail("Expected .assistantMessageCompleted, got \(events[0].payload)")
        }
        XCTAssertEqual(text, "Done — here's the diff.")
        XCTAssertEqual(tokensIn, 1500)
        XCTAssertEqual(tokensOut, 320)

        // Claude extension fields should carry the cache token data.
        guard let exts = events[0].providerExtensions,
              case .nested(let claude) = exts["claude"] else {
            return XCTFail("Expected claude extension fields")
        }
        XCTAssertEqual(claude["model"], .string("claude-sonnet-4-5"))
        XCTAssertEqual(claude["message_id"], .string("msg_1"))
        XCTAssertEqual(claude["cache_read_input_tokens"], .int(3200))
    }

    func test_assistantMessage_streamingPartial_noUsage_emitsTokenDelta() {
        // Partial line with text but no usage block — Claude's streaming
        // intermediate lines look like this.
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "id": "msg_1",
            "role": "assistant",
            "content": [
              { "type": "text", "text": "Streaming token..." }
            ]
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 5
        )
        XCTAssertEqual(events.count, 1)
        guard case .assistantTokenDelta(let text, _) = events[0].payload else {
            return XCTFail("Expected .assistantTokenDelta, got \(events[0].payload)")
        }
        XCTAssertEqual(text, "Streaming token...")
    }

    func test_assistantMessage_toolUse_emitsToolUseAndCompleted() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "id": "msg_1",
            "role": "assistant",
            "content": [
              { "type": "text", "text": "Reading the file." },
              {
                "type": "tool_use",
                "id": "tu_42",
                "name": "Read",
                "input": { "file_path": "Foo.swift" }
              }
            ],
            "usage": { "input_tokens": 500, "output_tokens": 50 }
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0
        )
        // 2 events: tool_use + assistantMessageCompleted, in that order.
        XCTAssertEqual(events.count, 2)
        guard case .toolUse(let name, let params, let invocationId) = events[0].payload else {
            return XCTFail("Expected first event .toolUse")
        }
        XCTAssertEqual(name, "Read")
        XCTAssertEqual(invocationId, "tu_42")
        XCTAssertEqual(params["file_path"], "Foo.swift")

        guard case .assistantMessageCompleted(let text, _, _) = events[1].payload else {
            return XCTFail("Expected second event .assistantMessageCompleted")
        }
        XCTAssertEqual(text, "Reading the file.")

        // Sequence numbers monotonic.
        XCTAssertEqual(events[0].sequenceNumber, 0)
        XCTAssertEqual(events[1].sequenceNumber, 1)
    }

    func test_assistantMessage_embeddedToolResult_emitsToolResult() {
        // Some Claude turns embed a tool_result block inside an assistant
        // content array (when the tool came back fast and the model
        // continued in the same turn).
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "role": "assistant",
            "content": [
              {
                "type": "tool_result",
                "tool_use_id": "tu_42",
                "content": "Read 100 lines.",
                "is_error": false
              }
            ]
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .toolResult(let invocationId, let success, let text) = events[0].payload else {
            return XCTFail("Expected .toolResult, got \(events[0].payload)")
        }
        XCTAssertEqual(invocationId, "tu_42")
        XCTAssertTrue(success)
        XCTAssertEqual(text, "Read 100 lines.")
    }

    func test_assistantMessage_unknownContentBlock_emitsUnknown() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "role": "assistant",
            "content": [
              { "type": "future_block_type_42", "payload": {} }
            ]
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .unknown(let name) = events[0].payload else {
            return XCTFail("Expected .unknown for forward-compat")
        }
        XCTAssertEqual(name, "claude.assistant.content.future_block_type_42")
    }

    // MARK: - Tool result (top-level role)

    func test_toolResult_topLevelRole_emitsToolResult() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "role": "tool",
            "tool_use_id": "tu_99",
            "content": "Wrote 42 lines to Foo.swift.",
            "is_error": false
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .toolResult(let invocationId, let success, let text) = events[0].payload else {
            return XCTFail("Expected .toolResult, got \(events[0].payload)")
        }
        XCTAssertEqual(invocationId, "tu_99")
        XCTAssertTrue(success)
        XCTAssertEqual(text, "Wrote 42 lines to Foo.swift.")
    }

    func test_toolResult_withIsErrorTrue_emitsFailureSuccess() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "role": "tool",
            "tool_use_id": "tu_x",
            "content": "Permission denied",
            "is_error": true
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .toolResult(_, let success, _) = events[0].payload else {
            return XCTFail("Expected .toolResult")
        }
        XCTAssertFalse(success)
    }

    // MARK: - System / sessionStarted

    func test_systemInitLine_emitsSessionStarted() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "type": "system",
          "subtype": "init",
          "model": "claude-sonnet-4-5"
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .sessionStarted(let model, let settings) = events[0].payload else {
            return XCTFail("Expected .sessionStarted")
        }
        XCTAssertEqual(model, "claude-sonnet-4-5")
        XCTAssertEqual(settings["subtype"], "init")
    }

    // MARK: - Unknown role

    func test_unknownRole_emitsUnknown() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "role": "future_role_xyz"
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .unknown(let name) = events[0].payload else {
            return XCTFail("Expected .unknown for forward-compat")
        }
        XCTAssertEqual(name, "claude.role.future_role_xyz")
    }

    // MARK: - Raw payload retention (codex #8)

    func test_rawPayloadRetention_attachedToAllEvents() {
        let json = """
        {
          "timestamp": "\(baseTimestamp)",
          "message": { "role": "user", "content": "Hello" }
        }
        """
        let line = parse(json)
        let bytes = json.data(using: .utf8)!
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 0, rawBytes: bytes
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].rawProviderPayload, bytes)
    }

    // MARK: - Provider instance id (F3 readiness)

    func test_providerInstanceId_threadedThroughEvents() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": { "role": "user", "content": "Hi" }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line,
            sessionId: sessionId,
            sequenceStart: 0,
            providerInstanceId: "claude_personal"
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].providerInstanceId, "claude_personal")
    }

    // MARK: - Sequence number contract

    func test_multiEventLine_sequenceNumbersStartAtSequenceStart() {
        let line = parse("""
        {
          "timestamp": "\(baseTimestamp)",
          "message": {
            "role": "assistant",
            "content": [
              { "type": "tool_use", "id": "tu_1", "name": "Read", "input": {} },
              { "type": "tool_use", "id": "tu_2", "name": "Edit", "input": {} }
            ],
            "usage": { "input_tokens": 100, "output_tokens": 50 }
          }
        }
        """)
        let events = ClaudeAdapter.translate(
            line: line, sessionId: sessionId, sequenceStart: 42
        )
        // 2 tool_use + 1 assistantMessageCompleted = 3 events
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].sequenceNumber, 42)
        XCTAssertEqual(events[1].sequenceNumber, 43)
        XCTAssertEqual(events[2].sequenceNumber, 44)
    }
}
