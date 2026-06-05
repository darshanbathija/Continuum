import SwiftUI
import BackgroundTasks
import ClawdmeterShared

@main
struct ClawdmeteriOSApp: App {
    /// Captures the APNS device token. UIKit delivers it to a UIApplication-
    /// Delegate (not to SwiftUI); `APNSDeviceTokenHolder` then forwards it to
    /// the paired Mac. ContentView drives `registerForRemoteNotifications()`.
    @UIApplicationDelegateAdaptor(iOSAppDelegate.self) private var appDelegate
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
    /// Tahoe redesign's own appearance toggle (defaults to dark per
    /// `TahoeThemeStore.loaded()`). When the legacy picker is on
    /// `.system`, this drives the color scheme so the Tahoe wallpaper
    /// (which is unconditionally dark when `t.dark == true`) stays in
    /// sync with the UIKit semantic colors that LiveGaugesHeader / Pair
    /// banners use under the hood. Without this sync, a user on iOS-light
    /// system mode + Tahoe-dark theme saw `Color.black` wallpaper but
    /// `secondarySystemGroupedBackground` cards rendered light — mixed.
    @AppStorage("tahoe.appearance") private var tahoeAppearanceRaw: String = "dark"
    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }
    /// Resolved scheme: explicit legacy pin wins; otherwise follow the
    /// Tahoe theme. Never returns `nil`, so the whole app — including
    /// UIKit semantic colors — stays consistently dark (or light) instead
    /// of falling back to the device system and creating mixed surfaces.
    private var resolvedColorScheme: ColorScheme {
        if let explicit = appearance.colorScheme {
            return explicit
        }
        return tahoeAppearanceRaw == "light" ? .light : .dark
    }

    init() {
        #if DEBUG
        let screenshotCodeFixture = ProcessInfo.processInfo.arguments.contains("--ios-code-demo")
        let client = AgentControlClient(codeTabVerificationFixture: screenshotCodeFixture)
        #else
        let client = AgentControlClient()
        #endif
        _agentClient = StateObject(wrappedValue: client)
        _outbox = StateObject(wrappedValue: MobileCommandOutbox(client: client))

        // E4: spin up the outbound relay client if a pairing record
        // exists. This runs side-by-side with the existing Tailscale
        // `AgentControlClient` path — the relay is the "second
        // transport" the design doc §1 promised, and stays in fallback
        // until E3 lands the Mac-side relay sender. When no pairing
        // exists this is a no-op; callers can still use Tailscale
        // unchanged.
        IOSRelayClientCoordinator.shared.start()
        // Track B (B1): bind the shared client so its `relayMux` tracks the
        // coordinator's mux client → the events + frontier streams route over
        // the relay when relayDefault is on (nil ⇒ direct, byte-identical).
        IOSRelayClientCoordinator.shared.bindAgentClient(client)
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
                // alongside the regular view tree. Per Apple docs, the
                // ROOT-MOST preferredColorScheme wins, so a `nil` here
                // overrides any inner `.preferredColorScheme(.dark)` from
                // TahoeThemeApplied. To keep the iOS app consistently
                // themed (no mixed light/dark surfaces), always resolve
                // to a concrete scheme — legacy pin > Tahoe > .dark.
                .preferredColorScheme(resolvedColorScheme)
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
