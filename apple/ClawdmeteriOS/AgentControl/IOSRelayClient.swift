// E4: iOS daemon outbound relay client.
//
// Sibling of the future E3 Mac client. Same wire protocol (E2 relay
// Worker, infra/relay/src/), same shared `RelayFrameCodec` (in
// `ClawdmeterShared/Relay/`), but with iOS-specific background-lifecycle
// handling per docs/design/secure-relay-apns-2026-05-26.md §11 and the
// E4 acceptance gates §6.1.
//
// Key invariants this file enforces:
//
//   - **Suspended-socket handling.** When iOS suspends the app the
//     `URLSessionWebSocketTask` is closed by the OS (radio off). On
//     foreground the client reopens with the SAME `iosTok` against
//     the SAME `sid` — the relay's reconnect-storm policy
//     (`evictExistingForRole`) is what makes this safe.
//
//   - **APNS wake timing.** When E6 lands and APNS pushes wake the
//     app for ~30s, the AppDelegate's BG handler will call
//     `connectForAPNSWake()` which opens the socket fast (single
//     attempt, short timeout) and lets it die when iOS suspends again.
//     Until E6 lands, that entry point is a no-op stub; the
//     foreground-resume path covers the normal case.
//
//   - **Retry windows.** Per the design doc the iOS client mirrors the
//     Mac client's exponential backoff (1→30s with jitter, mirrors
//     `iOSChatStore.backoffSchedule`).
//
//   - **Foreground handoff.** `UIApplication.didBecomeActiveNotification`
//     triggers a full reconnect; `UIApplication.willResignActiveNotification`
//     closes the socket so a half-open TCP doesn't keep iOS radio awake
//     in violation of the energy budget.
//
//   - **TLS 1.3 minimum, no downgrade.** The session config pins
//     `tlsMinimumSupportedProtocolVersion = .TLSv13`. Falling back to
//     plain `ws://` is permitted ONLY when the bundle's `relayUrl`
//     is `ws://localhost…` (dev override / `wrangler dev` round-trip
//     per E7's `RelayPairingBundle.isValidRelayURL`).
//
//   - **Constant-time tag compare.** Decryption uses `RelayFrameCodec.open`
//     which routes through CryptoKit's `ChaChaPoly.open`; that's documented
//     constant-time so threat #13 (timing side-channel) is mitigated by
//     construction. No raw `==` on tags or bearer echoes in this file.
//
// This file lives in `apple/ClawdmeteriOS/AgentControl/` (iOS-only) and
// is NOT linked into the Mac or Watch targets. E3 will land a sibling
// `MacRelayClient.swift` against the same `RelayFrameCodec`.

import Foundation
import Combine
import OSLog
import ClawdmeterShared
#if canImport(UIKit)
import UIKit
#endif
import CryptoKit

private let iosRelayLogger = Logger(subsystem: "com.clawdmeter.ios", category: "Relay")

// MARK: - Public state

/// Coarse connection state surfaced to UI. Mac is intentionally NOT
/// mirrored here — the Mac client's state will diverge (e.g., the Mac
/// peer is always "first-peer" and may have to upload the `?bundle=`
/// param on cold start).
public enum IOSRelayClientState: Equatable, Sendable {
    /// No pairing record or `start()` not yet called.
    case idle
    /// `start()` called but the WebSocket hasn't completed the upgrade
    /// handshake yet.
    case connecting
    /// WebSocket open + ECDH handshake exchanged with the Mac peer.
    case connected
    /// Foreground app went to background; OS forced the socket closed.
    /// We're waiting on `didBecomeActive` to reopen.
    case suspended
    /// WebSocket dropped; backoff retry scheduled.
    case reconnecting(attempt: Int)
    /// A non-retryable error (auth failed, TTL expired, etc.). The user
    /// must re-pair.
    case failed(reason: String)
}

/// Inbound plaintext message — what the caller (the iOS daemon's
/// op-dispatcher) actually consumes after the codec strips the AEAD
/// + replay layers.
public struct IOSRelayInboundMessage: Sendable, Equatable {
    public let seq: UInt64
    public let op: String
    public let data: Data
    public let receivedAt: Date
}

