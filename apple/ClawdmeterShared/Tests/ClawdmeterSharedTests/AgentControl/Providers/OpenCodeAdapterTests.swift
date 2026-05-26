import XCTest
@testable import ClawdmeterShared

/// Parity tests for the F1c `OpenCodeAdapter`. Locks in:
///   - Assistant message → `.assistantMessageCompleted` with correct token
///     counts (mirrors `OpencodeUsageParser` semantics)
///   - User message → `.userMessage` (content + parts shapes)
///   - Embedded cost field survives into extensions
///   - Token breakdown (input/output/reasoning/cache.write/cache.read)
///     preserved in opencode extension fields
///   - Provider+model id preserved
///   - Unknown role → `.unknown(name:)` forward-compat
///
/// Plan: F1c (Phase 1; D23) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`
final class OpenCodeAdapterTests: XCTestCase {

    private func parse(_ json: String) -> [String: Any] {
        let data = json.data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private let timestamp = Date(timeIntervalSince1970: 1_715_000_000)

    // MARK: - Assistant message

    func test_assistantMessage_emitsCompletedWithTokens() {
        let message = parse("""
        {
          "role": "assistant",
          "cost": 0.012,
          "tokens": {
            "input": 1500,
            "output": 320,
            "reasoning": 100,
            "cache": { "write": 0, "read": 4200 }
          },
          "modelID": "claude-sonnet-4.5",
          "providerID": "anthropic",
          "time": { "created": 1715000000000 },
          "path": { "cwd": "/Users/x/myrepo" },
          "content": "Here is the diff."
        }
        """)
        let events = OpenCodeAdapter.translate(
            message: message,
            messageId: "msg-1",
            timestamp: timestamp,
            sessionId: "session-1",
            sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.providerKind, .opencode)
        XCTAssertEqual(event.id, "opencode-msg-1-0")

        guard case .assistantMessageCompleted(let text, let tokensIn, let tokensOut) = event.payload else {
            return XCTFail("Expected .assistantMessageCompleted, got \(event.payload)")
        }
        XCTAssertEqual(text, "Here is the diff.")
        XCTAssertEqual(tokensIn, 1500)
        XCTAssertEqual(tokensOut, 320)

        // Extensions carry the full breakdown + cost.
        guard let ext = event.providerExtensions,
              case .nested(let opencode) = ext["opencode"] else {
            return XCTFail("Expected opencode extension fields")
        }
        XCTAssertEqual(opencode["model_id"], .string("claude-sonnet-4.5"))
        XCTAssertEqual(opencode["provider_id"], .string("anthropic"))
        XCTAssertEqual(opencode["cwd"], .string("/Users/x/myrepo"))
        XCTAssertEqual(opencode["reasoning_tokens"], .int(100))
        XCTAssertEqual(opencode["cache_write_tokens"], .int(0))
        XCTAssertEqual(opencode["cache_read_tokens"], .int(4200))
        XCTAssertEqual(opencode["embedded_cost_usd"], .double(0.012))
        XCTAssertEqual(opencode["created_ms"], .int(1_715_000_000_000))
    }

    func test_assistantMessage_partsArrayShape() {
        // Some OpenCode versions emit `parts: [{ text: ... }]` instead of
        // a flat `content` string. Adapter must handle both.
        let message = parse("""
        {
          "role": "assistant",
          "tokens": { "input": 100, "output": 50 },
          "modelID": "gpt-5",
          "providerID": "openai",
          "parts": [
            { "text": "First part." },
            { "text": "Second part." }
          ]
        }
        """)
        let events = OpenCodeAdapter.translate(
            message: message,
            messageId: "msg-2",
            timestamp: timestamp,
            sessionId: "session-1",
            sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .assistantMessageCompleted(let text, _, _) = events[0].payload else {
            return XCTFail("Expected .assistantMessageCompleted")
        }
        XCTAssertEqual(text, "First part.\nSecond part.")
    }

    func test_assistantMessage_missingTokensBlock_stillEmits() {
        // OpencodeUsageParser skips rows without tokens (analytics), but
        // the adapter still emits — chat consumers may want to see the
        // turn even when usage is missing. Token counts default to zero.
        let message = parse("""
        {
          "role": "assistant",
          "modelID": "gpt-5",
          "content": "Hi"
        }
        """)
        let events = OpenCodeAdapter.translate(
            message: message,
            messageId: "msg-3",
            timestamp: timestamp,
            sessionId: "session-1",
            sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .assistantMessageCompleted(_, let tokensIn, let tokensOut) = events[0].payload else {
            return XCTFail("Expected .assistantMessageCompleted")
        }
        XCTAssertEqual(tokensIn, 0)
        XCTAssertEqual(tokensOut, 0)
    }

    // MARK: - User message

    func test_userMessage_contentShape() {
        let message = parse("""
        {
          "role": "user",
          "modelID": "claude-sonnet-4.5",
          "content": "Refactor this."
        }
        """)
        let events = OpenCodeAdapter.translate(
            message: message,
            messageId: "msg-u",
            timestamp: timestamp,
            sessionId: "session-1",
            sequenceStart: 5
        )
        XCTAssertEqual(events.count, 1)
        guard case .userMessage(let text, _) = events[0].payload else {
            return XCTFail("Expected .userMessage")
        }
        XCTAssertEqual(text, "Refactor this.")
        XCTAssertEqual(events[0].sequenceNumber, 5)
    }

    // MARK: - Unknown role

    func test_unknownRole_emitsUnknown() {
        let message = parse("""
        { "role": "future_role_xyz" }
        """)
        let events = OpenCodeAdapter.translate(
            message: message,
            messageId: "msg-x",
            timestamp: timestamp,
            sessionId: "session-1",
            sequenceStart: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .unknown(let name) = events[0].payload else {
            return XCTFail("Expected .unknown")
        }
        XCTAssertEqual(name, "opencode.role.future_role_xyz")
    }

    // MARK: - Raw payload + provider instance

    func test_rawPayload_andProviderInstanceId_propagate() {
        let json = """
        { "role": "user", "content": "Hi" }
        """
        let message = parse(json)
        let bytes = json.data(using: .utf8)!
        let events = OpenCodeAdapter.translate(
            message: message,
            messageId: "msg-bytes",
            timestamp: timestamp,
            sessionId: "session-1",
            sequenceStart: 0,
            providerInstanceId: "opencode_main",
            rawBytes: bytes
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].rawProviderPayload, bytes)
        XCTAssertEqual(events[0].providerInstanceId, "opencode_main")
    }
}
