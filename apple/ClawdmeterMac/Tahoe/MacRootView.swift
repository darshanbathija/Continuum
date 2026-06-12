import SwiftUI
import AppKit
import ClawdmeterShared

private struct MacRootNotificationHandlers: ViewModifier {
    var handleSwitchTab: (Notification) -> Void
    var handleOpenSettingsSection: (Notification) -> Void
    var handleOpenRepoSettings: (Notification) -> Void
    var handleFocusCodeSearch: (Notification) -> Void
    var handleOpenGlobalPalette: (Notification) -> Void
    var handleOpenShortcutSheet: (Notification) -> Void
    var handleOpenFilePicker: (Notification) -> Void
    var handleOpenPlanQueue: (Notification) -> Void
    var handleExportSession: (Notification) -> Void
    var handleTransientToast: (Notification) -> Void
    var handleNextAttention: (Notification) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterSwitchTab), perform: handleSwitchTab)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenSettingsSection), perform: handleOpenSettingsSection)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenRepoSettings), perform: handleOpenRepoSettings)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterFocusCodeSearch), perform: handleFocusCodeSearch)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenGlobalPalette), perform: handleOpenGlobalPalette)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenShortcutSheet), perform: handleOpenShortcutSheet)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenFilePicker), perform: handleOpenFilePicker)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterShowPlanQueue), perform: handleOpenPlanQueue)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterExportSession), perform: handleExportSession)
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterShowTransientToast), perform: handleTransientToast)
            .onReceive(NotificationCenter.default.publisher(for: .sessionNextAttention), perform: handleNextAttention)
    }
}

enum MacRootCommandRouting {
    static func codeTabCommands(
        canOpenChatTab: Bool,
        canOpenTerminalTab: Bool
    ) -> [ClawdmeterCommandDescriptor] {
        [
            .init(
                id: "code.newChatTab",
                title: "New Workspace Chat Tab",
                subtitle: canOpenChatTab ? "Open another draft in this workspace" : "No workspace selected",
                keywords: ["tab", "chat", "draft", "workspace"],
                scope: .code,
                kind: .action,
                shortcutID: "code.newChatTab",
                isEnabled: canOpenChatTab,
                disabledReason: canOpenChatTab ? nil : "Open a code workspace first"
            ),
            .init(
                id: "code.newTerminalTab",
                title: "New Workspace Terminal Tab",
                subtitle: canOpenTerminalTab ? "Open a shell in this workspace" : "No terminal source selected",
                keywords: ["tab", "terminal", "shell", "workspace"],
                scope: .code,
                kind: .action,
                shortcutID: "code.newTerminalTab",
                isEnabled: canOpenTerminalTab,
                disabledReason: canOpenTerminalTab ? nil : "Open a code workspace first"
            ),
        ]
    }

    static func sessionRenameCommand(session: AgentSession?) -> ClawdmeterCommandDescriptor {
        .init(
            id: "session.rename",
            title: "Rename Open Session",
            subtitle: session?.displayLabel ?? "No session selected",
            keywords: ["title", "name"],
            scope: .session,
            kind: .session,
            shortcutID: "session.rename",
            isEnabled: session != nil,
            disabledReason: session == nil ? "No session selected" : nil
        )
    }

    static func workspaceNotificationName(for commandID: ClawdmeterCommandID) -> Notification.Name? {
        switch commandID.rawValue {
        case "code.newChatTab":
            return .newCodeChatTab
        case "code.newTerminalTab":
            return .newCodeTerminalTab
        case "session.rename":
            return .renameOpenSession
        default:
            return nil
        }
    }
}

/// Tahoe 26 Mac window root — replaces `DashboardView` as the primary
/// SwiftUI scene content. Owns the global `TahoeThemeStore`, paints the
/// wallpaper layer, and hosts the four titlebar tabs (Chat / Usage / Code /
/// Settings) and the menu bar window. Tab routing is purely local — each
/// tab is its own view file under `Tahoe/`.
struct MacRootView: View {
    enum Tab: String, CaseIterable, Hashable { case chat, usage, code, settings }

    @State private var theme: TahoeThemeStore
    @State private var tab: Tab
    /// Tabs we've ever rendered. ZStack-cached so a re-visit doesn't
    /// re-instantiate the view (which was the source of the "slow + jumpy"
    /// tab switches — destroying a fully-loaded Code workspace, sidebar
    /// state, transcript stores, and re-creating it from scratch on each
    /// tap). Once a tab is in the set, its view stays mounted with
    /// `opacity: 0` while inactive.
    @State private var visitedTabs: Set<Tab> = []
    @State private var requestedSettingsSection: String? = nil
    @State private var requestedEnvWorkspaceId: UUID? = nil
    @State private var repoSettingsContext: RepoSettingsContext? = nil

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
    @ObservedObject private var cursorModel: AppModel
    @ObservedObject private var grokModel: AppModel
    @ObservedObject private var skillCatalog = SkillCatalog.shared

    // v0.23: legacy chatMode + chatSoloProvider bindings retired with
    // MacChatView (T16). The V2 chat composer owns its own selection
    // state via `ChatV2Store` (T10). MacTitlebar's `secondaryRight`
    // branch for `.chat` is `EmptyView()` so it doesn't need bindings.

    // v0.29.32: first-run onboarding (providers are opt-in). Shown once.
    @State private var showOnboarding = !ProviderEnablement.hasOnboarded

