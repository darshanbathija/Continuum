// E3: Mac daemon outbound relay client.
//
// Sibling of the iOS client (E4 / PR #177). Both speak the same wire
// protocol — the canonical `RelayFrameCodec` envelope (header text +
// binary body) defined in `ClawdmeterShared/Relay/RelayFrameCodec.swift`.
// This file is the Mac-specific half: it dials the E2 relay Worker
// (infra/relay), drives the handshake-on-open + ciphertext-after-K
// state machine per docs/design/secure-relay-apns-2026-05-26.md §4 and
// translates inbound encrypted frames into HTTP requests against the
// in-process `AgentControlServer` via the loopback dispatcher.
//
// What the original E3 (PR #179) got wrong + what this respin fixes:
//
//   - PR #179 shipped a *duplicate* codec at
//     `ClawdmeterShared/RelayPairing/RelayFrameCodec.swift` with a
//     different wire shape (single-frame `nonce || ct`). E4 (PR #177)
//     then landed the CANONICAL header+body envelope per design §4 —
//     which is what the deployed E2 Worker actually expects. This file
//     reuses that canonical codec verbatim; no duplicate.
//
//   - PR #179 documented its connect as "provisional K, not the real
//     X25519 shared secret" because the iPhone's pubkey wasn't being
//     consumed. The respin completes the handshake: the inbound
//     handshake envelope (iPhone's X25519 pubkey) is routed into
//     `RelayPairingService.recordPeerHandshake(_:)` which derives the
//     real K via `RelayPairingKeyPair.deriveSharedKey(...)`, persists
//     a `RelayPairingRecord`, and hot-swaps the per-session key on
//     this client. Pre-K only handshake/control frames are accepted;
//     post-K, ciphertext flows.
//
// ## Lifecycle
//
//   idle
//     │  start() — pairing context present, TTL valid
//     ▼
//   connecting
//     │  WebSocket open
//     ▼
//   awaitingPeer (handshake sent, K not yet derived)
//     │  iPhone handshake frame received → K derived → record persisted
//     ▼
//   connected (ciphertext flows; replay-cursor active)
//     │
//     │  drop / cancel / TLS error
//     ▼
//   reconnecting(attempt:)  ── exponential backoff (1, 2, 4, 8, 30s cap)
//     │  start over (fresh transport, but same sid + macTok + keypair —
//     │  the iPhone's pubkey is already in our pairing record so K
//     │  derivation skips on reconnect)
//     ▼
//   connected (again)
//
// ## Why URLSession (vs Network.framework)
//
// Same reasoning as E4's iOS client: `URLSessionWebSocketTask` already
// drives chat-subscribe, terminal, frontier, etc. We reuse it for TLS
// 1.3, ATS policy, and Apple's keepalive logic. Network.framework's
// `NWConnection` exposes lower-level knobs but the relay protocol is
// plain WSS — no benefit to a lower layer.
//
// ## Why heartbeat at 25s
//
// Server-side keepalive (`infra/relay/src/durable-object.ts`'s
// `RelaySession.alarm()`) ticks every 30s. We pre-empt at 25s so a
// half-open NAT translation never goes >30s without traffic in either
// direction. Mirrors E4's iOS cadence + matches the E2 server's
// behavior — the relay forwards control frames blind, so a single
// client-side heartbeat is visible end-to-end.

import Foundation
import OSLog
import Combine
import Security
import ClawdmeterShared
import CryptoKit

private let macRelayLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelayClient")

// MARK: - Observable state

/// Coarse state the Settings UI / `RelayClientCoordinator` binds to.
/// Sibling of `IOSRelayClientState` but **explicitly distinct** because
/// the Mac peer has phases the iOS side never sees:
///   - `awaitingPeer`: socket open, our handshake sent, K not yet
///     derived because the iPhone hasn't connected (or its handshake
///     frame hasn't landed).
///   - `degraded`: >60s without a successful connect attempt. The
///     `AgentControlServer`'s outbound-notification path can read
///     `isReachable` to decide between the relay and Tailscale.
public enum MacRelayClientState: Equatable, Sendable {
    /// No pairing record, or `start()` not yet called.
    case idle
    /// `start()` called; WebSocket handshake in flight.
    case connecting
    /// WebSocket open; we sent our handshake envelope; K not yet
    /// derived (iPhone hasn't sent its pubkey).
    case awaitingPeer
    /// Both sides have K; ciphertext envelopes flow in both directions.
    case connected
    /// Backoff retry scheduled. `attempt` is 1-indexed.
    case reconnecting(attempt: Int)
    /// >60s of failed connects — `AgentControlServer` should prefer
    /// Tailscale until we transition out.
    case degraded
    /// Pairing TTL expired or peer pubkey mismatch — non-retryable.
    /// User must re-pair.
    case failed(reason: String)
    /// Explicitly `stop()`'d.
    case stopped
}

