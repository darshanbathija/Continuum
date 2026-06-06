import XCTest
@testable import Clawdmeter
@testable import ClawdmeterShared

/// Track B — B0.2: the loopback-WS bridge. Drives the bridge with a fake
/// loopback connection so the pump / full-duplex / coalescing / teardown paths
/// are deterministic — no real WS, no daemon.
@MainActor
final class RelaySubscriptionBridgeTests: XCTestCase {

    /// Fake loopback WS: `feed` pushes a daemon→iOS frame; `sent` records
    /// iOS→daemon writes; `close` ends the receive loop.
    final class FakeConn: RelaySubscriptionBridge.Conn {
        var sent: [Data] = []
        private(set) var closed = false
        private var inbox: [Data] = []
        private var waiters: [CheckedContinuation<Data?, Never>] = []

        func feed(_ d: Data) {
            if !waiters.isEmpty { waiters.removeFirst().resume(returning: d) }
            else { inbox.append(d) }
        }
        func send(_ data: Data) async throws { sent.append(data) }
        func receive() async throws -> Data? {
            if closed { return nil }
            if !inbox.isEmpty { return inbox.removeFirst() }
            return await withCheckedContinuation { waiters.append($0) }
        }
        func close() {
            closed = true
            let w = waiters; waiters.removeAll()
            for c in w { c.resume(returning: nil) }
        }
    }

    /// Captures outbound mux frames + hands back the FakeConn the factory made.
    private func makeBridge(coalesceWindow: TimeInterval = 0.05)
        -> (bridge: RelaySubscriptionBridge, outbound: () -> [RelayMuxFrame],
            lastConn: () -> FakeConn?, lastEnvelope: () -> Data?) {
        let outboxBox = OutboxBox()
        let connBox = ConnBox()
        let bridge = RelaySubscriptionBridge(
            wsURL: { URL(string: "ws://127.0.0.1:21732/ws") },
            loopbackToken: { "LOOPBACK-TOK" },
            connFactory: { _, envelope in
                let c = FakeConn()
                connBox.conn = c
                connBox.envelope = envelope
                return c
            },
            sendOutbound: { frame in outboxBox.frames.append(frame) },
            coalesceWindow: coalesceWindow
        )
        return (bridge, { outboxBox.frames }, { connBox.conn }, { connBox.envelope })
    }

    private final class OutboxBox { var frames: [RelayMuxFrame] = [] }
    private final class ConnBox { var conn: FakeConn?; var envelope: Data? }

