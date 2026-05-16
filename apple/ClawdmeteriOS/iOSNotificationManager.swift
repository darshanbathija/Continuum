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

    public init(client: AgentControlClient) {
        self.client = client
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
        let events = await client.fetchNeedsAttention()
        guard !events.isEmpty else { return true }
        var maxId: UInt64 = lastAckId
        for event in events where event.id > lastAckId {
            await postLocalNotification(event)
            maxId = max(maxId, event.id)
        }
        if maxId > lastAckId {
            lastAckId = maxId
            UserDefaults.standard.set(Int(maxId), forKey: ackIdKey)
            await client.ackNotifications(through: maxId)
        }
        return true
    }

    private func postLocalNotification(_ event: NotificationEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
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
        try? await UNUserNotificationCenter.current().add(request)
    }
}
