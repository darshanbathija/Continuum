import Foundation
import ClawdmeterShared

/// iOS-app-side bridge that listens for
/// `Notification.Name.agentControlSessionsRefreshed` from `AgentControlClient`
/// (now in Shared) and forwards the new `[AgentSession]` to the iOS-only
/// `LiveActivityCoordinator` + `WatchPlanBridgeIOS` singletons.
///
/// Why this exists: `AgentControlClient` moved into `ClawdmeterShared` in
/// PR #24a so the Mac loopback client could reuse it. The two iOS-only
/// bridging singletons (Live Activity + watch context) live in the iOS app
/// target and can't be linked from Shared. So instead of importing those
/// types into the shared client, the client posts a notification and this
/// tiny observer dispatches to the singletons.
///
/// Configured by `ContentView.init` (or anywhere the app constructs the
/// `AgentControlClient`). Holds a `NotificationCenter` token for the life
/// of the singleton.
@MainActor
final class AgentControlClientSessionObserver {

    static let shared = AgentControlClientSessionObserver()

    private var token: NSObjectProtocol?

    private init() {
        token = NotificationCenter.default.addObserver(
            forName: .agentControlSessionsRefreshed,
            object: nil,
            queue: .main
        ) { note in
            guard let sessions = note.userInfo?["sessions"] as? [AgentSession] else { return }
            Task { @MainActor in
                LiveActivityCoordinator.shared.refresh(from: sessions)
                // Audit P1 fix: require non-empty `planText` for Codex too
                // — the old filter marked every Codex session as waiting
                // (even mid-generation ones with no plan yet), which
                // overstates the Watch complication count and trains
                // users to ignore real approvals.
                let waiting = sessions.filter {
                    $0.status == .planning
                        && ($0.planText?.isEmpty == false)
                }
                let latest = waiting.max(by: { $0.lastEventAt < $1.lastEventAt })
                WatchPlanBridgeIOS.shared.updateContext(
                    count: waiting.count,
                    latestGoal: latest?.goal,
                    latestPlanSummary: latest?.planText,
                    latestSessionId: latest?.id
                )
            }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    /// Call once at iOS app startup (from `ContentView.init` or
    /// `iOSNotificationManager`) so the singleton is alive to receive
    /// notifications. The singleton self-registers on first access.
    static func configure() {
        _ = AgentControlClientSessionObserver.shared
    }
}
