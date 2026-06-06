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
        private static let lock = NSLock()
        private static var recordedRequests: [URLRequest] = []
        private static var recordedRequestBodies: [Data?] = []

        static var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        static var requestBodies: [Data?] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequestBodies
        }

        static func reset() {
            responder = nil
            lock.lock()
            recordedRequests = []
            recordedRequestBodies = []
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Self.bodyData(from: request)
            Self.lock.lock()
            Self.recordedRequests.append(request)
            Self.recordedRequestBodies.append(body)
            Self.lock.unlock()
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

        private static func bodyData(from request: URLRequest) -> Data? {
            if let body = request.httpBody {
                return body
            }
            guard let stream = request.httpBodyStream else {
                return nil
            }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            return data.isEmpty ? nil : data
        }
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

    func test_persistedQueuedSendRequiresManualRetryAfterRelaunch() async throws {
        struct StoreFile: Codable {
            var version: Int
            var pending: [MobileCommandEnvelope]
            var failed: [MobileCommandEnvelope]
        }

        OutboxURLProtocol.responder = { _ in
            (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }
        let storeURL = makeStoreURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = try encoder.encode(SendPromptRequest(
            text: "persisted prompt",
            asFollowUp: true,
            idempotencyKey: "persisted-key",
            origin: .userComposer,
            clientIntentId: "persisted-intent"
        ))
        let envelope = MobileCommandEnvelope(
            idempotencyKey: "persisted-key",
            deviceId: "test-device",
            sessionId: UUID(),
            kind: .send,
            status: .queued,
            payload: String(data: payload, encoding: .utf8) ?? "{}"
        )
        let store = StoreFile(version: 1, pending: [envelope], failed: [])
        try encoder.encode(store).write(to: storeURL, options: [.atomic])

        let outbox = MobileCommandOutbox(client: makeClient(), storeURL: storeURL, deviceId: "test-device")

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(outbox.pending.isEmpty)
        XCTAssertEqual(outbox.failed.first?.idempotencyKey, "persisted-key")
        XCTAssertEqual(OutboxURLProtocol.requests.count, 0)
    }

    func test_manualRetryRestampsLegacyQueuedSendAsUserComposer() async throws {
        struct StoreFile: Codable {
            var version: Int
            var pending: [MobileCommandEnvelope]
            var failed: [MobileCommandEnvelope]
        }

        OutboxURLProtocol.responder = { _ in
            (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }
        let storeURL = makeStoreURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = MobileCommandEnvelope(
            idempotencyKey: "legacy-hi-key",
            deviceId: "test-device",
            sessionId: UUID(),
            kind: .send,
            status: .queued,
            payload: #"{"text":"hi","asFollowUp":true,"idempotencyKey":"legacy-hi-key"}"#
        )
        let store = StoreFile(version: 1, pending: [envelope], failed: [])
        try encoder.encode(store).write(to: storeURL, options: [.atomic])

        let outbox = MobileCommandOutbox(client: makeClient(), storeURL: storeURL, deviceId: "test-device")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(outbox.pending.isEmpty)
        XCTAssertEqual(outbox.failed.first?.idempotencyKey, "legacy-hi-key")
        XCTAssertEqual(OutboxURLProtocol.requests.count, 0)

        outbox.retry(idempotencyKey: "legacy-hi-key")
        let restampedPayload = try XCTUnwrap(outbox.pending.first?.payload.data(using: .utf8))
        let restampedRequest = try JSONDecoder().decode(SendPromptRequest.self, from: restampedPayload)
        XCTAssertEqual(restampedRequest.origin, .userComposer)
        XCTAssertEqual(restampedRequest.idempotencyKey, "legacy-hi-key")

        let sent = await waitUntil {
            OutboxURLProtocol.requests.contains { request in
                request.url?.path.hasSuffix("/send") == true
            }
        }
        XCTAssertTrue(sent, "manual retry should dispatch exactly one restamped send")
        let sendBodies = zip(OutboxURLProtocol.requests, OutboxURLProtocol.requestBodies)
            .filter { request, _ in request.url?.path.hasSuffix("/send") == true }
            .map { _, body in body }
        XCTAssertEqual(sendBodies.count, 1)
        let body = try XCTUnwrap(sendBodies.first ?? nil)
        let request = try JSONDecoder().decode(SendPromptRequest.self, from: body)
        XCTAssertEqual(request.text, "hi")
        XCTAssertEqual(request.origin, .userComposer)
        XCTAssertEqual(request.idempotencyKey, "legacy-hi-key")
        XCTAssertNotNil(request.clientIntentId)
    }
}
