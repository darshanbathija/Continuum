import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// F1a-wire chat-side parity tests: prove `ParsedLine.from(json:)`
/// produces the same `ParsedLine` for Claude `user`/`assistant` lines
/// regardless of whether `FeatureFlags.useClaudeAdapter` is on or off.
///
/// **Why this matters.** With the flag off the chat path uses the legacy
/// `decodeUser` / `decodeAssistant` block-walkers. With the flag on it
/// routes through `ClaudeAdapter.translate(...)` to confirm the canonical
/// `ProviderRuntimeEvent` stream lights up, then re-uses the same
/// block-walkers for per-block UI enrichment (EditStats / EditDiff /
/// BashResult / AskUserQuestion). The strangler-fig contract: the same
/// JSONL produces the same `ParsedLine` (same `[ChatMessage]`, same delta
/// tokens, same model) regardless of the flag.
///
/// **Intentional differences (documented).** The wired path reads token
/// totals (input / output / cache_create / cache_read) and model off the
/// canonical event + claude extension envelope instead of off the raw
/// `message.usage` dict. The values MUST be identical — this just routes
/// the read through the canonical pipeline. If they ever diverge that's
/// a bug, not an intentional difference. No other intentional differences
/// in F1a-wire.
///
/// **Plan:** F1a-wire (Phase 1; D23 strangler-fig). The same suite shape
/// is reused for F1b-wire (Codex), F1c-wire (OpenCode), F1d-wire (Cursor),
/// F1e-wire (Antigravity).
@MainActor
final class F1aWireChatParityTests: XCTestCase {

    // MARK: - Setup

    override func tearDown() {
        super.tearDown()
        FeatureFlags.useClaudeAdapterOverride = nil
    }

    /// Helper: parse the same line under flag-off and flag-on, return
    /// both results so the caller can assert structural equality.
    private func parseBoth(_ jsonString: String) -> (off: ParsedLine?, on: ParsedLine?) {
        let data = jsonString.data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        FeatureFlags.useClaudeAdapterOverride = false
        let off = ParsedLine.from(json: json)

        FeatureFlags.useClaudeAdapterOverride = true
        let on = ParsedLine.from(json: json)

        FeatureFlags.useClaudeAdapterOverride = nil
        return (off, on)
    }

