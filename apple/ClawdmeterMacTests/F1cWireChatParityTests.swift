import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// F1c-wire chat-side parity tests: prove
/// `OpencodeSSEAdapter.parseMessageAdded(properties:)` produces the same
/// `ChatMessage` regardless of whether `FeatureFlags.useOpenCodeAdapter`
/// is on or off.
///
/// **Why this matters.** With the flag off the chat path uses the legacy
/// in-line `parseMessageAddedLegacy` parser. With the flag on it routes
/// through `parseMessageAddedViaAdapter`, which exercises
/// `OpenCodeAdapter.translate(...)` to confirm the canonical
/// `ProviderRuntimeEvent` stream lights up, then re-uses the legacy
/// parser verbatim for `ChatMessage` construction. The strangler-fig
/// contract: the same `properties` dict produces the same `ChatMessage?`
/// regardless of the flag.
///
/// **Intentional differences (documented).** The wired path runs the
/// adapter on the input but does NOT re-derive the `ChatMessage` fields
/// from the canonical events — that migration is deferred to a future PR
/// (gradually move tool-call / tool-result / text shapes into the
/// canonical `ExtensionField` envelope). No intentional differences in
/// F1c-wire chat output.
///
/// **Plan:** F1c-wire (Phase 1; D23 strangler-fig). Mirrors the
/// F1aWireChatParityTests shape used for the Claude chat-side wire.
@MainActor
final class F1cWireChatParityTests: XCTestCase {

    // MARK: - Setup

    override func tearDown() {
        super.tearDown()
        FeatureFlags.useOpenCodeAdapterOverride = nil
    }

    /// Helper: parse the same properties dict under flag-off and flag-on,
    /// return both results so the caller can assert structural equality.
    private func parseBoth(_ properties: [String: Any]) -> (off: ChatMessage?, on: ChatMessage?) {
        FeatureFlags.useOpenCodeAdapterOverride = false
        let off = OpencodeSSEAdapter.parseMessageAdded(properties: properties)

        FeatureFlags.useOpenCodeAdapterOverride = true
        let on = OpencodeSSEAdapter.parseMessageAdded(properties: properties)

        FeatureFlags.useOpenCodeAdapterOverride = nil
        return (off, on)
    }

    /// Compare two ChatMessages for structural equality. ChatMessage is
    /// Hashable + Equatable, but the `at` field is `Date()` synthesized
    /// per call — both invocations land at different timestamps. Compare
    /// the identity-bearing fields (id, kind, title, body, isError)
    /// instead, mirroring how F1aWireChatParityTests handles the same
    /// nondeterminism.
    private func assertChatMessageStructurallyEqual(
        _ a: ChatMessage?,
        _ b: ChatMessage?,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(a == nil, b == nil, "ChatMessage nil-ness diverged", file: file, line: line)
        guard let a, let b else { return }
        // id may be a synthesized UUID when `message.id` is absent —
        // both invocations generate different UUIDs in that case. Skip
        // id comparison when EITHER side looks like a UUID (matches the
        // 36-char hyphenated pattern). When BOTH sides have the same
        // explicit id (e.g. "msg_001"), the assertion still fires.
        let isUUIDLike: (String) -> Bool = { s in
            s.count == 36 && s.contains("-")
        }
        if !(isUUIDLike(a.id) && isUUIDLike(b.id)) {
            XCTAssertEqual(a.id, b.id, "id", file: file, line: line)
        }
        XCTAssertEqual(a.kind, b.kind, "kind", file: file, line: line)
        XCTAssertEqual(a.title, b.title, "title", file: file, line: line)
        XCTAssertEqual(a.body, b.body, "body", file: file, line: line)
        XCTAssertEqual(a.isError, b.isError, "isError", file: file, line: line)
    }

    // MARK: - Plain string content

    func test_parity_plainStringContent_assistant() {
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_001",
                "role": "assistant",
                "content": "Hello, how can I help?"
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertEqual(on?.kind, .assistantText)
        XCTAssertEqual(on?.body, "Hello, how can I help?")
    }

