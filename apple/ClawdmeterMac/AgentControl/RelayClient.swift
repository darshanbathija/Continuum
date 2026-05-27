import Foundation
import OSLog
import Combine
import ClawdmeterShared
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private let relayLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelayClient")

/// E3 — Mac daemon outbound relay client.
///
/// Opens a WebSocket to the E2 Cloudflare Worker relay (PR #151) using
/// credentials minted by E7 (PR #166) and ships encrypted envelopes via
/// the `RelayFrameCodec` (this PR). Existing `AgentControlServer` handlers
/// route over this transport identically to the Tailscale path — the relay
/// is purely a postal service for opaque encrypted bytes.
///
/// ## Design choices (documented inline because the why matters)
///
/// ### URLSession's WebSocket task (not Network.framework)
///
/// `URLSessionWebSocketTask` already drives every other WS in this app
/// (chat-subscribe, terminal, frontier). Reusing it means we get TLS 1.3,
/// HTTP/2 fallback, App Transport Security policy, and Apple's mature
/// keepalive logic for free. Network.framework's `NWConnection` exposes
/// more knobs (raw TCP / TLS) but the relay protocol is plain WSS — there's
/// no benefit to a lower layer.
///
/// ### Two codec instances per peer (one per direction)
///
/// `RelayFrameCodec` owns the `seq` counter; each direction has its own
/// counter, so we instantiate two — `outboundCodec` (for what we encrypt
/// + send) and `inboundCodec` (for what we receive + decrypt). Both share
/// the same symmetric key K derived at pairing time.
///
/// ### Heartbeat every 25s (under iOS 30s aggressive-wake threshold)
///
/// Mirrors the E2 relay's server-side keepalive cadence. Even though this
/// is the Mac side, sending a control ping every 25s keeps our Cloudflare
/// connection alive across NAT timeouts and signals to the peer (iOS) that
/// we're still here. We emit a *header-only* control frame; per the E2
/// envelope contract, control frames have no body.
///
/// ### Exponential backoff: 1s, 2s, 4s, 8s, …, 30s
///
/// Per the task spec. 30s cap because beyond that we want the user to
/// notice via UI affordance ("Relay unreachable") rather than silently
/// burn watts. Jitter (10%) prevents reconnect storms after relay
/// rotation.
///
/// ### Tailscale fallback policy
///
/// `AgentControlServer` retains its NWListener — both the relay AND the
/// Tailscale endpoint are listening for `/sessions`, `/chat`, etc. The
/// relay-enabled path is purely additive in this PR. The "fall back to
/// Tailscale when relay is down >60s" semantics live in `RelayClient`'s
/// `transportState` publisher; AgentControlServer chooses which delivery
/// path to use for outbound notifications (push-style) based on that
/// state, while inbound requests still arrive on whichever transport the
/// client used.
@MainActor
public final class RelayClient: ObservableObject {

    // MARK: - Observable state

    /// What the client is currently doing. iOS UI / Mac Settings can bind
    /// to this for an operator-facing status pill ("Relay connected",
    /// "Reconnecting in 4s", etc.).
    public enum TransportState: Equatable, Sendable {
        case idle              // No pairing record / not connected
        case connecting        // WS handshake in flight
        case connected         // WS open, frames flowing
        case reconnecting(attempt: Int, nextRetryAfterSeconds: Double)
        case degraded          // >60s without a successful connect; AgentControlServer should
                               // prefer Tailscale until we transition out
        case stopped           // Explicitly stop()'d
    }

    @Published public private(set) var transportState: TransportState = .idle

    /// Last successful inbound activity. Used by the >60s "degraded" gate
    /// + the operator-facing "last connected 12s ago" affordance.
    @Published public private(set) var lastInboundActivityAt: Date?

    /// Last attempt (success or failure) — for the connecting/reconnecting UI.
    @Published public private(set) var lastConnectAttemptAt: Date?

    /// Set when a connect attempt fails. Cleared on successful connect.
    /// Surfaces in the Mac Settings "Relay" panel for diagnostics.
    @Published public private(set) var lastConnectError: String?

    // MARK: - Inputs