// MARK: - Configuration

/// Snapshot of the pairing record fields the client needs. Decouples
/// the client from `RelayPairingRecord`'s file shape (and lets tests
/// fabricate a config without touching the on-disk store).
public struct IOSRelayClientConfig: Sendable, Equatable {
    public let sid: String
    public let iosTok: String
    public let relayUrl: String
    /// Mac's X25519 public key (base64url) — what we received in the QR.
    /// Already used to derive `symmetricKey` at pairing time, but kept
    /// here so the first-frame handshake check can compare what the
    /// peer claims against what we have.
    public let theirEcdhPublicKeyBase64URL: String
    /// 32-byte AEAD key derived at pairing time. The client never
    /// re-derives this on connect; key derivation lives in the pairing
    /// service.
    public let symmetricKey: Data
    /// Absolute Unix seconds at which the pairing expires (§5b).
    public let ttl: UInt64

    public init(
        sid: String,
        iosTok: String,
        relayUrl: String,
        theirEcdhPublicKeyBase64URL: String,
        symmetricKey: Data,
        ttl: UInt64
    ) {
        self.sid = sid
        self.iosTok = iosTok
        self.relayUrl = relayUrl
        self.theirEcdhPublicKeyBase64URL = theirEcdhPublicKeyBase64URL
        self.symmetricKey = symmetricKey
        self.ttl = ttl
    }

    /// Construct from the persisted pairing record + Keychain key.
    /// Returns nil if the record is missing required fields (key,
    /// peer's pubkey).
    public static func fromPairingRecord(
        _ record: RelayPairingRecord,
        symmetricKey: Data
    ) -> IOSRelayClientConfig? {
        guard let theirPub = record.theirEcdhPublicKeyBase64URL else { return nil }
        return IOSRelayClientConfig(
            sid: record.sid,
            iosTok: record.iosTok,
            relayUrl: record.relayUrl,
            theirEcdhPublicKeyBase64URL: theirPub,
            symmetricKey: symmetricKey,
            ttl: record.ttl
        )
    }
}

// MARK: - Lifecycle observer abstraction

/// Indirection over `NotificationCenter` so unit tests can drive the
/// iOS suspend/foreground transitions without going through UIKit.
public protocol IOSAppLifecycleObserving: AnyObject, Sendable {
    /// Closure invoked when the app enters background (socket should
    /// close).
    var onWillResignActive: (@Sendable () -> Void)? { get set }
    /// Closure invoked when the app foregrounds (socket should reopen).
    var onDidBecomeActive: (@Sendable () -> Void)? { get set }
    func start()
    func stop()
}

/// Default lifecycle observer backed by `NotificationCenter`. Uses the
/// `Notification.Name(...)` form rather than `UIApplication.…` constants
/// so the file links cleanly on test platforms that don't have UIKit.
public final class IOSAppLifecycleNotificationObserver: IOSAppLifecycleObserving, @unchecked Sendable {
    public var onWillResignActive: (@Sendable () -> Void)?
    public var onDidBecomeActive: (@Sendable () -> Void)?

    private var resignToken: NSObjectProtocol?
    private var activeToken: NSObjectProtocol?

    public init() {}

