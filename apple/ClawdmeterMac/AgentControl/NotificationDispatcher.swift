import Foundation
import ClawdmeterShared
import OSLog
import UserNotifications

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
    private let presentationProvider: @Sendable () -> SessionPresentationSnapshot
    private var macBatch: [NotificationEvent] = []
    private var macBatchFlushTask: Task<Void, Never>?

    public init(
        presentationProvider: @escaping @Sendable () -> SessionPresentationSnapshot = {
            let store = SessionPresentationStore(
                storeURL: SessionPresentationStore.defaultStoreURL(
                    appSupportDirectory: WorkspaceStore.defaultStoreURL().deletingLastPathComponent()
                )
            )
            return store.snapshot
        }
    ) {
        self.presentationProvider = presentationProvider
    }

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
        routeMacNotification(event)
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

    private func routeMacNotification(_ event: NotificationEvent) {
        let presentation = presentationProvider()
        let preferences = presentation.notificationPreferences
        guard !preferences.dndEnabled,
              !presentation.mutedSessionIds.contains(event.sessionId),
              !preferences.mutedEventIDs.contains(event.kind) else {
            return
        }

        guard preferences.batchBanners else {
            Task { await MacLocalNotificationPresenter.present(event, preferences: preferences) }
            return
        }

        macBatch.append(event)
        guard macBatchFlushTask == nil else { return }
        macBatchFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.flushMacBatch()
        }
    }

    private func flushMacBatch() async {
        let events = macBatch
        macBatch.removeAll()
        macBatchFlushTask = nil

        let presentation = presentationProvider()
        let preferences = presentation.notificationPreferences
        guard !preferences.dndEnabled else { return }
        let deliverable = events.filter {
            !presentation.mutedSessionIds.contains($0.sessionId)
                && !preferences.mutedEventIDs.contains($0.kind)
        }
        guard !deliverable.isEmpty else { return }

        if deliverable.count == 1, let event = deliverable.first {
            await MacLocalNotificationPresenter.present(event, preferences: preferences)
        } else {
            await MacLocalNotificationPresenter.presentBatch(deliverable, preferences: preferences)
        }
    }
}

private enum MacLocalNotificationPresenter {
    static func present(_ event: NotificationEvent, preferences: NotificationPresentationPreferences) async {
        await playChimeIfNeeded(preferences: preferences)
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = preferences.sensitivePreviews ? event.body : "Open Continuum to review this session."
        content.sound = preferences.playChimes ? .default : nil
        content.threadIdentifier = event.sessionId.uuidString
        content.userInfo = [
            "sessionId": event.sessionId.uuidString,
            "kind": event.kind,
        ]

        let request = UNNotificationRequest(
            identifier: "clawdmeter.mac.\(event.id)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            notifLogger.warning("Failed to enqueue Mac notification for event \(event.id): \(error.localizedDescription)")
        }
    }

    static func presentBatch(_ events: [NotificationEvent], preferences: NotificationPresentationPreferences) async {
        guard let first = events.first else { return }
        await playChimeIfNeeded(preferences: preferences)
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(events.count) Clawdmeter updates"
        content.body = preferences.sensitivePreviews
            ? events.map(\.title).prefix(3).joined(separator: ", ")
            : "Open Continuum to review pending sessions."
        content.sound = preferences.playChimes ? .default : nil
        content.threadIdentifier = "clawdmeter.mac.batch"
        content.userInfo = [
            "sessionId": first.sessionId.uuidString,
            "kind": "batch",
        ]

        let request = UNNotificationRequest(
            identifier: "clawdmeter.mac.batch.\(first.id)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            notifLogger.warning("Failed to enqueue Mac notification batch: \(error.localizedDescription)")
        }
    }

    private static func ensureAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                notifLogger.warning("Mac notification authorization failed: \(error.localizedDescription)")
                return false
            }
        default:
            return false
        }
    }

    @MainActor
    private static func playChimeIfNeeded(preferences: NotificationPresentationPreferences) {
        guard preferences.playChimes else { return }
        ChimeAudioPlayer.shared.playCompletion()
    }
}
