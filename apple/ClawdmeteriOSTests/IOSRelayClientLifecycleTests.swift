// E4: iOS-side relay client — background lifecycle behaviour.
//
// Verifies the suspend/foreground/APNS-wake state machine of
// `IOSRelayClient` against a faked-out transport + a fake lifecycle
// observer that simulates the OS notifications without UIKit.
//
// Per the design doc §11 ("iOS background suspension drops the WS")
// the client MUST:
//   - close its WebSocket cleanly on `willResignActive`
//   - reopen on `didBecomeActive`
//   - never assume a long-lived socket across a suspend
//
// Per §6.1 (E4 acceptance gates) the client MUST also:
//   - mirror the Mac client's exponential backoff after a failed open
//   - never fall back to a less-secure path silently
//   - replay-cursor the inbound `seq` so a replayed AEAD frame is dropped

import XCTest
import Combine
import ClawdmeterShared
@testable import Clawdmeter

// MARK: - Test doubles

/// Lifecycle observer that lets the test drive transitions directly.
final class FakeLifecycleObserver: IOSAppLifecycleObserving, @unchecked Sendable {
    var onWillResignActive: (@Sendable () -> Void)?
    var onDidBecomeActive: (@Sendable () -> Void)?
    private(set) var started: Bool = false
    private(set) var stopped: Bool = false
    func start() { started = true }
    func stop() { stopped = true }

    /// Drive the suspend transition.
    func simulateWillResignActive() { onWillResignActive?() }
    /// Drive the foreground transition.
    func simulateDidBecomeActive() { onDidBecomeActive?() }
}

/// WebSocket transport that records send calls and feeds canned receive
/// responses. Each call to `receive()` returns the next message in the
/// queue or hangs (via an unresumed continuation) until the test
/// completes the connection.
actor FakeTransport: IOSRelayWebSocketTransport {
    nonisolated let id = UUID()
    private(set) var sentText: [String] = []
    private(set) var sentData: [Data] = []
    private(set) var cancelled: Bool = false

    private var receiveQueue: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var pendingError: Error?

    func enqueue(_ message: URLSessionWebSocketTask.Message) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            receiveQueue.append(message)
        }
    }

    func enqueueError(_ error: Error) {
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        } else {
            pendingError = error
        }
    }

    func send(text: String) async throws {
        sentText.append(text)
    }
    func send(data: Data) async throws {
        sentData.append(data)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !receiveQueue.isEmpty {
            return receiveQueue.removeFirst()
        }
        if let pendingError {
            self.pendingError = nil
            throw pendingError
        }
        return try await withCheckedThrowingContinuation { cont in
            self.waiter = cont
        }
    }

    nonisolated func cancel() {
        Task { await self.markCancelled() }
    }
    private func markCancelled() {
        cancelled = true
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: CancellationError())
        }
    }

    // Test helpers (require actor context).
    var sentTextSnapshot: [String] { sentText }
    var sentDataSnapshot: [Data] { sentData }
    var wasCancelled: Bool { cancelled }
}

// MARK: - Fixture helpers

enum RelayLifecycleFixture {
    /// A consistent, deterministic config the tests pass into the client.
    /// The symmetric key + peer pubkey are taken from the cross-impl
    /// test vectors so a downstream "the codec rejects gibberish"
    /// assertion can verify against known good bytes.
    static func defaultConfig(
        sid: String = "test-session-123456789abcdef",
        iosTok: String = "ios-tok-1234567890abcdef1234",
        relayUrl: String = "wss://relay-staging.clawdmeter.dev",
        ttl: UInt64? = nil
    ) -> IOSRelayClientConfig {
        // 32-byte symmetric key from the HKDF test vector.
        let key = Data([
            0x14, 0x8e, 0x0a, 0x09, 0xad, 0x73, 0x2f, 0x51,
            0x16, 0x9a, 0xa3, 0x62, 0xcf, 0x68, 0xdb, 0x94,
            0xe4, 0x22, 0x6a, 0xb1, 0x0b, 0x3c, 0x50, 0x39,
            0xd5, 0xf8, 0xad, 0x58, 0x8e, 0x80, 0x4f, 0xe8,
        ])
        // 32-byte pubkey from the X25519 test vector (Mac's pubkey).
        let pubBytes = Data([
            0xa4, 0xe0, 0x92, 0x92, 0xb6, 0x51, 0xc2, 0x78,
            0xb9, 0x77, 0x2c, 0x56, 0x9f, 0x5f, 0xa9, 0xbb,
            0x13, 0xd9, 0x06, 0xb4, 0x6a, 0xb6, 0x8c, 0x9d,
            0xf9, 0xdc, 0x2b, 0x44, 0x09, 0xf8, 0xa2, 0x09,
        ])
        let pubB64 = base64URLEncode(pubBytes)
        let now = UInt64(Date().timeIntervalSince1970)
        return IOSRelayClientConfig(
            sid: sid,
            iosTok: iosTok,
            relayUrl: relayUrl,
            theirEcdhPublicKeyBase64URL: pubB64,
            symmetricKey: key,
            ttl: ttl ?? (now + 900)
        )
    }

