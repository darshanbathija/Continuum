import BackgroundTasks
import ClawdmeterShared

/// One-shot launch wiring for side effects that must not run twice.
///
/// `BGTaskScheduler.register(forTaskWithIdentifier:)` crashes with
/// `NSInternalInconsistencyException` if called twice for the same ID.
/// SwiftUI's `App.init()` can run more than once on recent iOS releases
/// (including iOS 27 on device), so registration must live behind `FireOnce`
/// and be triggered from `UIApplicationDelegate.didFinishLaunching`.
@MainActor
enum IOSAppBootstrap {
    private static let launchOnce = FireOnce()
    private static weak var agentClient: AgentControlClient?

    /// Called from `ClawdmeteriOSApp.init` once the shared `AgentControlClient`
    /// exists. Does not register BG tasks yet — waits for UIKit launch.
    static func attachAgentClient(_ client: AgentControlClient) {
        agentClient = client
    }

    /// Call from `iOSAppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    static func finishLaunching() {
        guard let client = agentClient else { return }
        launchOnce.run {
            registerBackgroundRefreshTask()
            IOSRelayClientCoordinator.shared.start()
            IOSRelayClientCoordinator.shared.bindAgentClient(client)
        }
    }

    private static func registerBackgroundRefreshTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: iOSNotificationManager.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let client = AgentControlClient()
            let manager = iOSNotificationManager(client: client)
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
}

private final class BGTaskCompletionGuard: @unchecked Sendable {
    private let fireOnce = FireOnce()
    func complete(task: BGTask, success: Bool) {
        fireOnce.run { task.setTaskCompleted(success: success) }
    }
}
