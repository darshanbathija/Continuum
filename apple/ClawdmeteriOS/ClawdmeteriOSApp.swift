import SwiftUI
import BackgroundTasks
import ClawdmeterShared

@main
struct ClawdmeteriOSApp: App {
    @StateObject private var model = UsageModel()
    /// Reads the same @AppStorage key the Settings picker writes.
    /// Applied on the WindowGroup so the resolved color scheme
    /// propagates into sheets + alerts (which a TabView-level modifier
    /// does NOT do — sheets present in a fresh trait environment).
    @AppStorage("clawdmeter.appearance") private var appearanceRaw: String = AppearanceMode.system.rawValue
    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    init() {
        // Register the BGAppRefreshTask handler at launch (D15 fallback for
        // APNS). The actual scheduling + ack/send happens inside
        // iOSNotificationManager; this just plants the dispatch handler.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: iOSNotificationManager.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            // Use a transient client for the refresh; the persistent
            // instance in ContentView shares UserDefaults state.
            let client = AgentControlClient()
            let manager = iOSNotificationManager(client: client)
            let refreshTask = Task { @MainActor in
                let ok = await manager.performRefresh()
                manager.scheduleBackgroundRefresh()
                task.setTaskCompleted(success: ok)
            }
            // P2-iOS-6: iOS will hard-kill the app if the BG task runs
            // past its budget without responding to the expiration signal.
            // Cancel the in-flight refresh and report failure so the task
            // completes cleanly within the deadline.
            task.expirationHandler = {
                refreshTask.cancel()
                task.setTaskCompleted(success: false)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // Applied here, INSIDE the WindowGroup, so the value
                // lands on the root view's traitCollection — that's
                // the path SwiftUI uses to re-theme sheets and alerts
                // alongside the regular view tree. Returning nil for
                // `.system` lets iOS Settings → Display & Brightness
                // drive things.
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
