import SwiftUI
import BackgroundTasks
import ClawdmeterShared

@main
struct ClawdmeteriOSApp: App {
    @StateObject private var model = UsageModel()
    /// v0.26.2 review: process-wide AgentControlClient so iPad multi-
    /// window doesn't open N parallel WS connections to the daemon
    /// AND so the outbox below has a single, stable dispatch client.
    /// Was previously @StateObject inside ContentView (per-scene).
    @StateObject private var agentClient: AgentControlClient
    /// v0.26.2 review: process-wide MobileCommandOutbox. Was previously
    /// @StateObject inside IOSRootView (per-scene under WindowGroup).
    /// On iPad multi-window each scene loaded outbox.json into its
    /// own memory, and persist() rewrote disk from in-memory state,
    /// so cross-window enqueues raced + the later write dropped the
    /// earlier window's commands. Hoisting to App scope means one
    /// outbox owns the queue for the whole process, every window
    /// sees the same `pending`/`failed`, every persist() is sequenced
    /// through the same actor.
    @StateObject private var outbox: MobileCommandOutbox
    /// Reads the same @AppStorage key the Settings picker writes.
    /// Applied on the WindowGroup so the resolved color scheme
    /// propagates into sheets + alerts (which a TabView-level modifier
    /// does NOT do — sheets present in a fresh trait environment).
    @AppStorage("clawdmeter.appearance") private var appearanceRaw: String = AppearanceMode.system.rawValue
    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    init() {
        let client = AgentControlClient()
        _agentClient = StateObject(wrappedValue: client)
        _outbox = StateObject(wrappedValue: MobileCommandOutbox(client: client))
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
            ContentView(model: model, agentClient: agentClient, outbox: outbox)
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

/// v0.7.7: BGTaskCompletionGuard replaced by shared `FireOnce` +
/// inline call-site closure. Behaviour identical: setTaskCompleted
/// runs exactly once for the first caller, regardless of whether the
/// expirationHandler or the in-flight refresh wins the race.
private final class BGTaskCompletionGuard: @unchecked Sendable {
    private let fireOnce = FireOnce()
    func complete(task: BGTask, success: Bool) {
        fireOnce.run { task.setTaskCompleted(success: success) }
    }
}
