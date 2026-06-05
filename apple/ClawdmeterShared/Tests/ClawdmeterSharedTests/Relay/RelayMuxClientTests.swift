import XCTest
@testable import ClawdmeterShared

/// Track B — B0.3: the iOS-side multiplex client (subscribe/demux/input/resub).
@MainActor
final class RelayMuxClientTests: XCTestCase {

    /// Deterministic id generators + an outbound capture.
    private func makeClient(maxRaw: Int = RelayMux.maxRawPayloadBytes)
        -> (client: RelayMuxClient, sent: () -> [RelayMuxFrame]) {
        let box = SentBox()
        var opSeq = 0
        var msgSeq = 0
        let client = RelayMuxClient(
            send: { box.frames.append($0) },
            makeOpId: { opSeq += 1; return "op-\(opSeq)" },
            makeMessageId: { msgSeq += 1; return "m-\(msgSeq)" },
            maxRawPayloadBytes: maxRaw
        )
        return (client, { box.frames })
    }
    private final class SentBox { var frames: [RelayMuxFrame] = [] }

    private func handlers(into received: ReceivedBox) -> RelayMuxClient.StreamHandlers {
        RelayMuxClient.StreamHandlers(
            onFrame: { received.frames.append($0) },
            onEnd: { received.ended = true },
            onError: { received.errors.append($0) }
        )
    }
    private final class ReceivedBox { var frames: [Data] = []; var ended = false; var errors: [String] = [] }

    func test_subscribe_sendsSubscribeFrameAndTracksStream() async {
        let (client, sent) = makeClient()
        let rx = ReceivedBox()
        let opId = await client.subscribe(.init(op: "chat-subscribe", sessionId: "s"), handlers: handlers(into: rx))
        XCTAssertEqual(opId, "op-1")
        XCTAssertEqual(client.activeCount, 1)
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent()[0].kind, .subscribe)
        XCTAssertEqual(sent()[0].opId, "op-1")
        let spec = RelaySubscribeSpec.decode(sent()[0].payload ?? Data())
        XCTAssertEqual(spec?.op, "chat-subscribe")
    }

    func test_inboundSubFrame_routedToHandler() async {
        let (client, _) = makeClient()
        let rx = ReceivedBox()
        let opId = await client.subscribe(.init(op: "events"), handlers: handlers(into: rx))
        client.handleInbound(RelayMuxFrame(opId: opId, kind: .subFrame, payload: Data("hello".utf8)))
        XCTAssertEqual(rx.frames.map { String(decoding: $0, as: UTF8.self) }, ["hello"])
    }

    func test_inboundChunkedSubFrame_reassembledThenDelivered() async {
        let (client, _) = makeClient()
        let rx = ReceivedBox()
        let opId = await client.subscribe(.init(op: "chat-subscribe", sessionId: "s"), handlers: handlers(into: rx))
        // Simulate the Mac chunking a big snapshot for this opId.
        let big = Data((0..<3000).map { UInt8($0 % 251) })
        let chunks = RelayChunker.split(opId: opId, kind: .subFrame, payload: big, messageId: "big1", maxRawPayloadBytes: 1024)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks.dropLast() { client.handleInbound(c) }
        XCTAssertEqual(rx.frames.count, 0, "no delivery until the last chunk")
        client.handleInbound(chunks.last!)
        XCTAssertEqual(rx.frames.count, 1)
        XCTAssertEqual(rx.frames.first, big)
    }

    func test_unknownOpId_ignored() async {
        let (client, _) = makeClient()
        let rx = ReceivedBox()
        _ = await client.subscribe(.init(op: "events"), handlers: handlers(into: rx))
        client.handleInbound(RelayMuxFrame(opId: "op-does-not-exist", kind: .subFrame, payload: Data("x".utf8)))
        XCTAssertEqual(rx.frames.count, 0)
    }

    func test_subEnd_firesOnEndAndDropsStream() async {
        let (client, _) = makeClient()
        let rx = ReceivedBox()
        let opId = await client.subscribe(.init(op: "terminal", sessionId: "s"), handlers: handlers(into: rx))
        client.handleInbound(RelayMuxFrame(opId: opId, kind: .subEnd))
        XCTAssertTrue(rx.ended)
        XCTAssertEqual(client.activeCount, 0)
        // A late frame after end is ignored (stream dropped).
        client.handleInbound(RelayMuxFrame(opId: opId, kind: .subFrame, payload: Data("late".utf8)))
        XCTAssertEqual(rx.frames.count, 0)
    }

    func test_error_firesOnErrorWithMessage() async {
        let (client, _) = makeClient()
        let rx = ReceivedBox()
        let opId = await client.subscribe(.init(op: "events"), handlers: handlers(into: rx))
        let payload = try? JSONSerialization.data(withJSONObject: ["error": "op not allowed: bad"])
        client.handleInbound(RelayMuxFrame(opId: opId, kind: .error, payload: payload))
        XCTAssertEqual(rx.errors, ["op not allowed: bad"])
        XCTAssertEqual(client.activeCount, 0)
    }

    func test_sendInput_chunksLargeTerminalInput() async {
        let (client, sent) = makeClient(maxRaw: 1024)
        let rx = ReceivedBox()
        let opId = await client.subscribe(.init(op: "terminal", sessionId: "s"), handlers: handlers(into: rx))
        let big = Data(repeating: 0x61, count: 2500)   // > 2 chunks
        await client.sendInput(opId, big)
        let inputFrames = sent().filter { $0.kind == .subFrame && $0.opId == opId }
        XCTAssertEqual(inputFrames.count, 3, "2500B / 1024 → 3 chunks")
        XCTAssertTrue(inputFrames.allSatisfy { $0.chunk != nil })
    }

    func test_sendInput_unknownStream_noop() async {
        let (client, sent) = makeClient()
        await client.sendInput("nope", Data("x".utf8))
        XCTAssertTrue(sent().isEmpty)
    }

    func test_resubscribeAll_reemitsEverySubscribe() async {
        let (client, sent) = makeClient()
        let rx = ReceivedBox()
        _ = await client.subscribe(.init(op: "chat-subscribe", sessionId: "a"), handlers: handlers(into: rx))
        _ = await client.subscribe(.init(op: "terminal", sessionId: "b"), handlers: handlers(into: rx))
        let before = sent().count
        await client.resubscribeAll()
        let resubs = sent().suffix(from: before)
        XCTAssertEqual(resubs.filter { $0.kind == .subscribe }.count, 2, "reconnect must re-subscribe every live stream")
        XCTAssertEqual(client.activeCount, 2)
    }

    func test_unsubscribe_sendsFrameAndDrops() async {
        let (client, sent) = makeClient()
        let rx = ReceivedBox()
        let opId = await client.subscribe(.init(op: "events"), handlers: handlers(into: rx))
        await client.unsubscribe(opId)
        XCTAssertTrue(sent().contains { $0.kind == .unsubscribe && $0.opId == opId })
        XCTAssertEqual(client.activeCount, 0)
        await client.unsubscribe(opId)   // idempotent
    }
}
