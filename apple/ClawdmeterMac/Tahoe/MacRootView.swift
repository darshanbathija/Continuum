import SwiftUI
import ClawdmeterShared

/// Tahoe 26 Mac window root — replaces `DashboardView` as the primary
/// SwiftUI scene content. Owns the global `TahoeThemeStore`, paints the
/// wallpaper layer, and hosts the four titlebar tabs (Chat / Usage / Code /
/// Settings) and the menu bar window. Tab routing is purely local — each
/// tab is its own view file under `Tahoe/`.
struct MacRootView: View {
    enum Tab: String, CaseIterable, Hashable { case chat, usage, code, design, settings }

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

    // v0.14.0 (plan v2.1 D6 + D7): handoff toast + reduce-motion guard.
    @State private var handoffToast: String? = nil
    @State private var toastDismissTask: Task<Void, Never>? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func scheduleToastDismiss() {
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { self.handoffToast = nil }
        }
    }

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
                    chatSoloProvider: $chatSoloProvider,
                    runtime: runtime
                )
                    .padding(.horizontal, 10)
                    .padding(.top, 10)

                Group {
                    switch tab {
                    case .chat:
                        MacChatView(
                            mode: $chatMode,
                            soloProvider: $chatSoloProvider,
                            loopbackClient: runtime.loopbackClient,
                            runtime: runtime
                        )
                    case .usage:
                        MacUsageView(
                            data: live,
                            claudeModel: claudeModel,
                            codexModel: codexModel,
                            geminiModel: geminiModel,
                            usageHistoryStore: runtime.usageHistoryStore
                        )
                    case .code:
                        MacCodeView(
                            data: code,
                            onNewSession: { repoKey in
                                newSessionPreselectedRepo = repoKey
                                newSessionPresented = true
                            },
                            loopbackClient: runtime.loopbackClient,
                            runtime: runtime
                        )
                    case .design:
                        MacDesignView(
                            daemon: runtime.openDesignDaemon,
                            onOpenInCode: { _ in
                                // Bridge plugin "Open in Code →" → flip tab.
                                // Per-repo pre-select integration pending T8 wiring.
                                tab = .code
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
        // v0.14.0 (plan v2.1 T8): Code→Design handoff. When AppRuntime
        // emits clawdmeterDidOpenInDesign (after bridge mints token +
        // Open Design returns the projectId), flip to Design tab.
        .onReceive(NotificationCenter.default.publisher(for: .clawdmeterDidOpenInDesign)) { note in
            tab = .design
            if let projectId = note.userInfo?["projectId"] as? String, !projectId.isEmpty {
                handoffToast = "Switched to: \(projectId.prefix(40))"
                scheduleToastDismiss()
            }
        }
        // v0.14.0 (D8): Cmd-1..Cmd-5 keyboard shortcuts for tabs.
        .background(
            Group {
                Button("") { tab = .chat }     .keyboardShortcut("1", modifiers: .command).opacity(0)
                Button("") { tab = .usage }    .keyboardShortcut("2", modifiers: .command).opacity(0)
                Button("") { tab = .code }     .keyboardShortcut("3", modifiers: .command).opacity(0)
                Button("") { tab = .design }   .keyboardShortcut("4", modifiers: .command).opacity(0)
                Button("") { tab = .settings } .keyboardShortcut("5", modifiers: .command).opacity(0)
            }
        )
        // v0.14.0 (D7): handoff toast overlay — top-anchored Tahoe chip
        // that autodismisses after 2s. Visible across all tabs.
        .overlay(alignment: .top) {
            if let handoffToast {
                Text(handoffToast)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 999, style: .continuous).fill(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 999, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 0.5))
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityLabel(handoffToast)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: handoffToast)
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
    /// PR #26 D6: runtime for the secondary-right chips (repo count,
    /// pairing state, sync popover trigger). Nil falls back to static
    /// text for Previews.
    /// v0.21.0 (Design tab): also drives the .design chip via
    /// runtime?.openDesignDaemon.
    var runtime: AppRuntime?

    init(
        active: MacRootView.Tab,
        onTab: @escaping (MacRootView.Tab) -> Void,
        theme: TahoeThemeStore,
        chatMode: Binding<MacChatView.Mode>,
        chatSoloProvider: Binding<TahoeProvider>,
        runtime: AppRuntime? = nil
    ) {
        self.active = active
        self.onTab = onTab
        self.theme = theme
        self._chatMode = chatMode
        self._chatSoloProvider = chatSoloProvider
        self.runtime = runtime
    }

    /// Repo count for the Usage-tab status label.
    private var repoCountLabel: String {
        let count = runtime?.sessionsModel.repos.count ?? 0
        if count == 0 { return "0 repos" }
        if count == 1 { return "1 repo" }
        return "\(count) repos"
    }

    /// Real pairing state for the sync chips. True when any iPhone is
    /// currently paired via the agentControlServer's pairingTokens.
    /// Nil runtime (Previews) returns false.
    private var isIPhonePaired: Bool {
        guard let runtime else { return false }
        return PairingTokenStore.shared.hasAnyPaired
    }

    @State private var syncChipPopoverPresented: Bool = false

    @ViewBuilder
    private var syncChipUsage: some View {
        Button(action: { syncChipPopoverPresented.toggle() }) {
            TahoeSyncChip(
                icon: "qr",
                text: isIPhonePaired ? "iPhone paired" : "Sync with iPhone"
            )
        }
        .buttonStyle(.plain)
        .help(isIPhonePaired ? "Manage paired devices" : "Pair an iPhone")
        // PR #34 (audit retro): the original TODO from PR #26b. The
        // titlebar chip now opens the same `PairingQRPopoverContent`
        // the menu-bar item uses. SwiftUI's `.popover` anchors to the
        // chip's frame; on macOS it renders as a native NSPopover.
        .popover(isPresented: $syncChipPopoverPresented, arrowEdge: .bottom) {
            Group {
                if let runtime {
                    PairingQRPopoverContent(runtime: runtime)
                        .tahoeTheme(TahoeThemeStore.loaded())
                        .padding(16)
                        .frame(width: 340)
                } else {
                    // Preview / unconfigured: tiny placeholder so the
                    // popover doesn't blow up the SwiftUI graph.
                    Text("Pairing unavailable — relaunch Clawdmeter.")
                        .font(TahoeFont.body(12))
                        .padding(20)
                        .frame(width: 280)
                }
            }
        }
    }

    @ViewBuilder
    private var syncChipCode: some View {
        TahoeSyncChip(text: isIPhonePaired ? "iPhone paired" : "No iPhone paired")
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
                    TahoeDashTab("Design",   active: active == .design)   { onTab(.design) }
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
                // PR #26 D6: removed the hardcoded "Updated 14s ago"
                // label (was lying to users). Replaced with a quick
                // status pill showing live repo count.
                Label {
                    Text("\(repoCountLabel) tracked")
                        .font(TahoeFont.body(12))
                } icon: {
                    TahoeIcon("folder", size: 11)
                }
                .foregroundStyle(t.fg2)
                TahoeHair(vertical: true).frame(height: 14)
                // PR #26 D6: sync chip becomes a button — opens a popover
                // with the pairing QR when no iPhone is paired, otherwise
                // shows paired state.
                syncChipUsage
            }
        case .code:
            syncChipCode
        case .design:
            // v0.21.0: health-dot + active project name from the daemon.
            // Nil-runtime (Previews) falls back to a neutral placeholder.
            if let daemon = runtime?.openDesignDaemon {
                HStack(spacing: 6) {
                    Circle()
                        .fill(designHealthColor(for: daemon))
                        .frame(width: 8, height: 8)
                    Text(designChipText(for: daemon))
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                }
            } else {
                Text("Design").font(TahoeFont.body(12)).foregroundStyle(t.fg3)
            }
        case .settings:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.1") · synced")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg2)
        }
    }

    private func designHealthColor(for daemon: OpenDesignDaemonManager) -> Color {
        switch daemon.lifecycle {
        case .ready:                                 return .green
        case .starting, .loading, .restarting:       return .orange
        case .crashed, .failed:                      return .red
        case .idle:                                  return .gray
        }
    }

    private func designChipText(for daemon: OpenDesignDaemonManager) -> String {
        if let name = daemon.activeProjectName, !name.isEmpty {
            return name
        }
        switch daemon.lifecycle {
        case .ready:    return "No project open"
        case .starting: return "Starting…"
        case .loading:  return "Loading…"
        case .crashed:  return "Daemon crashed"
        case .failed:   return "Daemon failed"
        case .restarting: return "Restarting…"
        case .idle:     return "Not started"
        }
    }
}
