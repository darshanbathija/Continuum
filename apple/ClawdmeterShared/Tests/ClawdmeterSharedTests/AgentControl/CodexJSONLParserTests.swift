import XCTest
@testable import ClawdmeterShared

/// Tests for the Codex JSONL parser. The Mac-side staging pipeline used
/// to own this logic — extracting it to Shared (Sessions v2.0.2 cleanup)
/// makes these regressions catchable in CI instead of by eye.
///
/// Covered surfaces:
/// 1. summarizeInput — every Codex tool name + the generic fallback
/// 2. expandedDetail — Codex tools that produce a detail; non-Codex returns nil
/// 3. decodeResponseItem — all four payload variants + skip cases
///    (env_context filter, developer role, unknown payload type)
final class CodexJSONLParserTests: XCTestCase {

    // MARK: - summarizeInput

    func test_summarize_exec_command_prefers_description() {
        let s = CodexJSONLParser.summarizeInput(
            ["cmd": "ls -la /etc", "description": "List etc"],
            for: "exec_command", fallback: ""
        )
        XCTAssertEqual(s, "List etc")
    }

    func test_summarize_exec_command_falls_back_to_cmd() {
        let s = CodexJSONLParser.summarizeInput(
            ["cmd": "echo hello\nworld"],
            for: "exec_command", fallback: ""
        )
        XCTAssertEqual(s, "echo hello world")  // newline collapsed
    }

    func test_summarize_shell_treated_as_exec_command() {
        let s = CodexJSONLParser.summarizeInput(
            ["cmd": "ls"], for: "shell", fallback: ""
        )
        XCTAssertEqual(s, "ls")
    }

    func test_summarize_spawn_agent_prefers_brief() {
        let s = CodexJSONLParser.summarizeInput(
            ["brief": "refactor auth", "task": "do the refactor"],
            for: "spawn_agent", fallback: ""
        )
        XCTAssertEqual(s, "refactor auth")
    }

    func test_summarize_spawn_agent_falls_back_to_task() {
        let s = CodexJSONLParser.summarizeInput(
            ["task": "rebuild the index"],
            for: "spawn_agent", fallback: ""
        )
        XCTAssertEqual(s, "rebuild the index")
    }

    func test_summarize_apply_patch_picks_first_file_header() {
        let patch = """
        Some preamble
        *** Update File: src/foo.ts
        @@ -1 +1 @@
        -old
        +new
        """
        let s = CodexJSONLParser.summarizeInput(
            ["input": patch], for: "apply_patch", fallback: ""
        )
        XCTAssertEqual(s, "*** Update File: src/foo.ts")
    }

    func test_summarize_apply_patch_handles_patch_key() {
        let patch = "+++ b/foo.ts\n@@ -1 +1 @@\n-old\n+new"
        let s = CodexJSONLParser.summarizeInput(
            ["patch": patch], for: "apply_patch", fallback: ""
        )
        XCTAssertEqual(s, "+++ b/foo.ts")
    }

    func test_summarize_apply_patch_no_headers_collapses_newlines() {
        let s = CodexJSONLParser.summarizeInput(
            ["diff": "line1\nline2"], for: "apply_patch", fallback: ""
        )
        XCTAssertEqual(s, "line1 line2")
    }

    func test_summarize_read_file_returns_path() {
        let s = CodexJSONLParser.summarizeInput(
            ["path": "/Users/x/repo/foo.swift"],
            for: "read_file", fallback: ""
        )
        XCTAssertEqual(s, "/Users/x/repo/foo.swift")
    }

    func test_summarize_write_file_returns_path() {
        let s = CodexJSONLParser.summarizeInput(
            ["path": "/tmp/out.txt"], for: "write_file", fallback: ""
        )
        XCTAssertEqual(s, "/tmp/out.txt")
    }

    func test_summarize_unknown_tool_uses_shortest_string_field() {
        let s = CodexJSONLParser.summarizeInput(
            ["long": "a very long argument string", "short": "ok"],
            for: "unknown_tool", fallback: "FALLBACK"
        )
        XCTAssertEqual(s, "ok")
    }

    func test_summarize_falls_back_when_no_strings() {
        let s = CodexJSONLParser.summarizeInput(
            ["n": 42], for: "unknown_tool", fallback: "FB\nback"
        )
        XCTAssertEqual(s, "FB back")  // newline collapsed in fallback too
    }

    // MARK: - expandedDetail

    func test_expanded_exec_command_returns_cmd() {
        let d = CodexJSONLParser.expandedDetail(
            ["cmd": "ls -la", "description": "list"],
            for: "exec_command"
        )
        XCTAssertEqual(d, "ls -la")
    }

    func test_expanded_spawn_agent_prefers_brief() {
        let d = CodexJSONLParser.expandedDetail(
            ["brief": "long brief", "task": "short task"],
            for: "spawn_agent"
        )
        XCTAssertEqual(d, "long brief")
    }

    func test_expanded_apply_patch_returns_first_available() {
        let d = CodexJSONLParser.expandedDetail(
            ["patch": "p", "diff": "d"], for: "apply_patch"
        )
        XCTAssertEqual(d, "p")
    }

    func test_expanded_unknown_returns_nil() {
        XCTAssertNil(CodexJSONLParser.expandedDetail(
            ["path": "/tmp/f"], for: "read_file"
        ))
    }

    // MARK: - decodeResponseItem: message

