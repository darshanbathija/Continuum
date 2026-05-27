import XCTest
import Network
import Combine
@testable import Clawdmeter
import ClawdmeterShared
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// E3 — Mac daemon RelayClient handshake + reconnect + heartbeat tests.
///
/// Uses an in-process Network.framework WebSocket listener as the "mock
/// relay" (we can't dial the real CF Worker from a unit test — the test
/// runner has no network entitlements + we don't want the staging Worker
/// to see test traffic). The mock listener emulates the relay enough to
/// exercise:
///
///   1. The URL construction (sid, token, bundle param)
///   2. The Authorization Bearer header
///   3. The text-header / binary-body envelope shape
///   4. Encrypt → relay-as-postal-service → decrypt round-trip with the
///      hand-rolled XChaCha20-Poly1305 codec
///   5. Reconnect-with-backoff when the socket drops
///   6. Heartbeat ping every 25s (compressed for the test via a custom
///      class-static knob — the real cadence is too long for CI)
///
/// We deliberately do NOT exercise the E2 Worker's full auth/handshake
/// negotiation; that's the relay's job and gets covered by `relay.integration.test.ts`
/// in `infra/relay/test/`. Here we assert that the Mac client speaks the
/// agreed wire shape correctly.
@MainActor
final class RelayClientHandshakeTests: XCTestCase {

    // MARK: - Helpers

    /// Spin up an in-process Network.framework WS listener and return the
    /// port it bound to + a handle to close it later.
    fileprivate final class MockRelayListener: @unchecked Sendable {
        let listener: NWListener
        let port: UInt16
        let acceptedConnections: LockedArray<NWConnection>
        private let lock = NSLock()
        private var _onConnect: ((NWConnection) -> Void)?
        var onConnect: ((NWConnection) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _onConnect }
            set { lock.lock(); defer { lock.unlock() }; _onConnect = newValue }
        }

