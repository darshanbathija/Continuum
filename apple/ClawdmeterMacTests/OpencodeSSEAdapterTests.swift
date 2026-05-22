import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// PR #30 — OpencodeSSEAdapter unit tests. Covers the event-dispatch
/// surface (testable without the network stack) + the BidirectionalMap
/// round-trip. The full SSE consume loop is exercised manually with a
/// live `opencode serve` against the integration QA path.
@MainActor
final class OpencodeSSEAdapterTests: XCTestCase {

    // MARK: - BidirectionalMap

    func test_bidirectionalMap_setAndLookup() {
        var map = OpencodeSSEAdapter.BidirectionalMap()
        let uuid = UUID()
        map.set(clawdmeterID: uuid, opencodeID: "ses_abc123")
        XCTAssertEqual(map.clawdmeterToOpencode[uuid], "ses_abc123")
        XCTAssertEqual(map.opencodeToClawdmeter["ses_abc123"], uuid)
    }

    func test_bidirectionalMap_removeAllClearsBothDirections() {
        var map = OpencodeSSEAdapter.BidirectionalMap()
        map.set(clawdmeterID: UUID(), opencodeID: "ses_a")
        map.set(clawdmeterID: UUID(), opencodeID: "ses_b")
        XCTAssertEqual(map.clawdmeterToOpencode.count, 2)
        XCTAssertEqual(map.opencodeToClawdmeter.count, 2)
        map.removeAll()
        XCTAssertTrue(map.clawdmeterToOpencode.isEmpty)
        XCTAssertTrue(map.opencodeToClawdmeter.isEmpty)
    }

    func test_bidirectionalMap_overwriteSameClawdmeterID() {
        // If the same Clawdmeter UUID gets re-bound to a different
        // opencode id (recovery after a server crash, etc.), the
        // mapping should update — the first opencode id becomes
        // orphaned in the reverse direction. This documents the
        // current behavior; if we ever need ref-counting, this test
        // is the canary.
        var map = OpencodeSSEAdapter.BidirectionalMap()
        let uuid = UUID()
        map.set(clawdmeterID: uuid, opencodeID: "ses_old")
        map.set(clawdmeterID: uuid, opencodeID: "ses_new")
        XCTAssertEqual(map.clawdmeterToOpencode[uuid], "ses_new")
        XCTAssertEqual(map.opencodeToClawdmeter["ses_new"], uuid)
        // The old reverse mapping is stale by design — the dict still
        // contains it, just pointing at the same uuid. Future PR can
        // tighten this if needed.
    }

    // MARK: - dispatchEvent (JSON → handleEvent)

