import Foundation
import UIKit
import UserNotifications
import ClawdmeterShared
import os

/// Holds the latest APNS device token and registers it with the paired Mac
/// daemon once both the token and a pairing exist. Registration is idempotent
/// on the daemon (it overwrites the stored token for the pairing session), so
/// `registerIfReady()` is safe to call repeatedly — on token arrival, app
/// launch, and foreground (the token can arrive before the user has paired).
final class APNSDeviceTokenHolder: @unchecked Sendable {
    static let shared = APNSDeviceTokenHolder()

    private let lock = NSLock()
    private var hexToken: String?
    private let log = Logger(subsystem: "ai.continuum.ios", category: "APNS")

    func setToken(_ hex: String) {
        lock.lock(); hexToken = hex; lock.unlock()
    }

    /// Best-effort POST of the held token to the Mac. No-op until both a token
    /// and a pairing record exist. Uses a transient `AgentControlClient` — its
    /// host/port/Bearer config is read from the shared UserDefaults, exactly
    /// like the BGAppRefresh path in `ClawdmeteriOSApp`.
    func registerIfReady() async {
        let hex = currentToken()
        guard let hex else { return }
        guard let sid = RelayPairingStore.shared.loadRecord()?.sid else {
            log.debug("APNS token held; no pairing yet — will retry on next trigger")
            return
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "ai.continuum.ios"
        let ok = await AgentControlClient().registerAPNSDeviceToken(
            deviceToken: hex, bundleId: bundleId, sessionId: sid)
        log.log("APNS device-token register: \(ok ? "ok" : "failed", privacy: .public)")
    }

    private func currentToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        return hexToken
    }
}

/// Minimal `UIApplicationDelegate` whose only job is to capture the APNS device
/// token — UIKit delivers it to an app-delegate, never to SwiftUI. ContentView
/// drives `registerForRemoteNotifications()` after notification auth and
/// re-attempts the upstream registration on foreground; this delegate just
/// receives the two token callbacks UIKit requires a delegate for. It does NOT
/// claim the `UNUserNotificationCenter` delegate (nothing else does, and
/// lock-screen pushes don't need it).
final class iOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        IOSAppBootstrap.finishLaunching()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02hhx", $0) }.joined()
        APNSDeviceTokenHolder.shared.setToken(hex)
        Task { await APNSDeviceTokenHolder.shared.registerIfReady() }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Logger(subsystem: "ai.continuum.ios", category: "APNS")
            .error("registerForRemoteNotifications failed: \(error.localizedDescription, privacy: .public)")
        // The D15 local-notification fallback (BGAppRefreshTask) still works.
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let handled = await APNSRemotePushHandler.handle(userInfo: userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }
}

extension iOSAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task {
            let handled = await APNSRemotePushHandler.handle(userInfo: notification.request.content.userInfo)
            completionHandler(handled ? [] : [.banner, .sound])
        }
    }
}

enum APNSRemotePushHandler {
    private static let log = Logger(subsystem: "ai.continuum.ios", category: "APNSRemotePush")

    @discardableResult
    static func handle(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let encryptedPayload = userInfo["cmEncrypted"] as? String else {
            return false
        }
        guard let record = RelayPairingStore.shared.loadRecord(),
              let relayKey = RelayPairingStore.shared.loadSymmetricKey(),
              let payloadKey = APNSGatewayKey.derivePayloadKey(
                relaySymmetricKey: relayKey,
                sessionId: record.sid
              ) else {
            log.warning("APNS push ignored: no pairing payload key available")
            return false
        }
        do {
            let body = try APNSPayloadSealer.openJSON(
                as: APNSPushBody.self,
                wire: encryptedPayload,
                keyBytes: payloadKey
            )
            return await postLocalNotification(body)
        } catch {
            log.warning("APNS push decrypt failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @MainActor
    private static func postLocalNotification(_ body: APNSPushBody) async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral else {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = body.title
        content.body = body.body
        content.sound = .default
        content.threadIdentifier = body.sessionId
        content.userInfo = [
            "sessionId": body.sessionId,
            "kind": body.kind,
            "triggerAt": body.triggerAt,
            "source": "apns-gateway",
        ]
        let request = UNNotificationRequest(
            identifier: "continuum.apns.\(body.kind).\(body.sessionId).\(body.triggerAt)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            log.warning("Failed to enqueue decrypted APNS local notification: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
