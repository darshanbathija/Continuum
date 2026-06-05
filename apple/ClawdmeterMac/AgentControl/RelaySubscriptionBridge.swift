import Foundation
import OSLog
import ClawdmeterShared

private let bridgeLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelaySubscriptionBridge")

/// Track B — B0.2: the **loopback-WebSocket bridge**.
///
/// The keystone of subscription-over-relay. The relay tunnel is request/
/// response only; the 4 live WS streams (chat-subscribe, terminal, events,
/// frontier, lifecycle) have no relay path. Rather than refactor the 4 working
/// `WSChannel`s, the bridge opens a SECOND, loopback WebSocket to the daemon's
/// own WS port and forwards frames — so every channel is reused UNCHANGED (D2).
///
/// ```
/// iOS --relay-- Mac:                     subscribe(opId, spec)
///   RelaySubscriptionBridge.handle(.subscribe)
///     → build loopback envelope SERVER-SIDE (allowlist + loopback token)
///     → connFactory(ws://127.0.0.1:<wsPort>, envelope)   [reuses the real WSChannel]
///     → pump: conn.receive() → subFrame(opId, payload) → sendOutbound  ──relay──▶ iOS
///   terminal input/resize from iOS: handle(.subFrame) → conn.send(payload)  (full-duplex, CB-P1a)
/// ```
///
/// Hardenings folded from the review:
/// - **Server-built envelope** (CB-P1e): the loopback subscribe JSON is built
///   from an allowlisted op schema with the daemon's OWN loopback token; an
///   iOS-supplied token/op is never trusted.
/// - **Per-channel coalescing** (CB-P1d): chat/frontier snapshots debounce
///   last-write-wins over the metered relay; terminal bytes + events + the
///   lifecycle spine are forwarded in order, never dropped.
@MainActor
public final class RelaySubscriptionBridge {

    /// A loopback WS connection to the daemon's own WS port. Prod is a
    /// `URLSessionWebSocketTask` wrapper; tests inject a fake.
    public protocol Conn: AnyObject {
        /// iOS → daemon (terminal input / resize / title).
        func send(_ data: Data) async throws
        /// daemon → iOS frame; nil signals the loopback WS closed.
        func receive() async throws -> Data?
        func close()
    }

    public typealias ConnFactory = @MainActor (_ url: URL, _ subscribeEnvelope: Data) async throws -> Conn
    public typealias SendOutbound = @MainActor (RelayMuxFrame) async -> Void

    private let wsURL: @MainActor () -> URL?
    private let loopbackToken: @MainActor () -> String?
    private let connFactory: ConnFactory
    private let sendOutbound: SendOutbound
    private let coalesceWindow: TimeInterval

    private struct Live {
        let conn: Conn
        let pump: Task<Void, Never>
        let policy: RelaySubPolicy
        let coalescer: SnapshotCoalescer?
    }
    private var live: [String: Live] = [:]

    /// - Parameters:
    ///   - wsURL: `ws://127.0.0.1:<boundWsPort>` (closure — the port binds late).
    ///   - loopbackToken: the daemon's per-launch loopback bearer.
    ///   - coalesceWindow: LWW debounce for snapshot streams over the relay.
    public init(
        wsURL: @escaping @MainActor () -> URL?,
        loopbackToken: @escaping @MainActor () -> String?,
        connFactory: @escaping ConnFactory,
        sendOutbound: @escaping SendOutbound,
        coalesceWindow: TimeInterval = 0.4
    ) {
        self.wsURL = wsURL
        self.loopbackToken = loopbackToken
        self.connFactory = connFactory
        self.sendOutbound = sendOutbound
        self.coalesceWindow = coalesceWindow
    }

    /// Entry point from the relay frame handler for `op == RelayMux.op`.
    public func handle(_ frame: RelayMuxFrame) async {
        switch frame.kind {
        case .subscribe:      await openSubscription(frame)
        case .subFrame:       await forwardInput(frame)          // iOS → daemon (terminal)
        case .unsubscribe, .subEnd: closeSubscription(frame.opId)
        case .request, .response, .end, .error:
            // Multiplexed one-shot requests are handled by the request path,
            // not the subscription bridge; ignore here.
            break
        }
    }

    /// Tear down every live subscription (relay socket dropped / app quit).
    public func shutdownAll() {
        for opId in Array(live.keys) { closeSubscription(opId) }
    }

    public var liveCount: Int { live.count }

    // MARK: - Subscribe