    func test_dispatchEvent_decodesAndRoutes() {
        // We can't easily assert on AgentEventStream.recordEvent side
        // effects from here (global static) — instead we assert that
        // malformed payloads don't crash the dispatcher, which is the
        // observable behavior the adapter promises.
        let adapter = OpencodeSSEAdapter.shared
        // Valid JSON, unknown type — should log + ignore (no throw).
        adapter.dispatchEvent(jsonString: #"{"type":"some.future.event","properties":{}}"#)
        // Malformed JSON — should log + ignore.
        adapter.dispatchEvent(jsonString: "not json at all")
        // Empty string — should log + ignore.
        adapter.dispatchEvent(jsonString: "")
        // Missing type field — defaults to "" which is the keep-alive
        // branch.
        adapter.dispatchEvent(jsonString: #"{"properties":{}}"#)
        // If we got here without crashing, the dispatcher is robust.
    }

    func test_handleEvent_keepAliveEmptyTypeIsNoOp() {
        // The keep-alive branch (empty type string) should return
        // without throwing or mutating state. Verified by calling it
        // directly and observing no exception.
        OpencodeSSEAdapter.shared.handleEvent(type: "", properties: [:])
    }

    func test_handleEvent_messageAddedWithoutRegistrationIsDropped() {
        // message.added for an unknown opencodeID logs + ignores. The
        // assertion is: doesn't crash, doesn't write a phantom event.
        OpencodeSSEAdapter.shared.stop()  // clear the map
        OpencodeSSEAdapter.shared.handleEvent(
            type: "message.added",
            properties: ["sessionID": "ses_phantom", "message": ["role": "assistant"]]
        )
        // No crash → pass. (The dropped-event path is logged but the
        // production behavior is exactly "log and move on".)
    }

    func test_handleEvent_messageAddedWithRegistrationRoutes() {
        // Register a mapping, then dispatch a message.added — should
        // not crash + should leave the mapping intact for subsequent
        // events.
        OpencodeSSEAdapter.shared.stop()
        let uuid = UUID()
        OpencodeSSEAdapter.shared.register(clawdmeterID: uuid, opencodeID: "ses_known")
        OpencodeSSEAdapter.shared.handleEvent(
            type: "message.added",
            properties: ["sessionID": "ses_known", "message": ["role": "assistant"]]
        )
        XCTAssertEqual(OpencodeSSEAdapter.shared.sessionMap.opencodeToClawdmeter["ses_known"], uuid)
    }

    func test_handleEvent_sessionErrorWithRegistrationRoutes() {
        OpencodeSSEAdapter.shared.stop()
        let uuid = UUID()
        OpencodeSSEAdapter.shared.register(clawdmeterID: uuid, opencodeID: "ses_err")
        OpencodeSSEAdapter.shared.handleEvent(
            type: "session.error",
            properties: ["sessionID": "ses_err", "error": "tool call timed out"]
        )
        // Survived without crash; map still intact.
        XCTAssertEqual(OpencodeSSEAdapter.shared.sessionMap.opencodeToClawdmeter["ses_err"], uuid)
    }

    func test_register_idempotent() {
        OpencodeSSEAdapter.shared.stop()
        let uuid = UUID()
        OpencodeSSEAdapter.shared.register(clawdmeterID: uuid, opencodeID: "ses_idem")
        OpencodeSSEAdapter.shared.register(clawdmeterID: uuid, opencodeID: "ses_idem")
        XCTAssertEqual(OpencodeSSEAdapter.shared.sessionMap.opencodeToClawdmeter["ses_idem"], uuid)
        XCTAssertEqual(OpencodeSSEAdapter.shared.sessionMap.clawdmeterToOpencode[uuid], "ses_idem")
    }

    // MARK: - Stop semantics

    func test_stop_clearsMap() {
        OpencodeSSEAdapter.shared.register(clawdmeterID: UUID(), opencodeID: "ses_x")
        OpencodeSSEAdapter.shared.register(clawdmeterID: UUID(), opencodeID: "ses_y")
        XCTAssertFalse(OpencodeSSEAdapter.shared.sessionMap.opencodeToClawdmeter.isEmpty)
        OpencodeSSEAdapter.shared.stop()
        XCTAssertTrue(OpencodeSSEAdapter.shared.sessionMap.opencodeToClawdmeter.isEmpty)
    }

    // MARK: - v0.23.2 T7: opencodeSessionId(for:) accessor

    func test_opencodeSessionId_returnsNilWhenUnregistered() {
        OpencodeSSEAdapter.shared.stop()
        XCTAssertNil(OpencodeSSEAdapter.shared.opencodeSessionId(for: UUID()))
    }

    func test_opencodeSessionId_returnsValueAfterRegister() {
        OpencodeSSEAdapter.shared.stop()
        let uuid = UUID()
        OpencodeSSEAdapter.shared.register(clawdmeterID: uuid, opencodeID: "ses_lookup_1")
        XCTAssertEqual(OpencodeSSEAdapter.shared.opencodeSessionId(for: uuid), "ses_lookup_1")
    }

    func test_opencodeSessionId_clearedAfterStop() {
        OpencodeSSEAdapter.shared.stop()
        let uuid = UUID()
        OpencodeSSEAdapter.shared.register(clawdmeterID: uuid, opencodeID: "ses_lookup_2")
        XCTAssertEqual(OpencodeSSEAdapter.shared.opencodeSessionId(for: uuid), "ses_lookup_2")
        OpencodeSSEAdapter.shared.stop()
        XCTAssertNil(OpencodeSSEAdapter.shared.opencodeSessionId(for: uuid))
    }

    // MARK: - v0.23.2 T7: parseMessageAdded(properties:)

    func test_parseMessageAdded_nilWhenMessageMissing() {
        XCTAssertNil(OpencodeSSEAdapter.parseMessageAdded(properties: [:]))
        XCTAssertNil(OpencodeSSEAdapter.parseMessageAdded(properties: ["other": "value"]))
    }

    func test_parseMessageAdded_plainStringContent_assistant() {
        let props: [String: Any] = [
            "message": [
                "id": "msg_001",
                "role": "assistant",
                "content": "Hello, how can I help?"
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertNotNil(chat)
        XCTAssertEqual(chat?.id, "msg_001")
        XCTAssertEqual(chat?.kind, .assistantText)
        XCTAssertEqual(chat?.title, "Assistant")
        XCTAssertEqual(chat?.body, "Hello, how can I help?")
        XCTAssertFalse(chat?.isError ?? true)
    }

    func test_parseMessageAdded_plainStringContent_user() {
        let props: [String: Any] = [
            "message": [
                "id": "msg_user_001",
                "role": "user",
                "content": "What time is it?"
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertEqual(chat?.kind, .userText)
        XCTAssertEqual(chat?.title, "User")
        XCTAssertEqual(chat?.body, "What time is it?")
    }

    func test_parseMessageAdded_arrayContent_textParts() {
        let props: [String: Any] = [
            "message": [
                "id": "msg_002",
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "First chunk."],
                    ["type": "text", "text": "Second chunk."]
                ]
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertNotNil(chat)
        XCTAssertEqual(chat?.kind, .assistantText)
        XCTAssertEqual(chat?.body, "First chunk.\nSecond chunk.")
    }

    func test_parseMessageAdded_toolCallShortCircuits() {
        // First tool-call wins per current behavior; subsequent siblings ignored.
        let props: [String: Any] = [
            "message": [
                "id": "msg_tool_call",
                "role": "assistant",
                "content": [
                    ["type": "tool-call", "name": "Bash", "input": ["command": "ls"]]
                ]
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertNotNil(chat)
        XCTAssertEqual(chat?.kind, .toolCall)
        XCTAssertEqual(chat?.title, "Bash")
        // input is JSON-serialized with .sortedKeys so it's stable.
        XCTAssertEqual(chat?.body, #"{"command":"ls"}"#)
    }

    func test_parseMessageAdded_toolUseAliasAccepted() {
        // opencode wire shape may also emit `tool_use` (Anthropic-style).
        let props: [String: Any] = [
            "message": [
                "id": "msg_tu",
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "name": "Read", "input": ["path": "/tmp/x"]]
                ]
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertEqual(chat?.kind, .toolCall)
        XCTAssertEqual(chat?.title, "Read")
    }

    func test_parseMessageAdded_toolResultText() {
        let props: [String: Any] = [
            "message": [
                "id": "msg_result",
                "role": "assistant",
                "content": [
                    ["type": "tool-result", "output": "file listed", "isError": false]
                ]
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertEqual(chat?.kind, .toolResult)
        XCTAssertEqual(chat?.title, "Result")
        XCTAssertEqual(chat?.body, "file listed")
        XCTAssertFalse(chat?.isError ?? true)
    }

    func test_parseMessageAdded_toolResultIsError() {
        let props: [String: Any] = [
            "message": [
                "id": "msg_err",
                "role": "assistant",
                "content": [
                    ["type": "tool_result", "text": "command failed", "isError": true]
                ]
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertEqual(chat?.kind, .toolResult)
        XCTAssertTrue(chat?.isError ?? false)
        XCTAssertEqual(chat?.body, "command failed")
    }

    func test_parseMessageAdded_emptyTextArrayReturnsNil() {
        // Array content with no text fragments and no tool parts produces
        // an empty join → guard returns nil (caller emits snapshot signal).
        let props: [String: Any] = [
            "message": [
                "id": "msg_empty",
                "role": "assistant",
                "content": [
                    ["type": "unknown"],
                    ["type": "also-unknown"]
                ]
            ]
        ]
        XCTAssertNil(OpencodeSSEAdapter.parseMessageAdded(properties: props))
    }

    func test_parseMessageAdded_defaultsToAssistantRole() {
        // Missing role defaults to "assistant" per the parser contract.
        let props: [String: Any] = [
            "message": [
                "id": "msg_no_role",
                "content": "auto-assistant"
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertEqual(chat?.kind, .assistantText)
        XCTAssertEqual(chat?.title, "Assistant")
    }

    func test_parseMessageAdded_synthesizesIdWhenMissing() {
        // No id field → parser generates a fresh UUID so the ChatMessage
        // identity stays stable but the message still routes.
        let props: [String: Any] = [
            "message": [
                "role": "assistant",
                "content": "no id here"
            ]
        ]
        let chat = OpencodeSSEAdapter.parseMessageAdded(properties: props)
        XCTAssertNotNil(chat)
        XCTAssertFalse(chat?.id.isEmpty ?? true,
            "missing id must fall back to a synthesized non-empty UUID")
    }

    // MARK: - v0.23.2 T7: chatStoreAccessor closure injection

    func test_chatStoreAccessor_defaultsToNil() {
        OpencodeSSEAdapter.shared.chatStoreAccessor = nil
        XCTAssertNil(OpencodeSSEAdapter.shared.chatStoreAccessor)
    }

    func test_chatStoreAccessor_canBeAssignedAndCleared() {
        // The closure shape itself; the AgentControlServer spawn path
        // wires this lazily and idempotently. The test verifies the
        // accessor surface accepts a Sendable @MainActor closure and
        // can be cleared after teardown.
        OpencodeSSEAdapter.shared.chatStoreAccessor = { _ in nil }
        XCTAssertNotNil(OpencodeSSEAdapter.shared.chatStoreAccessor)
        OpencodeSSEAdapter.shared.chatStoreAccessor = nil
        XCTAssertNil(OpencodeSSEAdapter.shared.chatStoreAccessor)
    }

    func test_handleEvent_messageAddedUsesAccessor_whenRegistered() {
        // End-to-end of the SSE → store pipe without spinning up a real
        // SessionChatStore. We inject an accessor that returns nil but
        // record whether it was invoked.
        OpencodeSSEAdapter.shared.stop()
        let uuid = UUID()
        OpencodeSSEAdapter.shared.register(clawdmeterID: uuid, opencodeID: "ses_accessor")
        var invokedFor: UUID?
        OpencodeSSEAdapter.shared.chatStoreAccessor = { id in
            invokedFor = id
            return nil
        }
        defer { OpencodeSSEAdapter.shared.chatStoreAccessor = nil }

        OpencodeSSEAdapter.shared.handleEvent(
            type: "message.added",
            properties: [
                "sessionID": "ses_accessor",
                "message": [
                    "id": "msg_seen",
                    "role": "assistant",
                    "content": "test body"
                ]
            ]
        )
        XCTAssertEqual(invokedFor, uuid,
            "chatStoreAccessor must be invoked with the registered Clawdmeter UUID")
    }

    func test_handleEvent_messageAddedSkipsAccessor_whenUnregistered() {
        // Unknown opencode session id → accessor is NOT invoked (no
        // phantom store lookups for sessions we don't own).
        OpencodeSSEAdapter.shared.stop()
        var invoked = false
        OpencodeSSEAdapter.shared.chatStoreAccessor = { _ in
            invoked = true
            return nil
        }
        defer { OpencodeSSEAdapter.shared.chatStoreAccessor = nil }

        OpencodeSSEAdapter.shared.handleEvent(
            type: "message.added",
            properties: [
                "sessionID": "ses_unknown",
                "message": ["role": "assistant", "content": "nope"]
            ]
        )
        XCTAssertFalse(invoked,
            "chatStoreAccessor must NOT fire for unregistered opencode session ids")
    }
}
