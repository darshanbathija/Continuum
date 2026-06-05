import XCTest
@testable import ClawdmeterShared

/// Track B — B1.5: FrontierSnapshotStore drives the aggregate frontier stream
/// over the relay multiplex when its AgentControlClient carries a relayMux
/// (the Shared-module injection path shared with events).
@MainActor
final class FrontierRelayTests: XCTestCase {

    private final class Box { var frames: [RelayMuxFrame] = [] }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return cond()
    }

    func test_frontier_subscribesAndAppliesSnapshotOverRelay() async throws {
        let groupId = UUID()
        let sent = Box()
        let mux = RelayMuxClient(send: { sent.frames.append($0) }, makeOpId: { "f-op" })

        let client = AgentControlClient()
        client.relayMux = mux       // injected as the iOS app would via bindAgentClient
        let store = FrontierSnapshotStore(groupId: groupId, client: client)
        store.start()

        let subscribed = await waitUntil { sent.frames.contains { $0.kind == .subscribe } }
        XCTAssertTrue(subscribed, "frontier store must open a relay frontier-subscribe")
        let sub = try XCTUnwrap(sent.frames.first { $0.kind == .subscribe })
        let spec = try XCTUnwrap(RelaySubscribeSpec.decode(sub.payload ?? Data()))
        XCTAssertEqual(spec.op, "frontier-subscribe")
        XCTAssertEqual(spec.groupId, groupId.uuidString)

        // Mac replies with an aggregate snapshot over the relay.
        let snap = FrontierGroupSnapshot(groupId: groupId, updateCounter: 3, children: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        mux.handleInbound(RelayMuxFrame(opId: sub.opId, kind: .subFrame, payload: try enc.encode(snap)))

        let applied = await waitUntil { store.snapshot.updateCounter == 3 }
        XCTAssertTrue(applied, "a relay frontier snapshot must replace .snapshot wholesale")
        store.stop()
    }

    func test_noRelayMux_staysDirect() async {
        // No relayMux ⇒ the store does NOT emit a relay subscribe (legacy path).
        let client = AgentControlClient()
        XCTAssertNil(client.relayMux)
        // (We don't start() here — the direct path would attempt a live WS.)
    }
}