/// Inbound decrypted-and-dispatched envelope. Surfaced for diagnostics
/// + observability (the actual handler is `frameHandler`, which runs
/// inside the client and translates to a loopback HTTP call).
public struct MacRelayInboundMessage: Sendable, Equatable {
    public let seq: UInt64
    public let op: String
    public let data: Data
    public let receivedAt: Date
}

// MARK: - Configuration

public extension RelaySessionCreationProof {

    static func issue(
        signingKey: Data,
        sessionId: String,
        macTokenHash: String,
        iosTokenHash: String,
        ttlSeconds: UInt64,
        issuedAtSeconds: UInt64 = UInt64(Date().timeIntervalSince1970),
        nonce: String? = nil
    ) -> RelaySessionCreationProof {
        let nonceValue = nonce ?? randomNonce()
        let message = [
            "relay-create",
            sessionId,
            macTokenHash,
            iosTokenHash,
            String(ttlSeconds),
            String(issuedAtSeconds),
            nonceValue,
        ].joined(separator: ":")
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: signingKey)
        )
        return RelaySessionCreationProof(
            issuedAtSeconds: issuedAtSeconds,
            nonce: nonceValue,
            signature: base64URLEncode(Data(mac))
        )
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: 0...UInt8.max)
            }
        }
        return base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Snapshot of the pairing record fields the client needs. Decoupled
/// from `RelayPairingBundle` / `RelayPairingRecord` so tests can
/// fabricate a context without touching either.
public struct MacRelayClientConfig: Sendable, Equatable {
    public let sid: String
    /// Our bearer token. Mac always presents `macTok`; the relay
    /// hashes + compares against the stored `macTokenHash` per E2.
    public let macTok: String
    /// SHA-256 hex of our own bearer token. The relay's first-peer
    /// bootstrap (`?bundle=`) sends both hashes — present in case the
    /// session DO hasn't been initialized yet on cold start.
    public let macTokHashHex: String
    /// SHA-256 hex of the iOS peer's bearer token. Mac uploads this
    /// in the `?bundle=` param on first connect; the iPhone never
    /// uploads its own hashes — only presents whatever it scanned.
    public let iosTokHashHex: String
    /// Relay base URL — `wss://relay-staging.clawdmeter.dev` or
    /// `ws://localhost:8787` in dev. Comes from the E7 bundle.
    public let relayUrl: String
    /// Pairing TTL — absolute Unix seconds at which the relay will
    /// reject further connects.
    public let ttl: UInt64
    /// Mac's X25519 public key (32 raw bytes). Sent as our handshake
    /// envelope on every connect so the iPhone can verify against
    /// what it scanned.
    public let ourPublicKeyBytes: Data
    /// Operator-signed grant authorizing first-peer relay session creation.
    /// The Worker refuses unsigned bundles so arbitrary clients cannot create
    /// Durable Object sessions with attacker-chosen bearer hashes.
    public let creationProof: RelaySessionCreationProof?

    public init(
        sid: String,
        macTok: String,
        macTokHashHex: String,
        iosTokHashHex: String,
        relayUrl: String,
        ttl: UInt64,
        ourPublicKeyBytes: Data,
        creationProof: RelaySessionCreationProof? = nil
    ) {
        self.sid = sid
        self.macTok = macTok
        self.macTokHashHex = macTokHashHex
        self.iosTokHashHex = iosTokHashHex
        self.relayUrl = relayUrl
        self.ttl = ttl
        self.ourPublicKeyBytes = ourPublicKeyBytes
        self.creationProof = creationProof
    }

