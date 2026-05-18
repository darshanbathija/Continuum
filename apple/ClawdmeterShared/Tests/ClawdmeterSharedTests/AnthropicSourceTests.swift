import XCTest
@testable import ClawdmeterShared

/// Tests `AnthropicSource` against a `URLProtocol`-based mock so we can simulate
/// the Phase 0 Data Source Contract responses without hitting the network.
final class AnthropicSourceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeSource() -> AnthropicSource {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let tokenProvider = StubTokenProvider(token: "sk-ant-oat01-fake")
        return AnthropicSource(tokenProvider: tokenProvider, urlSession: session)
    }

    /// v0.4.11: source switched from `POST /v1/messages` + header parsing to
    /// `GET /api/oauth/usage` + JSON body parsing. These tests exercise the
    /// three response shapes the new decoder handles (multi-window object,
    /// single-binding object, and the `{rate_limits:{…}}` envelope).

    func test_poll_happyPath_multiWindowShape() async throws {
        let body = """
        {
          "five_hour":  {"utilization": 0.05, "resets_at": "2026-05-14T11:00:00Z"},
          "seven_day":  {"utilization": 0.26, "resets_at": "2026-05-20T01:00:00Z"},
          "rate_limit_type": "five_hour",
          "organization_uuid": "test-org"
        }
        """.data(using: .utf8)!

        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT", "content-type": "application/json"], body)
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.sessionPct, 5)
        XCTAssertEqual(usage.weeklyPct, 26)
        XCTAssertEqual(usage.status, .allowed)
        XCTAssertEqual(usage.representativeClaim, .fiveHour)
        XCTAssertEqual(usage.organizationID, "test-org")
    }

    func test_poll_happyPath_statuslineShape() async throws {
        // The shape `claude` itself feeds into the statusline JSON. Nested under
        // `rate_limits` with `used_percentage` (0..100) on each window.
        let body = """
        {
          "rate_limits": {
            "five_hour": {"used_percentage": 14.0, "resets_at": "2026-05-14T11:00:00Z"},
            "seven_day": {"used_percentage": 38.0, "resets_at": "2026-05-20T01:00:00Z"}
          }
        }
        """.data(using: .utf8)!

        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT", "content-type": "application/json"], body)
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.sessionPct, 14)
        XCTAssertEqual(usage.weeklyPct, 38)
    }

    func test_poll_singleBindingShape_fillsBoundWindowOnly() async throws {
        // The minimal "current binding" shape. Only the weekly-7d window has a
        // value; the 5h window should be 0 until we see it again.
        let body = """
        {"rate_limit_type": "seven_day", "utilization": 0.42, "resets_at": "2026-05-20T01:00:00Z"}
        """.data(using: .utf8)!

        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT", "content-type": "application/json"], body)
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.weeklyPct, 42)
        XCTAssertEqual(usage.sessionPct, 0)
        XCTAssertEqual(usage.representativeClaim, .sevenDay)
    }

    func test_poll_compositeStatus_limitedAtOrAbove100() async throws {
        let body = """
        {
          "five_hour":  {"utilization": 1.00, "resets_at": "2026-05-14T11:00:00Z"},
          "seven_day":  {"utilization": 0.50, "resets_at": "2026-05-20T01:00:00Z"},
          "rate_limit_type": "five_hour"
        }
        """.data(using: .utf8)!

        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT"], body)
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.status, .limited)
    }

    func test_poll_401_throwsUnauthenticated() async {
        MockURLProtocol.responder = { _ in (401, [:], Data()) }
        do {
            _ = try await makeSource().poll()
            XCTFail("Expected throw")
        } catch AISourceError.unauthenticated {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_poll_429_throwsRateLimitedWithRetryAfter() async {
        MockURLProtocol.responder = { _ in (429, ["Retry-After": "60"], Data()) }
        do {
            _ = try await makeSource().poll()
            XCTFail("Expected throw")
        } catch AISourceError.rateLimited(let retry) {
            XCTAssertEqual(retry, 60)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_poll_unparsableBody_throwsMalformedResponse() async {
        // 200 but the body isn't JSON we can decode — surface as malformed
        // rather than crashing. v0.4.11 reverse-engineered the shape from
        // the Claude CLI's binary, so we want to fail loudly if it shifts.
        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT"], "<html/>".data(using: .utf8)!)
        }
        do {
            _ = try await makeSource().poll()
            XCTFail("Expected throw")
        } catch AISourceError.malformedResponse {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_poll_500_throwsNetworkFailure() async {
        MockURLProtocol.responder = { _ in (500, [:], Data()) }
        do {
            _ = try await makeSource().poll()
            XCTFail("Expected throw")
        } catch AISourceError.networkFailure {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_refreshCredentials_boundedRetry_throwsAuthExpiredAfterTwoAttempts() async throws {
        // E7: bounded refresh per 10-min window
        let provider = AlwaysFailRefreshProvider()
        let source = AnthropicSource(tokenProvider: provider)

        // 2 attempts allowed
        _ = try? await source.refreshCredentialsIfNeeded()
        _ = try? await source.refreshCredentialsIfNeeded()

        // 3rd: throw .authExpired
        do {
            _ = try await source.refreshCredentialsIfNeeded()
            XCTFail("Expected authExpired throw")
        } catch AISourceError.authExpired {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Helpers

    private final class StubTokenProvider: TokenProvider {
        let token: String?
        init(token: String?) { self.token = token }
        var currentAccessToken: String? { token }
        var hasToken: Bool { token != nil }
        func refreshIfNeeded() async throws -> Bool { false }
    }

    private final class AlwaysFailRefreshProvider: TokenProvider {
        var currentAccessToken: String? { "stub" }
        var hasToken: Bool { true }
        func refreshIfNeeded() async throws -> Bool { false }
    }
}

/// Test-only URLProtocol that lets each test set a per-request responder.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (statusCode: Int, headers: [String: String], body: Data))? = nil

    static func reset() {
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let responder = MockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, headers, body) = responder(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
