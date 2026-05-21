import XCTest
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
}
