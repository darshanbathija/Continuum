#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Coverage for the chat-IDE Gemini JSONL parser. Fixtures derived from
/// real `~/.gemini/tmp/<repo>/chats/session-*.jsonl` files written by
/// Gemini CLI 0.42.0.
final class GeminiJSONLParserTests: XCTestCase {

    private func stableId(suffix: String) -> String {
        // Deterministic test stub mirroring SessionChatStore.stableId(_:suffix:)
        // shape (`<line-id>:<suffix>` style).
        "test:\(suffix)"
    }

    // MARK: - Header line

    func test_headerLine_returnsEmpty() {
        // First line of a Gemini JSONL is metadata (sessionId, projectHash,
        // startTime, lastUpdated, kind: "main") and MUST NOT surface as a
        // chat message — otherwise the conversation leads with garbage.
        let json: [String: Any] = [
            "sessionId": "eddb10c4-8ec0-4a7e-837d-0819d59c8575",
            "projectHash": "847395f29d7314a1d36b6424c92c3b9fdddc3aa2fe063adab8b8fa30cfa6c429",
            "startTime": "2026-05-12T15:36:28.686Z",
            "lastUpdated": "2026-05-12T15:36:28.686Z",
            "kind": "main"
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertTrue(out.isEmpty, "Header line must NOT produce a chat row")
    }

    // MARK: - User turn

    func test_userLine_concatenatesTextParts() {
        let json: [String: Any] = [
            "id": "b2f6658b-41bf-4dd5-bbd1-07599564444d",
            "timestamp": "2026-05-12T15:36:45.881Z",
            "type": "user",
            "content": [
                ["text": "diff --git a/README.md b/README.md"],
                ["text": "Please review this change."]
            ]
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .userText)
        XCTAssertEqual(out.first?.title, "You")
        XCTAssertEqual(out.first?.body, "diff --git a/README.md b/README.md\nPlease review this change.")
    }

    func test_userLine_bareStringContentSurfaces() {
        // Tolerant of older/future schema where content is a bare string
        // instead of an array of parts.
        let json: [String: Any] = [
            "id": "abc",
            "timestamp": "2026-05-12T15:36:45.881Z",
            "type": "user",
            "content": "what is the time complexity of quicksort?"
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .userText)
        XCTAssertEqual(out.first?.body, "what is the time complexity of quicksort?")
    }

    func test_userLine_emptyContent_returnsEmpty() {
        let json: [String: Any] = [
            "id": "abc",
            "timestamp": "2026-05-12T15:36:45.881Z",
            "type": "user",
            "content": []
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Model turn

    func test_modelLine_surfacesAsAssistantText() {
        let json: [String: Any] = [
            "id": "68d0974d-28f2-405a-81d9-02e154f933d7",
            "timestamp": "2026-05-08T11:45:30.506Z",
            "type": "model",
            "content": "I will start by using the codebase_investigator tool."
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .assistantText)
        XCTAssertEqual(out.first?.title, "Gemini")
        XCTAssertEqual(out.first?.body, "I will start by using the codebase_investigator tool.")
    }

    func test_modelLine_geminiTypeAlias() {
        // Older Gemini CLI versions emit `type: "gemini"` instead of "model".
        let json: [String: Any] = [
            "id": "x",
            "timestamp": "2026-05-08T11:45:30.506Z",
            "type": "gemini",
            "content": "hello world"
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .assistantText)
    }

    func test_modelLine_withThoughts_emitsReasoningBubble() {
        let json: [String: Any] = [
            "id": "x",
            "timestamp": "2026-05-08T11:45:30.506Z",
            "type": "model",
            "content": "Final answer: O(n log n)",
            "thoughts": [
                ["subject": "Approach", "description": "Pick a pivot, partition, recurse."],
                ["subject": "Complexity", "description": "Average O(n log n), worst O(n^2)."]
            ]
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertEqual(out.count, 2, "Both reasoning + assistant bubbles should surface")
        XCTAssertEqual(out[0].kind, .meta, "Thoughts go in the .meta bubble")
        XCTAssertEqual(out[0].title, "Reasoning")
        XCTAssertTrue(out[0].body.contains("**Approach**"))
        XCTAssertTrue(out[0].body.contains("Pick a pivot"))
        XCTAssertEqual(out[1].kind, .assistantText)
        XCTAssertEqual(out[1].body, "Final answer: O(n log n)")
    }

    func test_modelLine_emptyContent_returnsEmpty() {
        let json: [String: Any] = [
            "id": "x",
            "timestamp": "2026-05-08T11:45:30.506Z",
            "type": "model",
            "content": "   "
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertTrue(out.isEmpty, "Whitespace-only content should not surface a bubble")
    }

    // MARK: - System / unknown types

    func test_systemLine_returnsEmpty() {
        // Synthetic context injection (env, instructions) — filter out.
        let json: [String: Any] = [
            "id": "x",
            "type": "system",
            "content": "you are a helpful assistant"
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertTrue(out.isEmpty)
    }

    func test_unknownType_returnsEmpty() {
        let json: [String: Any] = [
            "id": "x",
            "type": "future-event-kind",
            "content": "something"
        ]
        let out = GeminiJSONLParser.decode(json: json, at: Date(), stableId: stableId)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - End-to-end multi-line fixture

    func test_endToEnd_userThenModel() {
        // Two-line conversation: a user turn + a model response. Each
        // returns the right bubble shape independently.
        let header: [String: Any] = [
            "sessionId": "abc",
            "kind": "main"
        ]
        let user: [String: Any] = [
            "id": "u1",
            "type": "user",
            "content": [["text": "hi"]]
        ]
        let model: [String: Any] = [
            "id": "m1",
            "type": "model",
            "content": "hello!"
        ]

        let now = Date()
        let h = GeminiJSONLParser.decode(json: header, at: now, stableId: stableId)
        let u = GeminiJSONLParser.decode(json: user, at: now, stableId: stableId)
        let m = GeminiJSONLParser.decode(json: model, at: now, stableId: stableId)

        XCTAssertEqual(h.count, 0)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].kind, .userText)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].kind, .assistantText)
    }
}
#endif