    private func openSubscription(_ frame: RelayMuxFrame) async {
        let opId = frame.opId
        // Duplicate live subscribe for the same opId is a protocol error — ignore
        // (CB-P1b: don't open a 2nd loopback WS for an in-flight stream id).
        guard live[opId] == nil else {
            bridgeLogger.warning("duplicate subscribe for live opId \(opId, privacy: .public); ignoring")
            return
        }
        guard let payload = frame.payload, let spec = RelaySubscribeSpec.decode(payload) else {
            await emitError(opId: opId, message: "malformed subscribe spec")
            return
        }
        guard RelaySubAllowlist.isAllowed(spec.op) else {
            await emitError(opId: opId, message: "op not allowed: \(spec.op)")
            return
        }
        guard let token = loopbackToken(),
              let envelope = RelaySubAllowlist.loopbackEnvelope(spec: spec, loopbackToken: token),
              let url = wsURL() else {
            await emitError(opId: opId, message: "loopback unavailable")
            return
        }
        let conn: Conn
        do {
            conn = try await connFactory(url, envelope)
        } catch {
            await emitError(opId: opId, message: "loopback connect failed")
            return
        }
        let policy = RelaySubAllowlist.policy(for: spec.op)
        let coalescer: SnapshotCoalescer? = policy == .snapshotLWW
            ? SnapshotCoalescer(window: coalesceWindow) { [weak self] data in
                await self?.sendOutbound(RelayMuxFrame(opId: opId, kind: .subFrame, payload: data))
            }
            : nil
        let pump = Task { [weak self] in
            guard let self else { return }
            await self.pumpLoop(opId: opId)
        }
        live[opId] = Live(conn: conn, pump: pump, policy: policy, coalescer: coalescer)
        bridgeLogger.info("opened relay sub opId=\(opId, privacy: .public) op=\(spec.op, privacy: .public) policy=\(String(describing: policy), privacy: .public)")
    }

    /// daemon → iOS: read loopback WS frames and forward as subFrames, applying
    /// the per-channel coalescing policy.
    private func pumpLoop(opId: String) async {
        guard let entry = live[opId] else { return }
        let conn = entry.conn
        while !Task.isCancelled {
            let frame: Data?
            do { frame = try await conn.receive() }
            catch { break }
            guard let data = frame else { break }   // loopback WS closed
            switch entry.policy {
            case .snapshotLWW:
                entry.coalescer?.submit(data)        // debounced LWW
            case .orderedNoDrop:
                await sendOutbound(RelayMuxFrame(opId: opId, kind: .subFrame, payload: data))
            }
        }
        // Loopback closed or errored → tell iOS the stream ended + clean up.
        if live[opId] != nil {
            await sendOutbound(RelayMuxFrame(opId: opId, kind: .subEnd, payload: nil))
            teardown(opId)
        }
    }

    // MARK: - Input (full-duplex: iOS → daemon)

    private func forwardInput(_ frame: RelayMuxFrame) async {
        guard let entry = live[frame.opId] else { return }   // unknown/closed stream
        guard let payload = frame.payload, !payload.isEmpty else { return }
        do { try await entry.conn.send(payload) }
        catch { bridgeLogger.warning("loopback input send failed opId=\(frame.opId, privacy: .public)") }
    }

    // MARK: - Teardown

    private func closeSubscription(_ opId: String) {
        teardown(opId)
    }

    private func teardown(_ opId: String) {
        guard let entry = live.removeValue(forKey: opId) else { return }
        entry.pump.cancel()
        entry.coalescer?.cancel()
        entry.conn.close()
    }

    private func emitError(opId: String, message: String) async {
        bridgeLogger.warning("relay sub error opId=\(opId, privacy: .public): \(message, privacy: .public)")
        await sendOutbound(RelayMuxFrame(
            opId: opId, kind: .error,
            payload: try? JSONSerialization.data(withJSONObject: ["error": message], options: [])
        ))
    }
}

/// Debounced last-write-wins for replaceable snapshot streams (chat / frontier)
/// over the metered relay (D5 / CB-P1d). A newer snapshot supersedes an older
/// un-flushed one, so a 10×/sec streaming chat doesn't re-ship the full
/// transcript through Cloudflare every tick.
@MainActor
final class SnapshotCoalescer {
    private var pending: Data?
    private var flushTask: Task<Void, Never>?
    private let window: TimeInterval
    private let flush: @MainActor (Data) async -> Void

    init(window: TimeInterval, flush: @escaping @MainActor (Data) async -> Void) {
        self.window = window
        self.flush = flush
    }

    /// Record the latest snapshot; schedule a single flush of the newest value.
    func submit(_ payload: Data) {
        pending = payload
        guard flushTask == nil else { return }   // a flush is already scheduled
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.window * 1_000_000_000))
            await self.fire()
        }
    }

    private func fire() async {
        flushTask = nil
        guard let p = pending else { return }
        pending = nil
        await flush(p)
    }

    func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pending = nil
    }
}
