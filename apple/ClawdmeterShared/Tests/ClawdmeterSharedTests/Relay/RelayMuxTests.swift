import XCTest
@testable import ClawdmeterShared

/// Track B — B0.1: the multiplex envelope + chunker/reassembler.
final class RelayMuxTests: XCTestCase {

    // MARK: - Envelope

    func testFrameRoundTrips() throws {
        let frame = RelayMuxFrame(
            opId: "op-1", kind: .subscribe,
            payload: Data(#"{"op":"chat-subscribe","sessionId":"abc"}"#.utf8)
        )
        let bytes = try frame.encoded()
        let back = try XCTUnwrap(RelayMuxFrame.decode(bytes))
        XCTAssertEqual(back, frame)
    }

    func testOpIdIsMandatory() {
        // A frame missing opId is a protocol violation → decode returns nil.
        let noOpId = Data(#"{"kind":"request","payload":null}"#.utf8)
        XCTAssertNil(RelayMuxFrame.decode(noOpId), "decode must reject a frame with no opId")
    }

    func testUnknownKindRejected() {
        let bad = Data(#"{"opId":"x","kind":"bogus"}"#.utf8)
        XCTAssertNil(RelayMuxFrame.decode(bad))
    }

    func testEmptyBytesDecodeNil() {
        XCTAssertNil(RelayMuxFrame.decode(Data()))
    }

    // MARK: - Chunking

    func testSmallPayloadIsSingleFrame() {
        let payload = Data(repeating: 0x41, count: 100)
        let frames = RelayChunker.split(opId: "op", kind: .subFrame, payload: payload, messageId: "m1")
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(frames[0].chunk, "a sub-cap payload must not be chunked")
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testLargePayloadSplitsAndReassembles() throws {
        // 3.5 chunks worth → 4 frames.
        let max = 1024
        let payload = Data((0..<(max * 3 + 500)).map { UInt8($0 % 251) })
        let frames = RelayChunker.split(
            opId: "op", kind: .subFrame, payload: payload, messageId: "m1", maxRawPayloadBytes: max
        )
        XCTAssertEqual(frames.count, 4)
        for (i, f) in frames.enumerated() {
            let c = try XCTUnwrap(f.chunk)
            XCTAssertEqual(c.index, i)
            XCTAssertEqual(c.count, 4)
            XCTAssertEqual(c.messageId, "m1")
        }
        // Reassemble — even out of order — yields the original bytes exactly once.
        let r = RelayChunkReassembler()
        var result: Data?
        for f in [frames[2], frames[0], frames[3], frames[1]] {
            if let done = try r.accept(f) { result = done }
        }
        XCTAssertEqual(result, payload)
        XCTAssertEqual(r.inFlightCount, 0, "completed message must be evicted")
    }

    func testReassemblerRejectsDuplicateChunk() throws {
        let frames = RelayChunker.split(
            opId: "op", kind: .subFrame, payload: Data(repeating: 7, count: 2048),
            messageId: "m", maxRawPayloadBytes: 1024
        )
        let r = RelayChunkReassembler()
        _ = try r.accept(frames[0])
        XCTAssertThrowsError(try r.accept(frames[0])) { err in
            XCTAssertEqual(err as? RelayChunkReassembler.RejectReason, .duplicate)
        }
    }

    func testReassemblerEnforcesByteCap() throws {
        let frames = RelayChunker.split(
            opId: "op", kind: .subFrame, payload: Data(repeating: 7, count: 4096),
            messageId: "m", maxRawPayloadBytes: 1024
        )
        let r = RelayChunkReassembler(maxBufferedBytes: 1500)   // < 2 chunks
        _ = try r.accept(frames[0])
        XCTAssertThrowsError(try r.accept(frames[1])) { err in
            XCTAssertEqual(err as? RelayChunkReassembler.RejectReason, .overCap)
        }
        XCTAssertEqual(r.inFlightCount, 0, "a capped message must be dropped, not retained")
    }

    func testReassemblerTimesOutStalledMessage() throws {
        let frames = RelayChunker.split(
            opId: "op", kind: .subFrame, payload: Data(repeating: 7, count: 2048),
            messageId: "m", maxRawPayloadBytes: 1024
        )
        let r = RelayChunkReassembler(timeout: 10)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = try r.accept(frames[0], now: t0)
        XCTAssertEqual(r.inFlightCount, 1)
        // 11s later the stalled message is pruned; the late chunk starts fresh.
        _ = try r.accept(frames[1], now: t0.addingTimeInterval(11))
        XCTAssertEqual(r.inFlightCount, 1, "the original stalled message must have been pruned")
    }

    func testBadIndexRejected() {
        let r = RelayChunkReassembler()
        let bad = RelayMuxFrame(
            opId: "op", kind: .subFrame,
            chunk: RelayChunkHeader(messageId: "m", index: 5, count: 2),
            payload: Data([1])
        )
        XCTAssertThrowsError(try r.accept(bad)) { err in
            XCTAssertEqual(err as? RelayChunkReassembler.RejectReason, .badIndex)
        }
    }

    func testReservedOpConstant() {
        XCTAssertEqual(RelayMux.op, "mux")
    }
}