    func test_parity_plainStringContent_user() {
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_user_001",
                "role": "user",
                "content": "What time is it?"
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertEqual(on?.kind, .userText)
        XCTAssertEqual(on?.title, "User")
    }

    // MARK: - Array content

    func test_parity_arrayContent_textParts() {
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_002",
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "First chunk."],
                    ["type": "text", "text": "Second chunk."]
                ]
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertEqual(on?.body, "First chunk.\nSecond chunk.")
    }

    func test_parity_arrayContent_toolCall() {
        // First tool-call short-circuits. Both paths must select the
        // same tool name + serialize the input the same way.
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_tool_call",
                "role": "assistant",
                "content": [
                    ["type": "tool-call", "name": "Bash", "input": ["command": "ls"]]
                ]
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertEqual(on?.kind, .toolCall)
        XCTAssertEqual(on?.title, "Bash")
        XCTAssertEqual(on?.body, #"{"command":"ls"}"#)
    }

    func test_parity_arrayContent_toolUseAlias() {
        // `tool_use` is the Anthropic-style alias OpenCode also emits.
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_tu",
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "name": "Read", "input": ["path": "/tmp/x"]]
                ]
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertEqual(on?.kind, .toolCall)
        XCTAssertEqual(on?.title, "Read")
    }

    func test_parity_arrayContent_toolResult_output() {
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_result",
                "role": "assistant",
                "content": [
                    ["type": "tool-result", "output": "file listed", "isError": false]
                ]
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertEqual(on?.kind, .toolResult)
        XCTAssertEqual(on?.body, "file listed")
        XCTAssertFalse(on?.isError ?? true)
    }

    func test_parity_arrayContent_toolResult_isError() {
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_err",
                "role": "assistant",
                "content": [
                    ["type": "tool_result", "text": "command failed", "isError": true]
                ]
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertTrue(on?.isError ?? false)
    }

    // MARK: - Drops (both paths return nil)

    func test_parity_nilWhenMessageMissing() {
        let (off, on) = parseBoth([:])
        XCTAssertNil(off, "Legacy returns nil when properties.message is missing")
        XCTAssertNil(on, "Adapter path must also return nil")
    }

    func test_parity_nilWhenMessageMissingWithOtherFields() {
        let (off, on) = parseBoth(["other": "value"])
        XCTAssertNil(off)
        XCTAssertNil(on)
    }

    func test_parity_emptyTextArrayReturnsNil() {
        // Array content with no text fragments and no recognized tool
        // parts → empty join → guard returns nil.
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_empty",
                "role": "assistant",
                "content": [
                    ["type": "unknown"],
                    ["type": "also-unknown"]
                ]
            ]
        ])
        XCTAssertNil(off)
        XCTAssertNil(on)
    }

    // MARK: - Default + synthesized fields

    func test_parity_defaultsToAssistantRole() {
        // Missing role defaults to "assistant" per the parser contract.
        let (off, on) = parseBoth([
            "message": [
                "id": "msg_no_role",
                "content": "auto-assistant"
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertEqual(on?.kind, .assistantText)
        XCTAssertEqual(on?.title, "Assistant")
    }

    func test_parity_synthesizesIdWhenMissing() {
        // No id field → parser generates a fresh UUID. The two
        // invocations generate DIFFERENT UUIDs, so the id field is
        // expected to diverge — but the rest of the ChatMessage shape
        // (kind, title, body) MUST match. Our structural-equality
        // helper skips id comparison when both sides look like UUIDs.
        let (off, on) = parseBoth([
            "message": [
                "role": "assistant",
                "content": "no id here"
            ]
        ])
        assertChatMessageStructurallyEqual(off, on)
        XCTAssertNotNil(on)
        XCTAssertFalse(on?.id.isEmpty ?? true,
            "missing id must fall back to a synthesized non-empty UUID")
    }
}