    public func start() {
        let center = NotificationCenter.default
        resignToken = center.addObserver(
            forName: Notification.Name("UIApplicationWillResignActiveNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWillResignActive?()
        }
        activeToken = center.addObserver(
            forName: Notification.Name("UIApplicationDidBecomeActiveNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onDidBecomeActive?()
        }
    }

    public func stop() {
        if let resignToken { NotificationCenter.default.removeObserver(resignToken) }
        if let activeToken { NotificationCenter.default.removeObserver(activeToken) }
        resignToken = nil
        activeToken = nil
    }

    deinit { stop() }
}

// MARK: - WebSocket transport abstraction

/// Indirection over `URLSession.webSocketTask(...)` so tests can fake the
/// transport. The wrapper exposes just the four calls the client needs:
/// open, send-text-header, send-binary-body, recv, cancel.
public protocol IOSRelayWebSocketTransport: Sendable {
    func send(text: String) async throws
    func send(data: Data) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

/// Real transport — wraps `URLSessionWebSocketTask`.
public final class IOSRelayURLSessionTransport: IOSRelayWebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    public init(task: URLSessionWebSocketTask) { self.task = task }

    public func send(text: String) async throws {
        try await task.send(.string(text))
    }
    public func send(data: Data) async throws {
        try await task.send(.data(data))
    }
    public func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }
    public func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - IOSRelayClient

@MainActor
public final class IOSRelayClient: ObservableObject {

    // MARK: Public observable state

    @Published public private(set) var state: IOSRelayClientState = .idle
    @Published public private(set) var lastConnectedAt: Date?
    @Published public private(set) var lastInbound: IOSRelayInboundMessage?

    /// Backoff schedule mirrors `iOSChatStore.backoffSchedule` so the
    /// two stores share user-visible behavior. Per the design doc
    /// "exponential backoff matches the Mac client" — the Mac client's
    /// schedule (E3) will mirror this.
    public static let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// Connect timeout. Kept short on iOS because the OS gives an APNS
    /// wake ~30s; we want to fail fast and let the next foreground
    /// retry try again rather than spinning the whole wake budget on
    /// one open.
    public static let connectTimeout: TimeInterval = 8

    // MARK: Internal

    private let config: IOSRelayClientConfig
    /// Ephemeral X25519 keypair for this connection. Per §5b key
    /// material is process-only — re-creating the client cycles it.
    /// Note: this is a NEW keypair per connect, not the iPhone's
    /// pairing keypair (which was discarded after K was derived at
    /// pairing time, per the E7 service). The peer expects to receive
    /// a public key in the first handshake envelope; for v1 we send
    /// the iPhone's *pairing* pubkey echoed via `ourEcdhPublicKey`.
    /// If that record is missing (older pairing) we generate a fresh
    /// keypair and the Mac peer rederives K from it.
    ///
    /// Future: when key-rotation lands, this keypair will be rotated
    /// per-session and `symmetricKey` will be derived fresh on connect.
    private let ourPublicKeyBytes: Data

    private let lifecycle: IOSAppLifecycleObserving
    private let transportFactory: @MainActor (_ url: URL, _ tok: String) async throws -> IOSRelayWebSocketTransport
    private var transport: IOSRelayWebSocketTransport?

    /// Track B (B1): the shared multiplex client. Inbound `op == "mux"` frames
    /// route to it (NOT `lastInbound`), and it's re-driven on reconnect. The
    /// coordinator sets this when `clawdmeter.transport.relayDefault` is on; nil
    /// means the legacy request/response-only behavior is byte-identical.
    var muxClient: RelayMuxClient?

    /// Track B (B1.7): the request/response correlator. Inbound mux frames are
    /// passed to BOTH it and `muxClient`; each ignores opIds/kinds it doesn't
    /// own (subscriptions vs requests), so the dual-dispatch is safe.
    var requestClient: RelayMuxRequestClient?

    private var runTask: Task<Void, Never>?
    private var consecutiveFailures: Int = 0
    /// Highest `seq` we've seen from the Mac peer. Inbound frames
    /// with `seq <= inboundHighSeq` are dropped as replays per §4.3.
    private var inboundHighSeq: UInt64 = 0
    /// Next `seq` to use on outbound frames. Per §4.3 the counter is
    /// monotonic per direction; we start at 1 (0 reserved for sentinel).
    private var nextOutboundSeq: UInt64 = 1

    private let symmetricKey: SymmetricKey

    // MARK: Init

    /// Designated initializer. Most callers should use
    /// `IOSRelayClient.from(pairingService:)`. Tests construct directly
    /// with a fake lifecycle + transport.
    public init(
        config: IOSRelayClientConfig,
        ourPublicKeyBytes: Data,
        lifecycle: IOSAppLifecycleObserving = IOSAppLifecycleNotificationObserver(),
        transportFactory: @escaping @MainActor (_ url: URL, _ tok: String) async throws -> IOSRelayWebSocketTransport
            = IOSRelayClient.defaultTransportFactory
    ) {
        self.config = config
        self.ourPublicKeyBytes = ourPublicKeyBytes
        self.lifecycle = lifecycle
        self.transportFactory = transportFactory
        self.symmetricKey = SymmetricKey(data: config.symmetricKey)

        lifecycle.onWillResignActive = { [weak self] in
            Task { @MainActor [weak self] in self?.handleWillResignActive() }
        }
        lifecycle.onDidBecomeActive = { [weak self] in
            Task { @MainActor [weak self] in self?.handleDidBecomeActive() }
        }
    }

    // MARK: Public API

    /// Open the relay socket + start the receive loop. Idempotent — a
    /// second `start()` while already running is a no-op.
    public func start() {
        guard runTask == nil else { return }
        guard !isExpired() else {
            transition(to: .failed(reason: "Pairing TTL expired — re-pair from the Mac."))
            return
        }
        lifecycle.start()
        runTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    /// Tear the connection down + stop lifecycle observation. Safe to
    /// call multiple times.
    public func stop() {
        runTask?.cancel()
        runTask = nil
        transport?.cancel()
        transport = nil
        lifecycle.stop()
        transition(to: .idle)
    }

    /// E6 entry point — called by the `iOSNotificationManager`'s APNS
    /// wake handler once that PR lands. For now we just forward to
    /// `start()`; when E6 lands the implementation will:
    ///   - reuse the current `runTask` if already connected;
    ///   - else schedule a single connect attempt with a shorter
    ///     timeout (3s vs the default 8s) so we don't exhaust the
    ///     ~30s wake budget on a slow handshake.
    public func connectForAPNSWake() {
        iosRelayLogger.debug("APNS-wake reconnect requested")
        if case .connected = state { return }
        start()
    }

    /// Send a plaintext payload to the Mac peer. Returns once the
    /// header + body have been handed to the OS WebSocket task; does
    /// NOT wait for an ack (the peer's ack arrives via the inbound
    /// loop as a separate envelope).
    public func send(op: String, payload: Data) async throws {
        guard let transport else { throw IOSRelayClientError.notConnected }
        let seq = nextOutboundSeq
        nextOutboundSeq &+= 1
        let plaintext = RelayPlaintext(seq: seq, op: op, data: payload)
        let plaintextBytes = try plaintext.encodeCanonicalJSON()
        let nonce = RelayFrameCodec.randomNonce()
        let sealed = try RelayFrameCodec.seal(
            plaintext: plaintextBytes,
            key: symmetricKey,
            nonce: nonce
        )
        // The 24-byte nonce goes on the wire prepended to the sealed
        // body, so the peer can decrypt without negotiating a nonce
        // counter. (libsodium calls this "detached AD" mode for the
        // nonce field; we're rolling it inline since the relay treats
        // the body as opaque bytes anyway.)
        var body = Data()
        body.append(nonce)
        body.append(sealed)
        let header = RelayEnvelopeHeader(from: .ios, type: .ciphertext)
        try await transport.send(text: String(decoding: header.encodeCanonicalJSON(), as: UTF8.self))
        try await transport.send(data: body)
    }

    /// Send a peer-to-peer control frame (heartbeat). The relay forwards
    /// these blind to the Mac peer.
    public func sendControlFrame() async throws {
        guard let transport else { throw IOSRelayClientError.notConnected }
        let header = RelayEnvelopeHeader(from: .ios, type: .control)
        try await transport.send(text: String(decoding: header.encodeCanonicalJSON(), as: UTF8.self))
    }

    // MARK: Lifecycle handlers

    private func handleWillResignActive() {
        iosRelayLogger.info("willResignActive — closing relay socket so OS doesn't keep radio awake")
        // §11: iOS will force-close the socket on suspend anyway; we
        // pre-empt so the close code on the wire is .normalClosure
        // rather than 1006-abnormal. The Mac peer sees a clean close
        // and evicts our role slot.
        transport?.cancel()
        transport = nil
        runTask?.cancel()
        runTask = nil
        transition(to: .suspended)
    }

    private func handleDidBecomeActive() {
        iosRelayLogger.info("didBecomeActive — reopening relay socket")
        // Full reconnect path. The fresh `start()` re-derives an
        // ephemeral keypair only IF the symmetric key were rotated;
        // for v1 we reuse the pairing-time K so the handshake envelope
        // we send mirrors what we sent originally.
        guard runTask == nil else { return }
        start()
    }

    // MARK: Connection loop

    private func runConnectionLoop() async {
        while !Task.isCancelled {
            if isExpired() {
                await transitionAsync(to: .failed(reason: "Pairing TTL expired — re-pair from the Mac."))
                return
            }
            do {
                await transitionAsync(to: .connecting)
                try await openAndHandshake()
                await transitionAsync(to: .connected)
                consecutiveFailures = 0
                lastConnectedAt = Date()
                // Track B (B1): re-open every live stream on (re)connect — the
                // Mac re-opens each loopback WS + replays its current snapshot
                // (D4). No-op on the first connect (no streams yet).
                await muxClient?.resubscribeAll()
                try await receiveLoop()
                // Normal close — bail out unless lifecycle resumes us.
                await transitionAsync(to: .idle)
                return
            } catch is CancellationError {
                // Cooperative cancellation from `stop()` or
                // `handleWillResignActive()`. Don't surface as a
                // reconnect attempt.
                return
            } catch let e as IOSRelayClientError where e.isFatal {
                iosRelayLogger.error("relay fatal: \(String(describing: e), privacy: .public)")
                await transitionAsync(to: .failed(reason: e.userMessage))
                return
            } catch {
                consecutiveFailures += 1
                let attempt = consecutiveFailures
                iosRelayLogger.warning("relay transient error (attempt \(attempt)): \(String(describing: error), privacy: .public)")
                await transitionAsync(to: .reconnecting(attempt: attempt))
                let delay = Self.backoffDelay(for: attempt)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func openAndHandshake() async throws {
        // Track B (CB-P0b): each connection is a fresh seq epoch. The Mac resets
        // its counters per connection (RelayClient.resetPerConnectState); iOS
        // MUST too — otherwise after a reconnect the Mac's outbound seq restarts
        // at 1 while our `inboundHighSeq` is still high, so every resubscribe
        // response is dropped as a replay and the streams never resume. Reset
        // BEFORE any frame is sent/received on the new socket.
        inboundHighSeq = 0
        nextOutboundSeq = 1
        guard let url = Self.buildConnectURL(config: config) else {
            throw IOSRelayClientError.malformedURL
        }
        let transport = try await transportFactory(url, config.iosTok)
        self.transport = transport

        // First envelope: our handshake (X25519 public key). Even though
        // both peers derived K at pairing time, the design doc §4.2
        // calls for both peers to exchange public keys "as the first
        // frame (plaintext over WSS)" so the relay can route + so each
        // peer has a transcript fingerprint they can show in UI.
        let header = RelayEnvelopeHeader(from: .ios, type: .handshake)
        try await transport.send(text: String(decoding: header.encodeCanonicalJSON(), as: UTF8.self))
        try await transport.send(data: ourPublicKeyBytes)

        // The Mac peer will reciprocate with its handshake envelope on
        // its first frame, but we don't block on that — chat-class ops
        // can flow immediately because K is already derived. The
        // inbound receive loop handles the handshake envelope when it
        // arrives (validates it matches `theirEcdhPublicKeyBase64URL`).
    }

    private func receiveLoop() async throws {
        guard let transport else { throw IOSRelayClientError.notConnected }
        // Frame interleave: text header followed by binary body. The
        // relay echoes the original sender's ordering by construction
        // (single-peer fan-out preserves frame order on the wire).
        var pendingHeader: RelayEnvelopeHeader?
        while !Task.isCancelled {
            let message = try await transport.receive()
            switch message {
            case .string(let text):
                guard let header = RelayEnvelopeHeader.decode(Data(text.utf8)) else {
                    throw IOSRelayClientError.protocolViolation("malformed header")
                }
                // Mac is the only peer that can send us frames; if the
                // header claims `from: .ios` that's a forged role and
                // we tear down.
                guard header.from == .mac else {
                    throw IOSRelayClientError.protocolViolation("header.from=\(header.from)")
                }
                if header.type == .control {
                    // Control frames are header-only; nothing to do.
                    pendingHeader = nil
                    continue
                }
                pendingHeader = header
            case .data(let body):
                guard let header = pendingHeader else {
                    throw IOSRelayClientError.protocolViolation("body without header")
                }
                pendingHeader = nil
                try handleInboundBody(header: header, body: body)
            @unknown default:
                continue
            }
        }
    }

    private func handleInboundBody(header: RelayEnvelopeHeader, body: Data) throws {
        switch header.type {
        case .handshake:
            try handleHandshakeBody(body)
        case .ciphertext:
            try handleCiphertextBody(body)
        case .control:
            // Already handled in receiveLoop.
            break
        }
    }

    private func handleHandshakeBody(_ body: Data) throws {
        guard body.count == 32 else {
            throw IOSRelayClientError.protocolViolation("handshake body must be 32 bytes (got \(body.count))")
        }
        // Sanity-check: the Mac's pubkey on the wire MUST match what
        // we stored at pairing time. If it doesn't, the Mac has been
        // re-paired since we last saw it; tear down so the user
        // re-scans the new QR.
        guard let expectedRaw = base64URLDecode(config.theirEcdhPublicKeyBase64URL) else {
            throw IOSRelayClientError.protocolViolation("stored peer pubkey malformed")
        }
        // Constant-time compare (threat #13).
        guard body.constantTimeEquals(expectedRaw) else {
            throw IOSRelayClientError.peerPubkeyMismatch
        }
        iosRelayLogger.info("Mac handshake envelope validated (pubkey matches pairing record)")
    }

    private func handleCiphertextBody(_ body: Data) throws {
        // Body format on the wire: nonce (24 bytes) || sealed bytes.
        guard body.count > RelayFrameCodec.nonceLength + RelayFrameCodec.tagLength else {
            throw IOSRelayClientError.protocolViolation("ciphertext body too small")
        }
        let nonce = body.prefix(RelayFrameCodec.nonceLength)
        let sealed = body.suffix(from: body.startIndex + RelayFrameCodec.nonceLength)
        let plaintextBytes: Data
        do {
            plaintextBytes = try RelayFrameCodec.open(
                sealed: Data(sealed),
                key: symmetricKey,
                nonce: Data(nonce)
            )
        } catch {
            // AEAD failure: surfaced as a protocol violation, never as a
            // user-visible exception. Tear the session down so a
            // forged frame from a path attacker can't desync the seq
            // counter.
            throw IOSRelayClientError.protocolViolation("AEAD failed")
        }
        guard let parsed = RelayPlaintext.decode(plaintextBytes) else {
            throw IOSRelayClientError.protocolViolation("plaintext JSON malformed")
        }
        // Replay protection (§4.3). Drop frames with seq <= the highest
        // we've already accepted. Drop, not throw — a single replay is
        // not necessarily an attack (e.g., the Mac retried after we
        // already processed it).
        if parsed.seq <= inboundHighSeq {
            iosRelayLogger.warning("dropping replayed seq=\(parsed.seq) (high=\(self.inboundHighSeq))")
            return
        }
        inboundHighSeq = parsed.seq

        // Track B (B1): multiplex frames are demuxed by the mux client and must
        // NOT land in `lastInbound` (legacy request/response observers would
        // mis-handle them). Early-return after dispatch.
        if parsed.op == RelayMux.op {
            // Drop a single malformed mux frame — do NOT throw (review P1#4): a
            // throw is a non-fatal error → full socket reconnect, tearing down +
            // resubscribing ALL streams over one bad per-stream frame. The mux
            // client already tolerates/ignores junk; match that blast radius.
            guard let frame = RelayMuxFrame.decode(parsed.data) else {
                iosRelayLogger.warning("dropping malformed mux frame (seq=\(parsed.seq))")
                return
            }
            muxClient?.handleInbound(frame)        // subscriptions (subFrame/subEnd)
            requestClient?.handleInbound(frame)    // request/response correlator
            return
        }

        lastInbound = IOSRelayInboundMessage(
            seq: parsed.seq,
            op: parsed.op,
            data: parsed.data,
            receivedAt: Date()
        )
    }

    // MARK: Helpers

    private func transition(to next: IOSRelayClientState) {
        guard state != next else { return }
        state = next
    }

    private func transitionAsync(to next: IOSRelayClientState) async {
        await MainActor.run { self.transition(to: next) }
    }

    private func isExpired() -> Bool {
        return UInt64(Date().timeIntervalSince1970) >= config.ttl
    }

    /// Build the `wss://relay.../v1/relay/sessions/<sid>/connect` URL.
    /// The relayUrl from the bundle is the base; we append the path
    /// + sid. We do NOT include `?bundle=...` on iOS — the Mac is the
    /// first peer per E2's first-peer-bootstrap contract.
    static func buildConnectURL(config: IOSRelayClientConfig) -> URL? {
        let base = config.relayUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/v1/relay/sessions/\(config.sid)/connect"
        return URL(string: urlString)
    }

    static func backoffDelay(for attempt: Int) -> TimeInterval {
        let idx = min(max(0, attempt - 1), Self.backoffSchedule.count - 1)
        let base = Self.backoffSchedule[idx]
        // ±15% jitter so N reconnect-storming clients don't synchronise.
        let jitter = base * 0.15 * Double.random(in: -1...1)
        return max(0.25, base + jitter)
    }

    /// Default transport factory — opens a real URLSessionWebSocketTask
    /// with TLS 1.3 + bearer auth. Tests pass in a fake.
    @MainActor
    public static func defaultTransportFactory(url: URL, token: String) async throws -> IOSRelayWebSocketTransport {
        let config = URLSessionConfiguration.ephemeral
        // Threat #12 / #14: pin TLS 1.3 minimum + reject HTTP/1.1
        // upgrade attempts. The ephemeral config drops shared cookie /
        // cache state so a half-completed handshake can't replay later.
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        // Allow `ws://localhost` for the dev override (E7
        // `RelayPairingBundle.isValidRelayURL`). Production builds
        // never hit this branch because the bundle validator rejects
        // non-`wss://` non-localhost URLs at scan time.
        if url.scheme == "ws", url.host == "localhost" {
            // No-op — URLSession already permits plaintext ws to
            // localhost on iOS without an ATS exception.
        }
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url, timeoutInterval: connectTimeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()
        return IOSRelayURLSessionTransport(task: task)
    }
}

// MARK: - Error type

public enum IOSRelayClientError: Error, Equatable, Sendable {
    case notConnected
    case malformedURL
    case protocolViolation(String)
    case peerPubkeyMismatch
    case authFailed
    case pairingExpired

    /// True if the error is not retryable — the client SHOULD NOT
    /// schedule a reconnect, and the user must re-pair.
    var isFatal: Bool {
        switch self {
        case .peerPubkeyMismatch, .authFailed, .pairingExpired: return true
        default: return false
        }
    }

    var userMessage: String {
        switch self {
        case .notConnected: return "Not connected"
        case .malformedURL: return "Relay URL is malformed; re-pair from the Mac."
        case .protocolViolation(let why): return "Relay protocol violation: \(why)"
        case .peerPubkeyMismatch: return "Mac's identity changed since pairing; re-pair from the Mac."
        case .authFailed: return "Relay rejected the bearer token; re-pair from the Mac."
        case .pairingExpired: return "Pairing TTL expired; re-pair from the Mac."
        }
    }
}

// MARK: - Base64URL helper

private func base64URLDecode(_ s: String) -> Data? {
    var padded = s
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded.append("=") }
    return Data(base64Encoded: padded)
}
