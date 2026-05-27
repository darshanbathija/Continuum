import Foundation
import Network
import OSLog
import Combine
import ClawdmeterShared

private let chatStreamLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ChatStreamWS")

/// Phase 2 of the WhatsApp-smooth Sessions pipeline. One-per-client
/// WebSocket bridge between a `SessionChatStore` and an iPhone (or other
/// paired client) `iOSChatStore`.
///
/// Codex's outside-voice plan review (D6) explicitly cut the originally-
/// planned `WireChatEvent` delta envelope (with `.snapshot` /
/// `.appendItems` / `.patchLastToolRun` / `.resyncRequired` cases). v1
/// shipped full-snapshot push only — the per-commit JSON payload is bounded
/// (≤500 items per store, ~150KB at the upper end) and the bandwidth
/// savings of deltas don't justify the bug surface of resync semantics
/// before measurements prove a problem.
///
/// **A10 (wire v21) — shell/detail split:** the channel now branches once
/// per connection based on the client's reported `wireVersion`:
///   - `wireVersion >= 21` → per commit, the daemon sends:
///       1. A thin `ChatShellEvent` (~80 bytes) wrapped in a
///          `{ type: "shell", shell: {...} }` envelope, then
///       2. A heavy `ChatDetailEvent` (items + plan + sources + artifacts
///          + tokens) wrapped in a `{ type: "detail", detail: {...} }`
///          envelope.
///       The activity strip / sidebar can paint from the shell before
///       waiting for the detail, which yields ≥80% smaller payloads per
///       UI tick during a token burst.
///   - `wireVersion <= 20` (or absent) → the daemon sends the legacy
///      raw `WireChatSnapshot` JSON frame, unchanged.
///
/// Wire envelope (JSON text frames):
///   Client → Server: the initial WS-subscription envelope (handled by
///     `AgentControlServer.routeWSSubscription`) with `op: "chat-subscribe"`,
///     `sessionId: <UUID>`, and (v21+) `wireVersion: <Int>`. After that,
///     the channel is server-push only; client doesn't send chat frames.
///     Disconnect when done.
///
///   Server → Client (legacy, v <= 20): each frame is a JSON-encoded
///     `WireChatSnapshot`. First frame is the current snapshot for the
///     session. Subsequent frames coalesce via a 100ms debounce.
///
///   Server → Client (v21+): each commit emits two text frames in
///     order — a shell envelope, then a detail envelope. Same 100ms
///     coalesce window applies. The first commit after subscribe sends
///     the initial snapshot's pair.
///
/// Lifecycle:
///   - `start()` calls `registry.acquire(for:)` to retain the chat store
///     beyond the idle eviction window, observes its `snapshot` publisher
///     via Combine, and pushes the initial frame(s).
///   - `stop()` cancels the Combine subscription, calls
///     `registry.release(sessionId:)`, and closes the connection. The
///     registry's idle sweep then evicts the store some time after the
///     last release (5 min default).
@MainActor
public final class ChatStreamWebSocketChannel: WSChannel {

    private let connection: NWConnection
    private let session: AgentSession
    private let registry: DaemonChatStoreRegistry
    private weak var store: SessionChatStore?
    private var cancellable: AnyCancellable?
    /// JSON encoder configured once. `iso8601` matches the iPhone-side
    /// decoder in `AgentControlClient`, and `withoutEscapingSlashes` cuts
    /// a few KB off snapshots that quote file paths.
    private let encoder: JSONEncoder
    /// True when the client speaks wireVersion >= 21 (chooses shell/detail
    /// dispatch). Selected ONCE at construction time; never re-evaluated.
    private let useShellDetail: Bool

    /// Coalesce window for snapshot pushes. 100ms is fast enough that
    /// streaming reply tokens feel live (10fps update), slow enough that
    /// a chatty agent doesn't melt the WS frame budget.
    public static let coalesceWindowMs: Int = 100

    public init(
        connection: NWConnection,
        session: AgentSession,
        registry: DaemonChatStoreRegistry,
        clientWireVersion: Int? = nil
    ) {
        self.connection = connection
        self.session = session
        self.registry = registry
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
        self.useShellDetail = AgentControlWireVersion.supportsShellDetail(serverWireVersion: clientWireVersion)
    }

