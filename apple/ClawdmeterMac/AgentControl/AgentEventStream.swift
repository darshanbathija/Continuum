import Foundation
import Network
import Combine
import OSLog
import ClawdmeterShared

private let eventLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AgentEventStream")

/// Per-client structured event stream over WebSocket.
///
/// Implements the E8 cursor contract:
/// - Client connects with `{op:"events", token, since: <lastSeenSeq>}`.
/// - If `since` is older than retention (1024 events / 1 hour), server
///   responds with a `snapshot` frame containing the current sessions
///   list + `asOfSeq`, then resumes incremental events from there.
/// - If `since` is in the retention window, server replays missed events
///   in order then streams new ones live.
/// - Per-session monotonic event sequence comes from
///   `AgentSessionRegistry`. Every status change / planText update
///   increments `lastEventSeq` on the session.
///
/// Network.framework WebSocket sends each `AgentEvent` as a TEXT frame
/// containing JSON. iOS decodes per the wire-stable Codable shape.
@MainActor
public final class AgentEventStream: WSChannel {

    private let connection: NWConnection
    private let registry: AgentSessionRegistry
    private let sinceSeq: UInt64

    private var observerCancellable: AnyCancellable?
    private var recordedCancellable: AnyCancellable?
    private var lastSentSeq: UInt64 = 0

    /// In-memory ring of recent events. Retention: last 1024 events or
    /// last hour, whichever is smaller. Indexed by global event id
    /// (UInt64 monotonic across all sessions).
    private static var globalEventLog: [AgentEvent] = []
    private static var nextGlobalSeq: UInt64 = 1
    private static let maxRetention = 1024
    private static let retentionWindow: TimeInterval = 3_600
    private static var lastSyntheticSnapshot: [UUID: AgentSession] = [:]

    /// P2-Mac-1: `recordEvent` was only delivered to subscribers when a
    /// later `registry.$sessions` mutation triggered `emitDiff`. Plan-mode
    /// + done-detector watchers emit events without mutating the registry,
    /// so those events sat undelivered until something unrelated bumped
    /// the registry. This subject lets every active stream wake up the
    /// moment a new event lands in the log.
    private static let eventRecorded = PassthroughSubject<Void, Never>()

    public init(connection: NWConnection, registry: AgentSessionRegistry, sinceSeq: UInt64) {
        self.connection = connection
        self.registry = registry
        self.sinceSeq = sinceSeq
        // Codex fix: seed `lastSentSeq` from `sinceSeq` so a client
        // reconnecting at the current tail doesn't trigger a duplicate
        // flush of every retained event the first time
        // `eventRecorded` fires. Before this, `lastSentSeq` defaulted
        // to 0, the startup replay sent nothing (no events past
        // current tail), and the next recorded event made
        // `flushPending` re-send every retained event whose seq > 0.
        self.lastSentSeq = sinceSeq
    }

    public func start() {
        Task { @MainActor [self] in
            // Phase 1: catch up — either snapshot (cursor too old) or replay.
            let cutoff = Date().addingTimeInterval(-Self.retentionWindow)
            let inWindow = Self.globalEventLog.filter { $0.at > cutoff }
            let oldestSeq = inWindow.first?.eventSeq ?? Self.nextGlobalSeq
            if sinceSeq < oldestSeq {
                await sendSnapshot()
            } else {
                for event in inWindow where event.eventSeq > sinceSeq {
                    await sendEvent(event)
                }
            }
            // Phase 2: live stream. Observe registry changes; every session
            // mutation bumps its `lastEventSeq` and we emit a `statusChanged`
            // event. JSONL watchers (Phase 4) can also call `recordEvent`
            // directly to emit planReady / doneDetected.
            observerCancellable = registry.$sessions
                .removeDuplicates()
                .sink { [weak self] sessions in
                    Task { @MainActor in
                        await self?.emitDiff(currentSessions: sessions)
                    }
                }
            // P2-Mac-1: also wake up the moment `recordEvent` appends to
            // the log so JSONL-driven events (planReady, doneDetected)
            // don't wait for an unrelated registry mutation to flush.
            recordedCancellable = Self.eventRecorded
                .sink { [weak self] _ in
                    Task { @MainActor in
                        await self?.flushPending()
                    }
                }
        }
    }

    public func stop() {
        observerCancellable?.cancel()
        observerCancellable = nil
        recordedCancellable?.cancel()
        recordedCancellable = nil
        connection.cancel()
    }

    /// Flush any events with seq > `lastSentSeq` to this connection.
    /// Called by the eventRecorded subject after `recordEvent` appends.
    private func flushPending() async {
        let toSend = Self.globalEventLog.filter { $0.eventSeq > lastSentSeq }
        for event in toSend {
            await sendEvent(event)
        }
    }

    // MARK: - Snapshot + emit

    private func sendSnapshot() async {
        let snapshot = AgentEventSnapshot(
            sessions: registry.sessions,
            asOfSeq: Self.nextGlobalSeq - 1
        )
        let payload = (try? JSONEncoder().encodeForWire(snapshot)) ?? Data()
        let event = AgentEvent(
            eventSeq: Self.nextGlobalSeq - 1,
            sessionId: UUID(),  // not session-specific
            kind: .snapshot,
            at: Date(),
            payload: String(decoding: payload, as: UTF8.self)
        )
        await sendEvent(event)
    }

