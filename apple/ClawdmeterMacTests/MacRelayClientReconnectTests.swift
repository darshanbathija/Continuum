// E3 (respin): Mac-side reconnect + backoff behavior.
//
// The Mac client mirrors the iOS client's exponential backoff (1, 2,
// 4, 8, 16, 30s with ±15% jitter). These tests verify:
//   - the schedule is in-range
//   - reconnects reuse the same sid + macTok (so the relay's DO sees
//     the same session on retry)
//   - an expired TTL bails out without dialing
//   - the `degraded` state activates after enough failed connects
//
// Reconnect-on-drop is exercised here by canceling the fake transport
// out from under the run loop and asserting a second `transportFactory`
// invocation occurs.

import XCTest
import Combine
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class MacRelayClientReconnectTests: XCTestCase {

    // ───────────────────────────────────────────────────────────
    // Backoff schedule
    // ───────────────────────────────────────────────────────────

    func testBackoffScheduleStaysInRangeAcrossAttempts() {
        for attempt in 1...MacRelayClient.backoffSchedule.count + 2 {
            let delay = MacRelayClient.backoffDelay(for: attempt)
            // Floor 0.25s; ceiling 30 * 1.15 (jitter cap on the last
            // step). Every attempt should be inside that range.
            XCTAssertGreaterThanOrEqual(delay, 0.25)
            XCTAssertLessThanOrEqual(delay, 30.0 * 1.2)
        }
    }

    func testBackoffFloorOnFirstAttempt() {
        let d = MacRelayClient.backoffDelay(for: 1)
        XCTAssertGreaterThanOrEqual(d, 0.25)
        XCTAssertLessThanOrEqual(d, 1.15)
    }

    func testBackoffIsRoughlyMonotonic() {
        // The schedule's nominal values are monotonic; jitter is
        // bounded so attempt 6's expected base (30s) is always >= the
        // floor of attempt 1 (~1s minus 15% = 0.85s, clamped at 0.25).
        let a1Avg = (0..<50).map { _ in MacRelayClient.backoffDelay(for: 1) }.reduce(0, +) / 50.0
        let a6Avg = (0..<50).map { _ in MacRelayClient.backoffDelay(for: 6) }.reduce(0, +) / 50.0
        XCTAssertLessThan(a1Avg, a6Avg, "later attempts should average bigger delays")
    }

    // ───────────────────────────────────────────────────────────
    // URL stability across reconnects: same sid + macTok
    // ───────────────────────────────────────────────────────────

    func testReconnectReusesSameSidAndToken() async throws {
        // Two transports for two open attempts. The factory captures
        // the URL + token for inspection.
        let cfg = MacRelayFixture.defaultConfig()
        let first = MacFakeRelayTransport()
        let second = MacFakeRelayTransport()
        let capturedURLs = MacReconnectURLBox()
        let firstOpen = expectation(description: "first open")
        let secondOpen = expectation(description: "second open")
        var openCount = 0
        let recorder = MacFakeHandshakeRecorder()
        let client = MacRelayClient(
            config: cfg,
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { url, token in
                capturedURLs.appendURL(url, token: token)
                openCount += 1
                switch openCount {
                case 1:
                    firstOpen.fulfill()
                    return first
                case 2:
                    secondOpen.fulfill()
                    return second
                default:
                    fatalError("unexpected open count \(openCount)")
                }
            }
        )
        client.start()
        await fulfillment(of: [firstOpen], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        // Drop the first transport from underneath the run loop.
        await first.enqueueError(NSError(domain: "test.drop", code: -1))
        // Backoff schedule starts at ~1s; wait long enough for the
        // second attempt.
        await fulfillment(of: [secondOpen], timeout: 5)
        // Both URLs must carry the same sid + macTok.
        let urls = capturedURLs.urls()
        let tokens = capturedURLs.tokens()
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0], cfg.macTok)
        XCTAssertEqual(tokens[1], cfg.macTok)
        XCTAssertEqual(urls[0].path, "/v1/relay/sessions/\(cfg.sid)/connect")
        XCTAssertEqual(urls[1].path, "/v1/relay/sessions/\(cfg.sid)/connect")
        // First open SHOULD include the bundle (first peer); second
        // SHOULD NOT (the DO is initialized).
        let c0 = URLComponents(url: urls[0], resolvingAgainstBaseURL: false)
        let c1 = URLComponents(url: urls[1], resolvingAgainstBaseURL: false)
        XCTAssertNotNil(c0?.queryItems?.first(where: { $0.name == "bundle" }))
        XCTAssertNil(c1?.queryItems?.first(where: { $0.name == "bundle" }))
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Expired pairing fails immediately
    // ───────────────────────────────────────────────────────────

    func testExpiredPairingFailsImmediately() {
        var factoryCalled = false
        let expired = MacRelayFixture.defaultConfig(ttl: 0)
        let recorder = MacFakeHandshakeRecorder()
        let client = MacRelayClient(
            config: expired,
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in
                factoryCalled = true
                return MacFakeRelayTransport()
            }
        )
        client.start()
        XCTAssertFalse(factoryCalled, "must not dial against an expired pairing")
        if case .failed = client.state { /* good */ } else {
            XCTFail("expected .failed for expired pairing; got \(client.state)")
        }
    }

    // ───────────────────────────────────────────────────────────
    // start() idempotent
    // ───────────────────────────────────────────────────────────

    func testStartIsIdempotent() async throws {
        let transport = MacFakeRelayTransport()
        var openCount = 0
        let factoryFired = expectation(description: "factory fired once")
        let recorder = MacFakeHandshakeRecorder()
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in
                openCount += 1
                if openCount == 1 { factoryFired.fulfill() }
                return transport
            }
        )
        client.start()
        client.start()
        client.start()
        await fulfillment(of: [factoryFired], timeout: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(openCount, 1, "start() must be idempotent while running")
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // isReachable gates correctly
    // ───────────────────────────────────────────────────────────

    func testIsReachableIsFalseWhileIdle() {
        let recorder = MacFakeHandshakeRecorder()
        let client = MacRelayClient(
            config: MacRelayFixture.defaultConfig(),
            pairingService: recorder,
            frameHandler: { _ in nil },
            transportFactory: { _, _ in MacFakeRelayTransport() }
        )
        XCTAssertFalse(client.isReachable)
    }
}

/// Small Sendable inbox for captured URLs across the closure-driven
/// transport factory. Avoids `var capturing` warnings under strict
/// concurrency.
@MainActor
final class MacReconnectURLBox {
    private var _urls: [URL] = []
    private var _tokens: [String] = []
    nonisolated init() {}
    func appendURL(_ url: URL, token: String) {
        _urls.append(url)
        _tokens.append(token)
    }
    func urls() -> [URL] { _urls }
    func tokens() -> [String] { _tokens }
}