    /// SHA-256 hex of a string. Public so callers (AppRuntime,
    /// integration tests) can construct hashes without re-implementing.
    public static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - WebSocket transport abstraction

/// Indirection over `URLSession.webSocketTask(...)` so tests can drive
/// the socket via a fake. Same shape as E4's iOS transport (deliberately
/// — keeps the test patterns interchangeable).
public protocol MacRelayWebSocketTransport: Sendable {
    func send(text: String) async throws
    func send(data: Data) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

/// Real transport — wraps `URLSessionWebSocketTask`.
public final class MacRelayURLSessionTransport: MacRelayWebSocketTransport, @unchecked Sendable {
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

// MARK: - Pairing-service indirection for the X25519 handshake

/// Indirection over `RelayPairingService.recordPeerHandshake(_:)` so the
/// client can be unit-tested without a live keypair. AppRuntime supplies
/// a real implementation; tests pass a fake that returns a known K.
public protocol MacRelayPairingHandshakeRecorder: AnyObject, Sendable {
    /// Called when the iPhone's pubkey arrives over the relay. The
    /// implementation derives the symmetric key K, persists a pairing
    /// record (so the APNS gateway can find K independently), and
    /// returns K bytes. Returns nil if derivation failed (bad pubkey,
    /// keypair missing) — the client then tears down + reconnects.
    @MainActor
    func recordPeerHandshake(iPhoneEcdhPublicKeyBase64URL: String) -> Data?
}

// MARK: - MacRelayClient

@MainActor
public final class MacRelayClient: ObservableObject {

    // MARK: Public observable state

    @Published public private(set) var state: MacRelayClientState = .idle
    @Published public private(set) var lastConnectedAt: Date?
    @Published public private(set) var lastInbound: MacRelayInboundMessage?
    /// Surfaced for the Settings panel + degraded-state gate.
    @Published public private(set) var lastConnectError: String?

    /// True iff the relay has been reachable recently. `AgentControlServer`'s
    /// outbound-notification logic reads this to choose between relay
    /// and Tailscale.
    public var isReachable: Bool {
        switch state {
        case .connected, .awaitingPeer: return true
        case .connecting, .reconnecting:
            if let last = lastConnectedAt,
               Date().timeIntervalSince(last) < Self.degradedAfterSeconds {
                return true
            }
            return false
        case .idle, .degraded, .failed, .stopped: return false
        }
    }

    // MARK: Configuration

    /// Backoff schedule (seconds). Mirrors the iOS client's
    /// `IOSRelayClient.backoffSchedule` so the two halves have the
    /// same user-visible behavior across a relay outage.
    public static let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// Heartbeat cadence — server-side keepalive ticks 30s; we pre-empt
    /// at 25s so neither side ever sees a >30s quiet stretch.
    public static let heartbeatIntervalSeconds: TimeInterval = 25

    /// After this many seconds of no successful connect, transition to
    /// `.degraded`. `AgentControlServer` prefers Tailscale beyond this.
    public static let degradedAfterSeconds: TimeInterval = 60

    /// Connect timeout. Kept reasonably tight so a stalled DNS doesn't
    /// burn the whole user-perceived "reconnecting…" attempt.
    public static let connectTimeout: TimeInterval = 10

    // MARK: Internal state

    private let config: MacRelayClientConfig
    private weak var pairingService: (any MacRelayPairingHandshakeRecorder)?

    /// Symmetric key — nil until the iPhone's handshake arrives. Once
    /// derived, the codec uses it for every ciphertext frame.
    private var symmetricKey: SymmetricKey?

    /// Highest `seq` we've accepted from the iPhone. Inbound frames
    /// with `seq <= inboundHighSeq` are dropped as replays (§4.3).
    private var inboundHighSeq: UInt64 = 0
    /// Next outbound `seq`. Monotonic per direction, starting at 1
    /// (0 reserved as sentinel).
    private var nextOutboundSeq: UInt64 = 1

    /// Receiver-injectable; set on AppRuntime side after the loopback
    /// dispatcher is constructed. Returns the response bytes the Mac
    /// should encrypt + send back, or nil for fire-and-forget.
    public typealias FrameHandler = @MainActor (MacRelayInboundMessage) async -> Data?
    public var frameHandler: FrameHandler

    /// Track B (review P0#2): invoked when a fresh iPhone handshake is validated
    /// (a new/reconnected iOS peer on this persisted Mac socket). AppRuntime
    /// wires this to tear down the loopback-WS bridge's live streams so the
    /// iOS resubscribe (which reuses the same opIds) re-opens them fresh.
    public var onPeerReconnect: (@MainActor () -> Void)?

