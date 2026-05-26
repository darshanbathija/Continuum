import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// F1b-wire chat-side parity tests: prove `ParsedLine.from(json:)`
/// produces the same `ParsedLine` for Codex `response_item` lines
/// regardless of whether `FeatureFlags.useCodexAdapter` is on or off.
///
/// **Why this matters.** With the flag off the chat path uses the legacy
/// `CodexJSONLParser.decodeResponseItem` block-walker. With the flag on
/// it routes through a transient `CodexAdapter` to confirm the canonical
/// `ProviderRuntimeEvent` stream lights up, then re-uses the same
/// block-walker for per-tool UI enrichment (EditDiff / BashResult /
/// reasoning / web_search). The strangler-fig contract: the same JSONL
/// produces the same `ParsedLine` (same `[ChatMessage]`, same delta
/// tokens, same model) regardless of the flag.
///
/// **Intentional differences (documented).** Codex's chat lines
/// (`response_item`) never carry billing tokens — those live in
/// `event_msg.token_count` which the chat layer drops outright. Both
/// paths therefore yield `deltaInputTokens == 0` etc. for every Codex
/// chat line. If the adapter emits `.unknown` for `response_item` (its
/// expected behavior — see `CodexAdapter.translate`), the wired path
/// still calls the legacy block-walker for ChatMessage construction.
///
/// **Plan:** F1b-wire (Phase 1; D23 strangler-fig).
@MainActor
final class F1bWireChatParityTests: XCTestCase {

    // MARK: - Setup

    override func tearDown() {
        super.tearDown()
        FeatureFlags.useCodexAdapterOverride = nil
    }

    /// Helper: parse the same line under flag-off and flag-on, return
    /// both results so the caller can assert structural equality.
    private func parseBoth(_ jsonString: String) -> (off: ParsedLine?, on: ParsedLine?) {
        let data = jsonString.data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        FeatureFlags.useCodexAdapterOverride = false
        let off = ParsedLine.from(json: json)

        FeatureFlags.useCodexAdapterOverride = true
        let on = ParsedLine.from(json: json)

        FeatureFlags.useCodexAdapterOverride = nil
        return (off, on)
    }

    /// Structural-equality assertion for two `ParsedLine?`. Same shape as
    /// F1a's `assertParsedLineEqual` — compare field-by-field so a future
    /// struct add doesn't silently bypass the assertion.
    private func assertParsedLineEqual(
        _ a: ParsedLine?,
        _ b: ParsedLine?,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(a == nil, b == nil, "ParsedLine nil-ness diverged", file: file, line: line)
        guard let a, let b else { return }
        XCTAssertEqual(a.timestamp, b.timestamp, "timestamp", file: file, line: line)
        XCTAssertEqual(a.deltaInputTokens, b.deltaInputTokens, "deltaInputTokens", file: file, line: line)
        XCTAssertEqual(a.deltaOutputTokens, b.deltaOutputTokens, "deltaOutputTokens", file: file, line: line)
        XCTAssertEqual(a.deltaCacheCreationTokens, b.deltaCacheCreationTokens, "deltaCacheCreationTokens", file: file, line: line)
        XCTAssertEqual(a.deltaCacheReadTokens, b.deltaCacheReadTokens, "deltaCacheReadTokens", file: file, line: line)
        XCTAssertEqual(a.model, b.model, "model", file: file, line: line)
        XCTAssertEqual(a.messages, b.messages, "messages", file: file, line: line)
    }

    // MARK: - response_item: message (assistant / user prose)

    func test_parity_assistantMessage() {
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex reply"}]}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertNotNil(on)
    }

