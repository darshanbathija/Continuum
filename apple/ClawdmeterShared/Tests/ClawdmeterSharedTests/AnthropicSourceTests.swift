import XCTest
@testable import ClawdmeterShared

/// Tests `AnthropicSource` against a `URLProtocol`-based mock.
///
/// The important safety contract is that quota polling never posts to
/// `/v1/messages`: it must use the non-generative OAuth usage endpoint so a
/// background refresh cannot create throwaway Claude conversations or spend
/// model quota.
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

    // MARK: - Primary path: /api/oauth/usage

    func test_poll_usesOAuthUsageGetWithoutPromptBody() async throws {
        var observedPath: String?
        var observedMethod: String?
        var observedBody: Data?
        var observedBeta: String?
        let usageBody = """
        {"rate_limit_type":"five_hour","utilization":14,"resets_at":"2026-05-14T11:00:00Z","organization_uuid":"test-org"}
        """.data(using: .utf8)!

        MockURLProtocol.responder = { request in
            observedPath = request.url?.path
            observedMethod = request.httpMethod
            observedBody = request.httpBody
            observedBeta = request.value(forHTTPHeaderField: "anthropic-beta")
            return (
                statusCode: 200,
                headers: ["date": "Thu, 14 May 2026 07:40:31 GMT"],
                body: usageBody
            )
        }

        let usage = try await makeSource().poll()

        XCTAssertEqual(observedPath, "/api/oauth/usage")
        XCTAssertEqual(observedMethod, "GET")
        XCTAssertNil(observedBody)
        XCTAssertEqual(observedBeta, "oauth-2025-04-20")
        XCTAssertEqual(usage.sessionPct, 14)
        XCTAssertEqual(usage.weeklyPct, 0)
        XCTAssertEqual(usage.representativeClaim, .fiveHour)
        XCTAssertEqual(usage.organizationID, "test-org")
    }

    func test_poll_dualWindowBody_parsesBothWindows() async throws {
        let usageBody = """
        {
          "rate_limits": {
            "five_hour": {"utilization": 31, "resets_at": "2026-05-14T11:00:00Z"},
            "seven_day": {"used_percentage": 81, "resets_at": "2026-05-20T13:00:00Z"}
          }
        }
        """.data(using: .utf8)!

        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT"], usageBody)
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.sessionPct, 31)
        XCTAssertEqual(usage.weeklyPct, 81)
        XCTAssertEqual(usage.status, .allowed)
        XCTAssertEqual(usage.representativeClaim, .unknown)
    }

    func test_poll_dualWindowBody_acceptsWholeNumberUtilizationPercent() async throws {
        let usageBody = """
        {
          "rate_limits": {
            "five_hour": {"utilization": 37, "resets_at": "2026-05-14T11:00:00Z"},
            "seven_day": {"utilization": 68, "resets_at": "2026-05-20T13:00:00Z"}
          }
        }
        """.data(using: .utf8)!

        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT"], usageBody)
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.sessionPct, 37)
        XCTAssertEqual(usage.weeklyPct, 68)
        XCTAssertEqual(usage.status, .allowed)
    }

    /// Regression for the "Weekly 100%" gauge bug. The live
    /// `/api/oauth/usage` reports `utilization` in PERCENTAGE units
    /// (`five_hour: 8.0` = 8%, `seven_day: 1.0` = 1%). The old heuristic
    /// treated values <= 1.0 as a 0...1 fraction and multiplied by 100, so a
    /// genuine 1% weekly read rendered as 100%. Sub-1% usage must stay sub-1%.
    func test_poll_utilizationIsPercentNotFraction_subOnePercentDoesNotPin() async throws {
        let usageBody = """
        {
          "five_hour":  {"utilization": 8.0, "resets_at": "2026-06-13T06:29:59Z"},
          "seven_day":  {"utilization": 1.0, "resets_at": "2026-06-17T00:59:59Z"},
          "seven_day_sonnet": {"utilization": 0.0, "resets_at": "2026-06-17T01:00:00Z"}
        }
        """.data(using: .utf8)!

        MockURLProtocol.responder = { _ in
            (200, ["date": "Sat, 13 Jun 2026 02:23:06 GMT"], usageBody)
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.sessionPct, 8)
        XCTAssertEqual(usage.weeklyPct, 1, "1.0% weekly utilization must read as 1%, not 100%")
        XCTAssertEqual(usage.status, .allowed)
    }

    func test_poll_limitedWhenEitherWindowAtOneHundred() async throws {
        let usageBody = """
        {
          "five_hour": {"used_percentage": 100, "resets_at": "2026-05-14T11:00:00Z"},
          "seven_day": {"used_percentage": 50, "resets_at": "2026-05-20T13:00:00Z"}
        }
        """.data(using: .utf8)!

        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT"], usageBody)
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.sessionPct, 100)
        XCTAssertEqual(usage.weeklyPct, 50)
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

    func test_poll_malformedBody_throwsMalformedResponse() async {
        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT"], Data("not-json".utf8))
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

    // MARK: - Refresh

    func test_refreshCredentials_boundedRetry_throwsAuthExpiredAfterTwoAttempts() async throws {
        let provider = AlwaysFailRefreshProvider()
        let source = AnthropicSource(tokenProvider: provider)

        _ = try? await source.refreshCredentialsIfNeeded()
        _ = try? await source.refreshCredentialsIfNeeded()

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