    public func start() {
        guard let store = registry.acquire(for: session) else {
            chatStreamLogger.warning("chat-subscribe: registry could not acquire store for session \(self.session.id.uuidString, privacy: .public)")
            sendCloseAndCancel(.protocolCode(.unsupportedData))
            return
        }
        self.store = store
        chatStreamLogger.info("chat-subscribe started for session \(self.session.id.uuidString, privacy: .public) (shell/detail=\(self.useShellDetail, privacy: .public))")
        // Push the current snapshot immediately so the client has
        // something to paint before the first commit cycle bumps it.
        Task { @MainActor [weak self] in
            await self?.pushSnapshot(store.snapshot)
        }
        // Combine subscription. `debounce` collapses rapid commits into a
        // single push per coalesce window; `removeDuplicates` filters out
        // no-op republishes that bump the same updateCounter (the staging
        // commit task only republishes when counter changes, but a
        // defense-in-depth filter here is cheap).
        //
        // C2 — was `store.$snapshot` pre-C2. With the store now
        // `@Observable`, the daemon-side Combine bridge is
        // `snapshotPublisher` (a `PassthroughSubject` pushed alongside
        // each `snapshot =` write inside the commit task).
        cancellable = store.snapshotPublisher
            .removeDuplicates { $0.updateCounter == $1.updateCounter }
            .debounce(
                for: .milliseconds(Self.coalesceWindowMs),
                scheduler: DispatchQueue.main
            )
            .sink { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    await self?.pushSnapshot(snapshot)
                }
            }
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
        registry.release(sessionId: session.id)
        connection.cancel()
        chatStreamLogger.info("chat-subscribe stopped for session \(self.session.id.uuidString, privacy: .public)")
    }

    // MARK: - Push

    private func pushSnapshot(_ snapshot: SessionChatStore.ChatSnapshot) async {
        let wire = WireChatSnapshot(
            sessionId: session.id,
            items: snapshot.items,
            planSteps: snapshot.planSteps,
            sourceEntries: snapshot.sourceEntries,
            artifactEntries: snapshot.artifactEntries,
            codexTodos: snapshot.codexTodos,
            pendingPermissionPrompt: store?.pendingPermissionPrompt,
            totalInputTokens: snapshot.totalInputTokens,
            totalOutputTokens: snapshot.totalOutputTokens,
            cacheReadTokens: snapshot.totalCacheReadTokens,
            cacheCreationTokens: snapshot.totalCacheCreationTokens,
            lastEventAt: snapshot.lastEventAt ?? session.lastEventAt,
            updateCounter: snapshot.updateCounter,
            currentTurnState: snapshot.currentTurnState
        )
        if useShellDetail {
            await pushShellDetail(from: wire)
        } else {
            await pushLegacySnapshot(wire)
        }
    }

    /// v20-and-earlier path: send the whole `WireChatSnapshot` JSON
    /// payload as one text frame (the original Phase 2 wire).
    private func pushLegacySnapshot(_ wire: WireChatSnapshot) async {
        guard let body = try? encoder.encode(wire) else {
            chatStreamLogger.error("chat-subscribe: failed to encode snapshot for session \(self.session.id.uuidString, privacy: .public)")
            return
        }
        await sendTextFrame(body, identifier: "chat-snapshot")
    }

    /// v21+ path: send a thin shell envelope first, then the heavy detail
    /// envelope. Two frames per commit. The shell drives the activity
    /// strip / sidebar summary; the detail fills in the body.
    private func pushShellDetail(from wire: WireChatSnapshot) async {
        let shellFrame = ChatStreamFrame.shell(wire.shellEvent())
        let detailFrame = ChatStreamFrame.detail(wire.detailEvent())
        guard let shellBody = try? encoder.encode(shellFrame) else {
            chatStreamLogger.error("chat-subscribe: failed to encode shell frame for session \(self.session.id.uuidString, privacy: .public)")
            return
        }
        await sendTextFrame(shellBody, identifier: "chat-shell")
        guard let detailBody = try? encoder.encode(detailFrame) else {
            chatStreamLogger.error("chat-subscribe: failed to encode detail frame for session \(self.session.id.uuidString, privacy: .public)")
            return
        }
        await sendTextFrame(detailBody, identifier: "chat-detail")
    }

    private func sendTextFrame(_ body: Data, identifier: String) async {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: identifier, metadata: [meta])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(
                content: body,
                contentContext: ctx,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        chatStreamLogger.debug("chat-subscribe send failed (\(identifier, privacy: .public)): \(error.localizedDescription)")
                    }
                    cont.resume()
                }
            )
        }
    }

    private func sendCloseAndCancel(_ code: NWProtocolWebSocket.CloseCode) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = code
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        connection.send(
            content: nil,
            contentContext: ctx,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            }
        )
    }
}
