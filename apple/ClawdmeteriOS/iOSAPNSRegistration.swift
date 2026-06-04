import Foundation
import UIKit
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
        lock.lock(); let hex = hexToken; lock.unlock()
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
}