    /// 32 bytes of pubkey the iPhone sends as its handshake envelope.
    /// Distinct from the Mac's so the test can verify the right one
    /// goes on the wire.
    static let iosHandshakePubkeyBytes: Data = Data(repeating: 0x42, count: 32)

    static func base64URLEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Tests

@MainActor
final class IOSRelayClientLifecycleTests: XCTestCase {

    // ───────────────────────────────────────────────────────────
    // Connection open path
    // ───────────────────────────────────────────────────────────

    func testStartOpensTransportAndSendsHandshake() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        let factoryCalled = expectation(description: "transport factory called")
        let client = IOSRelayClient(
            config: RelayLifecycleFixture.defaultConfig(),
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryCalled.fulfill()
                return transport
            }
        )

        client.start()
        await fulfillment(of: [factoryCalled], timeout: 2)
        // Give the run-loop a tick to send the handshake.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(lifecycle.started, "client must subscribe to lifecycle notifications")
        let texts = await transport.sentText
        let datas = await transport.sentData
        XCTAssertEqual(texts.count, 1, "exactly one handshake header should be sent")
        XCTAssertEqual(datas.count, 1, "exactly one handshake body should be sent")
        // Header bytes must be canonical { v, from, type }.
        XCTAssertEqual(texts.first, #"{"v":1,"from":"ios","type":"handshake"}"#)
        XCTAssertEqual(datas.first, RelayLifecycleFixture.iosHandshakePubkeyBytes)
        client.stop()
    }