    private let transportFactory: @MainActor (_ url: URL, _ token: String) async throws -> MacRelayWebSocketTransport
    private var transport: MacRelayWebSocketTransport?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var consecutiveFailures: Int = 0
    /// First successful connect → bundle param SHOULD ride along; on
    /// reconnects we omit it because the relay's DO already has the
    /// session state.
    private var hasUploadedBundle: Bool = false

    // MARK: Init

    /// Designated initializer. Production callers use
    /// `MacRelayClient.production(config:pairingService:frameHandler:)`;
    /// tests pass a fake transport factory + a fake pairing recorder.
    public init(
        config: MacRelayClientConfig,
        pairingService: any MacRelayPairingHandshakeRecorder,
        frameHandler: @escaping FrameHandler,
        transportFactory: @escaping @MainActor (_ url: URL, _ token: String) async throws -> MacRelayWebSocketTransport
            = MacRelayClient.defaultTransportFactory
    ) {
        self.config = config
        self.pairingService = pairingService
        self.frameHandler = frameHandler
        self.transportFactory = transportFactory
    }

    // MARK: Public API

    /// Open the relay socket + start the connect/reconnect loop.
    /// Idempotent — a second `start()` while already running is a no-op.
    public func start() {
        guard runTask == nil else { return }
        guard !isExpired() else {
            transition(to: .failed(reason: "Pairing TTL expired — re-pair from the Mac."))
            return
        }
        macRelayLogger.info("RelayClient starting (sid=\(self.config.sid.prefix(8), privacy: .public)…)")
        runTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    /// Tear down the connection + cancel all pending work. Safe to call
    /// multiple times.
    public func stop() {
        macRelayLogger.info("RelayClient stop()")
        runTask?.cancel()
        runTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        transport?.cancel()
        transport = nil
        transition(to: .stopped)
    }

    /// Send an encrypted op to the iPhone. Throws if the socket is
    /// down or K hasn't been derived yet (pre-handshake sends are
    /// nonsensical — the peer can't decrypt).
    public func send(op: String, payload: Data) async throws {
        guard let transport else { throw MacRelayClientError.notConnected }
        guard let key = symmetricKey else { throw MacRelayClientError.notHandshaked }
        let seq = nextOutboundSeq
        nextOutboundSeq &+= 1
        let plaintext = RelayPlaintext(seq: seq, op: op, data: payload)
        let plaintextBytes = try plaintext.encodeCanonicalJSON()
        let nonce = RelayFrameCodec.randomNonce()
        let sealed = try RelayFrameCodec.seal(
            plaintext: plaintextBytes,
            key: key,
            nonce: nonce
        )
        // Body shape on the wire: 24-byte nonce || sealed. Matches the
        // iOS client (E4) — both sides agree on this prepend so the
        // peer can recover the nonce without out-of-band negotiation.
        var body = Data()
        body.append(nonce)
        body.append(sealed)
        let header = RelayEnvelopeHeader(from: .mac, type: .ciphertext)
        try await transport.send(text: String(decoding: header.encodeCanonicalJSON(), as: UTF8.self))
        try await transport.send(data: body)
    }

    /// Send a header-only control frame (heartbeat). The relay
    /// forwards these blind to the iPhone.
    public func sendControlFrame() async throws {
        guard let transport else { throw MacRelayClientError.notConnected }
        let header = RelayEnvelopeHeader(from: .mac, type: .control)
        try await transport.send(text: String(decoding: header.encodeCanonicalJSON(), as: UTF8.self))
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
                // openAndHandshake puts us in .awaitingPeer. Stay there
                // until either the peer's handshake frame arrives (we
                // transition to .connected from within handleHandshakeBody)
                // OR the receive loop throws.
                consecutiveFailures = 0
                lastConnectedAt = Date()
                hasUploadedBundle = true
                lastConnectError = nil
                try await receiveLoop()
                // Clean close — fall through to a fresh dial on the next
                // iteration. Mirrors E4: the relay's idle eviction would
                // re-evict us on connect, but the loop converges quickly.
                await transitionAsync(to: .idle)
                return
            } catch is CancellationError {
                return
            } catch let e as MacRelayClientError where e.isFatal {
                macRelayLogger.error("relay fatal: \(String(describing: e), privacy: .public)")
                await transitionAsync(to: .failed(reason: e.userMessage))
                return
            } catch {
                consecutiveFailures += 1
                let attempt = consecutiveFailures
                macRelayLogger.warning(
                    "relay transient error (attempt \(attempt)): \(String(describing: error), privacy: .public)"
                )
                self.lastConnectError = error.localizedDescription
                await transitionAsync(to: .reconnecting(attempt: attempt))
                // Tear K + replay state down between connects. The
                // iPhone will send its handshake again on the next
                // open, which re-derives K and resets the cursors.
                resetPerConnectState()
                // Update the degraded gate before sleeping so the UI /
                // AgentControlServer sees an up-to-date view.
                if shouldEnterDegraded() {
                    await transitionAsync(to: .degraded)
                }
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
        guard let url = Self.buildConnectURL(config: config, includeBundle: !hasUploadedBundle) else {
            throw MacRelayClientError.malformedURL
        }
        let transport = try await transportFactory(url, config.macTok)
        self.transport = transport
        await transitionAsync(to: .awaitingPeer)
        // First envelope: our handshake (X25519 public key). Per §4.2
        // both peers send a handshake frame on connect even though we
        // could in theory have derived K already from the QR — the
        // explicit frame lets each side verify the other's pubkey
        // matches what it expected (constant-time compare on either
        // side rejects a forged pubkey).
        let header = RelayEnvelopeHeader(from: .mac, type: .handshake)
        try await transport.send(text: String(decoding: header.encodeCanonicalJSON(), as: UTF8.self))
        try await transport.send(data: config.ourPublicKeyBytes)
        // Kick off the heartbeat now that the socket is up. It will
        // self-cancel if the transport disappears.
        startHeartbeat()
    }

    private func receiveLoop() async throws {
        guard let transport else { throw MacRelayClientError.notConnected }
        var pendingHeader: RelayEnvelopeHeader?
        while !Task.isCancelled {
            let message = try await transport.receive()
            switch message {
            case .string(let text):
                // The E2 Worker emits the literal "__keepalive__" text
                // frame every 30s — see `RelaySession.alarm()`. Drop
                // it silently; it's not a relay-protocol envelope.
                if text == "__keepalive__" {
                    pendingHeader = nil
                    continue
                }
                guard let header = RelayEnvelopeHeader.decode(Data(text.utf8)) else {
                    throw MacRelayClientError.protocolViolation("malformed header")
                }
                // The iPhone is the only peer that can speak to us;
                // a forged `from: .mac` is a protocol violation and we
                // tear down (D22 defense at the message layer).
                guard header.from == .ios else {
                    throw MacRelayClientError.protocolViolation("header.from=\(header.from)")
                }
                if header.type == .control {
                    // Header-only; nothing more to do.
                    pendingHeader = nil
                    continue
                }
                pendingHeader = header
            case .data(let body):
                guard let header = pendingHeader else {
                    throw MacRelayClientError.protocolViolation("body without header")
                }
                pendingHeader = nil
                try await handleInboundBody(header: header, body: body)
            @unknown default:
                continue
            }
        }
    }

    private func handleInboundBody(header: RelayEnvelopeHeader, body: Data) async throws {
        switch header.type {
        case .handshake:
            try handleHandshakeBody(body)
        case .ciphertext:
            try await handleCiphertextBody(body)
        case .control:
            // Already handled in receiveLoop (header-only).
            break
        }
    }

    private func handleHandshakeBody(_ body: Data) throws {
        guard body.count == 32 else {
            throw MacRelayClientError.protocolViolation("handshake body must be 32 bytes (got \(body.count))")
        }
        // Hand the pubkey to `RelayPairingService.recordPeerHandshake`,
        // which derives K via X25519+HKDF, persists a record, and
        // returns the 32 raw key bytes. Failures are treated as a
        // protocol violation (peer pubkey was malformed) — tear down +
        // reconnect; the user may need to re-pair.
        guard let service = pairingService else {
            // Service deallocated — shouldn't happen in production
            // (AppRuntime holds it for the app's lifetime) but tests
            // could exercise this. Treat as transient.
            throw MacRelayClientError.protocolViolation("pairing service unavailable")
        }
        let theirPubBase64URL = RelayPairingBase64URL.encode(body)
        guard let kBytes = service.recordPeerHandshake(
            iPhoneEcdhPublicKeyBase64URL: theirPubBase64URL
        ) else {
            // The pairing service returns nil for "invalid pubkey" OR
            // "no active keypair" — both indicate the relay can't
            // proceed. Treat as fatal: the user needs to re-pair from
            // the Mac so a fresh keypair gets minted.
            throw MacRelayClientError.peerPubkeyMismatch
        }
        guard kBytes.count == 32 else {
            throw MacRelayClientError.protocolViolation("derived K wrong size (\(kBytes.count))")
        }
        symmetricKey = SymmetricKey(data: kBytes)
        // Track B (review P0#1 / CB-P0b): a fresh iPhone handshake means a NEW
        // iOS connection. The relay evicts only the same-role iOS socket on its
        // reconnect — THIS Mac socket persists, so runConnectionLoop's
        // resetPerConnectState() never runs. Reset our seq epoch here to match
        // iOS's fresh counters; otherwise every resubscribe frame (iOS restarts
        // outbound at seq 1) is `seq <= inboundHighSeq` → dropped as a replay,
        // and all relayed streams go silently dead after the first reconnect.
        inboundHighSeq = 0
        nextOutboundSeq = 1
        macRelayLogger.info("iPhone handshake validated → K derived; ciphertext channel live; seq epoch reset")
        transition(to: .connected)
        // Tear down any loopback streams bound to the PREVIOUS iOS connection so
        // the iOS resubscribe (same opIds) re-opens them fresh (review P0#2).
        onPeerReconnect?()
    }

    private func handleCiphertextBody(_ body: Data) async throws {
        guard let key = symmetricKey else {
            // Ciphertext before handshake — protocol violation. The
            // iPhone must send its handshake envelope FIRST. (Both
            // peers do.) Tear down + reconnect.
            throw MacRelayClientError.protocolViolation("ciphertext before handshake")
        }
        // Wire shape: 24-byte nonce || sealed. Mirrors the iOS client.
        guard body.count > RelayFrameCodec.nonceLength + RelayFrameCodec.tagLength else {
            throw MacRelayClientError.protocolViolation("ciphertext body too small")
        }
        let nonce = body.prefix(RelayFrameCodec.nonceLength)
        let sealed = body.suffix(from: body.startIndex + RelayFrameCodec.nonceLength)
        let plaintextBytes: Data
        do {
            plaintextBytes = try RelayFrameCodec.open(
                sealed: Data(sealed),
                key: key,
                nonce: Data(nonce)
            )
        } catch {
            // Tampered ciphertext, wrong K, or downgraded `v` — all
            // surface as `.aeadFailed` from CryptoKit. Tear down.
            throw MacRelayClientError.protocolViolation("AEAD failed")
        }
        guard let parsed = RelayPlaintext.decode(plaintextBytes) else {
            throw MacRelayClientError.protocolViolation("plaintext JSON malformed")
        }
        // Replay protection (§4.3): drop frames with seq ≤ what we've
        // already accepted. Drop, not throw — a single replay is not
        // necessarily an attack (the iPhone may have retried after we
        // processed the original).
        if parsed.seq <= inboundHighSeq {
            macRelayLogger.warning("dropping replayed seq=\(parsed.seq) (high=\(self.inboundHighSeq))")
            return
        }
        inboundHighSeq = parsed.seq

        let inbound = MacRelayInboundMessage(
            seq: parsed.seq,
            op: parsed.op,
            data: parsed.data,
            receivedAt: Date()
        )
        lastInbound = inbound
        // Dispatch to the loopback bridge. The handler returns response
        // bytes which we encrypt + send back as `<op>.response`. Errors
        // inside the handler are absorbed — they should not tear the
        // socket down because they represent backend (HTTP) errors,
        // not relay-protocol errors.
        let response = await frameHandler(inbound)
        if let response, !response.isEmpty {
            do {
                try await send(op: "\(parsed.op).response", payload: response)
            } catch {
                macRelayLogger.warning(
                    "failed to send response for \(parsed.op, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.heartbeatIntervalSeconds * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard let self else { return }
                // Header-only control frame. If the transport is gone
                // we silently exit — the run loop has already noticed.
                do {
                    try await self.sendControlFrame()
                } catch {
                    return
                }
            }
        }
    }

    // MARK: Helpers

    private func transition(to next: MacRelayClientState) {
        guard state != next else { return }
        state = next
    }

    private func transitionAsync(to next: MacRelayClientState) async {
        await MainActor.run { self.transition(to: next) }
    }

    private func isExpired() -> Bool {
        UInt64(Date().timeIntervalSince1970) >= config.ttl
    }

    private func shouldEnterDegraded() -> Bool {
        guard let last = lastConnectedAt else { return consecutiveFailures > 1 }
        return Date().timeIntervalSince(last) >= Self.degradedAfterSeconds
    }

    /// Clear per-connect state: drop K, reset replay/seq counters, kill
    /// the heartbeat. Called between reconnects so a forged frame from
    /// the previous session can't desync the new one.
    private func resetPerConnectState() {
        symmetricKey = nil
        inboundHighSeq = 0
        nextOutboundSeq = 1
        heartbeatTask?.cancel()
        heartbeatTask = nil
        transport?.cancel()
        transport = nil
    }

    /// Build the WS URL the Mac dials. Per E2 the path is
    /// `/v1/relay/sessions/<sid>/connect`. The `?token=` query is a
    /// belt-and-suspenders backup for the `Authorization` header —
    /// both forms are accepted by `extractBearerToken` and we send both.
    /// On the first connect of a session (`includeBundle=true`) we
    /// upload the auth bundle so the DO can initialize the session.
    static func buildConnectURL(config: MacRelayClientConfig, includeBundle: Bool) -> URL? {
        let base = config.relayUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: base),
              let scheme = baseURL.scheme,
              (scheme == "wss" || scheme == "ws"),
              let host = baseURL.host else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = baseURL.port {
            components.port = port
        }
        components.path = "/v1/relay/sessions/\(config.sid)/connect"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "token", value: config.macTok),
        ]
        if includeBundle {
            if let proof = config.creationProof {
                // E2's first-peer bootstrap shape — bearer hashes + absolute TTL
                // + operator-signed creation proof, base64-of-JSON. See
                // `infra/relay/src/auth.ts#isValidAuthBundle` and
                // `#validateSessionCreationProof` for the server-side contract.
                let bundle: [String: Any] = [
                    "creation": [
                        "issuedAtSeconds": proof.issuedAtSeconds,
                        "nonce": proof.nonce,
                        "signature": proof.signature,
                    ],
                    "iosTokenHash": config.iosTokHashHex,
                    "macTokenHash": config.macTokHashHex,
                    "ttlSeconds": config.ttl,
                ]
                if let data = try? JSONSerialization.data(
                    withJSONObject: bundle,
                    options: [.sortedKeys]
                ) {
                    queryItems.append(
                        URLQueryItem(name: "bundle", value: data.base64EncodedString())
                    )
                }
            } else {
                macRelayLogger.warning(
                    "Relay first-connect bundle omitted: no operator creation proof configured"
                )
            }
        }
        components.queryItems = queryItems
        return components.url
    }