    /// Structural-equality assertion for two `ParsedLine?`. ParsedLine
    /// itself isn't Equatable (ChatMessage is Hashable but the inner
    /// `EditDiff` types may not all be); compare field-by-field so a
    /// future struct add doesn't silently bypass the assertion.
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
        // ChatMessage is Hashable + Codable; compare the array directly.
        XCTAssertEqual(a.messages, b.messages, "messages", file: file, line: line)
    }

    // MARK: - User lines

    func test_parity_user_plainString() {
        let (off, on) = parseBoth("""
        {"type":"user","timestamp":"2026-05-15T10:00:00Z","cwd":"/Users/x/repo","message":{"role":"user","content":"Refactor SessionChatStore"}}
        """)
        assertParsedLineEqual(off, on)
    }

    func test_parity_user_contentBlocks_textOnly() {
        let (off, on) = parseBoth("""
        {"type":"user","timestamp":"2026-05-15T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Block 1"},{"type":"text","text":"Block 2"}]}}
        """)
        assertParsedLineEqual(off, on)
    }

    func test_parity_user_contentBlocks_withToolResult() {
        let (off, on) = parseBoth("""
        {"type":"user","timestamp":"2026-05-15T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"here:"},{"type":"tool_result","tool_use_id":"tu_1","content":"100 lines","is_error":false}]}}
        """)
        assertParsedLineEqual(off, on)
    }

    func test_parity_user_emptyContent_returnsNil() {
        let (off, on) = parseBoth("""
        {"type":"user","timestamp":"2026-05-15T10:00:00Z","message":{"role":"user","content":""}}
        """)
        XCTAssertNil(off, "Legacy drops empty content")
        XCTAssertNil(on, "Adapter path must also drop empty content")
    }

    // MARK: - Assistant lines

    func test_parity_assistant_textOnly_withUsage() {
        let (off, on) = parseBoth("""
        {"type":"assistant","timestamp":"2026-05-15T10:00:00Z","requestId":"req_1","cwd":"/Users/x/repo","message":{"id":"msg_1","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":1500,"output_tokens":320,"cache_creation_input_tokens":0,"cache_read_input_tokens":3200}}}
        """)
        assertParsedLineEqual(off, on)
    }

    func test_parity_assistant_textPlusBashToolUse() {
        let (off, on) = parseBoth("""
        {"type":"assistant","timestamp":"2026-05-15T10:00:00Z","message":{"id":"msg_2","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Running."},{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls","description":"List files"}}],"usage":{"input_tokens":100,"output_tokens":20}}}
        """)
        assertParsedLineEqual(off, on)
    }

    func test_parity_assistant_editToolUse_preservesEditStats() {
        // Edit tool_use should produce EditStats in both paths. The
        // adapter path re-uses the same block-walker for UI enrichment,
        // so the EditStats payload must be byte-identical.
        let (off, on) = parseBoth("""
        {"type":"assistant","timestamp":"2026-05-15T10:00:00Z","message":{"id":"msg_3","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"tool_use","id":"tu_2","name":"Edit","input":{"file_path":"/Users/x/repo/README.md","old_string":"old text","new_string":"new text"}}],"usage":{"input_tokens":200,"output_tokens":50}}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertNotNil(on?.messages.first?.editStats, "Edit tool_use → EditStats must survive the wired path")
    }

    func test_parity_assistant_askUserQuestion_preservesPayload() {
        let (off, on) = parseBoth("""
        {"type":"assistant","timestamp":"2026-05-15T10:00:00Z","message":{"id":"msg_4","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"tool_use","id":"tu_3","name":"AskUserQuestion","input":{"questions":[{"question":"Ship now?","header":"Decision","multiSelect":false,"options":[{"label":"Yes","description":"Ship immediately"},{"label":"No","description":"Wait"}]}]}}],"usage":{"input_tokens":50,"output_tokens":10}}}
        """)
        assertParsedLineEqual(off, on)
        XCTAssertNotNil(on?.messages.first?.askUserQuestion, "AskUserQuestion tool_use → payload must survive the wired path")
    }

    func test_parity_assistant_streamingPartial_noUsage() {
        // Streaming partial: assistant content but no usage envelope.
        // Legacy emits a ParsedLine with all-zero token deltas. Adapter
        // emits an assistantTokenDelta; wired path collects no token
        // totals (the bridge only reads from assistantMessageCompleted)
        // and ends up with all-zero deltas — same as legacy.
        let (off, on) = parseBoth("""
        {"type":"assistant","timestamp":"2026-05-15T10:00:00Z","message":{"id":"msg_5","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"streaming..."}]}}
        """)
        assertParsedLineEqual(off, on)
    }

    func test_parity_assistant_emptyContent_returnsNil() {
        let (off, on) = parseBoth("""
        {"type":"assistant","timestamp":"2026-05-15T10:00:00Z","message":{"id":"msg_6","role":"assistant","model":"claude-sonnet-4-5","content":[],"usage":{"input_tokens":100,"output_tokens":50}}}
        """)
        XCTAssertNil(off, "Legacy drops empty content")
        XCTAssertNil(on, "Adapter path must also drop empty content")
    }

    func test_parity_assistant_modelMissing() {
        let (off, on) = parseBoth("""
        {"type":"assistant","timestamp":"2026-05-15T10:00:00Z","message":{"id":"msg_7","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"output_tokens":50}}}
        """)
        assertParsedLineEqual(off, on)
        // Both legacy and wired paths get model from message.model;
        // when absent, both yield nil. Adapter falls back to legacy.
        XCTAssertNil(on?.model, "Missing model → nil under both paths")
    }

    // MARK: - Non-Claude (codex / unrelated) routes are untouched

    func test_parity_codexResponseItem_routeUnchanged() {
        // F1a-wire only touches the Claude branch — codex response_item
        // lines must produce the same result regardless of flag state.
        let (off, on) = parseBoth("""
        {"type":"response_item","timestamp":"2026-05-15T10:00:00Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex reply"}]}}
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