    func test_decode_user_message_with_top_level_content_string() {
        let json: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": "fix the auth bug",
            ],
        ]
        let now = Date()
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: now, idForSuffix: { suffix in "test:\(suffix)" }
        )
        XCTAssertEqual(messages.count, 1)
        let msg = messages[0]
        XCTAssertEqual(msg.kind, .userText)
        XCTAssertEqual(msg.title, "You")
        XCTAssertEqual(msg.body, "fix the auth bug")
        XCTAssertEqual(msg.id, "test:codex-message")
        XCTAssertEqual(msg.at, now)
    }

    func test_decode_assistant_message_with_block_array() {
        let json: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [
                    ["type": "output_text", "text": "first part"],
                    ["type": "output_text", "text": "second part"],
                ],
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].kind, .assistantText)
        XCTAssertEqual(messages[0].title, "Codex")
        XCTAssertEqual(messages[0].body, "first part\nsecond part")
    }

    func test_decode_skips_environment_context_user_turn() {
        let json: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": "<environment_context>\ncwd=/foo\n</environment_context>",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertTrue(messages.isEmpty)
    }

    func test_decode_skips_developer_role() {
        let json: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "developer",
                "content": "system wrapper noise",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertTrue(messages.isEmpty)
    }

    func test_decode_skips_empty_message_body() {
        let json: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "message", "role": "user", "content": "",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - decodeResponseItem: function_call

    func test_decode_function_call_with_json_args() {
        let json: [String: Any] = [
            "payload": [
                "type": "function_call",
                "name": "exec_command",
                "arguments": #"{"cmd":"ls -la","description":"list dir"}"#,
                "call_id": "fc_abc123",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "fallback" }
        )
        XCTAssertEqual(messages.count, 1)
        let msg = messages[0]
        XCTAssertEqual(msg.kind, .toolCall)
        XCTAssertEqual(msg.title, "exec_command")
        XCTAssertEqual(msg.body, "list dir")  // description preferred
        XCTAssertEqual(msg.detail, "ls -la")  // expandedDetail returns cmd
        XCTAssertEqual(msg.id, "call:fc_abc123")
    }

    func test_decode_function_call_with_non_json_args_uses_raw() {
        let json: [String: Any] = [
            "payload": [
                "type": "function_call",
                "name": "weird_tool",
                "arguments": "not\njson",
                "call_id": "fc_xyz",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].body, "not json")  // newline collapsed
        XCTAssertEqual(messages[0].detail, "not\njson")
    }

    func test_decode_function_call_missing_call_id_uses_base_id() {
        let json: [String: Any] = [
            "payload": [
                "type": "function_call",
                "name": "tool",
                "arguments": "{}",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { suffix in "BASE:\(suffix)" }
        )
        XCTAssertEqual(messages[0].id, "call:BASE:codex-function_call")
    }

    // MARK: - decodeResponseItem: function_call_output

    func test_decode_function_call_output_raw_string() {
        let json: [String: Any] = [
            "payload": [
                "type": "function_call_output",
                "output": "hello stdout",
                "call_id": "fc_abc123",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertEqual(messages.count, 1)
        let msg = messages[0]
        XCTAssertEqual(msg.kind, .toolResult)
        XCTAssertEqual(msg.title, "Tool result")
        XCTAssertEqual(msg.body, "hello stdout")
        XCTAssertEqual(msg.id, "result:fc_abc123")
    }

    func test_decode_function_call_output_unwraps_envelope() {
        let json: [String: Any] = [
            "payload": [
                "type": "function_call_output",
                "output": #"{"output":"unwrapped","metadata":{}}"#,
                "call_id": "fc_x",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertEqual(messages[0].body, "unwrapped")
    }

    func test_decode_function_call_output_truncates_at_4kb() {
        let big = String(repeating: "a", count: 5000)
        let json: [String: Any] = [
            "payload": [
                "type": "function_call_output",
                "output": big,
                "call_id": "fc_x",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].body.hasSuffix("…[truncated]"))
        // 4096 chars + "\n…[truncated]" (13 chars)
        XCTAssertLessThan(messages[0].body.count, 5000)
    }

    func test_decode_function_call_output_empty_skipped() {
        let json: [String: Any] = [
            "payload": [
                "type": "function_call_output",
                "output": "",
                "call_id": "fc_x",
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - decodeResponseItem: reasoning

    func test_decode_reasoning_with_summary_blocks() {
        let json: [String: Any] = [
            "payload": [
                "type": "reasoning",
                "summary": [
                    ["text": "Considering options."],
                    ["text": "Picked A."],
                ],
            ],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].kind, .meta)
        XCTAssertEqual(messages[0].title, "Thinking")
        XCTAssertEqual(messages[0].body, "Considering options.\nPicked A.")
    }

    func test_decode_reasoning_with_top_level_summary_string() {
        let json: [String: Any] = [
            "payload": ["type": "reasoning", "summary": "one block"],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertEqual(messages[0].body, "one block")
    }

    func test_decode_reasoning_empty_skipped() {
        let json: [String: Any] = [
            "payload": ["type": "reasoning", "summary": ""],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - decodeResponseItem: skip cases

    func test_decode_unknown_payload_type_skipped() {
        let json: [String: Any] = [
            "payload": ["type": "future_kind", "stuff": "ignore"],
        ]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertTrue(messages.isEmpty)
    }

    func test_decode_missing_payload_skipped() {
        let json: [String: Any] = ["type": "response_item"]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertTrue(messages.isEmpty)
    }

    func test_decode_payload_without_type_skipped() {
        let json: [String: Any] = ["payload": ["role": "user"]]
        let messages = CodexJSONLParser.decodeResponseItem(
            json: json, at: Date(), idForSuffix: { _ in "x" }
        )
        XCTAssertTrue(messages.isEmpty)
    }
}
