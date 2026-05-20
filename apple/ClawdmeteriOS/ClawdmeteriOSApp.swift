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
            // P2-iOS-6 + codex-5: BGTask lifecycle hazards.
            // - iOS hard-kills the app if BGTask runs past its budget
            //   without responding to the expiration signal.
            // - iOS treats double setTaskCompleted as a violation. Earlier
            //   patch had a race: expirationHandler completed (false) but
            //   the still-running refreshTask could complete (ok) a second
            //   time. Single-shot guard ensures the first caller wins.
            let completionGuard = BGTaskCompletionGuard()
            let refreshTask = Task { @MainActor in
                let ok = await manager.performRefresh()
                manager.scheduleBackgroundRefresh()
                completionGuard.complete(task: task, success: ok)
            }
            task.expirationHandler = {
                refreshTask.cancel()
                completionGuard.complete(task: task, success: false)
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

/// Single-shot guard so the BGTask expirationHandler and the in-flight
/// refresh Task can both attempt to complete the task without iOS
/// flagging a double-complete. The first caller wins; subsequent calls
/// are no-ops.
private final class BGTaskCompletionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func complete(task: BGTask, success: Bool) {
        lock.lock()
        let firstCall = !completed
        completed = true
        lock.unlock()
        guard firstCall else { return }
        task.setTaskCompleted(success: success)
    }
}