    /// Detect changes since the last emit and synthesize `statusChanged`
    /// events. Phase 4 will replace this with explicit `recordEvent(_)` calls
    /// from PlanModeWatcher / DoneDetector / etc.
    private func emitDiff(currentSessions: [AgentSession]) async {
        Self.recordSyntheticDiffEventsIfNeeded(currentSessions: currentSessions)
        await flushPending()
    }

    private static func recordSyntheticDiffEventsIfNeeded(currentSessions: [AgentSession]) {
        for session in currentSessions {
            let prev = lastSyntheticSnapshot[session.id]
            if prev?.status != session.status || prev?.planText != session.planText {
                let kind: AgentEventKind = session.planText != prev?.planText && session.planText != nil
                    ? .planReady
                    : (session.status == .done ? .doneDetected : .statusChanged)
                AgentEventStream.recordEvent(
                    sessionId: session.id,
                    kind: kind,
                    payload: kind == .planReady
                        ? (session.planText.map { ["planText": $0] } ?? [:])
                        : ["status": session.status.rawValue]
                )
            }
        }
        for (oldId, _) in lastSyntheticSnapshot where !currentSessions.contains(where: { $0.id == oldId }) {
            AgentEventStream.recordEvent(sessionId: oldId, kind: .sessionDeleted, payload: [:])
        }
        lastSyntheticSnapshot = Dictionary(uniqueKeysWithValues: currentSessions.map { ($0.id, $0) })
    }

    internal static func resetEventLogForTesting() {
        globalEventLog.removeAll()
        nextGlobalSeq = 1
        lastSyntheticSnapshot.removeAll()
        lastStatusPushAt.removeAll()
    }

    internal static var eventLogCountForTesting: Int {
        globalEventLog.count
    }

    internal static func recordSyntheticDiffEventsForTesting(currentSessions: [AgentSession]) {
        recordSyntheticDiffEventsIfNeeded(currentSessions: currentSessions)
    }

    private func sendEvent(_ event: AgentEvent) async {
        lastSentSeq = max(lastSentSeq, event.eventSeq)
        guard let data = try? JSONEncoder().encodeForWire(event) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "event", metadata: [meta])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(
                content: data, contentContext: ctx, isComplete: true,
                completion: .contentProcessed { _ in cont.resume() }
            )
        }
    }

    // MARK: - Global event log (consumed by all subscribers)

    /// Record a structured event into the global retention ring. Called
    /// by JSONL watchers, plan-mode watcher, done-detector. All active
    /// AgentEventStream subscribers pick it up on their next emit pass.
    public static func recordEvent(sessionId: UUID, kind: AgentEventKind, payload: [String: String]) {
        let seq = nextGlobalSeq
        nextGlobalSeq += 1
        let payloadString = (try? JSONSerialization.data(withJSONObject: payload).utf8String) ?? "{}"
        let event = AgentEvent(
            eventSeq: seq,
            sessionId: sessionId,
            kind: kind,
            at: Date(),
            payload: payloadString
        )
        globalEventLog.append(event)
        // Bound retention: trim to last `maxRetention` items.
        if globalEventLog.count > maxRetention {
            globalEventLog.removeFirst(globalEventLog.count - maxRetention)
        }
        eventLogger.debug("Recorded event seq=\(seq) kind=\(kind.rawValue) session=\(sessionId.uuidString, privacy: .public)")
        // P2-Mac-1: wake every active AgentEventStream so JSONL-driven
        // events deliver without waiting for a registry mutation.
        eventRecorded.send(())

        // Status-changed APNS push (opt-in; the noisiest surface). Throttled
        // per session by statusChangedMinIntervalSeconds so transitions don't
        // flood the lock screen. plan/done get their own dedicated pushes.
        if kind == .statusChanged {
            maybeFireStatusChangedPush(sessionId: sessionId, payload: payload)
        }
    }

    private static var lastStatusPushAt: [UUID: Date] = [:]

    private static func maybeFireStatusChangedPush(sessionId: UUID, payload: [String: String]) {
        let settings = APNSGatewaySettings.shared
        guard settings.isEnabled(surface: .statusChanged) else { return }
        let now = Date()
        let minInterval = TimeInterval(settings.statusChangedMinIntervalSeconds)
        if let last = lastStatusPushAt[sessionId], now.timeIntervalSince(last) < minInterval { return }
        lastStatusPushAt[sessionId] = now
        let status = payload["status"] ?? payload["to"] ?? "updated"
        let body = APNSPushBody(
            kind: "statusChanged",
            sessionId: sessionId.uuidString,
            title: "Session \(status)",
            body: "Status changed to \(status).",
            triggerAt: UInt64(now.timeIntervalSince1970)
        )
        let coordinator = APNSGatewayPushCoordinator.shared
        Task { _ = await coordinator.notify(surface: .statusChanged, body: body) }
    }
}

private extension JSONEncoder {
    func encodeForWire<T: Encodable>(_ value: T) throws -> Data {
        self.dateEncodingStrategy = .iso8601
        return try self.encode(value)
    }
}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
