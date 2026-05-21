import SwiftUI
import ClawdmeterShared

/// Root iOS tab container. v0.8 nav reshuffle: Live tab dissolved into
/// Analytics tab's header (`LiveGaugesHeader`); Sessions renamed to Code;
/// Chat tab added as the first tab (Phase 5 of v0.8). Order: Chat /
/// Analytics / Code, matching the plan.
struct ContentView: View {
    @ObservedObject var model: UsageModel
    @StateObject private var agentClient = AgentControlClient()
    @StateObject private var notifManager: iOSNotificationManager
    @State private var showingSettings: Bool = false

    init(model: UsageModel) {
        self.model = model
        let client = AgentControlClient()
        _agentClient = StateObject(wrappedValue: client)
        _notifManager = StateObject(wrappedValue: iOSNotificationManager(client: client))
        WatchPlanBridgeIOS.configure(client: client)
        model.wire(daemonClient: client)
        LiveActivityCoordinator.shared.client = client
    }

    var body: some View {
        TabView {
            iOSChatView(client: agentClient)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }

            iOSAnalyticsView(model: model, agentClient: agentClient, showingSettings: $showingSettings)
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar")
                }

            iOSSessionsView(client: agentClient)
                .tabItem {
                    Label("Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
        .task {
            await notifManager.requestAuthorizationIfNeeded()
            notifManager.scheduleBackgroundRefresh()
        }
    }
}