    func test_parity_userMessage() {
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"refactor this"}]}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertNotNil(on)
    }

    func test_parity_userMessage_environmentContext_dropped() {
        // Codex injects environment-context turns; both paths must drop.
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd=/x</environment_context>"}]}}
        """)
        XCTAssertNil(off, "Legacy drops environment_context")
        XCTAssertNil(on, "Adapter path must also drop environment_context")
    }

    func test_parity_developerRole_dropped() {
        // role:"developer" wrappers aren't surfaced in chat.
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"sys prompt"}]}}
        """)
        XCTAssertNil(off)
        XCTAssertNil(on)
    }

    // MARK: - response_item: function_call (tool invocations)

    func test_parity_functionCall_execCommand_preservesBashResult() {
        // Codex's exec_command/shell tool produces a BashResult preview
        // in the chat row. The adapter routes through the legacy block-
        // walker so the BashResult survives the wired path.
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"function_call","name":"shell","call_id":"call_1","arguments":"{\\"cmd\\":\\"ls -la\\",\\"description\\":\\"List files\\"}"}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertEqual(on?.messages.first?.title, "shell")
    }

    func test_parity_functionCall_applyPatch_preservesEditDiff() {
        // apply_patch carries a unified diff; both paths must produce the
        // same EditDiff preview.
        let (off, on) = parseBoth(#"""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"function_call","name":"apply_patch","call_id":"call_2","arguments":"{\"input\":\"*** Begin Patch\\n*** Update File: README.md\\n@@\\n-old\\n+new\\n*** End Patch\"}"}}
        """#)
        assertParsedLineEqual(off, on)
    }

    func test_parity_functionCallOutput() {
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"function_call_output","call_id":"call_1","output":"file1.swift\\nfile2.swift"}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertEqual(on?.messages.first?.kind, .toolResult)
    }

    func test_parity_functionCallOutput_bashEnvelope_preservesExitCode() {
        // Codex's shell output sometimes wraps in `{output, exit_code,
        // stdout, stderr}`; the bashResult preview must survive parity.
        let (off, on) = parseBoth(#"""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"function_call_output","call_id":"call_3","output":"{\"exit_code\":0,\"stdout\":\"hello\\n\",\"stderr\":\"\"}"}}
        """#)
        assertParsedLineEqual(off, on)
    }

    // MARK: - response_item: reasoning

    func test_parity_reasoning_summary() {
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"reasoning","summary":[{"text":"Considering the refactor."}]}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertEqual(on?.messages.first?.kind, .meta)
    }

    func test_parity_reasoning_empty_dropped() {
        // Empty reasoning summary → both paths drop.
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"reasoning","summary":[]}}
        """)
        XCTAssertNil(off)
        XCTAssertNil(on)
    }

    // MARK: - response_item: web_search

    func test_parity_webSearchCall() {
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"web_search_call","call_id":"ws_1","action":{"query":"swift actor reentrancy"},"status":"completed"}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertEqual(on?.messages.first?.title, "web_search")
    }

    // MARK: - response_item: custom_tool_call

    func test_parity_customToolCall() {
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"custom_tool_call","name":"my_tool","call_id":"ct_1","input":"{\\"key\\":\\"value\\"}"}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertEqual(on?.messages.first?.kind, .toolCall)
    }

    // MARK: - Token totals stay zero across the flag

    func test_parity_tokensAlwaysZeroForChatLines() {
        // Codex chat-side lines never carry billing tokens — those live
        // in event_msg.token_count which the chat layer drops outright.
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}}
        """)
        XCTAssertEqual(off?.deltaInputTokens, 0)
        XCTAssertEqual(off?.deltaOutputTokens, 0)
        XCTAssertEqual(on?.deltaInputTokens, 0)
        XCTAssertEqual(on?.deltaOutputTokens, 0)
        XCTAssertNil(on?.model, "Codex chat lines never carry message-level model")
    }

    // MARK: - Non-Codex routes untouched by the flag

    func test_parity_claudeAssistantLine_routeUnchanged() {
        // F1b-wire only touches the Codex (response_item) branch — Claude
        // user/assistant lines must produce the same result regardless
        // of the Codex flag's state.
        let (off, on) = parseBoth("""
        {"type":"assistant","timestamp":"2026-05-15T10:00:00Z","message":{"id":"msg_x","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"output_tokens":5}}}
        """)
        assertParsedLineEqual(off, on)
    }

    func test_parity_unknownType_returnsNil() {
        let (off, on) = parseBoth("""
        {"type":"some_future_kind","timestamp":"2026-05-15T10:00:00Z","payload":{}}
        """)
        XCTAssertNil(off)
        XCTAssertNil(on)
    }
}
