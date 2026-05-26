import Foundation
import UserNotifications
import BackgroundTasks
import ClawdmeterShared
import OSLog

private let notifLogger = Logger(subsystem: "com.clawdmeter.ios", category: "NotificationManager")

/// Local-notification path (D15: no APNS).
///
/// - While foregrounded: relies on the WebSocket event stream to push
///   plan-ready / session-done events; we surface them as in-app
///   `UNUserNotificationCenter` notifications immediately.
/// - While backgrounded: iOS schedules `BGAppRefreshTask` on its own
///   cadence (~15–30 min). On wake, we poll `GET /sessions/needs-attention`,
///   surface each pending event as a local notification, then ack the
///   highest id.
///
/// iOS Info.plist needs:
///   <key>UIBackgroundModes</key><array><string>fetch</string></array>
///   <key>BGTaskSchedulerPermittedIdentifiers</key>
///     <array><string>com.clawdmeter.ios.refresh</string></array>
@MainActor
public final class iOSNotificationManager: ObservableObject {

    public static let taskIdentifier = "com.clawdmeter.ios.refresh"
    public static let scheduledInterval: TimeInterval = 30 * 60  // 30 min

    public let client: AgentControlClient
    @Published public private(set) var lastAckId: UInt64 = 0

    private let ackIdKey = "clawdmeter.sessions.lastAckId"
    private let presentationProvider: @MainActor () -> SessionPresentationSnapshot

    public init(
        client: AgentControlClient,
        presentationProvider: @escaping @MainActor () -> SessionPresentationSnapshot = {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let store = SessionPresentationStore(
                storeURL: SessionPresentationStore.defaultStoreURL(appSupportDirectory: appSupport)
            )
            return store.snapshot
        }
    ) {
        self.client = client
        self.presentationProvider = presentationProvider
        self.lastAckId = UInt64(UserDefaults.standard.integer(forKey: ackIdKey))
    }

    // MARK: - Permission

    public func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    // MARK: - Background task scheduling

    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor [weak self] in
                guard let self else { task.setTaskCompleted(success: false); return }
                let succeeded = await self.performRefresh()
                self.scheduleBackgroundRefresh()
                task.setTaskCompleted(success: succeeded)
            }
        }
    }

    public func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.scheduledInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            notifLogger.debug("BGAppRefreshTask submit failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Refresh

    @discardableResult
    public func performRefresh() async -> Bool {
        guard client.isConfigured else { return false }
        // P1-Mac-21: don't ack notifications the user never saw. Skip the
        // refresh entirely if notification authorization is denied, and
        // only advance `lastAckId` for events whose local enqueue actually
        // succeeded — otherwise a transient UNUserNotificationCenter error
        // or a denied state silently dropped plan-ready / session-done
        // events because the ack races past them.
        let presentation = presentationProvider()
        let preferences = presentation.notificationPreferences
        let events = await client.fetchNeedsAttention()
        let unseenEvents = events.filter { $0.id > lastAckId }
        guard !unseenEvents.isEmpty else { return true }
        if preferences.dndEnabled {
            notifLogger.debug("DND enabled; suppressing and acking \(unseenEvents.count) events")
            if let maxId = unseenEvents.map(\.id).max() {
                await ackThrough(maxId)
            }
            return true
        }
        let authStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard authStatus == .authorized || authStatus == .provisional || authStatus == .ephemeral else {
            return false
        }
        if preferences.batchBanners, unseenEvents.count > 1 {
            let deliverable = unseenEvents.filter {
                !presentation.mutedSessionIds.contains($0.sessionId)
                    && !preferences.mutedEventIDs.contains($0.kind)
            }
            if deliverable.isEmpty {
                if let maxId = unseenEvents.map(\.id).max() {
                    await ackThrough(maxId)
                }
                return true
            }
            guard await postBatchedLocalNotification(deliverable, preferences: preferences) else {
                return false
            }
            if let maxId = unseenEvents.map(\.id).max() {
                await ackThrough(maxId)
            }
            return true
        }
        var maxId: UInt64 = lastAckId
        for event in unseenEvents {
            if presentation.mutedSessionIds.contains(event.sessionId) || preferences.mutedEventIDs.contains(event.kind) {
                maxId = max(maxId, event.id)
                continue
            }
            let delivered = await postLocalNotification(event, preferences: preferences)
            guard delivered else {
                // Stop advancing on first failure so subsequent retry can
                // re-deliver. ackNotifications below covers everything up
                // to the highest *successfully* delivered id.
                break
            }
            maxId = max(maxId, event.id)
        }
        if maxId > lastAckId {
            await ackThrough(maxId)
        }
        return true
    }

    @discardableResult
    private func postLocalNotification(
        _ event: NotificationEvent,
        preferences: NotificationPresentationPreferences
    ) async -> Bool {
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
            identifier: "clawdmeter.\(event.id)",
            content: content,
            trigger: nil  // fire immediately
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            notifLogger.warning("Failed to enqueue local notification for event \(event.id): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func postBatchedLocalNotification(
        _ events: [NotificationEvent],
        preferences: NotificationPresentationPreferences
    ) async -> Bool {
        guard let first = events.first else { return true }
        let content = UNMutableNotificationContent()
        content.title = "\(events.count) Clawdmeter updates"
        content.body = preferences.sensitivePreviews
            ? events.map(\.title).prefix(3).joined(separator: ", ")
            : "Open Continuum to review pending sessions."
        content.sound = preferences.playChimes ? .default : nil
        content.threadIdentifier = "clawdmeter.batch"
        content.userInfo = [
            "sessionId": first.sessionId.uuidString,
            "kind": "batch",
        ]
        let request = UNNotificationRequest(
            identifier: "clawdmeter.batch.\(first.id)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            notifLogger.warning("Failed to enqueue batched local notification: \(error.localizedDescription)")
            return false
        }
    }

    private func ackThrough(_ maxId: UInt64) async {
        lastAckId = maxId
        UserDefaults.standard.set(Int(maxId), forKey: ackIdKey)
        await client.ackNotifications(through: maxId)
    }
}