    private func subscribeFrame(opId: String, op: String, sessionId: String? = nil) throws -> RelayMuxFrame {
        let spec = RelaySubscribeSpec(op: op, sessionId: sessionId)
        return RelayMuxFrame(opId: opId, kind: .subscribe, payload: try spec.encoded())
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    // MARK: - ordered streams (terminal/events): every frame forwarded in order

    func test_orderedStream_forwardsFramesInOrder() async throws {
        let (bridge, outbound, lastConn, _) = makeBridge()
        try await bridge.handle(subscribeFrame(opId: "t1", op: "terminal", sessionId: "s"))
        let conn = try XCTUnwrap(lastConn())
        conn.feed(Data("a".utf8)); conn.feed(Data("b".utf8)); conn.feed(Data("c".utf8))
        let ok = await waitUntil { outbound().filter { $0.kind == .subFrame }.count == 3 }
        XCTAssertTrue(ok, "all 3 ordered frames must forward")
        let payloads = outbound().filter { $0.kind == .subFrame }.map { String(decoding: $0.payload ?? Data(), as: UTF8.self) }
        XCTAssertEqual(payloads, ["a", "b", "c"], "ordered, no drop")
        XCTAssertTrue(outbound().allSatisfy { $0.opId == "t1" })
        bridge.shutdownAll()
    }

    // MARK: - server-built envelope (CB-P1e)

    func test_subscribe_buildsServerSideEnvelopeWithLoopbackToken() async throws {
        let (bridge, _, _, lastEnvelope) = makeBridge()
        try await bridge.handle(subscribeFrame(opId: "c1", op: "chat-subscribe", sessionId: "abc"))
        let env = try XCTUnwrap(lastEnvelope())
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: env) as? [String: Any])
        XCTAssertEqual(dict["token"] as? String, "LOOPBACK-TOK", "loopback envelope must carry the daemon token")
        XCTAssertEqual(dict["op"] as? String, "chat-subscribe")
        XCTAssertEqual(dict["sessionId"] as? String, "abc")
        bridge.shutdownAll()
    }

    func test_disallowedOp_emitsErrorAndOpensNoConn() async throws {
        let (bridge, outbound, lastConn, _) = makeBridge()
        try await bridge.handle(subscribeFrame(opId: "x1", op: "compose-draft"))
        XCTAssertNil(lastConn(), "a non-allowlisted op must not open a loopback WS")
        XCTAssertEqual(outbound().filter { $0.kind == .error }.count, 1)
        XCTAssertEqual(bridge.liveCount, 0)
    }

    // MARK: - full-duplex (CB-P1a): iOS → daemon input

    func test_fullDuplex_forwardsInputToLoopback() async throws {
        let (bridge, _, lastConn, _) = makeBridge()
        try await bridge.handle(subscribeFrame(opId: "t1", op: "terminal", sessionId: "s"))
        let conn = try XCTUnwrap(lastConn())
        await bridge.handle(RelayMuxFrame(opId: "t1", kind: .subFrame, payload: Data("ls\r".utf8)))
        let ok = await waitUntil { conn.sent.count == 1 }
        XCTAssertTrue(ok, "terminal input must pump iOS→daemon")
        XCTAssertEqual(conn.sent.first, Data("ls\r".utf8))
        bridge.shutdownAll()
    }

    // MARK: - teardown

    func test_unsubscribe_closesConnAndDropsStream() async throws {
        let (bridge, _, lastConn, _) = makeBridge()
        try await bridge.handle(subscribeFrame(opId: "t1", op: "terminal", sessionId: "s"))
        let conn = try XCTUnwrap(lastConn())
        await bridge.handle(RelayMuxFrame(opId: "t1", kind: .unsubscribe))
        XCTAssertTrue(conn.closed)
        XCTAssertEqual(bridge.liveCount, 0)
    }

    func test_loopbackClose_emitsSubEnd() async throws {
        let (bridge, outbound, lastConn, _) = makeBridge()
        try await bridge.handle(subscribeFrame(opId: "e1", op: "events"))
        let conn = try XCTUnwrap(lastConn())
        conn.close()   // daemon WS dropped
        let ok = await waitUntil { outbound().contains { $0.kind == .subEnd && $0.opId == "e1" } }
        XCTAssertTrue(ok, "a closed loopback WS must surface a subEnd to iOS")
        XCTAssertEqual(bridge.liveCount, 0)
    }

    // Review P0#2: a repeat subscribe for a LIVE opId is the reconnect
    // resubscribe — it must RE-OPEN (close the stale loopback WS, open a fresh
    // one) so the snapshot replays. (Previously it was ignored → the stream
    // stayed dead after an iOS reconnect.)
    func test_duplicateSubscribe_reopensStream() async throws {
        let (bridge, _, lastConn, _) = makeBridge()
        try await bridge.handle(subscribeFrame(opId: "t1", op: "terminal", sessionId: "s"))
        let first = try XCTUnwrap(lastConn())
        try await bridge.handle(subscribeFrame(opId: "t1", op: "terminal", sessionId: "s"))
        let second = try XCTUnwrap(lastConn())
        XCTAssertFalse(first === second, "resubscribe must open a FRESH loopback WS")
        XCTAssertTrue(first.closed, "the stale loopback WS must be torn down on re-open")
        XCTAssertEqual(bridge.liveCount, 1, "still exactly one live stream for the opId")
        bridge.shutdownAll()
    }

    func test_reopenLiveSubscriptions_reopensActiveStreamsOnMacReconnect() async throws {
        let (bridge, _, lastConn, _) = makeBridge()
        try await bridge.handle(subscribeFrame(opId: "t1", op: "terminal", sessionId: "s"))
        let first = try XCTUnwrap(lastConn())

        await bridge.reopenLiveSubscriptions()

        let second = try XCTUnwrap(lastConn())
        XCTAssertFalse(first === second, "Mac reconnect repair must open a fresh loopback WS")
        XCTAssertTrue(first.closed, "the stale loopback WS must close during reconnect repair")
        XCTAssertEqual(bridge.liveCount, 1, "reconnect repair must keep one live stream per opId")
        bridge.shutdownAll()
    }

    // MARK: - snapshot coalescing (CB-P1d): LWW keeps the latest

    func test_snapshotStream_coalescesToLatest() async throws {
        let (bridge, outbound, lastConn, _) = makeBridge(coalesceWindow: 0.15)
        try await bridge.handle(subscribeFrame(opId: "c1", op: "chat-subscribe", sessionId: "s"))
        let conn = try XCTUnwrap(lastConn())
        // Three snapshots within the debounce window → only the LAST ships.
        conn.feed(Data("snap1".utf8)); conn.feed(Data("snap2".utf8)); conn.feed(Data("snap3".utf8))
        let got = await waitUntil { outbound().contains { $0.kind == .subFrame } }
        XCTAssertTrue(got)
        // Give the window a beat to ensure no further frames are pending.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let subFrames = outbound().filter { $0.kind == .subFrame }
        XCTAssertEqual(subFrames.count, 1, "rapid snapshots must coalesce to one")
        XCTAssertEqual(String(decoding: subFrames[0].payload ?? Data(), as: UTF8.self), "snap3", "LWW keeps the newest")
        bridge.shutdownAll()
    }
}