    /// The pairing record E7 persists (sid, macTok, iosTok, ttl, relayUrl).
    /// In production this comes from `RelayPairingService.bundle` (the Mac
    /// just-minted state) OR `RelayPairingStore.loadRecord()` (after the
    /// iPhone has scanned + completed handshake).
    public struct PairingContext: Sendable, Equatable {
        public let sid: String
        public let macTok: String
        public let iosTokHash: String  // sha256 hex of iosTok — Mac MUST upload both hashes on first connect
        public let macTokHash: String  // sha256 hex of macTok — same reason
        public let derivedKey: Data    // 32-byte symmetric K from RelayPairingCrypto
        public let ttlUnixSeconds: UInt64
        public let relayBaseURL: String  // wss://relay-staging.clawdmeter.dev (or production)

        public init(
            sid: String,
            macTok: String,
            iosTokHash: String,
            macTokHash: String,
            derivedKey: Data,
            ttlUnixSeconds: UInt64,
            relayBaseURL: String
        ) {
            self.sid = sid
            self.macTok = macTok
            self.iosTokHash = iosTokHash
            self.macTokHash = macTokHash
            self.derivedKey = derivedKey
            self.ttlUnixSeconds = ttlUnixSeconds
            self.relayBaseURL = relayBaseURL
        }
    }

    /// Mac's "role" in the relay is always `mac` — the role is bound to
    /// the bearer token, not negotiated. Per E2 D22.
    private static let role = "mac"

    /// Handler the client invokes when an inbound frame decrypts. The
    /// AgentControlServer's relay-integration plumbing installs a handler
    /// that dispatches the inner op → existing HTTP route handlers.
    ///
    /// The frame's `data` field is the JSON-encoded payload the peer wants
    /// us to act on. The handler returns an op-specific response that we
    /// encrypt + send back.
    public typealias FrameHandler = @MainActor (RelayInnerFrame) async -> Data?

    /// The frame-handler is `var` rather than `let` so AppRuntime can swap
    /// in the loopback-backed dispatcher AFTER the AgentControlServer has
    /// bound its port (the dispatcher needs the bound port to issue the
    /// localhost HTTP request).
    public var frameHandler: FrameHandler
    private let urlSession: URLSession

    // MARK: - Internals

    private var pairing: PairingContext?
    private var outboundCodec: RelayFrameCodec?
    private var inboundCodec: RelayFrameCodec?

    /// Backoff schedule (seconds). Caps at 30s per acceptance.
    private static let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// Heartbeat cadence — server side does 25s; we mirror so a paired
    /// network never goes >25s without traffic in either direction.
    private static let heartbeatIntervalSeconds: TimeInterval = 25

    /// After this many seconds of no successful connect, transition to
    /// `.degraded` so the AgentControlServer can prefer Tailscale.
    private static let degradedAfterSeconds: TimeInterval = 60

    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var wsTask: URLSessionWebSocketTask?

    /// Reconnect attempt counter; reset on successful connect.
    private var reconnectAttempt: Int = 0

    /// Date of the most recent successful WebSocket open. Used by the
    /// >60s degraded gate.
    private var lastSuccessfulConnectAt: Date?

    public init(
        urlSession: URLSession = .shared,
        frameHandler: @escaping FrameHandler
    ) {
        self.urlSession = urlSession
        self.frameHandler = frameHandler
    }

    // MARK: - Public API

    /// Set (or replace) the pairing context. If already connected on a
    /// different context, the existing socket is torn down + a fresh
    /// connect begins.
    public func configure(pairing: PairingContext) {
        if let current = self.pairing, current == pairing {
            return  // no-op
        }
        relayLogger.info("Configured pairing context (sid=\(pairing.sid.prefix(8), privacy: .public)…)")
        self.pairing = pairing
        let symmetric = SymmetricKey(data: pairing.derivedKey)
        self.outboundCodec = RelayFrameCodec(key: symmetric, from: Self.role)
        self.inboundCodec = RelayFrameCodec(key: symmetric, from: "ios")  // codec.from is the SENDER role for the OUTBOUND
        // ^ The inbound codec is used only to decrypt; its `from` field is
        // for what WE'd put on outbound. We never call encrypt() on the
        // inbound codec, so this is a label-only nuisance. Fine.

        // If there was a live task, tear it down so the next connect uses
        // the new context.
        if let task = wsTask {
            task.cancel(with: .normalClosure, reason: Data("pairing replaced".utf8))
            wsTask = nil
        }
        if loopTask != nil {
            // Already running; the loop will redial with the new context
            // automatically since it reads `self.pairing` on each iteration.
        }
    }

    /// Drop the current pairing context entirely. Useful for "Forget"
    /// flows. The connect loop returns to `.idle`.
    public func clearPairing() {
        self.pairing = nil
        self.outboundCodec = nil
        self.inboundCodec = nil
        stop()
        transportState = .idle
    }