    // v0.14.0 (plan v2.1 D6 + D7): handoff toast + reduce-motion guard.
    @State private var handoffToast: String? = nil
    @State private var toastStartedAt: Date = Date()
    @State private var toastDismissTask: Task<Void, Never>? = nil
    @State private var transientToast: TransientToast? = nil
    @State private var transientToastStartedAt: Date = Date()
    @State private var transientToastDismissTask: Task<Void, Never>? = nil
    @State private var showingGlobalPalette: Bool = false
    @State private var showingShortcutSheet: Bool = false
    @State private var showingFilePicker: Bool = false
    @State private var showingPlanQueue: Bool = false
    @State private var composerModelPickerActive: Bool = false
    @State private var planQueue: PlanQueue = PlanQueue(rows: [])
    @StateObject private var presentationStore: SessionPresentationStore
    @StateObject private var workbenchState = WorkbenchState()
    private let shortcutRegistry = ClawdmeterShortcutRegistry()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    private func scheduleToastDismiss() {
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { self.handoffToast = nil }
        }
    }

    private func scheduleTransientToastDismiss(duration: TimeInterval) {
        transientToastDismissTask?.cancel()
        transientToastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(duration, 0.5) * 1_000_000_000))
            if !Task.isCancelled { self.transientToast = nil }
        }
    }

    init(runtime: AppRuntime, initialTab: Tab = .chat) {
        self.runtime = runtime
        self.sessionsModel = runtime.sessionsModel
        self.agentSessionRegistry = runtime.agentSessionRegistry
        self.claudeModel = runtime.claudeModel
        self.codexModel = runtime.codexModel
        self.geminiModel = runtime.geminiModel
        self.cursorModel = runtime.cursorModel
        self.grokModel = runtime.grokModel
        _theme = State(initialValue: TahoeThemeStore.loaded())
        _tab = State(initialValue: initialTab)
        // Seed the visited-tabs cache with the initial tab so the very
        // first render has a slot to populate (otherwise the ZStack
        // would briefly render nothing while `.task(id:)` catches up).
        _visitedTabs = State(initialValue: [initialTab])
        _presentationStore = StateObject(wrappedValue: SessionPresentationStore(
            storeURL: SessionPresentationStore.defaultStoreURL(
                appSupportDirectory: runtime.appSupportDirectory
            )
        ))
    }

    var body: some View {
        // A8 (v0.30.x): the per-provider usage reads used to live at the
        // top of body unconditionally. Result: a background usage poll for
        // any of the three providers invalidated the WHOLE MacRootView
        // body — re-rendering Chat / Code / Settings tabs that don't
        // consume usage at all. Moved into the `case .usage` arm below
        // so usage polls only re-render MacRootView when Usage is the
        // active tab.
        //
        // agentSessionRegistry.sessions stays at the top because the
        // code breadcrumb reads `runtime?.sessionsModel.openSession` and
        // needs to live-update across every tab.
        _ = agentSessionRegistry.sessions

        return ZStack {
            TahoeWallpaperView()
            VStack(spacing: 0) {
                MacTitlebar(
                    active: tab,
                    // Insert into visitedTabs synchronously alongside the
                    // tab change so the destination slot is mounted in
                    // the same render frame the tab switch happens —
                    // no one-frame gap where neither slot is hittable.
                    onTab: { newTab in
                        if !visitedTabs.contains(newTab) {
                            visitedTabs.insert(newTab)
                        }
                        tab = newTab
                    },
                    theme: theme,
                    runtime: runtime,
                    updateCoordinator: runtime.updateCoordinator,
                    workbenchState: workbenchState
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

                ZStack {
                    // Each tab view stays mounted once first rendered;
                    // an inactive tab is `opacity 0` + hit-test-disabled
                    // so it doesn't intercept clicks. This makes
                    // re-visits feel instant — no view-tree teardown,
                    // no re-fetch, no layout pop. The cross-fade is
                    // driven by `.animation(...value: tab)` below.
                    if visitedTabs.contains(.chat) {
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
                        .modifier(TabSlotVisibility(active: tab == .chat))
                    }
                    if visitedTabs.contains(.usage) {
                        // A8: per-provider usage reads — when the Usage
                        // tab is active the parent subscribes to live
                        // updates so the inner view re-renders. The
                        // discards happen inside this branch only, so
                        // background polls don't invalidate the parent
                        // when the user is in Chat / Code / Settings.
                        let _ = claudeModel.usage
                        let _ = codexModel.usage
                        let _ = geminiModel.usage
                        let _ = cursorModel.usage
                        let _ = grokModel.usage
                        let _ = runtime.opencodeModel.usage
                        MacUsageView(
                            data: runtime.tahoeLive,
                            claudeModel: claudeModel,
                            codexModel: codexModel,
                            geminiModel: geminiModel,
                            cursorModel: cursorModel,
                            grokModel: grokModel,
                            opencodeModel: runtime.opencodeModel,
                            usageHistoryStore: runtime.usageHistoryStore,
                            secondaryColumns: runtime.tahoeSecondaryColumns
                        )
                        .modifier(TabSlotVisibility(active: tab == .usage))
                    }
                    if visitedTabs.contains(.code) {
                        MacCodeShell(
                            model: sessionsModel,
                            presentationStore: presentationStore,
                            workbenchState: workbenchState
                        )
                            .modifier(TabSlotVisibility(active: tab == .code))
                    }
                    if visitedTabs.contains(.settings) {
                        MacSettingsView(
                            theme: theme,
                            claudeModel: claudeModel,
                            codexModel: codexModel,
                            geminiModel: geminiModel,
                            runtime: runtime,
                            presentationStore: presentationStore,
                            requestedSection: $requestedSettingsSection,
                            requestedEnvWorkspaceId: $requestedEnvWorkspaceId
                        )
                        .modifier(TabSlotVisibility(active: tab == .settings))
                    }
                }
                .padding([.horizontal, .bottom], 10)
                // Tight gap under the titlebar (was 10pt + a ~28pt safe-area
                // band; the band is gone now via the root .ignoresSafeArea).
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: tab)
                .task(id: tab) {
                    // Track first visit so the ZStack only materializes
                    // a tab on demand (lazy load). Subsequent visits
                    // re-show the already-mounted view in one frame.
                    visitedTabs.insert(tab)
                    if tab == .usage {
                        refreshUsageTabData()
                    }
                }
            }
        }
        .frame(minWidth: 1280, minHeight: 820)
        // v0.29.33: kill the dead band below the titlebar. AppKit reserves a
        // ~28pt titlebar-region top safe-area inset (see the MacTitlebar note);
        // the chip's own `.ignoresSafeArea(.top)` drew it up to y=0 but its
        // layout box still consumed the 28pt, leaving a visible gap between the
        // chip and the content (and making MacUsageView's ScrollView inset its
        // content by the same amount). Ignoring the top inset on the whole root
        // removes both: chip stays aligned with the traffic lights (unchanged),
        // content follows directly beneath it.
        .ignoresSafeArea(edges: .top)
        // v0.22.9: Cmd+1..Cmd+4 (+ Cmd+,) keyboard shortcuts now live
        // in the View / app menu via `.commands` on the Window scene
        // in ClawdmeterMacApp. The previous hidden-button hack was
        // unreliable because the buttons had to be in the first
        // responder chain — when the chat composer or any TextField
        // had focus, the shortcuts silently dropped. Menu-bar commands
        // are always-active and properly surface in the View menu so
        // users can discover them.
        .modifier(MacRootNotificationHandlers(
            handleSwitchTab: handleSwitchTab,
            handleOpenSettingsSection: handleOpenSettingsSection,
            handleOpenRepoSettings: handleOpenRepoSettings,
            handleFocusCodeSearch: handleFocusCodeSearch,
            handleOpenGlobalPalette: handleOpenGlobalPalette,
            handleOpenShortcutSheet: handleOpenShortcutSheet,
            handleOpenFilePicker: handleOpenFilePicker,
            handleOpenPlanQueue: handleOpenPlanQueue,
            handleExportSession: handleExportSession,
            handleTransientToast: handleTransientToast,
            handleNextAttention: handleNextAttention
        ))
        // v0.14.0 (D7): handoff toast overlay — top-anchored Tahoe chip
        // that autodismisses after 2s. Visible across all tabs.
        .overlay(alignment: .top) {
            handoffToastOverlay
        }
        // Notification bubbles live in the bottom-right corner — out of the
        // content's way instead of front-and-center over the transcript.
        .overlay(alignment: .bottomTrailing) {
            transientToastOverlay
        }
        .overlay {
            modalOverlay
        }
        // v0.29.32: first-run welcome — turn on the providers you use.
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet(runtime: runtime, onDone: { showOnboarding = false })
        }
        .sheet(item: $repoSettingsContext) { context in
            RepoSettingsSheet(
                context: context,
                workspaceStore: runtime.workspaceStore,
                envStore: runtime.repoEnvStore,
                resolver: runtime.repoEnvRuntimeResolver,
                onOpenFullSettings: openFullSettingsForRepo(workspaceId:)
            )
        }
        .onChange(of: handoffToast) { _, newValue in
            guard newValue != nil else { return }
            toastStartedAt = Date()
            scheduleToastDismiss()
        }
        .onChange(of: transientToast) { _, newValue in
            guard let newValue else { return }
            transientToastStartedAt = Date()
            scheduleTransientToastDismiss(duration: newValue.duration)
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerModelPickerActiveChanged)) { note in
            composerModelPickerActive = (note.userInfo?["isActive"] as? Bool) ?? false
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: handoffToast)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: transientToast)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: modalOverlayKey)
        .tahoeTheme(theme)
        .background(ContinuumTokens.palette(for: theme.appearance).bg)
        .background(
            ShortcutOverrideMonitor(
                shortcuts: shortcutRegistry,
                overrides: presentationStore.snapshot.shortcutOverrides,
                commands: buildCommandRegistry(),
                suppressGlobalNavigationShortcuts: composerModelPickerActive,
                onRun: runGlobalCommand
            )
        )
        .onAppear {
            skillCatalog.refreshIfStale()
            if tab == .usage {
                refreshUsageTabData()
            }
        }
    }

    private func refreshUsageTabData() {
        if ProviderEnablement.isEnabled("claude") { claudeModel.forcePoll() }
        if ProviderEnablement.isEnabled("codex") { codexModel.forcePoll() }
        if ProviderEnablement.isEnabled("gemini") { geminiModel.forcePoll() }
        if ProviderEnablement.isEnabled("cursor") { cursorModel.forcePoll() }
        if ProviderEnablement.isEnabled("grok") { grokModel.forcePoll() }
        runtime.usageHistoryStore.forceRefresh()
    }

    private func paletteScrim<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture {
                    showingGlobalPalette = false
                    showingShortcutSheet = false
                    showingFilePicker = false
                    showingPlanQueue = false
                }
            content()
        }
        .zIndex(100)
    }

    @ViewBuilder
    private var handoffToastOverlay: some View {
        if let handoffToast {
            HStack(spacing: 8) {
                Text(handoffToast)
                    .font(.system(size: 12, weight: .semibold))
                ToastCountdownRing(startedAt: toastStartedAt, duration: 2)
                    .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 999, style: .continuous).fill(ContinuumTokens.surface2))
            .overlay(RoundedRectangle(cornerRadius: 999, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 0.5))
            .padding(.top, 56)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(handoffToast)
        }
    }

    @ViewBuilder
    private var transientToastOverlay: some View {
        if let toast = transientToast {
            HStack(spacing: 10) {
                if toast.severity != .info {
                    Image(systemName: toast.severity == .success
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(toast.severity == .success
                                         ? SessionsV2Theme.success : SessionsV2Theme.danger)
                        .transition(.scale.combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(toast.title)
                        .font(.system(size: 12, weight: .semibold))
                    if let detail = toast.detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let actionTitle = toast.actionTitle {
                    Button(actionTitle) { performToastAction(toast) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .semibold))
                }
                ToastCountdownRing(startedAt: transientToastStartedAt, duration: toast.duration)
                    .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 999, style: .continuous).fill(ContinuumTokens.surface2))
            .overlay(RoundedRectangle(cornerRadius: 999, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 0.5))
            .padding(.trailing, 20)
            .padding(.bottom, 24)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var modalOverlay: some View {
        if showingGlobalPalette {
            globalPaletteOverlay
        } else if showingShortcutSheet {
            shortcutSheetOverlay
        } else if showingFilePicker {
            filePickerOverlay
        } else if showingPlanQueue {
            planQueueOverlay
        }
    }

    /// Single derived key driving `.animation(value:)` for every modal —
    /// keeps the body's modifier chain short enough for the SwiftUI
    /// type-checker. Any modal flag flipping invalidates this and
    /// triggers the shared 0.16s ease-in-out.
    private var modalOverlayKey: Int {
        var v = 0
        if showingGlobalPalette { v |= 1 }
        if showingShortcutSheet { v |= 2 }
        if showingFilePicker { v |= 4 }
        if showingPlanQueue { v |= 8 }
        return v
    }

    @ViewBuilder
    private var globalPaletteOverlay: some View {
        paletteScrim {
            GlobalCommandPalette(
                registry: buildCommandRegistry(),
                shortcuts: shortcutRegistry,
                shortcutOverrides: presentationStore.snapshot.shortcutOverrides,
                recentCommandIDs: presentationStore.snapshot.commandRecents,
                onRun: runGlobalCommand,
                onDismiss: { showingGlobalPalette = false }
            )
        }
    }

    @ViewBuilder
    private var shortcutSheetOverlay: some View {
        paletteScrim {
            KeyboardCheatSheet(
                registry: shortcutRegistry,
                overrides: presentationStore.snapshot.shortcutOverrides,
                onDismiss: { showingShortcutSheet = false }
            )
        }
    }

    @ViewBuilder
    private var filePickerOverlay: some View {
        paletteScrim {
            RepoFilePickerView(
                repoRoot: openSessionRepoRoot,
                presentationStore: presentationStore,
                onDismiss: { showingFilePicker = false }
            )
        }
    }

    @ViewBuilder
    private var planQueueOverlay: some View {
        paletteScrim {
            PlanQueueSheet(
                queue: planQueue,
                onDismiss: { showingPlanQueue = false }
            )
        }
    }

    private func handleSwitchTab(_ note: Notification) {
        guard let name = note.userInfo?["tab"] as? String else { return }
        switch name {
        case "chat":
            visitedTabs.insert(.chat)
            tab = .chat
        case "usage":
            visitedTabs.insert(.usage)
            tab = .usage
        case "code":
            visitedTabs.insert(.code)
            tab = .code
        case "settings":
            visitedTabs.insert(.settings)
            tab = .settings
        default:
            break
        }
    }

    private func handleOpenSettingsSection(_ note: Notification) {
        requestedSettingsSection = note.userInfo?["section"] as? String
        visitedTabs.insert(.settings)
        tab = .settings
    }

    private func handleOpenRepoSettings(_ note: Notification) {
        guard let repoKey = note.userInfo?["repoKey"] as? String,
              let repoDisplayName = note.userInfo?["repoDisplayName"] as? String,
              let repoRoot = note.userInfo?["repoRoot"] as? String
        else { return }
        let workspaceId = (note.userInfo?["workspaceId"] as? String).flatMap(UUID.init(uuidString:))
        repoSettingsContext = RepoSettingsContext(
            repoKey: repoKey,
            repoDisplayName: repoDisplayName,
            repoRoot: repoRoot,
            workspaceId: workspaceId
        )
    }

    private func openFullSettingsForRepo(workspaceId: UUID?) {
        requestedEnvWorkspaceId = workspaceId
        requestedSettingsSection = "envVariables"
        visitedTabs.insert(.settings)
        tab = .settings
    }

    private func handleFocusCodeSearch(_ note: Notification) {
        tab = .code
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .focusSidebarSearch, object: nil)
        }
    }

    private func handleOpenGlobalPalette(_ note: Notification) {
        skillCatalog.refreshIfStale()
        showingGlobalPalette = true
    }

    private func handleOpenShortcutSheet(_ note: Notification) {
        showingShortcutSheet = true
    }

    private func handleOpenFilePicker(_ note: Notification) {
        tab = .code
        showingFilePicker = true
    }

    /// Build the spawn queue and present the Continue Plan sheet. We
    /// rebuild on every open so the JSONL artifact picks up changes
    /// between sessions without an app restart.
    private func handleOpenPlanQueue(_ note: Notification) {
        planQueue = PlanQueueLoader.load(repoRoot: PlanRepoRoot.resolved())
        showingPlanQueue = true
    }

    private func handleExportSession(_ note: Notification) {
        exportOpenSession()
    }

    private func handleTransientToast(_ note: Notification) {
        guard let toast = note.userInfo?["toast"] as? TransientToast else { return }
        showTransientToast(toast)
    }

    private func handleNextAttention(_ note: Notification) {
        tab = .code
        openNextAttentionSession()
    }

    private func showTransientToast(_ toast: TransientToast) {
        transientToast = toast
    }

    private func performToastAction(_ toast: TransientToast) {
        guard let actionID = toast.actionID else { return }
        if actionID.hasPrefix("unarchive:"),
           let id = UUID(uuidString: String(actionID.dropFirst("unarchive:".count))) {
            Task { @MainActor in
                try? await sessionsModel.registry.unarchive(id: id)
            }
            transientToast = nil
        }
    }

    private var openSessionRepoRoot: String? {
        guard let session = sessionsModel.openSession else { return nil }
        let candidates = [
            session.effectiveCwd,
            session.worktreePath,
            session.runtimeCwd,
            session.repoKey,
        ]
        for raw in candidates {
            guard let root = normalizedDirectoryPath(raw) else { continue }
            return root
        }
        return nil
    }

    private func normalizedDirectoryPath(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let expanded = NSString(string: raw).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return expanded
    }

    private func buildCommandRegistry() -> ClawdmeterCommandRegistry {
        var commands: [ClawdmeterCommandDescriptor] = [
            .init(id: "global.palette", title: "Open Command Palette", subtitle: "Search every action", keywords: ["spotlight", "actions"], scope: .global, kind: .action, shortcutID: "global.palette"),
            .init(id: "global.shortcuts", title: "Show Keyboard Shortcuts", subtitle: "Search the shortcut cheat sheet", keywords: ["help", "cheat sheet"], scope: .global, kind: .action, shortcutID: "global.shortcuts"),
            .init(id: "global.filePicker", title: "Open Repo File", subtitle: openSessionRepoRoot ?? "No code session selected", keywords: ["file", "quick open", "cmd p"], scope: .global, kind: .navigation, shortcutID: "global.filePicker", isEnabled: openSessionRepoRoot != nil, disabledReason: openSessionRepoRoot == nil ? "Open a code session first" : nil),
            .init(id: "global.statusHUD", title: "Open Status HUD", subtitle: "Floating session monitor window", keywords: ["window", "monitor", "hud"], scope: .global, kind: .navigation),
            .init(id: "nav.chat", title: "Open Chat", subtitle: "Switch to the chat workbench", keywords: ["tab"], scope: .global, kind: .navigation, shortcutID: "nav.chat"),
            .init(id: "nav.usage", title: "Open Usage", subtitle: "Switch to usage analytics", keywords: ["tab", "analytics"], scope: .global, kind: .navigation, shortcutID: "nav.usage"),
            .init(id: "nav.code", title: "Open Code", subtitle: "Switch to the code workbench", keywords: ["tab", "sessions"], scope: .global, kind: .navigation, shortcutID: "nav.code"),
            .init(id: "nav.settings", title: "Open Settings", subtitle: "Switch to settings", keywords: ["preferences"], scope: .global, kind: .navigation, shortcutID: "nav.settings"),
            .init(id: "session.new", title: "New Code Session", subtitle: "Open the session launcher", keywords: ["spawn", "agent"], scope: .session, kind: .session),
            .init(id: "session.nextAttention", title: "Open Next Attention Session", subtitle: "Jump to unread, blocked, PR, plan, or failed-check work", keywords: ["unread", "blocked", "pr", "plan"], scope: .session, kind: .navigation, shortcutID: "session.nextAttention"),
            .init(id: "transcript.find", title: "Find in Transcript", subtitle: "Search the open chat transcript", keywords: ["search", "messages"], scope: .chat, kind: .action, shortcutID: "transcript.find"),
            .init(id: "transcript.nextMatch", title: "Next Transcript Match", subtitle: "Jump to the next in-chat search match", keywords: ["find", "search"], scope: .chat, kind: .action, shortcutID: "transcript.nextMatch"),
            .init(id: "transcript.previousMatch", title: "Previous Transcript Match", subtitle: "Jump to the previous in-chat search match", keywords: ["find", "search"], scope: .chat, kind: .action, shortcutID: "transcript.previousMatch"),
            .init(id: "transcript.latest", title: "Jump to Latest Message", subtitle: "Scroll the transcript to the newest event", keywords: ["bottom"], scope: .chat, kind: .action, shortcutID: "transcript.latest"),
            .init(id: "transcript.lastUser", title: "Jump to Last User Message", subtitle: "Return to the last prompt in the transcript", keywords: ["prompt"], scope: .chat, kind: .action, shortcutID: "transcript.lastUser"),
            .init(id: "composer.history", title: "Open Prompt History", subtitle: "Reuse a previous prompt or saved prompt", keywords: ["recall", "saved"], scope: .composer, kind: .action, shortcutID: "composer.history"),
            .init(id: "composer.send", title: "Send Prompt", subtitle: "Send the current composer draft", keywords: ["submit"], scope: .composer, kind: .action, shortcutID: "composer.send"),
            .init(id: "composer.queue", title: "Queue Follow-up", subtitle: "Queue the current draft for the running session", keywords: ["follow up", "later"], scope: .composer, kind: .action, shortcutID: "composer.queue"),
            .init(id: "composer.dictation", title: "Toggle Dictation", subtitle: "Start or stop composer dictation", keywords: ["voice", "microphone"], scope: .composer, kind: .action, shortcutID: "composer.dictation"),
            .init(id: "composer.attach", title: "Add Attachment", subtitle: "Attach files or context to the Code composer", keywords: ["file", "paperclip", "context"], scope: .composer, kind: .action, shortcutID: "composer.attach"),
            .init(id: "composer.modelEffort", title: "Open Model Selector", subtitle: "Open the Code model picker", keywords: ["model", "provider"], scope: .composer, kind: .action, shortcutID: "composer.modelEffort"),
            .init(id: "composer.context", title: "Open Context Usage", subtitle: "Show context-window and plan usage", keywords: ["context", "usage", "tokens"], scope: .composer, kind: .action, shortcutID: "composer.context"),
            .init(id: "composer.effortNext", title: "Increase Effort", subtitle: "Cycle the current model effort up", keywords: ["effort", "reasoning"], scope: .composer, kind: .action, shortcutID: "composer.effortNext"),
            .init(id: "composer.effortPrevious", title: "Decrease Effort", subtitle: "Cycle the current model effort down", keywords: ["effort", "reasoning"], scope: .composer, kind: .action, shortcutID: "composer.effortPrevious"),
            .init(id: "composer.permission.ask", title: "Permission Mode: Ask", subtitle: "Require approval before edits or commands", keywords: ["permission", "ask"], scope: .composer, kind: .action, shortcutID: "composer.permission.ask"),
            .init(id: "composer.permission.acceptEdits", title: "Permission Mode: Accept Edits", subtitle: "Allow edits while still asking for other actions", keywords: ["permission", "edits"], scope: .composer, kind: .action, shortcutID: "composer.permission.acceptEdits"),
            .init(id: "composer.permission.plan", title: "Permission Mode: Plan", subtitle: "Ask the provider to plan before editing", keywords: ["permission", "plan"], scope: .composer, kind: .action, shortcutID: "composer.permission.plan"),
            .init(id: "composer.permission.bypass", title: "Permission Mode: Bypass", subtitle: "Use the trusted full-access mode when available", keywords: ["permission", "bypass", "full access"], scope: .composer, kind: .action, shortcutID: "composer.permission.bypass"),
        ]
        commands.append(contentsOf: MacRootCommandRouting.codeTabCommands(
            canOpenChatTab: sessionsModel.canOpenNewWorkspaceChatDraftTab(),
            canOpenTerminalTab: sessionsModel.canOpenNewWorkspaceTerminalTab()
        ))
        commands.append(contentsOf: [
            .init(id: "code.search", title: "Focus Code Search", subtitle: "Search sessions and projects", keywords: ["filter"], scope: .code, kind: .action, shortcutID: "code.search"),
            .init(id: "code.workspaceSwitcher", title: "Open Workspace Switcher", subtitle: "Switch workspace or session", keywords: ["repo", "session", "switch"], scope: .code, kind: .navigation, shortcutID: "code.workspaceSwitcher"),
            .init(id: "code.reviewPane", title: "Toggle Review Pane", subtitle: "Show or hide Plan/Diff/PR/Terminal", keywords: ["plan", "diff", "terminal"], scope: .code, kind: .action, shortcutID: "code.reviewPane"),
            .init(id: "settings.pairIPhone", title: "Pair Or Manage iPhone", subtitle: "Open Settings for desktop sync", keywords: ["phone", "sync", "qr"], scope: .settings, kind: .setting),
        ])
        var registry = ClawdmeterCommandRegistry(commands: commands)
        if let session = sessionsModel.openSession {
            let transcriptURL = sessionsModel.chatStore(for: session)?.currentFileURL
            registry.upsert(.init(id: "session.subchat", title: "Create Sub-chat", subtitle: "Branch from \(session.displayLabel)", keywords: ["branch", "child"], scope: .session, kind: .session, shortcutID: "session.subchat"))
            registry.upsert(MacRootCommandRouting.sessionRenameCommand(session: session))
            registry.upsert(.init(id: "session.archive", title: "Archive Open Session", subtitle: session.displayLabel, keywords: ["hide", "done"], scope: .session, kind: .session, shortcutID: "session.archive", isEnabled: session.archivedAt == nil, disabledReason: session.archivedAt == nil ? nil : "Session is already archived"))
            registry.upsert(.init(id: "session.export", title: "Export Open Session", subtitle: "Write transcript, metadata, and diff bundle", keywords: ["bundle", "download"], scope: .session, kind: .external, shortcutID: "session.export"))
            registry.upsert(.init(id: "session.copyID", title: "Copy Open Session ID", subtitle: session.id.uuidString, keywords: ["uuid"], scope: .session, kind: .session))
            registry.upsert(.init(
                id: "session.revealJSONL",
                title: "Reveal Open Session JSONL",
                subtitle: session.displayLabel,
                keywords: ["finder", "transcript"],
                scope: .session,
                kind: .external,
                isEnabled: transcriptURL != nil,
                disabledReason: transcriptURL == nil ? "Transcript file is not available yet" : nil
            ))
            if let prURL = session.prMirrorState?.prURL {
                registry.upsert(.init(id: "session.openPR", title: "Open Pull Request", subtitle: prURL, keywords: ["github", "pr"], scope: .session, kind: .external))
            }
        } else {
            registry.upsert(.init(id: "session.subchat", title: "Create Sub-chat", subtitle: "No session selected", scope: .session, kind: .session, shortcutID: "session.subchat", isEnabled: false, disabledReason: "No session selected"))
            registry.upsert(MacRootCommandRouting.sessionRenameCommand(session: nil))
            registry.upsert(.init(id: "session.archive", title: "Archive Open Session", subtitle: "No session selected", scope: .session, kind: .session, shortcutID: "session.archive", isEnabled: false, disabledReason: "No session selected"))
        }
        for session in agentSessionRegistry.sessions.filter({ $0.archivedAt == nil }).sorted(by: { $0.lastEventAt > $1.lastEventAt }).prefix(10) {
            registry.upsert(.init(
                id: ClawdmeterCommandID(rawValue: "session.open.\(session.id.uuidString)"),
                title: "Open \(session.displayLabel)",
                subtitle: "\(session.agent.rawValue) · \(session.repoDisplayName)",
                keywords: [session.repoDisplayName, session.goal ?? "", session.model ?? ""],
                scope: .session,
                kind: .navigation
            ))
        }
        for skill in skillCatalog.commands {
            registry.upsert(.init(
                id: ClawdmeterCommandID(rawValue: "skill.\(skill.id)"),
                title: "/\(skill.id)",
                subtitle: skill.description,
                keywords: ["slash", "skill", skill.label],
                scope: .composer,
                kind: .skill
            ))
        }
        return registry
    }

    private func runGlobalCommand(_ command: ClawdmeterCommandDescriptor) {
        showingGlobalPalette = false
        try? presentationStore.recordCommand(command.id.rawValue)
        switch command.id.rawValue {
        case "global.palette":
            showingGlobalPalette = true
        case "global.shortcuts":
            showingShortcutSheet = true
        case "global.filePicker":
            tab = .code
            showingFilePicker = true
        case "global.statusHUD":
            openWindow(id: "status-hud")
        case "nav.chat":
            tab = .chat
        case "nav.usage":
            tab = .usage
        case "nav.code":
            tab = .code
        case "nav.settings", "settings.pairIPhone":
            if command.id.rawValue == "settings.pairIPhone" {
                requestedSettingsSection = "devices"
            }
            visitedTabs.insert(.settings)
            tab = .settings
        case "session.new":
            tab = .code
            sessionsModel.showingNewSessionSheet = true
        case "session.nextAttention":
            openNextAttentionSession()
        case "transcript.find":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .transcriptFind, object: nil) }
        case "transcript.nextMatch":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .transcriptNextMatch, object: nil) }
        case "transcript.previousMatch":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .transcriptPreviousMatch, object: nil) }
        case "transcript.latest":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .transcriptLatest, object: nil) }
        case "transcript.lastUser":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .transcriptLastUser, object: nil) }
        case "composer.history":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerHistory, object: nil) }
        case "composer.send":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerSend, object: nil) }
        case "composer.queue":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerQueue, object: nil) }
        case "composer.dictation":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerToggleDictation, object: nil) }
        case "composer.attach":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerAttach, object: nil) }
        case "composer.modelEffort":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerOpenModelEffort, object: nil) }
        case "composer.context":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerOpenContextUsage, object: nil) }
        case "composer.effortNext":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerCycleEffortNext, object: nil) }
        case "composer.effortPrevious":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .composerCycleEffortPrevious, object: nil) }
        case "composer.permission.ask":
            postPermissionModeShortcut(.ask)
        case "composer.permission.acceptEdits":
            postPermissionModeShortcut(.acceptEdits)
        case "composer.permission.plan":
            postPermissionModeShortcut(.plan)
        case "composer.permission.bypass":
            postPermissionModeShortcut(.bypass)
        case "code.newChatTab", "code.newTerminalTab", "session.rename":
            visitedTabs.insert(.code)
            tab = .code
            guard let notificationName = MacRootCommandRouting.workspaceNotificationName(for: command.id) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: notificationName, object: nil)
            }
        case "code.search":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .focusSidebarSearch, object: nil) }
        case "code.workspaceSwitcher":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .openWorkspaceSwitcher, object: nil) }
        case "code.reviewPane":
            tab = .code
            DispatchQueue.main.async { NotificationCenter.default.post(name: .toggleCodeReviewPane, object: nil) }
        case "session.subchat":
            guard let parentId = sessionsModel.openSessionId else { return }
            Task { _ = await sessionsModel.spawnSubchat(parentId: parentId) }
        case "session.archive":
            archiveOpenSession()
        case "session.export":
            exportOpenSession()
        case "session.copyID":
            copyOpenSessionID()
        case "session.revealJSONL":
            revealOpenSessionJSONL()
        case "session.openPR":
            openCurrentPR()
        default:
            if command.id.rawValue.hasPrefix("session.open."),
               let id = UUID(uuidString: String(command.id.rawValue.dropFirst("session.open.".count))) {
                tab = .code
                sessionsModel.openSessionId = id
            } else if command.id.rawValue.hasPrefix("skill.") {
                let skill = String(command.id.rawValue.dropFirst("skill.".count))
                tab = .code
                ComposerInsertionInbox.shared.enqueue(text: "/\(skill)\n", autoSend: true)
            }
        }
    }

    private func postPermissionModeShortcut(_ mode: PermissionMode) {
        tab = .code
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .composerSetPermissionMode,
                object: nil,
                userInfo: ["mode": mode.rawValue]
            )
        }
    }

    private func archiveOpenSession() {
        guard let session = sessionsModel.openSession, session.archivedAt == nil else { return }
        Task { @MainActor in
            try? await sessionsModel.registry.archive(id: session.id)
        }
        showTransientToast(TransientToast(
            title: "Archived \(session.displayLabel)",
            actionTitle: "Undo",
            actionID: "unarchive:\(session.id.uuidString)",
            duration: 5,
            isDestructiveRecovery: true
        ))
    }

    private func openNextAttentionSession() {
        let sessions = agentSessionRegistry.sessions
            .filter { $0.archivedAt == nil }
            .sorted { lhs, rhs in
                let lhsReasons = AttentionReasonResolver.reasons(
                    for: lhs,
                    unread: presentationStore.snapshot.unreadSessionIds.contains(lhs.id),
                    providerBlocked: sessionsModel.chatStore(for: lhs)?.pendingPermissionPrompt != nil,
                    snoozedUntil: presentationStore.snapshot.snoozedUntil[lhs.id]
                )
                let rhsReasons = AttentionReasonResolver.reasons(
                    for: rhs,
                    unread: presentationStore.snapshot.unreadSessionIds.contains(rhs.id),
                    providerBlocked: sessionsModel.chatStore(for: rhs)?.pendingPermissionPrompt != nil,
                    snoozedUntil: presentationStore.snapshot.snoozedUntil[rhs.id]
                )
                let lhsPriority = lhsReasons.first?.priority ?? 99
                let rhsPriority = rhsReasons.first?.priority ?? 99
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.lastEventAt > rhs.lastEventAt
            }
        let attention = sessions.filter {
            !AttentionReasonResolver.reasons(
                for: $0,
                unread: presentationStore.snapshot.unreadSessionIds.contains($0.id),
                providerBlocked: sessionsModel.chatStore(for: $0)?.pendingPermissionPrompt != nil,
                snoozedUntil: presentationStore.snapshot.snoozedUntil[$0.id]
            ).isEmpty
        }
        guard !attention.isEmpty else {
            showTransientToast(TransientToast(title: "No sessions need attention", duration: 2))
            return
        }
        let current = sessionsModel.openSessionId
        let target: AgentSession
        if let current, let idx = attention.firstIndex(where: { $0.id == current }) {
            target = attention[(idx + 1) % attention.count]
        } else {
            target = attention[0]
        }
        tab = .code
        sessionsModel.openSessionId = target.id
        try? presentationStore.markUnread(target.id, unread: false)
    }

    private func copyOpenSessionID() {
        guard let id = sessionsModel.openSession?.id.uuidString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        showTransientToast(TransientToast(title: "Copied session ID", duration: 2))
    }

    private func exportOpenSession() {
        guard let session = sessionsModel.openSession else {
            showTransientToast(TransientToast(title: "No session selected", duration: 2))
            return
        }
        do {
            let transcriptURL = sessionsModel.chatStore(for: session)?.currentFileURL
            let url = try SessionExportBundleWriter.export(
                session: session,
                transcriptURL: transcriptURL,
                presentation: presentationStore.snapshot
            )
            try? presentationStore.recordExportedSessionURL(url.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showTransientToast(TransientToast(
                title: "Exported session bundle",
                detail: url.lastPathComponent,
                duration: 4
            ))
        } catch {
            showTransientToast(TransientToast(
                title: "Export failed",
                detail: error.localizedDescription,
                duration: 5
            ))
        }
    }

    private func revealOpenSessionJSONL() {
        guard let session = sessionsModel.openSession,
              let url = sessionsModel.chatStore(for: session)?.currentFileURL
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openCurrentPR() {
        guard let raw = sessionsModel.openSession?.prMirrorState?.prURL,
              let url = URL(string: raw)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openChangelog() {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("CHANGELOG.md"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")
        ]
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(existing)
        } else {
            tab = .settings
            showTransientToast(TransientToast(title: "Changelog not found in this build", duration: 3))
        }
    }
}

private struct ShortcutOverrideMonitor: NSViewRepresentable {
    let shortcuts: ClawdmeterShortcutRegistry
    let overrides: [String: String]
    let commands: ClawdmeterCommandRegistry
    let suppressGlobalNavigationShortcuts: Bool
    let onRun: (ClawdmeterCommandDescriptor) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.update(
            shortcuts: shortcuts,
            overrides: overrides,
            commands: commands,
            suppressGlobalNavigationShortcuts: suppressGlobalNavigationShortcuts,
            onRun: onRun
        )
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            context.coordinator.handle(event)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            shortcuts: shortcuts,
            overrides: overrides,
            commands: commands,
            suppressGlobalNavigationShortcuts: suppressGlobalNavigationShortcuts,
            onRun: onRun
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        private var shortcuts = ClawdmeterShortcutRegistry()
        private var overrides: [String: String] = [:]
        private var commands = ClawdmeterCommandRegistry()
        private var suppressGlobalNavigationShortcuts = false
        private var onRun: ((ClawdmeterCommandDescriptor) -> Void)?

        func update(
            shortcuts: ClawdmeterShortcutRegistry,
            overrides: [String: String],
            commands: ClawdmeterCommandRegistry,
            suppressGlobalNavigationShortcuts: Bool,
            onRun: @escaping (ClawdmeterCommandDescriptor) -> Void
        ) {
            self.shortcuts = shortcuts
            self.overrides = overrides
            self.commands = commands
            self.suppressGlobalNavigationShortcuts = suppressGlobalNavigationShortcuts
            self.onRun = onRun
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            let eventChord = Self.normalizedChord(for: event)
            guard !eventChord.isEmpty else { return event }

            for shortcut in shortcuts.shortcuts {
                let chord = shortcuts.displayChord(for: shortcut, overrides: overrides)
                guard Self.normalize(chord) == eventChord,
                      let commandID = shortcut.commandID,
                      let command = commands.command(id: commandID),
                      command.isEnabled
                else { continue }
                if suppressGlobalNavigationShortcuts,
                   Self.isGlobalNavigation(command.id.rawValue) {
                    return event
                }
                onRun?(command)
                return nil
            }
            return event
        }

        private static func isGlobalNavigation(_ commandID: String) -> Bool {
            switch commandID {
            case "nav.chat", "nav.usage", "nav.code", "nav.settings":
                return true
            default:
                return false
            }
        }

        private static func normalizedChord(for event: NSEvent) -> String {
            var raw = ""
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.control) { raw += "⌃" }
            if flags.contains(.option) { raw += "⌥" }
            if flags.contains(.shift) { raw += "⇧" }
            if flags.contains(.command) { raw += "⌘" }
            raw += keyName(for: event)
            return normalize(raw)
        }

        private static func keyName(for event: NSEvent) -> String {
            switch event.keyCode {
            case 18: return "1"
            case 19: return "2"
            case 20: return "3"
            case 21: return "4"
            case 23: return "5"
            case 22: return "6"
            case 26: return "7"
            case 28: return "8"
            case 25: return "9"
            case 29: return "0"
            case 36, 76: return "Return"
            case 125: return "Down"
            case 126: return "Up"
            case 123: return "Left"
            case 124: return "Right"
            case 53: return "Esc"
            default:
                return (event.charactersIgnoringModifiers ?? event.characters ?? "").uppercased()
            }
        }

        private static func normalize(_ chord: String) -> String {
            let canonical = chord
                .replacingOccurrences(of: "Command", with: "⌘")
                .replacingOccurrences(of: "Cmd", with: "⌘")
                .replacingOccurrences(of: "Shift", with: "⇧")
                .replacingOccurrences(of: "Option", with: "⌥")
                .replacingOccurrences(of: "Alt", with: "⌥")
                .replacingOccurrences(of: "Control", with: "⌃")
                .replacingOccurrences(of: "Ctrl", with: "⌃")
                .replacingOccurrences(of: " ", with: "")
                .uppercased()
            let hasCommand = canonical.contains("⌘")
            let hasShift = canonical.contains("⇧")
            let hasOption = canonical.contains("⌥")
            let hasControl = canonical.contains("⌃")
            let key = canonical
                .replacingOccurrences(of: "⌘", with: "")
                .replacingOccurrences(of: "⇧", with: "")
                .replacingOccurrences(of: "⌥", with: "")
                .replacingOccurrences(of: "⌃", with: "")
            return [
                hasCommand ? "⌘" : "",
                hasShift ? "⇧" : "",
                hasOption ? "⌥" : "",
                hasControl ? "⌃" : ""
            ].joined() + key
        }
    }
}

