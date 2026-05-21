import SwiftUI
import ClawdmeterShared

/// Tahoe 26 Mac window root — replaces `DashboardView` as the primary
/// SwiftUI scene content. Owns the global `TahoeThemeStore`, paints the
/// wallpaper layer, and hosts the four titlebar tabs (Chat / Usage / Code /
/// Settings) and the menu bar window. Tab routing is purely local — each
/// tab is its own view file under `Tahoe/`.
struct MacRootView: View {
    enum Tab: String, CaseIterable, Hashable { case chat, usage, code, settings }

    @State private var theme: TahoeThemeStore
    @State private var tab: Tab

    /// AppRuntime — drives the live Usage / Menu-bar surfaces via the
    /// `tahoeLive` adapter in `MacTahoeAdapter.swift`. Other surfaces
    /// (Chat / Code / Settings) don't depend on it for v1.
    @ObservedObject private var runtime: AppRuntime
    /// Observed directly so MacCodeView re-renders when sessions appear,
    /// change status, or are archived. AppRuntime intentionally does NOT
    /// forward child publishers (see AppRuntime.swift:72), so we have to
    /// subscribe per-publisher here.
    @ObservedObject private var sessionsModel: SessionsModel
    @ObservedObject private var agentSessionRegistry: AgentSessionRegistry
    /// Per-provider AppModels — observed so the Usage tab + menu-bar
    /// popover repaint when polling lands new `UsageData`.
    @ObservedObject private var claudeModel: AppModel
    @ObservedObject private var codexModel: AppModel
    @ObservedObject private var geminiModel: AppModel

    // Chat-tab state hoisted to the root so the titlebar can host the
    // Broadcast/Solo toggle inline (mac-chat.jsx:175 nests it inside the
    // tabs chip; we mirror that by passing bindings down to MacChatView).
    @State private var chatMode: MacChatView.Mode = .broadcast
    @State private var chatSoloProvider: TahoeProvider = .claude

    /// New-session sheet state — `nil` means closed; an empty string means
    /// "no repo preselected"; a non-empty value pre-selects the repo on
    /// open. Hosted at the root so both MacCodeView (per-repo `+` and
    /// sidebar `folderPlus`) and the future Chat-tab sidebar can present it.
    @State private var newSessionPreselectedRepo: String? = nil
    @State private var newSessionPresented: Bool = false

    init(runtime: AppRuntime, initialTab: Tab = .chat) {
        self.runtime = runtime
        self.sessionsModel = runtime.sessionsModel
        self.agentSessionRegistry = runtime.agentSessionRegistry
        self.claudeModel = runtime.claudeModel
        self.codexModel = runtime.codexModel
        self.geminiModel = runtime.geminiModel
        _theme = State(initialValue: TahoeThemeStore.loaded())
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        // Reading the @ObservedObject child publishers in the body makes
        // SwiftUI's dependency tracking subscribe to each of them. Without
        // these touches, `runtime.tahoeLive` / `runtime.tahoeCode` would
        // still compute correctly but the parent wouldn't re-render when
        // the underlying @Published fired.
        _ = claudeModel.usage
        _ = codexModel.usage
        _ = geminiModel.usage
        _ = sessionsModel.repos
        _ = agentSessionRegistry.sessions

        let live = runtime.tahoeLive
        let code = runtime.tahoeCode
        return ZStack {
            TahoeWallpaperView()
            VStack(spacing: 0) {
                MacTitlebar(
                    active: tab,
                    onTab: { tab = $0 },
                    theme: theme,
                    chatMode: $chatMode,
                    chatSoloProvider: $chatSoloProvider
                )
                    .padding(.horizontal, 10)
                    .padding(.top, 10)

                Group {
                    switch tab {
                    case .chat:     MacChatView(mode: $chatMode, soloProvider: $chatSoloProvider)
                    case .usage:
                        MacUsageView(
                            data: live,
                            claudeModel: claudeModel,
                            codexModel: codexModel,
                            geminiModel: geminiModel
                        )
                    case .code:
                        MacCodeView(
                            data: code,
                            onNewSession: { repoKey in
                                newSessionPreselectedRepo = repoKey
                                newSessionPresented = true
                            }
                        )
                    case .settings:
                        MacSettingsView(
                            theme: theme,
                            claudeModel: claudeModel,
                            codexModel: codexModel,
                            geminiModel: geminiModel
                        )
                    }
                }
                .padding([.horizontal, .bottom], 10)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1280, minHeight: 820)
        .tahoeTheme(theme)
        .background(theme.appearance == .dark ? Color.black : Color(.sRGB, red: 0.94, green: 0.97, blue: 0.98))
        .sheet(isPresented: $newSessionPresented) {
            NewSessionMacSheet(model: sessionsModel, preselectedRepoKey: newSessionPreselectedRepo)
        }
    }
}

// MARK: - Titlebar (shared across all Mac tabs)

/// Floating titlebar — traffic lights chip + tabs chip + ancillary status.
/// Matches the pattern shared by every Mac artboard in the design
/// (mac-chat.jsx, mac-dashboard.jsx, mac-sessions.jsx, mac-settings.jsx).
struct MacTitlebar: View {
    @Environment(\.tahoe) private var t
    var active: MacRootView.Tab
    var onTab: (MacRootView.Tab) -> Void
    var theme: TahoeThemeStore
    @Binding var chatMode: MacChatView.Mode
    @Binding var chatSoloProvider: TahoeProvider

    init(
        active: MacRootView.Tab,
        onTab: @escaping (MacRootView.Tab) -> Void,
        theme: TahoeThemeStore,
        chatMode: Binding<MacChatView.Mode>,
        chatSoloProvider: Binding<TahoeProvider>
    ) {
        self.active = active
        self.onTab = onTab
        self.theme = theme
        self._chatMode = chatMode
        self._chatSoloProvider = chatSoloProvider
    }

    var body: some View {
        HStack(spacing: 10) {
            TahoeGlass(radius: 11, tone: .chip) {
                TahoeTrafficLights()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }

            TahoeGlass(radius: 11, tone: .chip) {
                HStack(spacing: 10) {
                    TahoeDashTab("Chat",     active: active == .chat)     { onTab(.chat) }
                    TahoeDashTab("Usage",    active: active == .usage)    { onTab(.usage) }
                    TahoeDashTab("Code",     active: active == .code)     { onTab(.code) }
                    TahoeDashTab("Settings", active: active == .settings) { onTab(.settings) }
                    Spacer(minLength: 0)
                    secondaryRight
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var secondaryRight: some View {
        switch active {
        case .chat:
            ChatModeToggle(mode: $chatMode, soloProvider: $chatSoloProvider)
        case .usage:
            HStack(spacing: 8) {
                Label {
                    Text("Updated 14s ago")
                        .font(TahoeFont.body(12))
                } icon: {
                    TahoeIcon("refresh", size: 11)
                }
                .foregroundStyle(t.fg2)
                TahoeHair(vertical: true).frame(height: 14)
                TahoeSyncChip(icon: "qr", text: "Sync with iPhone")
            }
        case .code:
            TahoeSyncChip(text: "iPhone paired")
        case .settings:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.1") · synced")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg2)
        }
    }
}
