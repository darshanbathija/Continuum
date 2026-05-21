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
            // Tahoe 26 redesign: the new MacRootView owns the four
            // titlebar tabs (Chat / Usage / Code / Settings) and the
            // global TahoeThemeStore. The original DashboardView is
            // intentionally retained in the file tree so AppRuntime
            // wiring isn't disturbed mid-port — pop-out + menu-bar code
            // paths still reference it.
            MacRootView()
                .background(DashboardOpener())   // bridges AppDelegate → openWindow
                .onAppear {
                    appDelegate.configure(runtime: runtime)
                    NotificationCenter.default.post(
                        name: UserDefaults.didChangeNotification, object: nil
                    )
                    NSApp.setActivationPolicy(.regular)
                }
        }
        // Sized to comfortably show the three-column Chat compare layout
        // (sidebar 248 + 3×~340 columns + gaps) at first open.
        .defaultSize(width: 1320, height: 920)
        .windowResizability(.contentMinSize)

        // G14: pop-out window for a single session. Accepts a UUID via the
        // `openWindow(value:)` environment action. The window's title and
        // content reflect the chosen session; closing it doesn't affect the
        // main dashboard.
        WindowGroup("Session", id: "session-detail", for: UUID.self) { $sessionId in
            if let sessionId,
               let session = runtime.agentSessionRegistry.sessions.first(where: { $0.id == sessionId }) {
                PoppedOutSessionView(session: session, model: runtime.sessionsModel)
            } else {
                ContentUnavailableView(
                    "Session not found",
                    systemImage: "questionmark.circle",
                    description: Text("This session may have been closed.")
                )
            }
        }
        .defaultSize(width: 720, height: 720)

        Settings {
            TabView {
                PreferencesView(
                    claudeModel: runtime.claudeModel,
                    codexModel: runtime.codexModel
                )
                .tabItem { Label("General", systemImage: "gearshape") }

                ProvidersSettingsView(
                    claudeModel: runtime.claudeModel,
                    codexModel: runtime.codexModel,
                    geminiModel: runtime.geminiModel
                )
                .tabItem { Label("Providers", systemImage: "person.crop.rectangle.stack") }

                PairingSettingsView(runtime: runtime)
                    .tabItem { Label("Sessions", systemImage: "rectangle.connected.to.line.below") }

                // v0.7.2: Codex SDK observation mode toggle + diagnostics.
                CodexSDKSettingsView()
                    .tabItem { Label("Codex SDK", systemImage: "swift") }

                // v0.7.7: Antigravity SDK toggle UI (D3 completion).
                AntigravitySDKSettingsView()
                    .tabItem { Label("Antigravity", systemImage: "sparkles") }

                DiagnosticsSettingsView()
                    .tabItem { Label("Diagnostics", systemImage: "stethoscope") }

                LiveActivitySetupView()
                    .tabItem { Label("Live Activities", systemImage: "bell.badge.waveform") }
            }
        }
    }
}

// MARK: - Pop-out session window

/// G14 detachable session view. Shows just the chat thread + composer for
/// the chosen session; no sidebar, no review pane. The host window picks
/// up the `.floating` level when the user toggles "Stay on top" in the
/// Window menu (handled by AppDelegate).
struct PoppedOutSessionView: View {
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let store = model.chatStore(for: session) {
                PoppedChatThread(store: store, session: session, model: model)
            } else {
                ContentUnavailableView {
                    Label("No JSONL yet", systemImage: "ellipsis.bubble")
                } description: {
                    Text("Waiting for the agent to write its first message…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(bg)
        .frame(minWidth: 480, minHeight: 360)
        // Register this session as protected from LRU eviction while the
        // pop-out window is on screen. Without this, navigating through
        // three other sessions in the main workspace would evict and
        // `stop()` this window's chat store underneath it (Codex M1).
        .onAppear { model.protectSession(session.id) }
        .onDisappear { model.unprotectSession(session.id) }
    }

    private var header: some View {
        HStack {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text(session.goal ?? session.repoDisplayName)
                .font(.system(size: 13, weight: .semibold))
            Text("· \(session.agent.rawValue.capitalized) · \(session.status.rawValue)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: toggleStayOnTop) {
                Image(systemName: "pin")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Toggle stay-on-top for this window")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toggleStayOnTop() {
        guard let window = NSApp.keyWindow else { return }
        window.level = (window.level == .floating) ? .normal : .floating
    }

    private var bg: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.08)
            : Color(red: 0.98, green: 0.98, blue: 0.98)
    }
}

/// Minimal chat-thread renderer reused inside PoppedOutSessionView. Mirrors
/// the main workspace's `ChatThreadScroll` but with no plan-card / no
/// review pane — just chat + send.
private struct PoppedChatThread: View {
    @ObservedObject var store: SessionChatStore
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    @State private var composerText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.messages) { msg in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: msg.kind == .userText
                                ? "person.fill"
                                : (msg.kind == .toolCall ? "wrench" : "sparkle"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(msg.body)
                                .font(.system(size: 12, design: msg.kind == .toolCall ? .monospaced : .default))
                                .foregroundStyle(.primary)
                                .lineLimit(msg.kind == .toolResult ? 3 : nil)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 12)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.vertical, 8)
            }
            Divider()
            HStack {
                TextField("Message the agent…", text: $composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .lineLimit(1...5)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(composerText.isEmpty ? .secondary : Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(composerText.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let runtime = AppDelegate.runtime,
              let pane = session.tmuxPaneId ?? session.tmuxWindowId
        else { return }
        composerText = ""
        let bytes = Data((text + "\n").utf8)
        Task {
            try? await runtime.tmuxClient.pasteBytes(paneId: pane, bytes: bytes)
        }
    }
}

/// Zero-pixel SwiftUI helper that owns an `openWindow` environment action and
/// forwards `AppDelegate.openDashboardRequest` notifications to it. Lives
/// inside the dashboard window so it can call `openWindow(id:)`. Also
/// listens for `popOutSession` (G14) and opens a new session-detail window.
private struct DashboardOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openDashboardRequest)) { _ in
                openWindow(id: "dashboard")
            }
            .onReceive(NotificationCenter.default.publisher(for: .popOutSession)) { note in
                guard let sessionId = note.userInfo?["sessionId"] as? UUID else { return }
                openWindow(id: "session-detail", value: sessionId)
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
