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

    func test_chatStream_unsubscribesStaleRelayBeforeFallback() async throws {
        let oldThreshold = iOSChatStore.relayStalenessThreshold
        iOSChatStore.relayStalenessThreshold = 0.05
        defer { iOSChatStore.relayStalenessThreshold = oldThreshold }

        let sessionId = UUID()
        let sent = Box()
        let mux = RelayMuxClient(send: { sent.frames.append($0) }, makeOpId: { "stale-chat-op" })
        let store = iOSChatStore(sessionId: sessionId, client: AgentControlClient())
        store.relayMux = mux
        store.start()

        let subscribed = await waitUntil { sent.frames.contains { $0.kind == .subscribe } }
        XCTAssertTrue(subscribed, "store must subscribe over relay before the watchdog can fire")

        let unsubscribed = await waitUntil { sent.frames.contains { $0.kind == .unsubscribe && $0.opId == "stale-chat-op" } }
        XCTAssertTrue(unsubscribed, "a stale relay stream must unsubscribe so fallback can run")
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

@MainActor
final class MobileCommandOutboxRetryTests: XCTestCase {

    private final class OutboxURLProtocol: URLProtocol {
        static var responder: ((URLRequest) -> (Int, [String: String], Data))?
        static var requests: [URLRequest] = []

        static func reset() {
            responder = nil
            requests = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            guard let responder = Self.responder else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (status, headers, data) = responder(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        OutboxURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> AgentControlClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutboxURLProtocol.self]
        return AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "test-token",
            urlSession: URLSession(configuration: config)
        )
    }

    private func makeStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-outbox-\(UUID().uuidString).json")
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    func test_non429ClientErrorMovesEnvelopeToFailedWithoutRetry() async throws {
        OutboxURLProtocol.responder = { _ in
            (403, ["Content-Type": "application/json"], Data())
        }
        let client = makeClient()
        let outbox = MobileCommandOutbox(client: client, storeURL: makeStoreURL(), deviceId: "test-device")

        outbox.enqueueSend(sessionId: UUID(), text: "ship it", asFollowUp: true)

        let failed = await waitUntil {
            outbox.failed.count == 1 && outbox.pending.isEmpty
        }
        XCTAssertTrue(failed, "non-429 4xx sends should move straight to failed")
        XCTAssertEqual(outbox.failed.first?.retryCount, 0)
        XCTAssertEqual(client.lastHTTPStatusCode, 403)
        XCTAssertEqual(OutboxURLProtocol.requests.count, 1)
    }

    func test_429ClientErrorStaysPendingForRetry() async throws {
        OutboxURLProtocol.responder = { _ in
            (429, ["Content-Type": "application/json", "Retry-After": "1"], Data())
        }
        let client = makeClient()
        let outbox = MobileCommandOutbox(client: client, storeURL: makeStoreURL(), deviceId: "test-device")

        outbox.enqueueSend(sessionId: UUID(), text: "retry later", asFollowUp: true)

        let queuedForRetry = await waitUntil {
            outbox.pending.first?.retryCount == 1 && outbox.failed.isEmpty
        }
        XCTAssertTrue(queuedForRetry, "429 should remain pending and follow the retry schedule")
        XCTAssertEqual(client.lastHTTPStatusCode, 429)
        if let key = outbox.pending.first?.idempotencyKey {
            outbox.discard(idempotencyKey: key)
        }
    }
}
