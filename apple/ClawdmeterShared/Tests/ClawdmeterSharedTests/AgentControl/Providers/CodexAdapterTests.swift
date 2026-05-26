import XCTest
@testable import ClawdmeterShared

/// Parity tests for the F1b `CodexAdapter`. Locks in:
///   - Session metadata → .sessionStarted (emitted once per adapter)
///   - turn_context model updates persist across translate() calls
///   - token_count cumulative → delta math matches legacy CodexUsageParser
///   - Session reset (non-monotonic drop) re-baselines as fresh cumulative
///   - agent_message + user_message + error map to canonical payloads
///   - Forward-compat .unknown for new event_msg subtypes + top-level types
///   - Sequence numbers monotonically increment per adapter instance
///   - Raw payload retention + Codex extension fields preserved
///
/// Plan: F1b (Phase 1; D23) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`
final class CodexAdapterTests: XCTestCase {

    private func parse(_ json: String) -> [String: Any] {
        let data = json.data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Session metadata

    func test_sessionMeta_emitsSessionStartedOnce() {
        let adapter = CodexAdapter(sessionId: "s1")
        let sessionMetaLine = parse("""
        {
          "timestamp": "2026-05-15T10:00:00Z",
          "type": "session_meta",
          "payload": { "cwd": "/Users/x/myrepo" }
        }
        """)
        let events1 = adapter.translate(line: sessionMetaLine)
        XCTAssertEqual(events1.count, 1)
        guard case .sessionStarted(let model, let settings) = events1[0].payload else {
            return XCTFail("Expected .sessionStarted, got \(events1[0].payload)")
        }
        XCTAssertEqual(model, "gpt-5") // default before turn_context lands
        XCTAssertEqual(settings["cwd"], "/Users/x/myrepo")

        // Subsequent session_meta lines (rare but possible) MUST NOT
        // re-emit .sessionStarted — once per adapter instance.
        let events2 = adapter.translate(line: sessionMetaLine)
        XCTAssertEqual(events2.count, 0)
    }

    func test_turnContext_updatesCurrentModel() {
        let adapter = CodexAdapter(sessionId: "s1")
        // session_meta emits first .sessionStarted with the default model.
        _ = adapter.translate(line: parse("""
        {
          "timestamp": "2026-05-15T10:00:00Z",
          "type": "session_meta",
          "payload": { "cwd": "/Users/x/myrepo" }
        }
        """))
        // turn_context updates the model.
        let turnContextLine = parse("""
        {
          "timestamp": "2026-05-15T10:00:01Z",
          "type": "turn_context",
          "payload": { "model": "gpt-5-codex", "cwd": "/Users/x/myrepo" }
        }
        """)
        let events = adapter.translate(line: turnContextLine)
        // No new .sessionStarted (already emitted); model update is
        // observable on subsequent token_count events.
        XCTAssertEqual(events.count, 0)

        // Confirm via a follow-up token_count event's extension field.
        let tcLine = parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": {
            "type": "token_count",
            "info": {
              "total_token_usage": {
                "input_tokens": 1000,
                "cached_input_tokens": 0,
                "output_tokens": 500
              }
            }
          }
        }
        """)
        let tcEvents = adapter.translate(line: tcLine)
        XCTAssertEqual(tcEvents.count, 1)
        guard let ext = tcEvents[0].providerExtensions,
              case .nested(let codex) = ext["codex"] else {
            return XCTFail("Expected codex extension fields")
        }
        XCTAssertEqual(codex["model"], .string("gpt-5-codex"))
    }

    // MARK: - Token count delta math

    func test_tokenCount_firstSnapshot_emitsDeltaFromZero() {
        let adapter = CodexAdapter(sessionId: "s1")
        let line = parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": {
            "type": "token_count",
            "info": {
              "total_token_usage": {
                "input_tokens": 1000,
                "cached_input_tokens": 0,
                "output_tokens": 500
              }
            }
          }
        }
        """)
        let events = adapter.translate(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .assistantMessageCompleted(_, let tokensIn, let tokensOut) = events[0].payload else {
            return XCTFail("Expected .assistantMessageCompleted")
        }
        XCTAssertEqual(tokensIn, 1000)
        XCTAssertEqual(tokensOut, 500)

        // Extensions carry the delta + cumulative breakdown.
        guard let ext = events[0].providerExtensions,
              case .nested(let codex) = ext["codex"] else {
            return XCTFail("Expected codex extension fields")
        }
        XCTAssertEqual(codex["delta_input"], .int(1000))
        XCTAssertEqual(codex["delta_output"], .int(500))
        XCTAssertEqual(codex["was_session_reset"], .bool(false))
    }

    func test_tokenCount_secondSnapshot_emitsDeltaFromPrevious() {
        let adapter = CodexAdapter(sessionId: "s1")
        _ = adapter.translate(line: parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": {
            "type": "token_count",
            "info": {
              "total_token_usage": {
                "input_tokens": 1000,
                "cached_input_tokens": 0,
                "output_tokens": 500
              }
            }
          }
        }
        """))
        let events = adapter.translate(line: parse("""
        {
          "timestamp": "2026-05-15T10:02:00Z",
          "type": "event_msg",
          "payload": {
            "type": "token_count",
            "info": {
              "total_token_usage": {
                "input_tokens": 3000,
                "cached_input_tokens": 500,
                "output_tokens": 1500
              }
            }
          }
        }
        """))
        XCTAssertEqual(events.count, 1)
        guard case .assistantMessageCompleted(_, let tokensIn, let tokensOut) = events[0].payload else {
            return XCTFail("Expected .assistantMessageCompleted")
        }
        // Cumulative uncached input: 3000 - 500 = 2500; previous uncached = 1000 → delta = 1500
        XCTAssertEqual(tokensIn, 1500)
        // Cumulative output: 1500; previous = 500 → delta = 1000
        XCTAssertEqual(tokensOut, 1000)
    }

    func test_tokenCount_nonMonotonicDrop_treatedAsSessionReset() {
        let adapter = CodexAdapter(sessionId: "s1")
        // First cumulative: 1000 input / 500 output.
        _ = adapter.translate(line: parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": {
            "type": "token_count",
            "info": {
              "total_token_usage": {
                "input_tokens": 1000,
                "cached_input_tokens": 0,
                "output_tokens": 500
              }
            }
          }
        }
        """))
        // Cumulative drops — session reset.
        let events = adapter.translate(line: parse("""
        {
          "timestamp": "2026-05-15T10:02:00Z",
          "type": "event_msg",
          "payload": {
            "type": "token_count",
            "info": {
              "total_token_usage": {
                "input_tokens": 200,
                "cached_input_tokens": 0,
                "output_tokens": 100
              }
            }
          }
        }
        """))
        XCTAssertEqual(events.count, 1)
        guard case .assistantMessageCompleted(_, let tokensIn, let tokensOut) = events[0].payload else {
            return XCTFail("Expected .assistantMessageCompleted")
        }
        // Reset: new cumulative IS the delta (don't go negative).
        XCTAssertEqual(tokensIn, 200)
        XCTAssertEqual(tokensOut, 100)

        guard let ext = events[0].providerExtensions,
              case .nested(let codex) = ext["codex"] else {
            return XCTFail("Expected codex extension fields")
        }
        XCTAssertEqual(codex["was_session_reset"], .bool(true))
    }

    func test_tokenCount_zeroDelta_emitsNothing() {
        let adapter = CodexAdapter(sessionId: "s1")
        let line = parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": {
            "type": "token_count",
            "info": {
              "total_token_usage": {
                "input_tokens": 0,
                "cached_input_tokens": 0,
                "output_tokens": 0
              }
            }
          }
        }
        """)
        let events = adapter.translate(line: line)
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - Agent / user message + error

    func test_eventMsg_agentMessage_emitsAssistantTokenDelta() {
        let adapter = CodexAdapter(sessionId: "s1")
        let line = parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": {
            "type": "agent_message",
            "message": "Here is the diff."
          }
        }
        """)
        let events = adapter.translate(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .assistantTokenDelta(let text, _) = events[0].payload else {
            return XCTFail("Expected .assistantTokenDelta, got \(events[0].payload)")
        }
        XCTAssertEqual(text, "Here is the diff.")
    }

    func test_eventMsg_userMessage_emitsUserMessage() {
        let adapter = CodexAdapter(sessionId: "s1")
        let line = parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": {
            "type": "user_message",
            "message": "Refactor this."
          }
        }
        """)
        let events = adapter.translate(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .userMessage(let text, _) = events[0].payload else {
            return XCTFail("Expected .userMessage")
        }
        XCTAssertEqual(text, "Refactor this.")
    }

    func test_eventMsg_error_emitsProviderError() {
        let adapter = CodexAdapter(sessionId: "s1")
        let line = parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": {
            "type": "error",
            "code": "rate_limit",
            "message": "Codex rate limited; retrying"
          }
        }
        """)
        let events = adapter.translate(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .providerError(let code, let message) = events[0].payload else {
            return XCTFail("Expected .providerError")
        }
        XCTAssertEqual(code, "rate_limit")
        XCTAssertEqual(message, "Codex rate limited; retrying")
    }

    // MARK: - Forward-compat .unknown

    func test_eventMsg_unknownSubtype_emitsUnknown() {
        let adapter = CodexAdapter(sessionId: "s1")
        let line = parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "event_msg",
          "payload": { "type": "future_subtype_42" }
        }
        """)
        let events = adapter.translate(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .unknown(let name) = events[0].payload else {
            return XCTFail("Expected .unknown")
        }
        XCTAssertEqual(name, "codex.event_msg.future_subtype_42")
    }

    func test_unknownTopLevelType_emitsUnknown() {
        let adapter = CodexAdapter(sessionId: "s1")
        let line = parse("""
        {
          "timestamp": "2026-05-15T10:01:00Z",
          "type": "future_top_level_xyz",
          "payload": {}
        }
        """)
        let events = adapter.translate(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .unknown(let name) = events[0].payload else {
            return XCTFail("Expected .unknown")
        }
        XCTAssertEqual(name, "codex.type.future_top_level_xyz")
    }

    // MARK: - Sequence numbers + provider instance

    func test_sequenceNumbers_monotonicAcrossCalls() {
        let adapter = CodexAdapter(
            sessionId: "s1",
            providerInstanceId: "codex_pro",
            initialSequenceNumber: 100
        )
        let sessionMetaLine = parse("""
        {
          "timestamp": "2026-05-15T10:00:00Z",
          "type": "session_meta",
          "payload": { "cwd": "/x" }
        }
        """)
        let agentLine = parse("""
        {
          "timestamp": "2026-05-15T10:00:01Z",
          "type": "event_msg",
          "payload": { "type": "agent_message", "message": "Hi" }
        }
        """)
        let e1 = adapter.translate(line: sessionMetaLine)
        let e2 = adapter.translate(line: agentLine)
        XCTAssertEqual(e1[0].sequenceNumber, 100)
        XCTAssertEqual(e2[0].sequenceNumber, 101)
        XCTAssertEqual(e1[0].providerInstanceId, "codex_pro")
        XCTAssertEqual(e2[0].providerInstanceId, "codex_pro")
    }

    // MARK: - Raw payload retention

    func test_rawPayloadRetention_attachedToEvents() {
        let adapter = CodexAdapter(sessionId: "s1")
        let json = """
        {
          "timestamp": "2026-05-15T10:00:00Z",
          "type": "session_meta",
          "payload": { "cwd": "/x" }
        }
        """
        let line = parse(json)
        let bytes = json.data(using: .utf8)!
        let events = adapter.translate(line: line, rawBytes: bytes)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].rawProviderPayload, bytes)
    }
}