    /// Start the connect / reconnect loop. Safe to call multiple times —
    /// only the first call spawns a task; subsequent calls are no-ops.
    public func start() {
        guard loopTask == nil else { return }
        guard pairing != nil else {
            relayLogger.notice("start() called with no pairing — staying .idle")
            transportState = .idle
            return
        }
        relayLogger.info("Starting relay connect loop")
        loopTask = Task { @MainActor [weak self] in
            await self?.runConnectLoop()
        }
    }

    /// Stop the connect / reconnect loop. Closes the WS if open. Idempotent.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let task = wsTask {
            task.cancel(with: .normalClosure, reason: Data("explicit stop".utf8))
        }
        wsTask = nil
        transportState = .stopped
        relayLogger.info("Relay client stopped")
    }

    /// Send an encrypted frame to the paired peer. Returns true if the
    /// frame was enqueued; false if no connection.
    @discardableResult
    public func send(op: String, data: Data) async -> Bool {
        guard let codec = outboundCodec, let task = wsTask else {
            relayLogger.debug("send(\(op, privacy: .public)) dropped — no connection")
            return false
        }
        do {
            let (header, body) = try codec.encrypt(op: op, data: data)
            try await task.send(.string(header.encodeJSON()))
            try await task.send(.data(body))
            return true
        } catch {
            relayLogger.error("send(\(op, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// True if the relay has been reachable within the last `degradedAfterSeconds`
    /// window. AgentControlServer's outbound-notification logic queries this
    /// to decide whether to prefer the relay or Tailscale.
    public var isReachable: Bool {
        switch transportState {
        case .connected: return true
        case .connecting, .reconnecting:
            // We're not currently connected, but if our LAST successful connect
            // was recent we still consider the path "warm enough" to retry.
            if let last = lastSuccessfulConnectAt,
               Date().timeIntervalSince(last) < Self.degradedAfterSeconds {
                return true
            }
            return false
        case .idle, .degraded, .stopped:
            return false
        }
    }

    // MARK: - Connect loop

    /// The main reconnect loop. Lives in a single `Task` that we spawn in
    /// `start()` and cancel in `stop()`. Inside the loop we open the WS,
    /// drive the receive loop, and on disconnect compute a backoff before
    /// dialing again.
    private func runConnectLoop() async {
        while !Task.isCancelled {
            guard let pairing = self.pairing else {
                transportState = .idle
                return
            }

            // Bail out before dialing if the session's TTL has already passed —
            // the relay would reject us anyway and we'd waste connect attempts.
            let now = UInt64(Date().timeIntervalSince1970)
            if now >= pairing.ttlUnixSeconds {
                relayLogger.notice("Pairing TTL has expired; not dialing relay")
                transportState = .stopped
                lastConnectError = "Pairing expired"
                return
            }

            lastConnectAttemptAt = Date()
            transportState = .connecting
            do {
                try await connectAndPump(pairing: pairing)
                // connectAndPump returned cleanly — that means we received
                // a graceful close. Loop again to redial.
                relayLogger.info("Relay connection closed cleanly; reconnecting")
            } catch is CancellationError {
                relayLogger.info("Relay connect loop cancelled")
                return
            } catch {
                relayLogger.error("Relay connect attempt failed: \(error.localizedDescription, privacy: .public)")
                lastConnectError = error.localizedDescription
            }

            // Re-evaluate degraded state.
            updateDegradedStateIfNeeded()

            // Compute next backoff delay.
            reconnectAttempt += 1
            let delay = backoff(for: reconnectAttempt)
            relayLogger.info("Backing off \(delay, privacy: .public)s before retry #\(self.reconnectAttempt, privacy: .public)")
            transportState = .reconnecting(attempt: reconnectAttempt, nextRetryAfterSeconds: delay)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return  // task cancelled
            }
        }
    }

    /// Open the WS, send the initial handshake, then enter the receive loop.
    /// Returns when the socket closes cleanly. Throws on error.
    private func connectAndPump(pairing: PairingContext) async throws {
        let url = try Self.makeConnectURL(pairing: pairing, includeBundle: lastSuccessfulConnectAt == nil)
        // Pass the bearer via the standard Authorization header — works for
        // native URLSession clients (it doesn't strip custom headers from
        // WebSocket upgrades the way browsers do). Per E2's
        // `extractBearerToken`, the header is checked first.
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(pairing.macTok)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: request)
        self.wsTask = task
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            if self.wsTask === task {
                self.wsTask = nil
            }
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
        task.resume()

        // We can't await the upgrade explicitly with URLSessionWebSocketTask —
        // the API treats the upgrade as opaque. The first `receive()` call
        // returns either a message (success) or an error (handshake failed).
        // Start the receive pump; it will throw if the upgrade failed.
        relayLogger.info("Dialing relay sid=\(pairing.sid.prefix(8), privacy: .public)…")

        // Start the heartbeat once the socket is up. We schedule it
        // unconditionally; if the first receive throws, the heartbeat task
        // will see `wsTask == nil` on the next tick and self-cancel.
        startHeartbeat(task: task)

        // Run the receive loop until the socket closes or throws.
        try await receiveLoop(task: task)
    }

    /// The receive pump. Reads frames in pairs: a text header followed by
    /// a binary body (for ciphertext / handshake frames) OR a single text
    /// header (for control frames). Per the E2 envelope contract.
    private func receiveLoop(task: URLSessionWebSocketTask) async throws {
        var pendingHeader: RelayEnvelopeHeader?
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw error
            }
            // First frame we receive promotes us to .connected.
            if transportState != .connected {
                transportState = .connected
                lastSuccessfulConnectAt = Date()
                reconnectAttempt = 0
                lastConnectError = nil
                relayLogger.info("Relay connection established")
            }
            lastInboundActivityAt = Date()

            switch message {
            case .string(let text):
                // The server-side keepalive frame is the literal "__keepalive__"
                // string per E2's `RelaySession.alarm()`. Drop it silently.
                if text == "__keepalive__" {
                    continue
                }
                guard let header = RelayEnvelopeHeader.decode(text) else {
                    relayLogger.warning("Discarding malformed header: \(text.prefix(64), privacy: .public)")
                    continue
                }
                if header.type == "control" {
                    // Control frames are header-only — no body to wait for.
                    // We ignore peer-sent control frames in v1 (only the
                    // server-side keepalive crosses the wire today, and we
                    // already filtered it).
                    pendingHeader = nil
                    continue
                }
                // Cache the header for the body frame to follow.
                pendingHeader = header
            case .data(let body):
                guard let header = pendingHeader else {
                    relayLogger.warning("Discarding body without preceding header (\(body.count, privacy: .public) bytes)")
                    continue
                }
                pendingHeader = nil
                await handleInboundCiphertext(header: header, body: body)
            @unknown default:
                continue
            }
        }
    }

    /// Decrypt an inbound ciphertext frame + dispatch via the installed
    /// frame handler. The handler may return response bytes which we
    /// then encrypt + send back to the peer.
    private func handleInboundCiphertext(header: RelayEnvelopeHeader, body: Data) async {
        guard let codec = inboundCodec else { return }
        let inner: RelayInnerFrame
        do {
            inner = try codec.decrypt(body: body)
        } catch RelayFrameCodecError.replayedSequence {
            relayLogger.warning(
                "replay-rejected: seq=\(codec.lastIncomingSequenceForTesting, privacy: .public) op was already accepted"
            )
            return
        } catch {
            // Decryption failure — drop the frame quietly. This is the
            // shape an attacker tampering with bytes between peers would
            // see; we don't help them by logging anything more specific.
            relayLogger.warning("Inbound frame failed authentication; dropping")
            return
        }
        relayLogger.debug(
            "Inbound op=\(inner.op, privacy: .public) seq=\(inner.seq, privacy: .public)"
        )
        let response = await frameHandler(inner)
        if let response {
            _ = await send(op: "\(inner.op).response", data: response)
        }
    }

    private func startHeartbeat(task: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, weak task] in
            while !Task.isCancelled, let task = task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.heartbeatIntervalSeconds * 1_000_000_000))
                } catch {
                    return
                }
                guard task.state == .running else { return }
                // Header-only control frame. Per E2's envelope contract,
                // control frames have no body.
                let header = RelayEnvelopeHeader(from: Self.role, type: "control")
                do {
                    try await task.send(.string(header.encodeJSON()))
                    relayLogger.debug("Heartbeat sent")
                } catch {
                    relayLogger.warning("Heartbeat failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                _ = self  // capture
            }
        }
    }

    private func updateDegradedStateIfNeeded() {
        guard let last = lastSuccessfulConnectAt else {
            // Never connected — degraded immediately if more than 60s since pairing.
            transportState = .degraded
            return
        }
        if Date().timeIntervalSince(last) >= Self.degradedAfterSeconds {
            transportState = .degraded
        }
    }

    private func backoff(for attempt: Int) -> TimeInterval {
        let idx = min(attempt - 1, Self.backoffSchedule.count - 1)
        let base = Self.backoffSchedule[max(0, idx)]
        // 10% jitter so a herd reconnect-storm doesn't drum-roll the relay.
        let jitter = base * Double.random(in: 0...0.1)
        return base + jitter
    }

    // MARK: - URL construction

    /// Build the WSS URL the Mac dials. Includes the bearer in the query
    /// string as a belt-and-suspenders backup in case URLSession ever
    /// drops the Authorization header on upgrade (it doesn't today, but
    /// E2 accepts the query-string fallback too).
    ///
    /// `includeBundle` should be true on the FIRST connect of a pairing
    /// (so the relay bootstraps the session state from the bundle), false
    /// on every subsequent reconnect — at that point the relay already
    /// has the state.
    static func makeConnectURL(pairing: PairingContext, includeBundle: Bool) throws -> URL {
        guard let baseURL = URL(string: pairing.relayBaseURL),
              let scheme = baseURL.scheme,
              (scheme == "wss" || scheme == "ws"),
              let host = baseURL.host else {
            throw RelayClientError.invalidRelayURL
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = baseURL.port {
            components.port = port
        }
        components.path = "/v1/relay/sessions/\(pairing.sid)/connect"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "token", value: pairing.macTok)
        ]
        if includeBundle {
            // E2's first-peer bootstrap: encode `{ macTokenHash, iosTokenHash, ttlSeconds }`
            // as base64-JSON. The relay's DO stores these hashes; subsequent
            // connects just present the bearer.
            let bundle: [String: Any] = [
                "macTokenHash": pairing.macTokHash,
                "iosTokenHash": pairing.iosTokHash,
                "ttlSeconds": pairing.ttlUnixSeconds,
            ]
            let bundleData = try JSONSerialization.data(
                withJSONObject: bundle,
                options: [.sortedKeys]
            )
            let bundleParam = bundleData.base64EncodedString()
            queryItems.append(URLQueryItem(name: "bundle", value: bundleParam))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RelayClientError.invalidRelayURL
        }
        return url
    }
}

