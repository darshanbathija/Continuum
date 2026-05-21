import SwiftUI
import ClawdmeterShared

/// Root iOS tab container. v0.8 nav reshuffle: Live tab dissolved into
/// Analytics tab's header (`LiveGaugesHeader`); Sessions renamed to Code;
/// Chat tab added as the first tab (Phase 5 of v0.8). Order: Chat /
/// Analytics / Code, matching the plan.
///
/// v0.12 button-wiring: settings sheet hoisted into `IOSRootView` so the
/// Live-tab gear button can present it directly. ContentView only owns
/// the runtime models + notification scheduling now.
struct ContentView: View {
    @ObservedObject var model: UsageModel
    @StateObject private var agentClient = AgentControlClient()
    @StateObject private var notifManager: iOSNotificationManager

    init(model: UsageModel) {
        self.model = model
        let client = AgentControlClient()
        _agentClient = StateObject(wrappedValue: client)
        _notifManager = StateObject(wrappedValue: iOSNotificationManager(client: client))
        WatchPlanBridgeIOS.configure(client: client)
        model.wire(daemonClient: client)
        LiveActivityCoordinator.shared.client = client
        // Wire the iOS-side bridge so AgentControlClient.refreshSessions
        // notifications (posted from Shared) reach the iOS-only Live
        // Activity + watch bridging singletons. See
        // AgentControlClientSessionObserver.swift for context.
        AgentControlClientSessionObserver.configure()
    }

    var body: some View {
        // Tahoe 26 redesign: the four-tab IOSRootView (Chat | Live |
        // Analytics | Code) replaces the previous 3-tab `TabView`. The
        // UsageModel is threaded in so the Live tab renders the live
        // per-provider quota via the `tahoeLive` adapter
        // (see IOSTahoeAdapter.swift).
        IOSRootView(usageModel: model, agentClient: agentClient)
            .task {
                await notifManager.requestAuthorizationIfNeeded()
                notifManager.scheduleBackgroundRefresh()
            }
    }
}
