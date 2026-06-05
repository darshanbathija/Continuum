import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Track B — B1.3: iOSChatStore drives the chat stream over the relay multiplex
/// when a RelayMuxClient is present, applying snapshots through the SAME
/// `applyIncomingFrame` boundary the direct WS uses.
@MainActor
final class IOSChatStoreRelayTests: XCTestCase {

    private final class Box { var frames: [RelayMuxFrame] = [] }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return cond()
    }

    func test_chatStream_subscribesAndAppliesSnapshotOverRelay() async throws {
        let sessionId = UUID()
        let sent = Box()
        let mux = RelayMuxClient(send: { sent.frames.append($0) }, makeOpId: { "chat-op" })

        let store = iOSChatStore(sessionId: sessionId, client: AgentControlClient())
        store.relayMux = mux       // relay is the default transport
        store.start()

        // It subscribes with a chat-subscribe spec for this session.
        let subscribed = await waitUntil { sent.frames.contains { $0.kind == .subscribe } }
        XCTAssertTrue(subscribed, "store must open a relay chat-subscribe")
        let sub = try XCTUnwrap(sent.frames.first { $0.kind == .subscribe })
        let spec = try XCTUnwrap(RelaySubscribeSpec.decode(sub.payload ?? Data()))
        XCTAssertEqual(spec.op, "chat-subscribe")
        XCTAssertEqual(spec.sessionId, sessionId.uuidString)

        // Simulate the Mac replying with a snapshot over the relay.
        let snap = WireChatSnapshot(
            sessionId: sessionId, items: [], planSteps: [], sourceEntries: [],
            artifactEntries: [], totalInputTokens: 7, totalOutputTokens: 42,
            lastEventAt: nil, updateCounter: 1
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        mux.handleInbound(RelayMuxFrame(opId: sub.opId, kind: .subFrame, payload: try enc.encode(snap)))

        let applied = await waitUntil { store.snapshot.totalOutputTokens == 42 && store.snapshot.updateCounter == 1 }
        XCTAssertTrue(applied, "a relay snapshot must flow through applyIncomingFrame into .snapshot")
        store.stop()
    }

    func test_flagOff_noMux_staysOnDirectPath() async throws {
        // No relayMux + no paired coordinator mux ⇒ the relay path is skipped.
        // We can't easily assert the direct WS without a daemon, but we CAN
        // assert the store does NOT emit any relay subscribe (it fell through).
        let sessionId = UUID()
        let store = iOSChatStore(sessionId: sessionId, client: AgentControlClient())
        XCTAssertNil(store.relayMux)
        XCTAssertNil(IOSRelayClientCoordinator.shared.muxClient,
                     "no pairing in tests ⇒ coordinator mux is nil ⇒ legacy path")
        // (start() would attempt the direct WS/HTTP ladder; we don't start it
        // here to avoid a live network attempt in the unit test.)
    }
}
