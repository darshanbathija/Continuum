import XCTest
import CryptoKit
import ClawdmeterShared
@testable import Clawdmeter

/// Track B — B1.1: IOSRelayClient routes `op == "mux"` frames to the shared
/// RelayMuxClient (not `lastInbound`), and resets the replay-seq epoch on every
/// connection so resubscribes survive a reconnect (CB-P0b). Reuses FakeTransport
/// + RelayLifecycleFixture from IOSRelayClientLifecycleTests.
@MainActor
final class IOSRelayMuxDispatchTests: XCTestCase {

    private final class ReceivedBox { var frames: [Data] = [] }

    /// Seal a RelayPlaintext into the (header text, body data) pair the Mac
    /// would put on the wire, using the fixture's symmetric key.
    private func sealed(seq: UInt64, op: String, data: Data) throws -> (String, Data) {
        let keyData = Data([
            0x14, 0x8e, 0x0a, 0x09, 0xad, 0x73, 0x2f, 0x51,
            0x16, 0x9a, 0xa3, 0x62, 0xcf, 0x68, 0xdb, 0x94,
            0xe4, 0x22, 0x6a, 0xb1, 0x0b, 0x3c, 0x50, 0x39,
            0xd5, 0xf8, 0xad, 0x58, 0x8e, 0x80, 0x4f, 0xe8,
        ])
        let key = SymmetricKey(data: keyData)
        let pt = try RelayPlaintext(seq: seq, op: op, data: data).encodeCanonicalJSON()
        let nonce = RelayFrameCodec.randomNonce()
        let body = try nonce + RelayFrameCodec.seal(plaintext: pt, key: key, nonce: nonce)
        let header = String(decoding: RelayEnvelopeHeader(from: .mac, type: .ciphertext).encodeCanonicalJSON(), as: UTF8.self)
        return (header, body)
    }

    private func muxFrameData(opId: String, payload: Data) throws -> Data {
        try RelayMuxFrame(opId: opId, kind: .subFrame, payload: payload).encoded()
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await cond()
    }

    func test_muxFrame_routesToMuxClient_notLastInbound() async throws {
        let rx = ReceivedBox()
        let mux = RelayMuxClient(send: { _ in }, makeOpId: { "op-1" })
        _ = await mux.subscribe(.init(op: "events"),
                                handlers: .init(onFrame: { rx.frames.append($0) }))

        let transport = FakeTransport()
        let client = IOSRelayClient(
            config: RelayLifecycleFixture.defaultConfig(),
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: FakeLifecycleObserver(),
            transportFactory: { _, _ in transport }
        )
        client.muxClient = mux
        client.start()
        try await Task.sleep(nanoseconds: 120_000_000)   // let handshake send

        let (hdr, body) = try sealed(seq: 1, op: RelayMux.op, data: muxFrameData(opId: "op-1", payload: Data("hi".utf8)))
        await transport.enqueue(.string(hdr))
        await transport.enqueue(.data(body))

        let got = await waitUntil { rx.frames.map { String(decoding: $0, as: UTF8.self) } == ["hi"] }
        XCTAssertTrue(got, "mux subFrame must reach the mux client's stream handler")
        XCTAssertNil(client.lastInbound, "a mux frame must NOT land in lastInbound (legacy observers)")
        client.stop()
    }

    /// CB-P0b: after a reconnect the Mac's outbound seq restarts at 1; iOS must
    /// reset `inboundHighSeq` to 0 or the resubscribe responses are dropped as
    /// replays. Proven black-box: a high-seq frame on connection 1, then a
    /// LOW-seq mux frame on connection 2 that is only delivered if the epoch reset.
    func test_inboundSeqResetsOnReconnect_CBP0b() async throws {
        let rx = ReceivedBox()
        let mux = RelayMuxClient(send: { _ in }, makeOpId: { "op-1" })
        _ = await mux.subscribe(.init(op: "events"),
                                handlers: .init(onFrame: { rx.frames.append($0) }))

        let t1 = FakeTransport()
        let t2 = FakeTransport()
        let transports = TransportSeq(t1, t2)
        let client = IOSRelayClient(
            config: RelayLifecycleFixture.defaultConfig(),
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: FakeLifecycleObserver(),
            transportFactory: { _, _ in await transports.next() }
        )
        client.muxClient = mux
        client.start()
        try await Task.sleep(nanoseconds: 120_000_000)

        // Connection 1: a non-mux frame at seq=5 → bumps inboundHighSeq to 5.
        let (h5, b5) = try sealed(seq: 5, op: "noop", data: Data("{}".utf8))
        await t1.enqueue(.string(h5)); await t1.enqueue(.data(b5))
        let bumped = await waitUntil { client.lastInbound?.seq == 5 }
        XCTAssertTrue(bumped, "seq=5 must be accepted on connection 1")

        // Force a reconnect: error connection 1 → client backs off + opens t2.
        await t1.enqueueError(URLError(.networkConnectionLost))

        // Connection 2: a LOW seq=1 mux frame. Only delivered if inboundHighSeq
        // was reset to 0 on the new connection (else 1 <= 5 → dropped).
        let (h1, b1) = try sealed(seq: 1, op: RelayMux.op, data: muxFrameData(opId: "op-1", payload: Data("after-reconnect".utf8)))
        // Wait until t2 is the live transport (handshake observed), then feed.
        let reconnected = await waitUntil(6) { await t2.sentTextSnapshot.isEmpty == false }
        XCTAssertTrue(reconnected, "client must reconnect onto t2")
        await t2.enqueue(.string(h1)); await t2.enqueue(.data(b1))

        let delivered = await waitUntil(4) {
            rx.frames.contains { String(decoding: $0, as: UTF8.self) == "after-reconnect" }
        }
        XCTAssertTrue(delivered, "low-seq frame after reconnect proves inboundHighSeq reset (CB-P0b)")
        client.stop()
    }

    /// Hands out transports in order across reconnects.
    private actor TransportSeq {
        private var queue: [FakeTransport]
        init(_ ts: FakeTransport...) { queue = ts }
        func next() -> FakeTransport { queue.isEmpty ? FakeTransport() : queue.removeFirst() }
    }
}