public enum RelayClientError: Error, Equatable {
    case invalidRelayURL
    case handshakeFailed(String)
    case decryptionFailed
    case noPairing
}

// MARK: - Helpers shared with E7 — pairing-record → context

extension RelayClient.PairingContext {

    /// Build a context from a freshly-minted Mac-side bundle (E7's
    /// `RelayPairingService.bundle` + the live `keypair`). This is the
    /// path the Mac takes immediately after `RelayPairingService.beginPairing()`
    /// while the iPhone is mid-scan.
    ///
    /// In the future (after E4 wires iOS), the Mac will also receive the
    /// iPhone's ephemeral public key over the relay's first frame and at
    /// that point the symmetric key K is finalized. Until then, the Mac
    /// holds its own keypair in `RelayPairingService.keypairForTesting`
    /// (this is the same `RelayPairingKeyPair` E4 will pull from).
    public static func fromMacBundle(
        bundle: RelayPairingBundle,
        derivedSymmetricKey: Data
    ) throws -> Self {
        let macHash = sha256Hex(bundle.macTok)
        let iosHash = sha256Hex(bundle.iosTok)
        return .init(
            sid: bundle.sid,
            macTok: bundle.macTok,
            iosTokHash: iosHash,
            macTokHash: macHash,
            derivedKey: derivedSymmetricKey,
            ttlUnixSeconds: bundle.ttl,
            relayBaseURL: bundle.relayUrl
        )
    }

    /// Build a context from a persisted `RelayPairingRecord` (typically the
    /// iOS side calls this on launch — but the Mac side has a sibling path
    /// in E3 that mirrors the structure when we restore from disk in
    /// the future "remember last pairing" feature; for now the Mac always
    /// starts from a fresh in-memory bundle per §5b).
    public static func fromRecord(_ record: RelayPairingRecord) -> Self {
        let macHash = sha256Hex(record.macTok)
        let iosHash = sha256Hex(record.iosTok)
        let derived = record.derivedSymmetricKeyBase64URL.flatMap(RelayPairingBase64URL.decode) ?? Data()
        return .init(
            sid: record.sid,
            macTok: record.macTok,
            iosTokHash: iosHash,
            macTokHash: macHash,
            derivedKey: derived,
            ttlUnixSeconds: record.ttl,
            relayBaseURL: record.relayUrl
        )
    }

    private static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
