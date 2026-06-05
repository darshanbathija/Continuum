import XCTest
@testable import ClawdmeterShared

/// Track B — B1.7: the request/response correlator over the relay multiplex.
@MainActor
final class RelayMuxRequestClientTests: XCTestCase {

    private final class SentBox { var frames: [RelayMuxFrame] = [] }

    private func makeClient(timeout: TimeInterval = 5, maxRaw: Int = RelayMux.maxRawPayloadBytes)
        -> (client: RelayMuxRequestClient, sent: SentBox) {
        let box = SentBox()
        var n = 0
        let client = RelayMuxRequestClient(
            send: { box.frames.append($0) },
            makeOpId: { n += 1; return "req-\(n)" },
            makeMessageId: { "m" },
            timeout: timeout,
            maxRawPayloadBytes: maxRaw
        )
        return (client, box)
    }

    private func waitForFrame(_ sent: SentBox, _ kind: RelayMuxKind) async -> RelayMuxFrame? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let f = sent.frames.first(where: { $0.kind == kind }) { return f }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return sent.frames.first(where: { $0.kind == kind })
    }

    func test_request_sendsRequestFrameAndResolvesOnResponse() async throws {
        let (client, sent) = makeClient()
        // Kick off the request; resolve it from a concurrent task once the
        // request frame has been emitted.
        async let respValue: RelayMuxResponse = client.request(method: "GET", path: "/sessions", body: nil)

        let reqFrame = await waitForFrame(sent, .request)
        let req = try XCTUnwrap(reqFrame.flatMap { RelayMuxRequest.decode($0.payload ?? Data()) })
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/sessions")
        let opId = try XCTUnwrap(reqFrame?.opId)

        let body = Data(#"{"ok":true}"#.utf8)
        let respPayload = try RelayMuxResponse(status: 200, body: body).encoded()
        client.handleInbound(RelayMuxFrame(opId: opId, kind: .response, payload: respPayload))

        let resp = try await respValue
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.body, body)
        XCTAssertEqual(client.inFlightCount, 0)
    }

    func test_largeResponse_reassembledFromChunks() async throws {
        let (client, sent) = makeClient(maxRaw: 1024)
        async let respValue: RelayMuxResponse = client.request(method: "GET", path: "/big", body: nil)
        let reqFrame = await waitForFrame(sent, .request)
        let opId = try XCTUnwrap(reqFrame?.opId)

        let bigBody = Data((0..<5000).map { UInt8($0 % 251) })
        let respPayload = try RelayMuxResponse(status: 200, body: bigBody).encoded()
        let chunks = RelayChunker.split(opId: opId, kind: .response, payload: respPayload, messageId: "r", maxRawPayloadBytes: 1024)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks { client.handleInbound(c) }

        let resp = try await respValue
        XCTAssertEqual(resp.body, bigBody, "chunked response must reassemble exactly")
    }

    func test_largeRequestBody_isChunkedOnTheWire() async throws {
        let (client, sent) = makeClient(maxRaw: 1024)
        let big = Data(repeating: 0x7a, count: 4000)
        async let respValue: RelayMuxResponse = client.request(method: "POST", path: "/x", body: big)
        // Let the chunked request frames flush.
        _ = await waitForFrame(sent, .request)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let reqFrames = sent.frames.filter { $0.kind == .request }
        XCTAssertGreaterThan(reqFrames.count, 1, "a large request body must chunk")
        XCTAssertTrue(reqFrames.allSatisfy { $0.chunk != nil })
        // resolve so the awaiting task doesn't hang the test
        let opId = reqFrames[0].opId
        client.handleInbound(RelayMuxFrame(opId: opId, kind: .response, payload: try RelayMuxResponse(status: 204, body: nil).encoded()))
        _ = try await respValue
    }

    func test_errorFrame_throwsRemoteError() async throws {
        let (client, sent) = makeClient()
        async let respValue: RelayMuxResponse = client.request(method: "GET", path: "/x", body: nil)
        let reqFrame = await waitForFrame(sent, .request)
        let opId = try XCTUnwrap(reqFrame?.opId)
        let errPayload = try JSONSerialization.data(withJSONObject: ["error": "loopback failed"])
        client.handleInbound(RelayMuxFrame(opId: opId, kind: .error, payload: errPayload))
        do {
            _ = try await respValue
            XCTFail("expected throw")
        } catch let e as RelayMuxRequestClient.RequestError {
            XCTAssertEqual(e, .remoteError("loopback failed"))
        }
    }

    func test_timeout_throws() async throws {
        let (client, sent) = makeClient(timeout: 0.2)
        async let respValue: RelayMuxResponse = client.request(method: "GET", path: "/slow", body: nil)
        _ = await waitForFrame(sent, .request)
        do {
            _ = try await respValue
            XCTFail("expected timeout")
        } catch let e as RelayMuxRequestClient.RequestError {
            XCTAssertEqual(e, .timeout)
        }
        XCTAssertEqual(client.inFlightCount, 0)
    }

    func test_failAll_failsInflight() async throws {
        let (client, sent) = makeClient(timeout: 10)
        async let respValue: RelayMuxResponse = client.request(method: "GET", path: "/x", body: nil)
        _ = await waitForFrame(sent, .request)
        client.failAll(.disconnected)
        do {
            _ = try await respValue
            XCTFail("expected disconnect")
        } catch let e as RelayMuxRequestClient.RequestError {
            XCTAssertEqual(e, .disconnected)
        }
    }
}