    static func backoffDelay(for attempt: Int) -> TimeInterval {
        let idx = min(max(0, attempt - 1), Self.backoffSchedule.count - 1)
        let base = Self.backoffSchedule[idx]
        // ±15% jitter — prevents N reconnect-storming clients drumming
        // the relay in lockstep after a Worker rotation. Floor at
        // 0.25s so tests don't hit zero-delay races.
        let jitter = base * 0.15 * Double.random(in: -1...1)
        return max(0.25, base + jitter)
    }

    /// Production transport factory. Tests pass in a fake.
    @MainActor
    public static func defaultTransportFactory(
        url: URL,
        token: String
    ) async throws -> MacRelayWebSocketTransport {
        let config = URLSessionConfiguration.ephemeral
        // TLS 1.3 minimum + ephemeral (no shared cookie/cache state)
        // matches the iOS client. `ws://localhost…` (dev override) is
        // permitted only because `RelayPairingBundle.isValidRelayURL`
        // rejects every other plaintext scheme at scan time.
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url, timeoutInterval: connectTimeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()
        return MacRelayURLSessionTransport(task: task)
    }
}

// MARK: - Error type

public enum MacRelayClientError: Error, Equatable, Sendable {
    case notConnected
    case notHandshaked
    case malformedURL
    case protocolViolation(String)
    case peerPubkeyMismatch
    case authFailed
    case pairingExpired

