import Foundation
import Network
import OSLog
import Combine
import ClawdmeterShared

private let frontierStreamLogger = Logger(subsystem: "com.clawdmeter.mac", category: "FrontierStreamWS")

/// v0.9.x — server push for the 3-pane Frontier compare UI.
///
/// One WS subscription per client per group. The channel acquires every
/// child's `SessionChatStore` from `DaemonChatStoreRegistry`, observes
/// their snapshots in parallel via Combine, and emits a single
/// `FrontierGroupSnapshot` envelope on each debounced 100ms commit
/// window.
///
/// This is a convenience aggregator — the same data is also reachable
/// via N independent `chat-subscribe` connections (one per child).
/// The aggregator wins for two reasons:
///   1. The iOS Frontier UI only renders one pane at a time anyway
///      (segmented control), so opening 3 sockets and tearing down 2
///      of their backpressure is wasteful.
///   2. The Mac 3-pane UI wants a single update tick to swap all 3
///      panes in lockstep — N independent subscriptions would land
///      out-of-order.
///
/// Wire envelope (JSON text frames):
///   Client → Server: `{op: "frontier-subscribe", token, groupId}`.
///   Server → Client: `FrontierGroupSnapshot` per coalesce window.
///     First frame contains the current state for all live children;
///     subsequent frames carry the latest snapshot for each. The
///     `updateCounter` field bumps on any child change so consumers
///     can debounce their own UI work.
///
/// Lifecycle: `start()` acquires each child store; `stop()` releases
/// them all. Children added to the group AFTER `start()` (via
/// retry-slot) are NOT live-subscribed in this iteration — the client
/// should reconnect after a retry-slot reply. Polish v0.9.x+.
@MainActor
public final class FrontierWebSocketChannel: WSChannel {

    private let connection: NWConnection
    private let groupId: UUID
    private let registry: DaemonChatStoreRegistry
    private let sessionRegistry: AgentSessionRegistry
    private var stores: [(child: AgentSession, store: SessionChatStore)] = []
    private var cancellables: [AnyCancellable] = []
    private var pendingPush: Task<Void, Never>?
    private var updateCounter: Int = 0
    private let encoder: JSONEncoder

    /// Coalesce window, same as chat-subscribe.
    public static let coalesceWindowMs: Int = 100

    public init(
        connection: NWConnection,
        groupId: UUID,
        registry: DaemonChatStoreRegistry,
        sessionRegistry: AgentSessionRegistry
    ) {
        self.connection = connection
        self.groupId = groupId
        self.registry = registry
        self.sessionRegistry = sessionRegistry
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func start() {
        let children = sessionRegistry.frontierGroupChildren(groupId: groupId)
        guard !children.isEmpty else {
            frontierStreamLogger.warning("frontier-subscribe: no children for group \(self.groupId.uuidString, privacy: .public)")
            sendCloseAndCancel(.protocolCode(.unsupportedData))
            return
        }
        for child in children {
            guard let store = registry.acquire(for: child) else { continue }
            stores.append((child, store))
            // Each child's snapshot publisher feeds a per-store
            // debounced push. We bump `updateCounter` and emit a fresh
            // aggregate envelope — slightly chatty if all 3 stream in
            // parallel, but the debounce collapses the burst.
            let cancellable = store.$snapshot
                .removeDuplicates { $0.updateCounter == $1.updateCounter }
                .debounce(
                    for: .milliseconds(Self.coalesceWindowMs),
                    scheduler: DispatchQueue.main
                )
                .sink { [weak self] _ in
                    self?.schedulePush()
                }
            cancellables.append(cancellable)
        }
        frontierStreamLogger.info("frontier-subscribe started group=\(self.groupId.uuidString, privacy: .public) children=\(self.stores.count)")
        // Initial push so the client has something to render before
        // the first commit cycle.
        Task { @MainActor [weak self] in
            await self?.pushAggregate()
        }
    }

    public func stop() {
        pendingPush?.cancel()
        pendingPush = nil
        for c in cancellables { c.cancel() }
        cancellables.removeAll()
        for (child, _) in stores {
            registry.release(sessionId: child.id)
        }
        stores.removeAll()
        connection.cancel()
        frontierStreamLogger.info("frontier-subscribe stopped group=\(self.groupId.uuidString, privacy: .public)")
    }

    // MARK: - Push

    private func schedulePush() {
        // Coalesce multiple per-child triggers into one envelope.
        pendingPush?.cancel()
        pendingPush = Task { @MainActor [weak self] in
            await self?.pushAggregate()
        }
    }

    private func pushAggregate() async {
        updateCounter += 1
        var children: [FrontierChild] = []
        for (child, store) in stores {
            let snap = store.snapshot
            let wire = WireChatSnapshot(
                sessionId: child.id,
                items: snap.items,
                planSteps: snap.planSteps,
                sourceEntries: snap.sourceEntries,
                artifactEntries: snap.artifactEntries,
                codexTodos: snap.codexTodos,
                totalInputTokens: snap.totalInputTokens,
                totalOutputTokens: snap.totalOutputTokens,
                lastEventAt: snap.lastEventAt ?? child.lastEventAt,
                updateCounter: snap.updateCounter
            )
            let status: FrontierChildStatus = {
                if child.archivedAt != nil { return .complete }
                if snap.items.isEmpty { return .pending }
                return .streaming
            }()
            children.append(FrontierChild(
                childIndex: child.frontierChildIndex ?? 0,
                sessionId: child.id,
                modelSlug: child.model ?? "",
                snapshot: wire,
                status: status
            ))
        }
        let envelope = FrontierGroupSnapshot(
            groupId: groupId,
            updateCounter: updateCounter,
            children: children
        )
        guard let body = try? encoder.encode(envelope) else {
            frontierStreamLogger.error("frontier-subscribe: encode failed group=\(self.groupId.uuidString, privacy: .public)")
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "frontier-snapshot", metadata: [meta])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(
                content: body,
                contentContext: ctx,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        frontierStreamLogger.debug("frontier-subscribe send failed: \(error.localizedDescription)")
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