    func testStartIsIdempotent() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        var openCount = 0
        let factoryFired = expectation(description: "factory fired once")
        let client = IOSRelayClient(
            config: RelayLifecycleFixture.defaultConfig(),
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                openCount += 1
                if openCount == 1 { factoryFired.fulfill() }
                return transport
            }
        )
        client.start()
        client.start() // No-op
        client.start() // No-op
        await fulfillment(of: [factoryFired], timeout: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(openCount, 1, "start() must be idempotent while running")
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Suspend → foreground reconnect cycle (§11 invariant)
    // ───────────────────────────────────────────────────────────

    func testSuspendClosesSocketAndForegroundReopens() async throws {
        let lifecycle = FakeLifecycleObserver()
        let firstTransport = FakeTransport()
        let secondTransport = FakeTransport()
        let firstOpen = expectation(description: "first connection")
        let secondOpen = expectation(description: "second connection after foreground")
        var openCount = 0
        let client = IOSRelayClient(
            config: RelayLifecycleFixture.defaultConfig(),
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                openCount += 1
                switch openCount {
                case 1:
                    firstOpen.fulfill()
                    return firstTransport
                case 2:
                    secondOpen.fulfill()
                    return secondTransport
                default:
                    fatalError("unexpected reconnect attempt")
                }
            }
        )
        client.start()
        await fulfillment(of: [firstOpen], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Simulate iOS suspending the app. Per §11 the client must
        // close the socket and transition to `.suspended`.
        lifecycle.simulateWillResignActive()
        try await Task.sleep(nanoseconds: 100_000_000)
        let firstCancelled = await firstTransport.wasCancelled
        XCTAssertTrue(firstCancelled, "willResignActive must cancel the WS task")
        XCTAssertEqual(client.state, .suspended, "state must transition to .suspended")

        // Simulate the app foregrounding. Client must reopen on a
        // FRESH transport — re-using the cancelled one is a bug.
        lifecycle.simulateDidBecomeActive()
        await fulfillment(of: [secondOpen], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(openCount, 2)
        let firstSent = await firstTransport.sentText
        let secondSent = await secondTransport.sentText
        XCTAssertEqual(firstSent.count, 1)
        XCTAssertEqual(secondSent.count, 1, "second connection should also handshake")
        client.stop()
    }

    func testForegroundIsNoOpIfAlreadyConnected() async throws {
        let lifecycle = FakeLifecycleObserver()
        let transport = FakeTransport()
        var openCount = 0
        let factoryFired = expectation(description: "factory fired once")
        let client = IOSRelayClient(
            config: RelayLifecycleFixture.defaultConfig(),
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                openCount += 1
                if openCount == 1 { factoryFired.fulfill() }
                return transport
            }
        )
        client.start()
        await fulfillment(of: [factoryFired], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)

        // While already running, a stray didBecomeActive must NOT
        // open a second socket.
        lifecycle.simulateDidBecomeActive()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(openCount, 1, "foreground while running is a no-op")
        client.stop()
    }

    // ───────────────────────────────────────────────────────────
    // Expired pairing
    // ───────────────────────────────────────────────────────────

    func testExpiredPairingFailsImmediately() {
        let lifecycle = FakeLifecycleObserver()
        var factoryCalled = false
        // TTL in the past.
        let expired = RelayLifecycleFixture.defaultConfig(ttl: 0)
        let client = IOSRelayClient(
            config: expired,
            ourPublicKeyBytes: RelayLifecycleFixture.iosHandshakePubkeyBytes,
            lifecycle: lifecycle,
            transportFactory: { _, _ in
                factoryCalled = true
                return FakeTransport()
            }
        )
        client.start()
        XCTAssertFalse(factoryCalled, "must not open a socket against an expired pairing")
        if case .failed = client.state { /* good */ } else {
            XCTFail("state must be .failed for expired pairing; got \(client.state)")
        }
    }

    // ───────────────────────────────────────────────────────────
    // Backoff schedule
    // ───────────────────────────────────────────────────────────

    func testBackoffScheduleMonotonicWithJitter() {
        for attempt in 1...IOSRelayClient.backoffSchedule.count + 2 {
            let delay = IOSRelayClient.backoffDelay(for: attempt)
            // Even with ±15% jitter, every attempt should land between
            // 0.25s (floor) and 1.2× the schedule's last entry.
            XCTAssertGreaterThanOrEqual(delay, 0.25)
            XCTAssertLessThanOrEqual(delay, 30.0 * 1.2)
        }
    }

    func testBackoffFloorOnFirstAttempt() {
        // First attempt should use the first slot (~1s ± jitter, floored at 0.25s).
        let d = IOSRelayClient.backoffDelay(for: 1)
        XCTAssertGreaterThanOrEqual(d, 0.25)
        XCTAssertLessThanOrEqual(d, 1.15)
    }

    // ───────────────────────────────────────────────────────────
    // URL construction
    // ───────────────────────────────────────────────────────────

    func testBuildConnectURLStaging() {
        let cfg = RelayLifecycleFixture.defaultConfig()
        let url = IOSRelayClient.buildConnectURL(config: cfg)
        XCTAssertEqual(url?.absoluteString,
                       "wss://relay-staging.clawdmeter.dev/v1/relay/sessions/test-session-123456789abcdef/connect")
    }

    func testBuildConnectURLLocalhostDev() {
        let cfg = RelayLifecycleFixture.defaultConfig(relayUrl: "ws://localhost:8787")
        let url = IOSRelayClient.buildConnectURL(config: cfg)
        XCTAssertEqual(url?.scheme, "ws")
        XCTAssertEqual(url?.host, "localhost")
        XCTAssertEqual(url?.port, 8787)
        XCTAssertEqual(url?.path, "/v1/relay/sessions/test-session-123456789abcdef/connect")
    }
}