    /// Fatal errors stop the reconnect loop — the user must re-pair.
    var isFatal: Bool {
        switch self {
        case .peerPubkeyMismatch, .authFailed, .pairingExpired: return true
        default: return false
        }
    }

    var userMessage: String {
        switch self {
        case .notConnected: return "Relay socket is not open."
        case .notHandshaked: return "Waiting for iPhone handshake."
        case .malformedURL: return "Relay URL is malformed — re-pair from the Mac."
        case .protocolViolation(let why): return "Relay protocol violation: \(why)"
        case .peerPubkeyMismatch: return "iPhone identity changed since pairing — re-pair from the Mac."
        case .authFailed: return "Relay rejected the Mac bearer — re-pair from the Mac."
        case .pairingExpired: return "Pairing TTL expired — re-pair from the Mac."
        }
    }
}

// MARK: - Pairing-service adapter

/// `RelayPairingService` is `@MainActor` and exposes
/// `recordPeerHandshake(iPhoneEcdhPublicKeyBase64URL:)` — we adapt it
/// to `MacRelayPairingHandshakeRecorder` so the client can be unit-
/// tested without a real service.
@MainActor
public final class RelayPairingServiceHandshakeRecorder: MacRelayPairingHandshakeRecorder, @unchecked Sendable {
    private weak var service: RelayPairingService?
    public init(service: RelayPairingService) {
        self.service = service
    }
    public func recordPeerHandshake(iPhoneEcdhPublicKeyBase64URL: String) -> Data? {
        service?.recordPeerHandshake(iPhoneEcdhPublicKeyBase64URL: iPhoneEcdhPublicKeyBase64URL)
    }
}

public final class RelaySessionCreationSigningKeyProvider: @unchecked Sendable {
    public static let shared = RelaySessionCreationSigningKeyProvider()
    private static let envKey = "CLAWDMETER_RELAY_OPERATOR_SIGNING_KEY"

