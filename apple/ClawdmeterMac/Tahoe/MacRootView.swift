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
    /// Observed directly so MacCodeShell re-renders when sessions appear,
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

    // v0.23: legacy chatMode + chatSoloProvider bindings retired with
    // MacChatView (T16). The V2 chat composer owns its own selection
    // state via `ChatV2Store` (T10). MacTitlebar's `secondaryRight`
    // branch for `.chat` is `EmptyView()` so it doesn't need bindings.

    // v0.14.0 (plan v2.1 D6 + D7): handoff toast + reduce-motion guard.
    @State private var handoffToast: String? = nil
    @State private var toastStartedAt: Date = Date()
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
        return ZStack {
            TahoeWallpaperView()
            VStack(spacing: 0) {
                MacTitlebar(
                    active: tab,
                    onTab: { tab = $0 },
                    theme: theme,
                    runtime: runtime
                )
                    .padding(.horizontal, 10)
                    // v0.22.7: flush the titlebar chip against the top of
                    // the window — previously a 10pt top inset was leaving
                    // a visible dark band above the chip even with the
                    // native title bar hidden. The chip now occupies y=0..44
                    // and the macOS traffic lights overlay vertically
                    // centered against it.
                    .padding(.top, 0)
                    // v0.22.14: even with .windowStyle(.hiddenTitleBar) +
                    // padding(.top, 0), AppKit still reserves a ~28pt
                    // titlebar-region safe-area inset by default — which
                    // showed as a visible dark band above the chip. The
                    // user reported "move the top row to the entire
                    // top (same level as the red/yellow/green buttons)".
                    // `.ignoresSafeArea(edges: .top)` on the chip lets
                    // it draw into the reserved titlebar region so its
                    // vertical center aligns with the macOS traffic
                    // lights.
                    .ignoresSafeArea(edges: .top)

                Group {
                    switch tab {
                    case .chat:
                        // v0.23 (Chat V2): the new chat surface replaces
                        // the legacy MacChatView. Phase 1 foundation
                        // (wire v14 + ChatSnapshotSource protocol +
                        // SessionInterruptDispatcher + Deep Research
                        // argv + /chat-sessions/search) is live; this
                        // V2 view consumes it end-to-end with sidebar +
                        // transcript + composer + status strip.
                        MacChatV2View(
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
                        MacCodeShell(model: sessionsModel)
                    case .settings:
                        MacSettingsView(
                            theme: theme,
                            claudeModel: claudeModel,
                            codexModel: codexModel,
                            geminiModel: geminiModel,
                            runtime: runtime
                        )
                    }
                }
                .padding([.horizontal, .bottom], 10)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1280, minHeight: 820)
        // v0.22.9: Cmd+1..Cmd+5 (+ Cmd+,) keyboard shortcuts now live
        // in the View / app menu via `.commands` on the Window scene
        // in ClawdmeterMacApp. The previous hidden-button hack was
        // unreliable because the buttons had to be in the first
        // responder chain — when the chat composer or any TextField
        // had focus, the shortcuts silently dropped. Menu-bar commands
        // are always-active and properly surface in the View menu so
        // users can discover them.
        .onReceive(NotificationCenter.default.publisher(for: .clawdmeterSwitchTab)) { note in
            guard let name = note.userInfo?["tab"] as? String else { return }
            switch name {
            case "chat":     tab = .chat
            case "usage":    tab = .usage
            case "code":     tab = .code
            case "settings": tab = .settings
            default:         break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawdmeterFocusCodeSearch)) { _ in
            tab = .code
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .focusSidebarSearch, object: nil)
            }
        }
        // v0.14.0 (D7): handoff toast overlay — top-anchored Tahoe chip
        // that autodismisses after 2s. Visible across all tabs.
        .overlay(alignment: .top) {
            if let handoffToast {
                HStack(spacing: 8) {
                    Text(handoffToast)
                        .font(.system(size: 12, weight: .semibold))
                    ToastCountdownRing(startedAt: toastStartedAt, duration: 2)
                        .frame(width: 14, height: 14)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 999, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 999, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 0.5))
                .padding(.top, 56)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel(handoffToast)
            }
        }
        .onChange(of: handoffToast) { _, newValue in
            guard newValue != nil else { return }
            toastStartedAt = Date()
            scheduleToastDismiss()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: handoffToast)
        .tahoeTheme(theme)
        .background(theme.appearance == .dark ? Color.black : Color(.sRGB, red: 0.94, green: 0.97, blue: 0.98))
    }
}

private struct ToastCountdownRing: View {
    let startedAt: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let progress = max(0, min(1, 1 - elapsed / max(duration, 0.1)))
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.primary.opacity(0.75),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityHidden(true)
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
    /// PR #26 D6: runtime for the secondary-right chips (repo count,
    /// pairing state, sync popover trigger). Nil falls back to static
    /// text for Previews.
    /// v0.27.0: .design chip removed along with the Design tab.
    var runtime: AppRuntime?

