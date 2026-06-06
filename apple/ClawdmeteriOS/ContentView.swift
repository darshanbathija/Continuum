import SwiftUI
import ClawdmeterShared
import UIKit
import UserNotifications
import Combine

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
    /// v0.26.2 review: agentClient + outbox are now process-wide,
    /// owned by `ClawdmeteriOSApp`. iPad multi-window scenes all
    /// observe the same instances, so cross-window enqueues no
    /// longer race on outbox.json and we don't open N parallel WS
    /// connections per device.
    @ObservedObject var agentClient: AgentControlClient
    @ObservedObject var outbox: MobileCommandOutbox
    @StateObject private var notifManager: iOSNotificationManager

    init(model: UsageModel, agentClient: AgentControlClient, outbox: MobileCommandOutbox) {
        self.model = model
        self.agentClient = agentClient
        self.outbox = outbox
        _notifManager = StateObject(wrappedValue: iOSNotificationManager(client: agentClient))
        WatchPlanBridgeIOS.configure(client: agentClient, outbox: outbox)
        model.wire(daemonClient: agentClient)
        LiveActivityCoordinator.shared.client = agentClient
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
        IOSRootView(usageModel: model, agentClient: agentClient, outbox: outbox)
            .task {
                await notifManager.requestAuthorizationIfNeeded()
                // APNS: once notif auth is granted, register for remote
                // notifications (delivers the device token to iOSAppDelegate)
                // and push it to the paired Mac. registerIfReady is idempotent.
                let status = await UNUserNotificationCenter.current()
                    .notificationSettings().authorizationStatus
                if status == .authorized || status == .provisional {
                    await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
                }
                await APNSDeviceTokenHolder.shared.registerIfReady()
                notifManager.scheduleBackgroundRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in
                // Re-attempt registration after the user pairs (the token may
                // have arrived before a pairing existed) or returns to foreground.
                Task { await APNSDeviceTokenHolder.shared.registerIfReady() }
            }
    }
}