    private let lock = NSLock()
    private let processEnv: [String: String]
    private var stored: Data?

    public init(processEnv: [String: String] = ProcessInfo.processInfo.environment) {
        self.processEnv = processEnv
        loadFromEnvironmentIfNeeded()
    }

    public func signingKey() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func setForTesting(_ key: Data?) {
        lock.lock()
        defer { lock.unlock() }
        stored = key
    }

    private func loadFromEnvironmentIfNeeded() {
        guard let raw = processEnv[Self.envKey], !raw.isEmpty,
              let decoded = Self.decodeBase64OrHex(raw),
              decoded.count >= 32 else { return }
        lock.lock()
        stored = decoded
        lock.unlock()
    }

    private static func decodeBase64OrHex(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil,
           trimmed.count % 2 == 0 {
            var bytes = Data()
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex {
                let next = trimmed.index(idx, offsetBy: 2)
                guard let b = UInt8(trimmed[idx..<next], radix: 16) else { return nil }
                bytes.append(b)
                idx = next
            }
            return bytes
        }
        let normalized = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

// MARK: - Config helpers

extension MacRelayClientConfig {

    /// Build a config from a freshly-minted Mac bundle + an in-process
    /// keypair. Used at AppRuntime time when the user taps "Pair iPhone".
    public static func fromMacBundle(
        bundle: RelayPairingBundle,
        ourPublicKeyBytes: Data,
        creationSigningKey: Data? = RelaySessionCreationSigningKeyProvider.shared.signingKey()
    ) -> MacRelayClientConfig {
        let macHash = sha256Hex(bundle.macTok)
        let iosHash = sha256Hex(bundle.iosTok)
        let creationProof = bundle.creationProof ?? creationSigningKey.map {
            RelaySessionCreationProof.issue(
                signingKey: $0,
                sessionId: bundle.sid,
                macTokenHash: macHash,
                iosTokenHash: iosHash,
                ttlSeconds: bundle.ttl
            )
        }
        return MacRelayClientConfig(
            sid: bundle.sid,
            macTok: bundle.macTok,
            macTokHashHex: macHash,
            iosTokHashHex: iosHash,
            relayUrl: bundle.relayUrl,
            ttl: bundle.ttl,
            ourPublicKeyBytes: ourPublicKeyBytes,
            creationProof: creationProof
        )
    }
}
