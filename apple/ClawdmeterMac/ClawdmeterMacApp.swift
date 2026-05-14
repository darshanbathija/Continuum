import SwiftUI
import ClawdmeterShared

/// Mac menu bar app entry point.
///
/// Per codex's diagnosis: `MenuBarExtra` label `.task` modifiers on macOS Tahoe
/// are unreliable for starting app-owned work. Both AppModels are owned by an
/// app-level `AppRuntime` (`@StateObject`), which starts them in its init and
/// forwards their `objectWillChange` so MenuBarExtra scenes invalidate reliably.
@main
struct ClawdmeterMacApp: App {
    @StateObject private var runtime = AppRuntime()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Hand the AppDelegate a reference to the runtime so its
        // applicationDidFinishLaunching has the models in hand. The delegate
        // creates the menu bar status items based on user prefs.
        // (Set after `runtime` is initialized — @StateObject's wrapped value
        // is constructed lazily on first access, so we read it once here.)
    }

    var body: some Scene {
        // Main window — appears when launched from /Applications, Spotlight,
        // or the Dock. Both providers side-by-side. The menu bar items are
        // created/destroyed by `AppDelegate` based on the per-provider
        // "show in menu bar" toggles in the dashboard.
        //
        // No more `MenuBarExtra` — the dashboard's toggles need to hide the
        // status items conditionally, which `MenuBarExtra(isInserted:)`
        // can't do without triggering Tahoe's KVO loop. `NSStatusItem`
        // (managed by AppDelegate) supports `.isVisible` natively.
        Window("Clawdmeter", id: "dashboard") {
            DashboardView(
                claudeModel: runtime.claudeModel,
                codexModel: runtime.codexModel,
                usageHistoryStore: runtime.usageHistoryStore
            )
            .background(DashboardOpener())   // bridges AppDelegate → openWindow
            .onAppear {
                // Late binding: AppDelegate runs before our SwiftUI view
                // hierarchy materializes, but we can publish the runtime
                // reference on first appearance and AppDelegate picks it
                // up via the static var.
                AppDelegate.runtime = runtime
                // Notify so the delegate re-applies visibility (no-op if
                // already configured).
                NotificationCenter.default.post(
                    name: UserDefaults.didChangeNotification, object: nil
                )
                // Make sure we're a regular app whenever the dashboard is
                // visible — the Dock icon goes back on.
                NSApp.setActivationPolicy(.regular)
            }
        }
        // Tall enough that the live cards + the analytics row (totals grid +
        // daily chart + by-repo) are all visible on first open without
        // scrolling on a typical Mac display.
        .defaultSize(width: 980, height: 1100)
        .windowResizability(.contentMinSize)

        Settings {
            PreferencesView(
                claudeModel: runtime.claudeModel,
                codexModel: runtime.codexModel
            )
        }
    }
}

/// Zero-pixel SwiftUI helper that owns an `openWindow` environment action and
/// forwards `AppDelegate.openDashboardRequest` notifications to it. Lives
/// inside the dashboard window so it can call `openWindow(id:)`.
private struct DashboardOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openDashboardRequest)) { _ in
                openWindow(id: "dashboard")
            }
    }
}

/// cmd+, Settings.
struct PreferencesView: View {
    @ObservedObject var claudeModel: AppModel
    @ObservedObject var codexModel: AppModel
    @AppStorage(AppTheme.storageKey) private var themeRaw: String = AppTheme.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }

            Section {
                Button("Force poll Claude") { claudeModel.forcePoll() }
                Button("Force poll Codex") { codexModel.forcePoll() }
            } header: {
                Text("Diagnostics")
            }
        }
        .padding(20)
        .frame(width: 440, height: 280)
        .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
    }
}
