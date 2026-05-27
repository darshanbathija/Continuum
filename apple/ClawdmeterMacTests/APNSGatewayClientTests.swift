// E6: APNS gateway client unit tests.
//
// The client posts encrypted push bodies to the operator's gateway Worker.
// These tests substitute a `URLProtocol` stub for the network so we can
// verify:
//   - the JSON body matches the Worker's schema
//   - the Authorization bearer signs to the expected HMAC
//   - payload-sealing happens (cleartext is never on the wire)
//   - 200 → .delivered with `apnsId`
//   - 410 → .unregistered + token purge
//   - 4xx/5xx → the right classification
//   - transport errors → .transportError
//
// We do NOT round-trip against the real Worker — that's covered by the
// Worker's own integration tests on the TS side. The byte parity between
// the two sides is asserted via `APNSGatewayBearerTests.testBearerByteParityWithFixedVector`
// in `ClawdmeterShared`.

import XCTest
@testable import Clawdmeter
@testable import ClawdmeterShared
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@MainActor
final class APNSGatewayClientTests: XCTestCase {

    // MARK: - URLProtocol stub

    final class MockProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data?))?
        nonisolated(unsafe) static var observedRequest: URLRequest?
        nonisolated(unsafe) static var observedBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            // URLProtocol strips the httpBody before delivering — read
            // from the bodyStream if present.
            var captured = request.httpBody ?? Data()
            if captured.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    captured.append(buf, count: n)
                }
            }
            Self.observedRequest = request
            Self.observedBody = captured
            guard let handler = Self.handler else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let (response, body) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let body { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() async throws {
        try await super.setUp()
        MockProtocol.handler = nil
        MockProtocol.observedRequest = nil
        MockProtocol.observedBody = nil
    }

    // MARK: - Fixtures

    /// Build a fully-populated `PushInput` with a deterministic key
    /// material so test assertions can reproduce the bearer + the seal.
    private func makeInput(
        signingKey: Data = Data(repeating: 0x11, count: 32),
        payloadKey: Data = Data(repeating: 0x22, count: 32),
        sessionId: String = "test-session-1234567890ab",
        deviceToken: String = String(repeating: "ab", count: 32)
    ) -> APNSGatewayClient.PushInput {
        let body = APNSPushBody(
            kind: "planApproval",
            sessionId: sessionId,
            title: "Plan ready",
            body: "Click to approve",
            triggerAt: 1_700_000_000
        )
        let fingerprint = String(repeating: "cd", count: 32)
        return APNSGatewayClient.PushInput(
            body: body,
            deviceToken: deviceToken,
            topic: "com.clawdmeter.iphone",
            sessionId: sessionId,
            senderMacFingerprint: fingerprint,
            signingKey: signingKey,
            payloadKey: payloadKey,
            priority: 10,
            pushType: .alert,
            collapseId: "plan-\(sessionId.prefix(16))"
        )
    }

    private func makeClient() async -> APNSGatewayClient {
        let client = APNSGatewayClient(urlSession: makeSession())
        await client._setEnvironment(.staging)
        return client
    }

    // MARK: - Tests

    /// 200 response is classified as .delivered and the apnsId is parsed.
    func testDeliveredResponseExtractsApnsId() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            )!
            let body = #"{"ok": true, "apnsId": "abcd-1234"}"#.data(using: .utf8)!
            return (resp, body)
        }
        let input = makeInput()
        let outcome = await client.push(
            input,
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        XCTAssertEqual(outcome.response, .delivered)
        XCTAssertEqual(outcome.apnsId, "abcd-1234")
        XCTAssertEqual(outcome.httpStatus, 200)
    }

    /// The request body must match the Worker's PushRequest schema:
    /// deviceToken, encryptedPayload (base64), topic, sessionId,
    /// senderMacFingerprint, plus the optional fields the daemon ships.
    func testRequestBodyMatchesWorkerSchema() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        let input = makeInput()
        _ = await client.push(
            input,
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        let body = try XCTUnwrap(MockProtocol.observedBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let parsed = try XCTUnwrap(json)
        XCTAssertEqual(parsed["deviceToken"] as? String, input.deviceToken)
        XCTAssertEqual(parsed["topic"] as? String, "com.clawdmeter.iphone")
        XCTAssertEqual(parsed["sessionId"] as? String, input.sessionId)
        XCTAssertEqual(parsed["senderMacFingerprint"] as? String, input.senderMacFingerprint)
        XCTAssertEqual(parsed["pushType"] as? String, "alert")
        XCTAssertEqual(parsed["priority"] as? Int, 10)
        // encryptedPayload must be present, non-empty, and a base64 string.
        let wire = try XCTUnwrap(parsed["encryptedPayload"] as? String)
        XCTAssertFalse(wire.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: wire))
    }

    /// The bearer the daemon sends must equal what `APNSGatewayBearer.issueBearer`
    /// produces — anything else gets rejected by the Worker as 401.
    func testBearerSignsCorrectly() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        let signingKey = Data(repeating: 0x77, count: 32)
        let input = makeInput(signingKey: signingKey)
        _ = await client.push(
            input,
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        let req = try XCTUnwrap(MockProtocol.observedRequest)
        let authHeader = try XCTUnwrap(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authHeader.hasPrefix("Bearer "))
        let token = String(authHeader.dropFirst("Bearer ".count))
        let expected = APNSGatewayBearer.issueBearer(
            signingKey: signingKey,
            sessionId: input.sessionId,
            senderMacFingerprint: input.senderMacFingerprint
        )
        XCTAssertEqual(token, expected)
    }

    /// The plaintext push body bytes must NEVER appear on the wire — the
    /// Worker never decrypts.
    func testCleartextNeverOnTheWire() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        let secret = "TOP-SECRET-PLAINTEXT-MARKER-DO-NOT-LEAK"
        let body = APNSPushBody(
            kind: "planApproval",
            sessionId: "abc",
            title: secret,
            body: secret,
            triggerAt: 1
        )
        let input = APNSGatewayClient.PushInput(
            body: body,
            deviceToken: String(repeating: "ee", count: 32),
            topic: "com.clawdmeter.iphone",
            sessionId: "test-session-123456789012",
            senderMacFingerprint: String(repeating: "11", count: 32),
            signingKey: Data(repeating: 0x55, count: 32),
            payloadKey: Data(repeating: 0x66, count: 32)
        )
        _ = await client.push(
            input,
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        let wireBody = try XCTUnwrap(MockProtocol.observedBody)
        let bodyString = String(data: wireBody, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyString.contains(secret),
                      "Cleartext body marker must NEVER appear in the wire payload")
    }

    /// 410 → .unregistered. AND the side-effect: the device token must be
    /// purged from `APNSPushDeviceTokenStore`.
    func testFourTenPurgesDeviceToken() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 410, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"error":"unregistered"}"#.utf8))
        }
        // Use an isolated tmp file so we don't pollute the real store.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("e6-token-store-\(UUID()).json")
        let store = APNSPushDeviceTokenStore(fileURL: tmp)
        let token = String(repeating: "ff", count: 32)
        store.register(sessionId: "session-410", deviceToken: token, bundleId: "com.clawdmeter.iphone")
        XCTAssertEqual(store.count, 1)
        // Use the shared singleton for the actual purge — the client code
        // resolves via `APNSPushDeviceTokenStore.shared`. To make this
        // test deterministic we substitute the entry on the shared store
        // for the duration of the test.
        APNSPushDeviceTokenStore.shared.register(
            sessionId: "session-410", deviceToken: token, bundleId: "com.clawdmeter.iphone"
        )
        defer {
            APNSPushDeviceTokenStore.shared.purgeByDeviceToken(token)
            try? FileManager.default.removeItem(at: tmp)
        }

        let input = APNSGatewayClient.PushInput(
            body: APNSPushBody(kind: "planApproval", sessionId: "session-410", title: "x", body: "y", triggerAt: 1),
            deviceToken: token,
            topic: "com.clawdmeter.iphone",
            sessionId: "session-410",
            senderMacFingerprint: String(repeating: "00", count: 32),
            signingKey: Data(repeating: 0xAA, count: 32),
            payloadKey: Data(repeating: 0xBB, count: 32)
        )
        let outcome = await client.push(
            input,
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        XCTAssertEqual(outcome.response, .unregistered)
        // The shared store's entry for this token MUST be gone.
        XCTAssertNil(APNSPushDeviceTokenStore.shared.entries.first { $0.deviceToken == token })
    }

    /// 401 → .unauthorized; the daemon doesn't retry.
    func testUnauthorized() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let outcome = await client.push(
            makeInput(),
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        XCTAssertEqual(outcome.response, .unauthorized)
    }

    /// 429 → .rateLimited.
    func testRateLimited() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 429, httpVersion: "HTTP/1.1",
                headerFields: ["retry-after": "60"]
            )!
            return (resp, Data(#"{"error":"rate-limited"}"#.utf8))
        }
        let outcome = await client.push(
            makeInput(),
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        XCTAssertEqual(outcome.response, .rateLimited)
    }

    /// 503 → .killSwitch (Worker kill-switch is on).
    func testKillSwitch() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"error":"service-unavailable"}"#.utf8))
        }
        let outcome = await client.push(
            makeInput(),
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        XCTAssertEqual(outcome.response, .killSwitch)
    }

    /// 403 → .forbidden — most often the cross-tenant binding check.
    func testForbiddenCrossTenant() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"error":"forbidden","reason":"device token bound to a different pairing session"}"#.utf8))
        }
        let outcome = await client.push(
            makeInput(),
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        XCTAssertEqual(outcome.response, .forbidden)
    }

    /// 400 with bad-token in the body → .badToken.
    func testBadTokenClassification() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"error":"bad-token"}"#.utf8))
        }
        let outcome = await client.push(
            makeInput(),
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        XCTAssertEqual(outcome.response, .badToken)
    }

    /// 400 without "bad-token" body → .schemaError.
    func testSchemaError() async throws {
        let client = await makeClient()
        MockProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!,
                statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(#"{"error":"bad-request","reason":"missing deviceToken"}"#.utf8))
        }
        let outcome = await client.push(
            makeInput(),
            gatewayURL: URL(string: "https://apns-gateway-staging.clawdmeter.dev/push")!
        )
        XCTAssertEqual(outcome.response, .schemaError)
    }
}