    init(
        active: MacRootView.Tab,
        onTab: @escaping (MacRootView.Tab) -> Void,
        theme: TahoeThemeStore,
        runtime: AppRuntime? = nil
    ) {
        self.active = active
        self.onTab = onTab
        self.theme = theme
        self.runtime = runtime
    }

    /// Repo count for the Usage-tab status label.
    private var repoCountLabel: String {
        let count = runtime?.sessionsModel.repos.count ?? 0
        if count == 0 { return "0 repos" }
        if count == 1 { return "1 repo" }
        return "\(count) repos"
    }

    @ViewBuilder
    private var codeBreadcrumb: some View {
        if let session = runtime?.sessionsModel.openSession {
            HStack(spacing: 7) {
                TahoeIcon("folder", size: 11)
                    .foregroundStyle(t.fg3)
                Text(session.repoDisplayName)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TahoeIcon("chevR", size: 9)
                    .foregroundStyle(t.fg4)
                Text(session.displayLabel)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 420)
            .help("\(session.repoDisplayName)\n\(session.displayLabel)")
        }
    }

    @State private var syncChipPopoverPresented: Bool = false

    @ViewBuilder
    private var syncChipUsage: some View {
        Button(action: { syncChipPopoverPresented.toggle() }) {
            TahoeSyncChip(
                icon: "qr",
                text: "Pair with iPhone"
            )
        }
        .buttonStyle(.plain)
        .help("Pair an iPhone")
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
        syncChipUsage
    }

    var body: some View {
        HStack(spacing: 10) {
            // v0.22.6: window is now `.hiddenTitleBar`, so the macOS
            // traffic lights overlay the top-left at the system level.
            // Reserve ~76pt of leading space so the tab chip doesn't
            // collide with the real (close/min/zoom) controls. We
            // dropped the decorative TahoeTrafficLights chip — it was
            // a non-functional Tahoe-themed clone that visually stacked
            // on top of the real lights.
            Color.clear.frame(width: 76, height: 1)

            if active == .code {
                TahoeGlass(radius: 11, tone: .chip) {
                    tabStrip
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                }
                .fixedSize()

                TahoeGlass(radius: 11, tone: .chip) {
                    HStack(spacing: 8) {
                        codeBreadcrumb
                        TahoeHair(vertical: true).frame(height: 14)
                        syncChipCode
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)

                codeActions
            } else {
                TahoeGlass(radius: 11, tone: .chip) {
                    HStack(spacing: 10) {
                        tabStrip
                        Spacer(minLength: 0)
                        // v0.24.0: in-app update chip. Always visible across
                        // every tab when an update is available OR the bundle
                        // is translocated. Self-hides via `chipState()` —
                        // returns EmptyView when there's nothing to surface,
                        // so the existing per-tab `secondaryRight` content
                        // continues to render alone on quiet days.
                        UpdateChip(coordinator: runtime?.updateCoordinator)
                        secondaryRight
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 44)
    }

    private var tabStrip: some View {
        HStack(spacing: 10) {
            TahoeDashTab("Chat",     active: active == .chat)     { onTab(.chat) }
            TahoeDashTab("Usage",    active: active == .usage)    { onTab(.usage) }
            TahoeDashTab("Code",     active: active == .code)     { onTab(.code) }
            TahoeDashTab("Settings", active: active == .settings) { onTab(.settings) }
        }
    }

    private var codeActions: some View {
        TahoeGlass(radius: 11, tone: .chip) {
            HStack(spacing: 2) {
                codeActionButton(icon: "sliders", help: "Focus Code filters") {
                    NotificationCenter.default.post(name: .focusSidebarSearch, object: nil)
                }
                codeActionButton(icon: "bell", help: "Pair or manage iPhone sync") {
                    syncChipPopoverPresented = true
                }
                codeActionButton(icon: "sidebar", help: "Open Plan and review pane") {
                    NotificationCenter.default.post(
                        name: .openCodeReviewPane,
                        object: nil,
                        userInfo: ["tab": WorkbenchPaneTab.plan.rawValue]
                    )
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 30)
        }
        .fixedSize()
    }

    private func codeActionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TahoeIcon(icon, size: 12)
                .foregroundStyle(t.fg3)
                .frame(width: 24, height: 24)
                .background(t.hair2.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var secondaryRight: some View {
        switch active {
        case .chat:
            // v0.22.9: removed `ChatModeToggle` (the titlebar "MODE
            // [Broadcast] [Solo]" segmented control). Mode is now driven
            // by a multi-select model picker in the chat composer
            // (`BroadcastChip`) — one source of truth, no duplicated
            // toggle. Selecting 1 provider = solo, >1 = broadcast.
            EmptyView()
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
            HStack(spacing: 8) {
                codeBreadcrumb
                Rectangle()
                    .fill(t.hairline)
                    .frame(width: 0.5, height: 14)
                syncChipCode
            }
        case .settings:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.1") · synced")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg2)
        }
    }
}