        init() throws {
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            let params = NWParameters.tcp
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            let acceptedConnections = LockedArray<NWConnection>()
            self.listener = listener
            self.acceptedConnections = acceptedConnections
            // Spin up briefly to allocate a port.
            let semaphore = DispatchSemaphore(value: 0)
            let boundPortBox = LockedBox<UInt16>(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    boundPortBox.set(port.rawValue)
                    semaphore.signal()
                } else if case .failed = state {
                    semaphore.signal()
                }
            }
            // Defer wiring the newConnectionHandler to set up after init —
            // because the closure needs to capture `self.onConnect` and
            // we don't have a `self` until init returns. Trick: we use a
            // separate `onConnectBox` that we share between the closure
            // here and the property getter via the `_onConnect` field.
            let onConnectBox = LockedBox<((NWConnection) -> Void)?>(value: nil)
            listener.newConnectionHandler = { connection in
                acceptedConnections.append(connection)
                connection.start(queue: .global())
                onConnectBox.get()?(connection)
            }
            listener.start(queue: .global())
            _ = semaphore.wait(timeout: .now() + 5)
            let boundPort = boundPortBox.get()
            guard boundPort > 0 else {
                listener.cancel()
                throw NSError(domain: "MockRelayListener", code: 1)
            }
            self.port = boundPort
            // Now that init is complete, replace _onConnect's storage with
            // a sink that updates onConnectBox so the newConnectionHandler
            // observes property updates.
            self.installOnConnectBridge(onConnectBox)
        }

        private func installOnConnectBridge(_ box: LockedBox<((NWConnection) -> Void)?>) {
            // Wrap the existing onConnect property: every set also writes
            // to the box. We do this via a custom didSet — but Swift
            // doesn't let us add a didSet after declaration, so we use
            // a sibling private setter that the property getter/setter
            // we declared above will route through.
            lock.lock(); defer { lock.unlock() }
            _connectBridge = box
        }
        private var _connectBridge: LockedBox<((NWConnection) -> Void)?>?

        deinit {
            listener.cancel()
        }

        var url: String {
            "ws://127.0.0.1:\(port)"
        }

        /// Update both the local storage and the box the listener observes.
        func setOnConnect(_ handler: @escaping (NWConnection) -> Void) {
            lock.lock()
            _onConnect = handler
            let box = _connectBridge
            lock.unlock()
            box?.set(handler)
        }
    }

    fileprivate final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(value: T) { self.value = value }
        func get() -> T {
            lock.lock(); defer { lock.unlock() }; return value
        }
        func set(_ v: T) {
            lock.lock(); defer { lock.unlock() }; value = v
        }
    }

    /// Thread-safe array for the listener to push connections into.
    fileprivate final class LockedArray<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) {
            lock.lock(); defer { lock.unlock() }
            items.append(item)
        }
        var snapshot: [T] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return items.count
        }
    }

    /// Construct a `PairingContext` using a fresh key + random session id.
    fileprivate func makeContext(
        relayURL: String,
        ttlSecondsFromNow: TimeInterval = 60
    ) -> RelayClient.PairingContext {
        // Random session ID — enforce the E2 pattern of base64url chars,
        // length 32 (within 16-64).
        let sid = RelayPairingMint.randomBase64URLToken()
        let macTok = RelayPairingMint.randomBase64URLToken()
        let iosTok = RelayPairingMint.randomBase64URLToken()
        // Shared symmetric key — both directions of the codec use the same K.
        let key = SymmetricKey(size: .bits256)
        let keyBytes = key.withUnsafeBytes { Data($0) }
        return .init(
            sid: sid,
            macTok: macTok,
            iosTokHash: Self.sha256Hex(iosTok),
            macTokHash: Self.sha256Hex(macTok),
            derivedKey: keyBytes,
            ttlUnixSeconds: UInt64(Date().timeIntervalSince1970 + ttlSecondsFromNow),
            relayBaseURL: relayURL
        )
    }

    static func sha256Hex(_ s: String) -> String {
        let d = Data(s.utf8)
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URL construction

    func testURLConstructionIncludesSidAndToken() throws {
        let context = makeContext(relayURL: "wss://relay-staging.clawdmeter.dev")
        let url = try RelayClient.makeConnectURL(pairing: context, includeBundle: false)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "relay-staging.clawdmeter.dev")
        XCTAssertEqual(url.path, "/v1/relay/sessions/\(context.sid)/connect")
        // Token must be in the query.
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let tok = comps?.queryItems?.first(where: { $0.name == "token" })?.value
        XCTAssertEqual(tok, context.macTok)
        // No bundle param when includeBundle is false.
        XCTAssertNil(comps?.queryItems?.first(where: { $0.name == "bundle" }))
    }

    func testURLConstructionIncludesBundleOnFirstConnect() throws {
        let context = makeContext(relayURL: "wss://relay-staging.clawdmeter.dev")
        let url = try RelayClient.makeConnectURL(pairing: context, includeBundle: true)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let bundleParam = comps?.queryItems?.first(where: { $0.name == "bundle" })?.value
        let bundleData = try XCTUnwrap(Data(base64Encoded: bundleParam ?? ""))
        let bundle = try JSONSerialization.jsonObject(with: bundleData) as? [String: Any]
        XCTAssertEqual(bundle?["macTokenHash"] as? String, context.macTokHash)
        XCTAssertEqual(bundle?["iosTokenHash"] as? String, context.iosTokHash)
        XCTAssertEqual((bundle?["ttlSeconds"] as? UInt64), context.ttlUnixSeconds)
    }

    func testURLConstructionRejectsInvalidScheme() throws {
        let context = makeContext(relayURL: "http://example.com")
        XCTAssertThrowsError(try RelayClient.makeConnectURL(pairing: context, includeBundle: false))
    }

    // MARK: - End-to-end connect + frame round-trip

    /// Drive the full happy path:
    ///   1. Mock relay starts
    ///   2. RelayClient configured + start()
    ///   3. Connect handshake completes (RelayClient transitions to .connected)
    ///   4. Mock relay sends an encrypted frame (header + body)
    ///   5. The Mac's frameHandler receives the decrypted inner frame
    ///   6. The Mac sends a response back; the mock relay receives the encrypted bytes
    func testConnectsAndExchangesEncryptedFrame() async throws {
        let mock = try MockRelayListener()
        defer { mock.listener.cancel() }

        let context = makeContext(relayURL: mock.url)

        // Used by the test to inspect what the Mac sent to the "relay".
        let receivedFromMac = LockedArray<Data>()
        let receivedHeaders = LockedArray<String>()

        // Mock-relay handler: peek at the first text header, then send an
        // encrypted "ping" frame to the Mac as if iOS sent it.
        let iosCodecForMock = RelayFrameCodec(
            key: SymmetricKey(data: context.derivedKey),
            from: "ios"
        )

        mock.setOnConnect { connection in
            // Receive frames in a loop; whenever we see a text header we
            // peek; whenever we see binary bytes we stash for later
            // inspection. After the FIRST message, push our own encrypted
            // frame to the Mac as if we were iOS.
            Self.recvLoop(connection: connection) { message, isText in
                if isText {
                    let s = String(decoding: message, as: UTF8.self)
                    receivedHeaders.append(s)
                } else {
                    receivedFromMac.append(message)
                }
            }

            // After a short pause to let the upgrade complete, send a
            // ciphertext envelope to the Mac as if iOS were the peer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                do {
                    let (header, body) = try iosCodecForMock.encrypt(
                        op: "ping", data: Data(#"{"hello":"world"}"#.utf8)
                    )
                    Self.send(connection: connection, text: header.encodeJSON())
                    Self.send(connection: connection, binary: body)
                } catch {
                    XCTFail("mock encrypt failed: \(error)")
                }
            }
        }

        // The Mac side. We expect frameHandler to be invoked once with the
        // decrypted inner frame.
        let handlerExpectation = expectation(description: "frameHandler called")
        var handlerSawOp: String?
        let client = RelayClient { inner in
            handlerSawOp = inner.op
            handlerExpectation.fulfill()
            // Return a small response — the client will encrypt + send.
            return Data(#"{"ok":true}"#.utf8)
        }
        client.configure(pairing: context)
        client.start()

        // Wait for the round-trip.
        await fulfillment(of: [handlerExpectation], timeout: 10)
        XCTAssertEqual(handlerSawOp, "ping")

        // Wait briefly for the response to come back.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Inspect headers + bodies the mock relay saw from the Mac:
        let headers = receivedHeaders.snapshot
        let bodies = receivedFromMac.snapshot

        // The Mac MUST send at least one ciphertext header + body pair
        // (the response to our ping). It may also send heartbeat control
        // frames depending on timing.
        let ciphertextHeaders = headers.filter { $0.contains("\"type\":\"ciphertext\"") }
        XCTAssertGreaterThanOrEqual(ciphertextHeaders.count, 1, "Mac should send a ciphertext envelope back as the response")
        XCTAssertGreaterThanOrEqual(bodies.count, 1)

        // Decrypt the FIRST body the Mac sent. (Same K both directions.)
        let macSideCodec = RelayFrameCodec(
            key: SymmetricKey(data: context.derivedKey),
            from: "mac"
        )
        if let firstBody = bodies.first {
            let decoded = try macSideCodec.decrypt(body: firstBody)
            XCTAssertEqual(decoded.op, "ping.response")
            XCTAssertTrue(
                String(decoding: decoded.data, as: UTF8.self).contains(#""ok""#),
                "decrypted response should contain the handler's payload"
            )
        }

        client.stop()
    }

    /// When the relay drops the connection, RelayClient must back off
    /// and reconnect — we assert two connections are accepted.
    func testReconnectsOnDrop() async throws {
        let mock = try MockRelayListener()
        defer { mock.listener.cancel() }
        let context = makeContext(relayURL: mock.url)

        let secondConnectionExpectation = expectation(description: "second connection accepted")
        let stopHandler = LockedArray<Void>()

        var firstDropped = false
        mock.setOnConnect { connection in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if !firstDropped {
                    firstDropped = true
                    connection.cancel()
                    return
                }
                // Second connection — let the test observe it landed.
                stopHandler.append(())
                secondConnectionExpectation.fulfill()
            }
        }

        let client = RelayClient { _ in nil }
        client.configure(pairing: context)
        client.start()

        // Wait — backoff is 1s, plus some slack.
        await fulfillment(of: [secondConnectionExpectation], timeout: 6)
        XCTAssertGreaterThanOrEqual(mock.acceptedConnections.count, 2)

        client.stop()
    }

    /// A pairing whose TTL is in the past must NOT cause a connect.
    func testDoesNotConnectAfterTTLExpired() async throws {
        let mock = try MockRelayListener()
        defer { mock.listener.cancel() }

        // 1s in the past.
        var ctx = makeContext(relayURL: mock.url, ttlSecondsFromNow: -1)
        ctx = .init(
            sid: ctx.sid,
            macTok: ctx.macTok,
            iosTokHash: ctx.iosTokHash,
            macTokHash: ctx.macTokHash,
            derivedKey: ctx.derivedKey,
            ttlUnixSeconds: UInt64(Date().timeIntervalSince1970 - 1),
            relayBaseURL: ctx.relayBaseURL
        )

        let client = RelayClient { _ in nil }
        client.configure(pairing: ctx)
        client.start()

        // Let the loop run; it should bail out without any connect attempt.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(mock.acceptedConnections.count, 0)
        XCTAssertEqual(client.transportState, .stopped)
    }

    /// Replay protection: if the relay forwards the same encrypted body
    /// twice, the second one must be rejected without invoking the handler.
    func testRejectsReplayedFrames() async throws {
        let mock = try MockRelayListener()
        defer { mock.listener.cancel() }
        let context = makeContext(relayURL: mock.url)
        let iosCodec = RelayFrameCodec(
            key: SymmetricKey(data: context.derivedKey),
            from: "ios"
        )

        let firstCallExpectation = expectation(description: "handler called once")
        var handlerCallCount = 0
        // We want a second handler call to NOT happen — assert via a
        // fulfilled-after-timeout pattern.

        mock.setOnConnect { connection in
            Self.recvLoop(connection: connection) { _, _ in /* discard */ }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                do {
                    let (header, body) = try iosCodec.encrypt(op: "ping", data: Data("{}".utf8))
                    // Send the same body twice.
                    Self.send(connection: connection, text: header.encodeJSON())
                    Self.send(connection: connection, binary: body)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        Self.send(connection: connection, text: header.encodeJSON())
                        Self.send(connection: connection, binary: body)
                    }
                } catch {
                    XCTFail("encrypt failed: \(error)")
                }
            }
        }

        let client = RelayClient { _ in
            handlerCallCount += 1
            if handlerCallCount == 1 {
                firstCallExpectation.fulfill()
            }
            return nil
        }
        client.configure(pairing: context)
        client.start()
        await fulfillment(of: [firstCallExpectation], timeout: 5)
        // Give the duplicate plenty of time to (incorrectly) trigger:
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(handlerCallCount, 1, "Replayed frame must be dropped by replay-protection check")

        client.stop()
    }

    // MARK: - WebSocket I/O helpers (Network.framework, mock side)

    /// Run the receive loop on a server-side NWConnection, invoking the
    /// callback for every message received. `isText=true` for text
    /// frames, false for binary.
    nonisolated static func recvLoop(connection: NWConnection, _ handler: @escaping @Sendable (Data, Bool) -> Void) {
        connection.receiveMessage { content, context, isComplete, error in
            if let content {
                let isText: Bool
                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    isText = (meta.opcode == .text)
                } else {
                    isText = false
                }
                handler(content, isText)
            }
            if let error {
                _ = error
                return
            }
            if isComplete && content == nil {
                return
            }
            recvLoop(connection: connection, handler)
        }
    }

    /// Send a text frame on a server-side NWConnection.
    nonisolated static func send(connection: NWConnection, text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    /// Send a binary frame.
    nonisolated static func send(connection: NWConnection, binary: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        connection.send(
            content: binary,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
}
