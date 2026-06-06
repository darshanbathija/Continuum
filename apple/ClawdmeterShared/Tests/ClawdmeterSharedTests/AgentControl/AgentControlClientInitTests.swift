import XCTest
@testable import ClawdmeterShared

/// PR #24a Step 1 regression tests: AgentControlClient now lives in
/// ClawdmeterShared with two construction modes — UserDefaults-backed
/// (existing iOS path) and explicit-arg (new Mac loopback path). Both
/// modes must coexist without leaking state across instances.
final class AgentControlClientInitTests: XCTestCase {

    private final class SentBox {
        var frames: [RelayMuxFrame] = []
    }

    private final class DirectFallbackURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var storedRequests: [URLRequest] = []
        static var responseData = Data("[]".utf8)
        static var responseStatus = 200

        static var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return storedRequests
        }

        static func reset() {
            lock.lock()
            storedRequests = []
            responseData = Data("[]".utf8)
            responseStatus = 200
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.storedRequests.append(request)
            let data = Self.responseData
            let status = Self.responseStatus
            Self.lock.unlock()

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://direct.invalid")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // Standard UserDefaults keys the client checks. Tests stomp them
    // to set up scenarios; teardown removes them.
    private let keys = [
        AgentControlClient.hostKey,
        AgentControlClient.httpPortKey,
        AgentControlClient.wsPortKey,
        AgentControlClient.tokenKey,
    ]

    override func tearDown() {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        DirectFallbackURLProtocol.reset()
        super.tearDown()
    }

    func test_userDefaultsBackedInit_readsFromUserDefaults() {
        UserDefaults.standard.set("10.0.0.42", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set(31000, forKey: AgentControlClient.httpPortKey)
        UserDefaults.standard.set(31001, forKey: AgentControlClient.wsPortKey)
        UserDefaults.standard.set("user-defaults-token", forKey: AgentControlClient.tokenKey)

        let client = AgentControlClient()

        XCTAssertEqual(client.host, "10.0.0.42")
        XCTAssertEqual(client.httpPort, 31000)
        XCTAssertEqual(client.wsPort, 31001)
        XCTAssertEqual(client.token, "user-defaults-token")
        XCTAssertTrue(client.isConfigured)
    }

    func test_userDefaultsBackedInit_unconfiguredWhenNoDefaults() {
        let client = AgentControlClient()
        XCTAssertNil(client.host)
        XCTAssertNil(client.token)
        XCTAssertFalse(client.isConfigured)
        // Port defaults still kick in via nonZeroOrDefault.
        XCTAssertEqual(client.httpPort, 21731)
        XCTAssertEqual(client.wsPort, 21732)
    }

    func test_explicitInit_overridesUserDefaults() {
        // Set UserDefaults to one host, construct with another.
        UserDefaults.standard.set("dont.use.me", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set("dont-use-token", forKey: AgentControlClient.tokenKey)

        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback-token-abc"
        )

        // Explicit values win.
        XCTAssertEqual(client.host, "127.0.0.1")
        XCTAssertEqual(client.httpPort, 21731)
        XCTAssertEqual(client.wsPort, 21732)
        XCTAssertEqual(client.token, "loopback-token-abc")
        XCTAssertTrue(client.isConfigured)
    }

    func test_explicitInit_setPairingDoesNotCorruptUserDefaults() {
        // UserDefaults previously paired with iOS — don't let a Mac
        // loopback client wipe these.
        UserDefaults.standard.set("paired-iphone.example", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set("paired-iphone-token", forKey: AgentControlClient.tokenKey)

        let loopback = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback"
        )
        // setPairing on an explicit-config instance is a no-op (logs a
        // warning); UserDefaults must remain intact.
        loopback.setPairing(host: "evil.example", httpPort: 1, wsPort: 2, token: "stolen")

        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentControlClient.hostKey),
                       "paired-iphone.example",
                       "Explicit-config setPairing must not overwrite UserDefaults")
        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentControlClient.tokenKey),
                       "paired-iphone-token")
        // The loopback client's own values stay the explicit ones.
        XCTAssertEqual(loopback.host, "127.0.0.1")
        XCTAssertEqual(loopback.token, "loopback")
    }

    func test_explicitInit_clearPairingIsNoOp() {
        UserDefaults.standard.set("paired-iphone.example", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set("paired-iphone-token", forKey: AgentControlClient.tokenKey)

        let loopback = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback"
        )
        loopback.clearPairing()

        // UserDefaults preserved.
        XCTAssertNotNil(UserDefaults.standard.string(forKey: AgentControlClient.hostKey))
        XCTAssertNotNil(UserDefaults.standard.string(forKey: AgentControlClient.tokenKey))
    }

    func test_userDefaultsInit_setPairingDoesUpdate() {
        let client = AgentControlClient()
        client.setPairing(host: "newhost.example", httpPort: 22222, wsPort: 22223, token: "new-token")

        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentControlClient.hostKey), "newhost.example")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: AgentControlClient.httpPortKey), 22222)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: AgentControlClient.wsPortKey), 22223)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentControlClient.tokenKey), "new-token")
    }

    func test_userDefaultsInit_clearPairingClears() {
        UserDefaults.standard.set("h.example", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set("t", forKey: AgentControlClient.tokenKey)
        let client = AgentControlClient()
        client.clearPairing()
        XCTAssertNil(UserDefaults.standard.string(forKey: AgentControlClient.hostKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: AgentControlClient.tokenKey))
    }

    @MainActor
    func test_relayOnlyClientIsConfiguredAndRefreshesSessionsThroughRelay() async throws {
        let sent = SentBox()
        var nextOp = 0
        let relay = RelayMuxRequestClient(
            send: { sent.frames.append($0) },
            makeOpId: {
                nextOp += 1
                return "req-\(nextOp)"
            },
            makeMessageId: { "m" },
            timeout: 2
        )
        let client = AgentControlClient()
        XCTAssertFalse(client.isConfigured)

        client.relayRequestClient = relay

        XCTAssertTrue(client.relayActive)
        XCTAssertTrue(client.isConfigured)
        async let refresh: Void = client.refreshSessions()

        let requestFrame = await waitForRelayFrame(sent, .request)
        let frame = try XCTUnwrap(requestFrame)
        let request = try XCTUnwrap(RelayMuxRequest.decode(frame.payload ?? Data()))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/sessions")
        let opId = try XCTUnwrap(frame.opId)

        let responsePayload = try RelayMuxResponse(status: 200, body: Data("[]".utf8)).encoded()
        relay.handleInbound(RelayMuxFrame(opId: opId, kind: .response, payload: responsePayload))
        _ = await refresh

        XCTAssertEqual(client.sessions.count, 0)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func test_relayRequestFailureFallsBackToDirectPairing() async throws {
        UserDefaults.standard.set("direct.example", forKey: AgentControlClient.hostKey)
        UserDefaults.standard.set(31000, forKey: AgentControlClient.httpPortKey)
        UserDefaults.standard.set(31001, forKey: AgentControlClient.wsPortKey)
        UserDefaults.standard.set("direct-token", forKey: AgentControlClient.tokenKey)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectFallbackURLProtocol.self]
        DirectFallbackURLProtocol.reset()

        let sent = SentBox()
        let relay = RelayMuxRequestClient(
            send: { sent.frames.append($0) },
            makeOpId: { "fallback-req" },
            makeMessageId: { "fallback-msg" },
            timeout: 2
        )
        let client = AgentControlClient(urlSession: URLSession(configuration: config))
        XCTAssertTrue(client.isConfigured)
        client.relayRequestClient = relay

        async let refresh: Void = client.refreshSessions()
        let requestFrame = await waitForRelayFrame(sent, .request)
        let frame = try XCTUnwrap(requestFrame)
        let opId = try XCTUnwrap(frame.opId)
        let errorPayload = try JSONSerialization.data(withJSONObject: ["error": "relay unavailable"])
        relay.handleInbound(RelayMuxFrame(opId: opId, kind: .error, payload: errorPayload))
        _ = await refresh

        let direct = try XCTUnwrap(DirectFallbackURLProtocol.requests.first)
        XCTAssertEqual(direct.url?.host, "direct.example")
        XCTAssertEqual(direct.url?.port, 31000)
        XCTAssertEqual(direct.url?.path, "/sessions")
        XCTAssertEqual(direct.value(forHTTPHeaderField: "Authorization"), "Bearer direct-token")
        XCTAssertNil(client.lastError)
    }

    func test_prMutationPathsUseServerAlignedTimeouts() {
        let session = "12345678-1234-1234-1234-123456789abc"
        XCTAssertEqual(AgentControlClient.timeoutForPathForTesting("/sessions/\(session)/create-pr"), 75)
        XCTAssertEqual(AgentControlClient.timeoutForPathForTesting("/sessions/\(session)/pr/review"), 75)
        XCTAssertEqual(AgentControlClient.timeoutForPathForTesting("/sessions/\(session)/merge"), 110)
        XCTAssertEqual(AgentControlClient.timeoutForPathForTesting("/sessions/\(session)/approve-plan"), 45)
    }

    func test_explicitInit_handlesIPv6Host() {
        // url-host literal helper brackets bare IPv6.
        let client = AgentControlClient(
            host: "::1",
            httpPort: 21731,
            wsPort: 21732,
            token: "v6"
        )
        XCTAssertEqual(client.host, "::1")
        // The literal helper itself is tested separately; just ensure
        // we don't crash on IPv6 hosts during init.
        XCTAssertEqual(AgentControlClient.urlHostLiteral("::1"), "[::1]")
        XCTAssertEqual(AgentControlClient.urlHostLiteral("[::1]"), "[::1]")
        XCTAssertEqual(AgentControlClient.urlHostLiteral("127.0.0.1"), "127.0.0.1")
    }

    @MainActor
    private func waitForRelayFrame(_ sent: SentBox, _ kind: RelayMuxKind) async -> RelayMuxFrame? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let frame = sent.frames.first(where: { $0.kind == kind }) {
                return frame
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return sent.frames.first(where: { $0.kind == kind })
    }
}
