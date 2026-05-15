import Foundation
import ClawdmeterShared
import OSLog

private let notifLogger = Logger(subsystem: "com.clawdmeter.mac", category: "NotificationDispatcher")

/// In-memory pending-notification queue for the iOS app.
///
/// D15 dropped APNS; iOS polls `GET /sessions/needs-attention` from
/// `BGAppRefreshTask` (or sees events live over the WebSocket while
/// foregrounded). This actor is the single source of truth for what's
/// "pending" — when iOS acks an id, everything `<= ackId` is dropped.
///
/// Retention: queue is bounded to the last 256 events. Older events fall
/// off — iOS may miss them, but the on-disk JSONL tails are the durable
/// log of what happened. Notifications are best-effort, not authoritative.
public actor NotificationDispatcher {

    /// Monotonic counter for assigning event ids. Survives daemon restart
    /// only if persisted; we don't persist in Phase 1 (acceptable for the
    /// notifications use case — every restart starts ack from 0 again).
    private var nextId: UInt64 = 1

    /// Pending events, FIFO. Capped at `maxQueueSize`; oldest drop.
    private var pending: [NotificationEvent] = []

    private let maxQueueSize = 256

    public init() {}

    /// Enqueue an event for delivery on iOS's next poll / WS push.
    @discardableResult
    public func enqueue(
        sessionId: UUID,
        kind: String,
        title: String,
        body: String,
        at: Date = Date()
    ) -> NotificationEvent {
        let event = NotificationEvent(
            id: nextId,
            sessionId: sessionId,
            kind: kind,
            title: title,
            body: body,
            at: at
        )
        nextId += 1
        pending.append(event)
        // Bound the queue.
        if pending.count > maxQueueSize {
            let dropped = pending.count - maxQueueSize
            pending.removeFirst(dropped)
            notifLogger.warning("Dropped \(dropped) oldest pending notification(s) — queue cap \(self.maxQueueSize)")
        }
        notifLogger.debug("Enqueued notification id=\(event.id) kind=\(kind) session=\(sessionId.uuidString, privacy: .public)")
        return event
    }

    /// Snapshot the current queue. Returned events are sorted by id ascending.
    public func snapshotEvents() -> [NotificationEvent] {
        pending
    }

    /// Drop everything with `id <= ackId`. Called from
    /// `POST /devices/ack-notifications` handler.
    public func ack(through ackId: UInt64) {
        let before = pending.count
        pending.removeAll { $0.id <= ackId }
        let dropped = before - pending.count
        if dropped > 0 {
            notifLogger.debug("Acked \(dropped) notifications through id \(ackId)")
        }
    }
}