/// ZStack tab slot modifier — keeps an inactive tab mounted but invisible
/// + un-hittable so it doesn't intercept clicks or steal focus. The
/// surrounding `.animation(value: tab)` drives the cross-fade.
private struct TabSlotVisibility: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            // Inactive slots collapse to zero apparent size for SwiftUI's
            // layout pass while still measuring their own content
            // intrinsically. We use `.zIndex` to keep the active slot on
            // top in case of overlapping draw order.
            .zIndex(active ? 1 : 0)
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
    /// PR #26 D6: runtime for the secondary-right chips (pairing state,
    /// sync popover trigger). Nil falls back to static text for Previews.
    /// v0.27.0: .design chip removed along with the Design tab.
    var runtime: AppRuntime?
    @ObservedObject var updateCoordinator: UpdateCoordinator
    @ObservedObject var workbenchState: WorkbenchState

    init(
        active: MacRootView.Tab,
        onTab: @escaping (MacRootView.Tab) -> Void,
        theme: TahoeThemeStore,
        runtime: AppRuntime? = nil,
        updateCoordinator: UpdateCoordinator,
        workbenchState: WorkbenchState
    ) {
        self.active = active
        self.onTab = onTab
        self.theme = theme
        self.runtime = runtime
        self.updateCoordinator = updateCoordinator
        self.workbenchState = workbenchState
    }

    @ViewBuilder
    private var codeBreadcrumb: some View {
        if let context = runtime?.sessionsModel.titlebarWorkspaceContext {
            HStack(spacing: 7) {
                TahoeIcon("folder", size: 11)
                    .foregroundStyle(t.fg3)
                Text(context.repoDisplayName)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TahoeIcon("chevR", size: 9)
                    .foregroundStyle(t.fg4)
                Text(context.branchLabel)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 420)
            .help("\(context.repoDisplayName)\n\(context.branchLabel)")
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
            // Reserve just enough leading space so the tab chip clears
            // the real (close/min/zoom) controls (rightmost edge ~66pt
            // at standard inset). The outer HStack's 10pt spacing adds
            // the visual buffer past that, no need to over-reserve.
            Color.clear.frame(width: 60, height: 1)

            if active == .code {
                TahoeGlass(radius: 6, tone: .chip) {
                    tabStrip
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                }
                .fixedSize()

                TahoeGlass(radius: 6, tone: .chip) {
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
                TahoeGlass(radius: 6, tone: .chip) {
                    HStack(spacing: 10) {
                        tabStrip
                        Spacer(minLength: 0)
                        UpdateAppControl(coordinator: updateCoordinator)
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
        TahoeGlass(radius: 6, tone: .chip) {
            HStack(spacing: 2) {
                UpdateAppControl(coordinator: updateCoordinator, compact: true)
                paneMenuButton
            }
            .padding(.horizontal, 7)
            .frame(height: 30)
        }
        .fixedSize()
    }

    /// Single right-pane menu. Replaces the older "bell + sidebar"
    /// trio — the bell button was bound to a popover anchored on a
    /// different chip and never showed reliably; the sidebar button
    /// only ever opened the Plan pane. This Menu lists every workbench
    /// tab plus a Collapse action so the user can open any pane in one
    /// click and dismiss it from the same chip.
    @ViewBuilder
    private var paneMenuButton: some View {
        Menu {
            paneMenuItem(.plan,      shortcut: "⇧⌘P")
            paneMenuItem(.diff,      shortcut: "⇧⌘D")
            paneMenuItem(.terminal,  shortcut: "⌃`")
            paneMenuItem(.sources)
            paneMenuItem(.artifacts, shortcut: "⇧⌘F")
            paneMenuItem(.pr)
            paneMenuItem(.browser)
            Divider()
            Button(action: {
                NotificationCenter.default.post(name: .toggleCodeReviewPane, object: nil)
            }) {
                if workbenchState.showingReviewPane {
                    Label("Collapse pane", systemImage: "sidebar.trailing")
                } else {
                    Label("Expand pane", systemImage: "sidebar.leading")
                }
            }
            .accessibilityIdentifier(
                workbenchState.showingReviewPane
                    ? "code.titlebar.right-pane.collapse"
                    : "code.titlebar.right-pane.expand"
            )
        } label: {
            TahoeIcon("sidebar", size: 12)
                .foregroundStyle(t.fg3)
                .frame(width: 24, height: 24)
                .background(t.hair2.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Right pane")
        .accessibilityIdentifier("code.titlebar.right-pane")
    }

    /// Menu row that opens a specific workbench tab. `WorkbenchPaneTab`
    /// owns its own systemImage so the icons stay aligned with the
    /// tab strip and the deep-link / keyboard-shortcut routes already
    /// registered for the Code scope.
    @ViewBuilder
    private func paneMenuItem(_ tab: WorkbenchPaneTab, shortcut: String? = nil) -> some View {
        Button(action: {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .openCodeReviewPane,
                    object: nil,
                    userInfo: ["tab": tab.rawValue]
                )
            }
        }) {
            HStack {
                Label(tab.rawValue, systemImage: tab.systemImage)
                if let shortcut {
                    Spacer()
                    Text(shortcut)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityIdentifier("code.titlebar.right-pane.\(tab.accessibilityKey)")
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
            syncChipUsage
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
