import XCTest
@testable import ClawdmeterShared

@MainActor
final class AutoReviverTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AutoReviverURLProtocol.reset()
    }

    func test_tickFiresAtMostOncePerSessionEpoch() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AutoReviverURLProtocol.self]
        let reviver = AutoReviver(
            tokenProvider: StubTokenProvider(token: "token"),
            session: URLSession(configuration: config),
            endpoint: URL(string: "https://example.invalid/messages")!
        )
        reviver.isEnabled = true
        let now = Date(timeIntervalSince1970: 10_000)
        let usage = makeUsage(sessionEpoch: Int(now.timeIntervalSince1970) - 1)

        await reviver.tick(usage: usage, now: now)
        await reviver.tick(usage: usage, now: now.addingTimeInterval(300))

        XCTAssertEqual(reviver.fireCount, 1)
        XCTAssertEqual(AutoReviverURLProtocol.requestCount, 1)

        let nextUsage = makeUsage(sessionEpoch: usage.sessionEpoch + 3_600)
        await reviver.tick(
            usage: nextUsage,
            now: Date(timeIntervalSince1970: TimeInterval(nextUsage.sessionEpoch + 1))
        )

        XCTAssertEqual(reviver.fireCount, 2)
        XCTAssertEqual(AutoReviverURLProtocol.requestCount, 2)
    }

    private func makeUsage(sessionEpoch: Int) -> UsageData {
        UsageData(
            sessionPct: 100,
            sessionResetMins: 0,
            sessionEpoch: sessionEpoch,
            weeklyPct: 10,
            weeklyResetMins: 60,
            weeklyEpoch: sessionEpoch + 86_400,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sessionEpoch))
        )
    }

    private final class StubTokenProvider: TokenProvider, @unchecked Sendable {
        let token: String?

        init(token: String?) {
            self.token = token
        }

        var currentAccessToken: String? { token }
        var hasToken: Bool { token != nil }

        func refreshIfNeeded() async throws -> Bool {
            false
        }
    }
}

private final class AutoReviverURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
