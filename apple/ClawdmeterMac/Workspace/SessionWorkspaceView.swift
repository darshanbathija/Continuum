import SwiftUI
import AppKit
import ClawdmeterShared

/// Routes both #174's (`clawdmeterOpenWorkspaceChatTab` /
/// `clawdmeterOpenWorkspaceTerminalTab`) and #185's
/// (`newCodeChatTab` / `newCodeTerminalTab`) notification posters into the
/// same two callbacks. Extracted out of `SessionWorkspaceView.body` so the
/// SwiftUI compiler can type-check the body chain in reasonable time — four
/// extra `.onReceive` modifiers in `body` tripped the
/// "compiler is unable to type-check this expression" guard.
private struct WorkspaceTabSpawnObservers: ViewModifier {
    let openChat: () -> Void
    let openTerminal: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenWorkspaceChatTab)) { _ in
                openChat()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newCodeChatTab)) { _ in
                openChat()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenWorkspaceTerminalTab)) { _ in
                openTerminal()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newCodeTerminalTab)) { _ in
                openTerminal()
            }
    }
}

/// G0/G1: three-pane Codex-desktop workspace.
///
/// Layout:
///   ┌─────────────┬──────────────────────────────┬────────────────────┐
///   │   Sidebar   │       Center thread          │    Review pane     │
///   │ repos +     │  Header (mode picker, ...)   │  [Plan|Diff|Src... │
///   │  sessions   │  chat messages               │  selected tab      │
///   │  search     │  composer                    │                    │
///   └─────────────┴──────────────────────────────┴────────────────────┘
///
/// Uses `HSplitView` so column widths persist and can be dragged. NavSplitView
/// was tried first; it column-folds on narrow widths and hides the back chrome
/// (the same bug that caused the pre-G0 blank-detail regression).
struct SessionWorkspaceView: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var presentationStore: SessionPresentationStore

    /// User's explicit toggle for the review pane. Default OFF so Sessions
    /// + chat get the full window by default; the user opts into the
    /// review pane via the right-edge gutter (CTA) or the toolbar button.
    @State private var showingModeSwitchOverlay: Bool = false
    @State private var modeSwitchLabel: String = ""
    @State private var showingWorkspaceSwitcher: Bool = false
    @StateObject private var launcher = SessionLauncherModel()
    @StateObject private var workbenchState = WorkbenchState()
    /// Workspace-level width, measured via GeometryReader. Drives responsive
    /// pane collapsing so even when the user opens the review pane it only
    /// renders if the window has room for it without clipping content.

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Minimum width required to render the review pane at its full
    /// content-respecting width (≥440pt) without crushing sidebar + chat.
    /// 220 (sidebar min) + 480 (center min) + 440 (review min) + chrome.
    private static let reviewPaneThreshold: CGFloat = 1200

    /// Minimum width required to render even the right-edge gutter CTA.
    /// Below this, the workspace is just sidebar + chat — the user can
    /// resize to summon the gutter back.
    private static let gutterThreshold: CGFloat = 900

    private var effectiveShowReviewPane: Bool {
        workbenchState.showingReviewPane && workbenchState.workspaceWidth >= Self.reviewPaneThreshold
    }

    private var effectiveShowGutter: Bool {
        !effectiveShowReviewPane && workbenchState.workspaceWidth >= Self.gutterThreshold
    }

    /// Diff needs space — bump the review pane to ~58% of the workspace
    /// width when Diff is the selected tab. Other tabs stay at the
    /// compact 380pt so the center chat keeps its breathing room.
    private var reviewPaneWidth: CGFloat {
        let workspace = CGFloat(workbenchState.workspaceWidth)
        let isDiff = workbenchState.selectedRightPane == .diff
        guard isDiff, workspace > 0 else { return 380 }
        // Clamp so even on a narrow window Diff stays usable, and on a
        // huge window it doesn't squeeze the center chat to nothing.
        let target = workspace * 0.58
        return max(560, min(target, workspace - 520))
    }

    var body: some View {
        // A6 (foundation): tap the body-invalidation counter so downstream
        // PRs can assert independence between this parent and the extracted
        // sub-views. No-op when `BodyInvalidationCounter.enabled` is false
        // (production default).
        BodyInvalidationCounter.bump("SessionWorkspaceView")
        return ZStack {
            t.pageBg.opacity(t.dark ? 0.35 : 0.18)
            HSplitView {
                TahoeGlass(radius: 20, tone: .panel) {
                    SidebarPane(
                        model: model,
                        workbenchState: workbenchState,
                        presentationStore: presentationStore
                    )
                }
                .frame(width: 260)
                .padding(.trailing, 5)

                // Center pane carries the chat AND, when the review pane is
                // collapsed, a thin right-edge gutter that doubles as the
                // expand CTA. Keeping the gutter inside the center column
                // (instead of as its own HSplitView child) means the user
                // can't accidentally drag-resize it.
                TahoeGlass(radius: 20, tone: .panel) {
                    HStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            if let documentTab = model.selectedWorkspaceDocumentTab,
                               let documentSession = model.registry.session(id: documentTab.sessionId) {
                                centerDocument(documentTab, session: documentSession)
                                    .id(documentTab.id)
                            } else if let terminalTab = model.selectedWorkspaceTerminalTab,
                               let terminalSession = model.registry.session(id: terminalTab.sessionId) {
                                centerTerminal(terminalTab, session: terminalSession)
                                    .id(terminalTab.id)
                            } else if let session = model.openSession {
                                CenterThread(
                                    session: session,
                                    isReadOnly: model.openSessionIsReadOnly,
                                    model: model,
                                    catalog: launcher.modelCatalog,
                                    workbenchState: workbenchState,
                                    presentationStore: presentationStore,
                                    density: workbenchState.density,
                                    onDensityChange: { workbenchState.setDensity($0) },
                                    onModeSwitch: { newMode in
                                        Task { await switchMode(session: session, to: newMode) }
                                    }
                                )
                                .id(session.id)
                            } else if let draft = model.draftWorkspaceTab {
                                centerDraft(draft)
                                    .id(draft.id)
                            } else {
                                centerEmpty
                            }
                            if showingModeSwitchOverlay {
                                modeSwitchOverlay
                            }
                            // v0.23 (T11+T16): use the lifted Shared
                            // PermissionPromptCard + MacPermissionResponder.
                            // Replaces the deleted LegacyMacPermissionPromptCard
                            // that used to live in ChatSoloView.swift.
                            if model.selectedWorkspaceDocumentTab == nil,
                               model.selectedWorkspaceTerminalTab == nil,
                               let session = model.openSession,
                               let store = model.chatStore(for: session),
                               let prompt = store.pendingPermissionPrompt {
                                PermissionPromptCard(
                                    prompt: prompt,
                                    sessionId: session.id,
                                    responder: MacPermissionResponder()
                                )
                                .padding(.horizontal, 20)
                                .padding(.bottom, 16)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        if effectiveShowGutter, model.openSession != nil {
                            TahoeHairline(vertical: true)
                            ReviewPaneGutter(
                                selectedTab: selectedRightPaneBinding,
                                onExpand: { tab in
                                    workbenchState.selectRightPane(tab)
                                    animateWorkspaceChange(.easeOut(duration: 0.18)) {
                                        workbenchState.setReviewPaneVisible(true)
                                    }
                                }
                            )
                        }
                    }
                }
                .frame(minWidth: 420, idealWidth: 600)
                .padding(.horizontal, 5)

                if effectiveShowReviewPane, let session = model.openSession {
                    TahoeGlass(radius: 20, tone: .panel) {
                        ReviewPane(
                            session: session,
                            chatStore: model.chatStore(for: session),
                            model: model,
                            workbenchState: workbenchState,
                            presentationStore: presentationStore,
                            selectedTab: selectedRightPaneBinding,
                            onClose: {
                                animateWorkspaceChange(.easeOut(duration: 0.18)) {
                                    workbenchState.setReviewPaneVisible(false)
                                }
                            },
                            onApprove: {
                                Task {
                                    guard await createApprovalCheckpoint(for: session) else { return }
                                    await model.approvePlan(id: session.id)
                                }
                            }
                        )
                        // Root cause: unlike the sibling CenterThread (which is
                        // .id(session.id)), ReviewPane kept structural identity
                        // across a session switch, so its panes (Artifacts, etc.)
                        // showed the previous session's state until refresh.
                        .id(session.id)
                    }
                    // Diff is the one pane that's useless at the default
                    // 380pt width — readers need to see ±50 cols at once.
                    // Bump it to ~58% of the workspace when Diff is the
                    // selected tab; the other tabs (Plan / Sources / PR /
                    // Terminal) stay compact so the center chat keeps its
                    // breathing room.
                    .frame(width: reviewPaneWidth)
                    .padding(.leading, 5)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(10)
        }
        .background(Color.clear)
        .background(
            // Measure the actual workspace width. Don't use GeometryReader
            // as the root because HSplitView misbehaves inside it.
            GeometryReader { proxy in
                Color.clear
                    .preference(key: WorkspaceWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(WorkspaceWidthKey.self) { workbenchState.updateWorkspaceWidth($0) }
        .sheet(isPresented: $model.showingNewSessionSheet) {
            NewSessionMacSheet(model: model)
        }
        .overlay {
            if showingWorkspaceSwitcher {
                ZStack {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture { showingWorkspaceSwitcher = false }
                    WorkspaceSwitcherSheet(
                        model: model,
                        focusedSession: model.openSession,
                        isPresented: $showingWorkspaceSwitcher
                    )
                    .frame(width: 620, height: 520)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 18)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
                }
                .zIndex(20)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showingWorkspaceSwitcher)
        .onAppear {
            restorePersistedSessionSelectionIfPossible()
        }
        .onChange(of: model.openSessionId) { _, newValue in
            workbenchState.selectSession(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCodeReviewPane)) { _ in
            guard workbenchState.workspaceWidth >= Self.reviewPaneThreshold else { return }
            animateWorkspaceChange(.easeOut(duration: 0.18)) {
                workbenchState.setReviewPaneVisible(!workbenchState.showingReviewPane)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeReviewPane)) { note in
            if let raw = note.userInfo?["tab"] as? String,
               let tab = WorkbenchPaneTab(rawValue: raw) {
                workbenchState.selectRightPane(tab)
            }
            animateWorkspaceChange(.easeOut(duration: 0.18)) {
                workbenchState.setReviewPaneVisible(true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkspaceSwitcher)) { _ in
            showingWorkspaceSwitcher = true
        }
        .modifier(WorkspaceTabSpawnObservers(
            openChat: openNewWorkspaceChatTab,
            openTerminal: openNewWorkspaceTerminalTab
        ))
        .onReceive(NotificationCenter.default.publisher(for: .showRawTerminal)) { note in
            guard let id = note.userInfo?["sessionId"] as? UUID else { return }
            if let open = model.openSession, open.id == id {
                guard model.canOpenWorkspaceTerminalTab(from: open) else { return }
                Task { await model.openOrCreateWorkspaceTerminalTab(from: open) }
            } else if let session = model.registry.sessions.first(where: { $0.id == id }) {
                guard model.canOpenWorkspaceTerminalTab(from: session) else { return }
                Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
            }
        }
        .task {
            await launcher.refreshProviderAvailability()
        }
        .background(KeyboardShortcuts(
            model: model
        ))
    }

    private var selectedRightPaneBinding: Binding<WorkbenchPaneTab> {
        Binding(
            get: { workbenchState.selectedRightPane },
            set: { workbenchState.selectRightPane($0) }
        )
    }

    private func animateWorkspaceChange(_ animation: Animation, _ updates: () -> Void) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                updates()
            }
        } else {
            withAnimation(animation, updates)
        }
    }

    private func restorePersistedSessionSelectionIfPossible() {
        guard model.draftWorkspaceTab == nil,
              model.openSessionId == nil,
              let selected = workbenchState.selectedSessionId,
              model.registry.sessions.contains(where: { $0.id == selected && $0.archivedAt == nil })
        else {
            return
        }
        model.openSessionId = selected
    }

    /// Shared helper called by both `clawdmeterOpenWorkspaceChatTab` (#174 menu
    /// command path) and `newCodeChatTab` (#185 chip / shortcut-registry path).
    /// Both posters reach the same `openDraftWorkspaceTab` API on the model so
    /// the two paths cannot drift.
    private func openNewWorkspaceChatTab() {
        guard let session = model.openSession else { return }
        model.openDraftWorkspaceTab(
            from: session,
            defaults: ComposerStore.ChipDefaults(
                agent: session.agent,
                modelId: session.model,
                effort: session.effort,
                mode: session.mode,
                planMode: false
            )
        )
    }

    /// Shared helper for the terminal-tab posters — `clawdmeterOpenWorkspaceTerminalTab`
    /// (#174) and `newCodeTerminalTab` (#185). Mirrors the original inline
    /// fallback that hops onto a sibling session when the foreground tab is a
    /// chat draft with no terminal of its own.
    private func openNewWorkspaceTerminalTab() {
        if let session = model.openSession {
            guard model.canOpenWorkspaceTerminalTab(from: session) else { return }
            Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
        } else if let draft = model.draftWorkspaceTab,
                  let sibling = WorkspaceKey.siblings(of: draft.workspaceKey, in: model.registry.sessions)
                    .first(where: { model.canOpenWorkspaceTerminalTab(from: $0) }) {
            Task { await model.openOrCreateWorkspaceTerminalTab(from: sibling) }
        }
    }

    /// Hidden buttons that own Option+Cmd+1..9 + Cmd+Shift+F + Cmd+;
    /// keyboard shortcuts. SwiftUI's `.keyboardShortcut` only fires when
    /// the view is in the focus chain; attaching to `Color.clear` in a
    /// background layer keeps them globally active without stealing focus.
    /// The number chords intentionally include Option because the app-level
    /// View menu reserves Cmd+1..5 for top-level tab switching.
    private struct KeyboardShortcuts: View {
        @ObservedObject var model: SessionsModel
        var body: some View {
            ZStack {
                ForEach(1...9, id: \.self) { index in
                    Button("") {
                        model.openVisibleSession(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")),
                                      modifiers: [.command, .option])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                }
                Button("") {
                    if let session = model.openSession {
                        model.openDraftWorkspaceTab(
                            from: session,
                            defaults: ComposerStore.ChipDefaults(
                                agent: session.agent,
                                modelId: session.model,
                                effort: session.effort,
                                mode: session.mode,
                                planMode: false
                            )
                        )
                    }
                }
                .keyboardShortcut("t", modifiers: [.command])
                .opacity(0)
                .frame(width: 0, height: 0)

                Button("") {
                    if let session = model.openSession,
                       model.canOpenWorkspaceTerminalTab(from: session) {
                        Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
            }
        }
    }

    // MARK: - Center empty state — Codex-style centered composer

    private var centerEmpty: some View {
        EmptyStateCenteredComposer(model: model, launcher: launcher, presentationStore: presentationStore)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centerDraft(_ draft: WorkspaceDraftTab) -> some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(
                model: model,
                workspaceKey: draft.workspaceKey,
                activeSession: nil,
                activeSessionId: nil,
                draftTab: draft,
                terminalTabs: model.workspaceTerminalTabs(in: draft.workspaceKey),
                activeTerminalTabId: nil,
                documentTabs: model.workspaceDocumentTabs(in: draft.workspaceKey),
                activeDocumentTabId: model.selectedWorkspaceDocumentTab?.id,
                terminalAvailable: WorkspaceKey.siblings(of: draft.workspaceKey, in: model.registry.sessions)
                    .contains(where: { model.canOpenWorkspaceTerminalTab(from: $0) }),
                onNewChat: {},
                onNewTerminal: {
                    if let first = WorkspaceKey.siblings(of: draft.workspaceKey, in: model.registry.sessions)
                        .first(where: { model.canOpenWorkspaceTerminalTab(from: $0) }) {
                        Task { await model.openOrCreateWorkspaceTerminalTab(from: first) }
                    }
                },
                onSelectTerminal: { model.selectWorkspaceTerminalTab($0) },
                onCloseTerminal: { tab in Task { await model.closeWorkspaceTerminalTab(tab) } },
                onSelectDocument: { model.selectWorkspaceDocumentTab($0) },
                onCloseDocument: { model.closeWorkspaceDocumentTab($0) }
            )
            EmptyStateCenteredComposer(
                model: model,
                launcher: launcher,
                presentationStore: presentationStore,
                workspaceDraft: draft
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func centerTerminal(_ tab: WorkspaceTerminalTab, session: AgentSession) -> some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(
                model: model,
                workspaceKey: tab.workspaceKey,
                activeSession: session,
                activeSessionId: session.id,
                draftTab: model.draftWorkspaceTab,
                terminalTabs: model.workspaceTerminalTabs(in: tab.workspaceKey),
                activeTerminalTabId: tab.id,
                documentTabs: model.workspaceDocumentTabs(in: tab.workspaceKey),
                activeDocumentTabId: model.selectedWorkspaceDocumentTab?.id,
                terminalAvailable: model.canOpenWorkspaceTerminalTab(from: session),
                onNewChat: {
                    model.openDraftWorkspaceTab(
                        from: session,
                        defaults: ComposerStore.ChipDefaults(
                            agent: session.agent,
                            modelId: session.model,
                            effort: session.effort,
                            mode: session.mode,
                            planMode: false
                        )
                    )
                },
                onNewTerminal: {
                    Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
                },
                onSelectTerminal: { model.selectWorkspaceTerminalTab($0) },
                onCloseTerminal: { terminalTab in
                    Task { await model.closeWorkspaceTerminalTab(terminalTab) }
                },
                onSelectDocument: { model.selectWorkspaceDocumentTab($0) },
                onCloseDocument: { model.closeWorkspaceDocumentTab($0) }
            )
            if let runtime = AppDelegate.runtime,
               let port = runtime.agentControlServer.boundWsPort {
                WorkspaceTerminalPane(
                    session: session,
                    terminalTab: tab,
                    wsPort: Int(port),
                    token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? "")
                )
            } else {
                ContentUnavailableView(
                    "Daemon offline",
                    systemImage: "wifi.exclamationmark",
                    description: Text("Restart Clawdmeter to reconnect terminal tabs.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func centerDocument(_ tab: WorkspaceDocumentTab, session: AgentSession) -> some View {
        VStack(spacing: 0) {
            WorkspaceTabStrip(
                model: model,
                workspaceKey: tab.workspaceKey,
                activeSession: session,
                activeSessionId: session.id,
                draftTab: model.draftWorkspaceTab,
                terminalTabs: model.workspaceTerminalTabs(in: tab.workspaceKey),
                activeTerminalTabId: model.selectedWorkspaceTerminalTab?.id,
                documentTabs: model.workspaceDocumentTabs(in: tab.workspaceKey),
                activeDocumentTabId: tab.id,
                terminalAvailable: model.canOpenWorkspaceTerminalTab(from: session),
                onNewChat: {
                    model.openDraftWorkspaceTab(
                        from: session,
                        defaults: ComposerStore.ChipDefaults(
                            agent: session.agent,
                            modelId: session.model,
                            effort: session.effort,
                            mode: session.mode,
                            planMode: false
                        )
                    )
                },
                onNewTerminal: {
                    Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
                },
                onSelectTerminal: { model.selectWorkspaceTerminalTab($0) },
                onCloseTerminal: { terminalTab in
                    Task { await model.closeWorkspaceTerminalTab(terminalTab) }
                },
                onSelectDocument: { model.selectWorkspaceDocumentTab($0) },
                onCloseDocument: { model.closeWorkspaceDocumentTab($0) }
            )
            MarkdownDocumentTabView(tab: tab)
        }
    }

    // MARK: - Mode-switch overlay (D13)

    private var modeSwitchOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(modeSwitchLabel)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        }
        .transition(.opacity)
    }

    @MainActor
    private func switchMode(session: AgentSession, to newMode: SessionMode) async {
        guard newMode != session.mode, newMode != .cloud else { return }
        modeSwitchLabel = "Switching to \(newMode.rawValue.capitalized)…"
        withAnimation(.easeInOut(duration: 0.15)) {
            showingModeSwitchOverlay = true
        }
        defer {
            withAnimation(.easeInOut(duration: 0.2)) {
                showingModeSwitchOverlay = false
            }
        }
        await model.switchMode(sessionId: session.id, to: newMode)
    }

    private func createApprovalCheckpoint(for session: AgentSession) async -> Bool {
        let service = CheckpointService()
        do {
            let checkpoint = try await service.createCheckpoint(session: session, summary: "Before plan approval")
            workbenchState.recordCheckpoint(checkpoint)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Theme

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.08)
            : Color(red: 0.96, green: 0.96, blue: 0.96)
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}

// MARK: - Sidebar (left pane)

private struct SidebarPane: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
    @ObservedObject var presentationStore: SessionPresentationStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Used to pause the 1Hz "external activity" tick when the window isn't
    // active (app backgrounded / occluded by another window). The tick only
    // drives cosmetic relative-time / "live now" freshness, so there's
    // nothing to refresh while the user can't see it.
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var searchFocused: Bool

    /// Persisted sidebar grouping + sorting + status-filter preferences.
    /// All three are local to the Mac UI — iOS has its own equivalents.
    @AppStorage("clawdmeter.sidebar.grouping") private var groupingRaw: String = SessionGrouping.status.rawValue
    @AppStorage("clawdmeter.sidebar.sorting")  private var sortingRaw: String  = SessionSorting.recency.rawValue
    @AppStorage("clawdmeter.sidebar.status")   private var statusRaw: String   = SessionStatusFilter.all.rawValue

    /// History section is collapsed by default — older external sessions
    /// clutter the sidebar and most of the time the user wants the active
    /// repos at the top. Tapping the History row expands the list.
    @AppStorage("clawdmeter.sidebar.historyExpanded") private var historyExpanded: Bool = false

    /// v0.29.33: opt-in to filesystem session discovery. Default false → the
    /// sidebar shows only Managed (explicitly-added) repos and RepoIndex does
    /// NO ~/.claude / ~/.codex / folder scan, so opening Code triggers no
    /// folder/cross-app permission prompt. The "Discover parallel sessions"
    /// button flips this shared key (RepoIndex reads the same UserDefaults
    /// key via ProviderEnablement) and refreshes → status-quo discovery.
    @AppStorage("clawdmeter.code.discoverParallelSessions") private var discoverParallelSessions: Bool = false

    /// v0.5.4: rename sheet state. v0.5.9: split into a dedicated bool
    /// + data target — the `Binding(get:set:)` pattern for `isPresented:`
    /// didn't reliably trigger alert presentation; the canonical pattern
    /// is `@State Bool` + `presenting:` payload.
    @State private var renameTarget: AgentSession?
    @State private var renameInput: String = ""
    @State private var showingRenameAlert: Bool = false
    /// Add Repo flow sheets. "Open project" doesn't need a sheet — it pops
    /// NSOpenPanel directly. Clone + Quick Start each get a SwiftUI sheet.
    @State private var showingCloneRepoSheet: Bool = false
    @State private var showingQuickStartRepoSheet: Bool = false
    // v0.5.10 — parallel state for Recent JSONL row rename. Keyed by path
    // (not session id) because these rows aren't Clawdmeter-owned
    // sessions; they're files we surface.
    @State private var renameJSONLTarget: RecentSession?
    @State private var renameJSONLInput: String = ""
    @State private var showingRenameJSONLAlert: Bool = false
    @State private var collapsedStatusGroupIDs: Set<String> = []
    @State private var collapsedPrioritySectionIDs: Set<String> = []
    @State private var sidebarViewportHeight: CGFloat = 0
    @State private var sidebarContentHeight: CGFloat = 0
    @State private var hoveredSessionId: UUID?
    @State private var hoveredRecentPath: String?
    @State private var colorTagTarget: AgentSession?
    @State private var colorTagInput: String = ""
    @State private var showingColorTagAlert = false
    @State private var comparisonPair: SessionComparisonPair?
    @State private var externalActivityNow: Date = Date()
    @State private var requestedRepoIdentityKeys: Set<String> = []

    /// A11: single-slot cache for the sidebar projection. Persists across
    /// body re-evals (reference type held via @State) so SwiftUI ticking
    /// the body for unrelated reasons (registry mutation that doesn't
    /// touch any displayed field, presentationStore change, etc.) doesn't
    /// re-bucket every session. Cache hits short-circuit the heavy
    /// grouper/canonicalizer call. The key bundles every input the
    /// projection reads — see `SidebarProjectionKey` for the contract.
    @State private var projectionCache = SingleSlotProjectionCache<SidebarProjectionKey, SidebarProjection>()

    private var grouping: SessionGrouping {
        SessionGrouping(rawValue: groupingRaw) ?? .repo
    }
    private var sorting: SessionSorting {
        SessionSorting(rawValue: sortingRaw) ?? .recency
    }
    private var statusFilter: SessionStatusFilter {
        SessionStatusFilter(rawValue: statusRaw) ?? .all
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            sidebarHeader
            TahoeHairline()
            content
        }
        .background(Color.clear)
        // v0.5.4 / v0.5.9 rename sheet. Explicit bool + presenting:
        // payload is the SwiftUI pattern that reliably presents — the
        // earlier Binding(get:set:) form silently no-op'd because the
        // closure-captured state read isn't tracked as a dependency.
        .alert(
            "Rename session",
            isPresented: $showingRenameAlert,
            presenting: renameTarget
        ) { target in
            TextField("Name", text: $renameInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                commitSessionRename(target, name: renameInput)
            }
            Button("Clear name", role: .destructive) {
                commitSessionRename(target, name: nil)
            }
            Button("Cancel", role: .cancel) {
                resetSessionRenameState()
            }
        } message: { target in
            Text("Currently: \(sessionTitle(target))")
        }
        // v0.5.10 — Recent JSONL row rename alert. Same canonical Bool
        // + presenting payload pattern as the session-rename alert.
        .alert(
            "Rename session",
            isPresented: $showingRenameJSONLAlert,
            presenting: renameJSONLTarget
        ) { target in
            TextField("Name", text: $renameJSONLInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                let trimmed = renameJSONLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                model.renameJSONLAlias(path: target.path, name: trimmed.isEmpty ? nil : trimmed)
                showingRenameJSONLAlert = false
                renameJSONLTarget = nil
                renameJSONLInput = ""
            }
            Button("Clear name", role: .destructive) {
                model.renameJSONLAlias(path: target.path, name: nil)
                showingRenameJSONLAlert = false
                renameJSONLTarget = nil
                renameJSONLInput = ""
            }
            Button("Cancel", role: .cancel) {
                showingRenameJSONLAlert = false
                renameJSONLTarget = nil
                renameJSONLInput = ""
            }
        } message: { target in
            Text("Currently: \(recentTitle(target))")
        }
        .alert(
            "Color tag",
            isPresented: $showingColorTagAlert,
            presenting: colorTagTarget
        ) { target in
            TextField("Tag name", text: $colorTagInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                try? presentationStore.setColorTag(target.id, tag: colorTagInput)
                showingColorTagAlert = false
                colorTagTarget = nil
                colorTagInput = ""
            }
            Button("Clear tag", role: .destructive) {
                try? presentationStore.setColorTag(target.id, tag: nil)
                showingColorTagAlert = false
                colorTagTarget = nil
                colorTagInput = ""
            }
            Button("Cancel", role: .cancel) {
                showingColorTagAlert = false
                colorTagTarget = nil
                colorTagInput = ""
            }
        } message: { target in
            Text("Use a short label like Review, Bug, Docs, or Ship for \(sessionTitle(target)).")
        }
        .sheet(item: $comparisonPair) { pair in
            SessionComparisonSheet(pair: pair, model: model)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            // Skip cosmetic freshness ticks while the window is inactive —
            // no visible relative-time/green-dot to refresh. (Same-window
            // hidden-tab gating needs an active-tab flag from MacRootView;
            // see cross-file note.)
            guard controlActiveState != .inactive else { return }
            guard model.repos.contains(where: { !$0.recentSessions.isEmpty }) else { return }
            externalActivityNow = now
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Text("Projects")
                .font(TahoeFont.body(11, weight: .bold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(t.fg3)
                .lineLimit(1)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            filterMenu
            addRepoMenu
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .sheet(isPresented: $showingCloneRepoSheet) {
            CloneRepoSheet(onboarding: model.repoOnboarding) { _ in }
        }
        .sheet(isPresented: $showingQuickStartRepoSheet) {
            QuickStartRepoSheet(onboarding: model.repoOnboarding) { _ in }
        }
    }

    /// Sidebar header's "+ Add project" Menu. Replaces the previous
    /// "New session" entry point on this button. New Session now lives on
    /// `Cmd+N` (unchanged) and the per-repo `+` button. Three rows mirror
    /// Conductor's Add-Repo popover.
    @ViewBuilder
    private var addRepoMenu: some View {
        Menu {
            Button {
                Task {
                    do { _ = try await model.repoOnboarding.openLocalFolder() }
                    catch let err as RepoOnboardingError {
                        if case .alreadyRegistered = err { return }
                        await MainActor.run { presentRepoOnboardingError(err) }
                    } catch {
                        await MainActor.run { presentRepoOnboardingError(error) }
                    }
                }
            } label: {
                Label("Open project", systemImage: "folder")
            }
            Button {
                showingCloneRepoSheet = true
            } label: {
                Label("Open GitHub project", systemImage: "globe")
            }
            Button {
                showingQuickStartRepoSheet = true
            } label: {
                Label("Quick start", systemImage: "plus.rectangle.on.folder")
            }
        } label: {
            TahoeIcon("folderPlus", size: 15, weight: .semibold)
                .foregroundStyle(t.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(t.accentAlpha(t.dark ? 0.18 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(t.accentAlpha(0.32), lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add project")
    }

    private func presentRepoOnboardingError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't add project"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
            alert.informativeText += "\n\n\(suggestion)"
        }
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Linear-style filter / group / sort menu. Active non-default
    /// selections paint the chip terra-cotta so the user knows the
    /// sidebar is filtered without opening the menu.
    @ViewBuilder
    private var filterMenu: some View {
        let isCustomised =
            grouping != .status
            || sorting != .recency
            || statusFilter != .all
        Menu {
            Section("Status") {
                ForEach(SessionStatusFilter.allCases, id: \.self) { option in
                    Button(action: { statusRaw = option.rawValue }) {
                        Label(option.displayName, systemImage: statusFilter == option ? "checkmark" : "")
                    }
                }
            }
            Section("Group by") {
                ForEach(SessionGrouping.allCases, id: \.self) { option in
                    Button(action: { groupingRaw = option.rawValue }) {
                        Label(option.displayName, systemImage: grouping == option ? "checkmark" : "")
                    }
                }
            }
            Section("Sort by") {
                ForEach(SessionSorting.allCases, id: \.self) { option in
                    Button(action: { sortingRaw = option.rawValue }) {
                        Label(option.displayName, systemImage: sorting == option ? "checkmark" : "")
                    }
                }
            }
            Section("Projects") {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh repo list", systemImage: "arrow.clockwise")
                }
            }
            if isCustomised {
                Divider()
                Button("Reset filters") {
                    statusRaw = SessionStatusFilter.all.rawValue
                    groupingRaw = SessionGrouping.status.rawValue
                    sortingRaw = SessionSorting.recency.rawValue
                }
            }
        } label: {
            TahoeIcon("filter", size: 12)
                .foregroundStyle(isCustomised ? t.accent : t.fg3)
                .frame(width: 24, height: 24)
                .background(isCustomised ? t.accentAlpha(0.15) : t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group, sort, and filter sessions")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            TahoeIcon("search", size: 12)
                .foregroundStyle(t.fg3)
            TextField("Search…", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(TahoeFont.body(12.5))
                .focused($searchFocused)
            if !model.searchQuery.isEmpty {
                Button(action: { model.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(t.fg3)
                }
                .buttonStyle(.plain)
            }
            Text("⌘K")
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(t.fg4)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(t.hairline, lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .onReceive(NotificationCenter.default.publisher(for: .focusSidebarSearch)) { _ in
            searchFocused = true
        }
    }

    private var statusBuckets: some View {
        HStack(spacing: 4) {
            sidebarBucket(
                title: "Active",
                count: statusCount(.active),
                active: statusFilter == .active,
                color: .green
            ) { toggleStatusFilter(.active) }
            sidebarBucket(
                title: "Review",
                count: statusCount(.inReview),
                active: statusFilter == .inReview,
                color: .orange
            ) { toggleStatusFilter(.inReview) }
            sidebarBucket(
                title: "Done",
                count: statusCount(.done),
                active: statusFilter == .done,
                color: terraCotta
            ) { toggleStatusFilter(.done) }
            sidebarBucket(
                title: "Archive",
                count: statusCount(.archived),
                active: statusFilter == .archived,
                color: .secondary
            ) { toggleStatusFilter(.archived) }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func toggleStatusFilter(_ filter: SessionStatusFilter) {
        statusRaw = statusFilter == filter ? SessionStatusFilter.all.rawValue : filter.rawValue
        if grouping != .status {
            groupingRaw = SessionGrouping.status.rawValue
        }
    }

    private func sidebarBucket(
        title: String,
        count: Int,
        active: Bool,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(active ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .foregroundStyle(active ? .white : color)
            .background(
                active ? color.opacity(0.82) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
    }

    private func statusCount(_ filter: SessionStatusFilter) -> Int {
        let sessions = model.filter(sessions: model.registry.sessions)
        switch filter {
        case .all:
            return sessions.count
        case .active:
            return sessions.filter { SessionSidebarGrouper.bucket(for: $0, reviewSessionIds: reviewSessionIds) == .active }.count
        case .inReview:
            return sessions.filter { SessionSidebarGrouper.bucket(for: $0, reviewSessionIds: reviewSessionIds) == .inReview }.count
        case .done:
            return sessions.filter { SessionSidebarGrouper.bucket(for: $0, reviewSessionIds: reviewSessionIds) == .done }.count
        case .archived:
            return sessions.filter { SessionSidebarGrouper.bucket(for: $0, reviewSessionIds: reviewSessionIds) == .archived }.count
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.filteredRepos.isEmpty && model.registry.sessions.isEmpty {
            emptyState
        } else {
            // A11: read the projection once at the top of the body so a
            // single cache hit covers content + filteredVisibleSessions
            // + reviewSessionIds. Local binding keeps the closure-level
            // re-reads as Swift property accesses (O(1)) rather than
            // re-running the cache lookup.
            let projection = currentProjection
            ScrollView {
                LazyVStack(spacing: 0) {
                    if projection.hasPriorityContent {
                        prioritySidebarContent(projection)
                    } else {
                        filteredEmptyState
                    }
                    // Sits under the Managed repos (or the empty state). Off by
                    // default; tapping opts in to full filesystem discovery for
                    // this and future launches. Until then nothing reads
                    // ~/.claude / ~/.codex or scans user folders.
                    if !discoverParallelSessions {
                        discoverSessionsButton
                    }
                }
                .padding(.vertical, 6)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SidebarContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SidebarViewportHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(SidebarContentHeightKey.self) { sidebarContentHeight = $0 }
            .onPreferenceChange(SidebarViewportHeightKey.self) { sidebarViewportHeight = $0 }
            .mask(sidebarMask)
        }
    }

    @ViewBuilder
    private var sidebarMask: some View {
        if sidebarContentHeight > sidebarViewportHeight + 8 {
            sidebarFadeMask
        } else {
            Rectangle().fill(.black)
        }
    }

    private var sidebarFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
        }
    }

    /// Search + showArchived already filter the repos via the model.
    /// The status filter is applied in the grouper for non-repo paths;
    /// for repo grouping we still want to honour it by post-filtering.
    private var filteredReposForGrouping: [AgentRepo] {
        model.filteredRepos
    }

    /// A11: cache-backed sidebar projection. Reads upstream state once
    /// per body pass, builds the cache key, consults the cache. On hit:
    /// returns the prior projection without re-bucketing. On miss:
    /// rebuilds via `SidebarProjectionBuilder.build(...)`. The body
    /// downstream (`content`, `filteredVisibleSessions`, `reviewSessionIds`)
    /// all read from this one projection so the cache hit applies to
    /// every consumer.
    ///
    /// **Search step runs outside the cache.** `model.filter(sessions:)`
    /// peeks at transcript bodies via the LRU-bound `chatStores` map,
    /// which lives in `SessionsModel` and isn't a value type. Running it
    /// outside the builder keeps the builder a pure function over its
    /// inputs (testable from XCTest). The post-search session list gets
    /// its own fingerprint in the cache key, so a chat-store tick that
    /// shifts which sessions pass the filter properly invalidates the
    /// cache even though the upstream query string is identical.
    private var currentProjection: SidebarProjection {
        let sessions = model.registry.sessions
        let searchFiltered = model.filter(sessions: sessions)
        let repos = model.filteredRepos
        let now = externalActivityNow
        let ownedJSONLPaths = model.knownOwnedJSONLPaths
        let prSnapshot = workbenchState.snapshot.prCache
        let workbenchPRStateBySession: [UUID: String?] = prSnapshot.reduce(into: [:]) { acc, kv in
            acc[kv.key] = kv.value.state
        }
        // v0.29.28: pull the manually-registered workspace keys (Add Repo
        // flow) so the projection can pull those repos out of "Active
        // outside Clawdmeter" / "History" and into Managed.
        let workspaceRepoKeys: Set<String> = Set(
            model.workspaceStore.all().map { RepoIdentity.normalize($0.repoRoot) }
        )
        let key = SidebarProjectionKey(
            registryFingerprint: SidebarProjectionBuilder.registryFingerprint(sessions),
            reposFingerprint: SidebarProjectionBuilder.reposFingerprint(repos),
            workbenchPRCacheFingerprint: SidebarProjectionBuilder.workbenchPRCacheFingerprint(prSnapshot),
            searchFilteredFingerprint: SidebarProjectionBuilder.searchFilteredFingerprint(searchFiltered),
            query: model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            archiveFilter: model.showArchived,
            statusFilter: statusFilter,
            grouping: grouping,
            sorting: sorting,
            pinnedSet: presentationStore.snapshot.pinnedSessionIds,
            ownedJSONLPathsFingerprint: SidebarProjectionBuilder.ownedJSONLPathsFingerprint(ownedJSONLPaths),
            externalActivityClockBucket: SidebarProjectionBuilder.externalActivityClockBucket(now: now, repos: repos),
            workspaceRepoKeysFingerprint: SidebarProjectionBuilder.workspaceRepoKeysFingerprint(workspaceRepoKeys)
        )
        return projectionCache.value(for: key) {
            SidebarProjectionBuilder.build(
                searchFilteredSessions: searchFiltered,
                repos: repos,
                searchQuery: model.searchQuery,
                showArchived: model.showArchived,
                statusFilter: statusFilter,
                grouping: grouping,
                sorting: sorting,
                pinnedSessionIds: presentationStore.snapshot.pinnedSessionIds,
                workbenchPRStateBySession: workbenchPRStateBySession,
                ownedJSONLPaths: ownedJSONLPaths,
                workspaceRepoKeys: workspaceRepoKeys,
                now: now
            )
        }
    }

    private var filteredVisibleSessions: [AgentSession] {
        currentProjection.visibleSessions
    }

    private var reviewSessionIds: Set<UUID> {
        currentProjection.reviewSessionIds
    }

    @ViewBuilder
    private func prioritySidebarContent(_ projection: SidebarProjection) -> some View {
        if !projection.workspaceSections.isEmpty {
            priorityLabel("Managed")
            ForEach(projection.workspaceSections) { section in
                workspaceSection(section)
            }
        }
        if !projection.activeExternalSections.isEmpty {
            priorityLabel("Active outside Clawdmeter")
            ForEach(projection.activeExternalSections) { section in
                externalRepoSection(section)
            }
        }
        if !projection.historySections.isEmpty {
            historyDivider
            historyToggle(repoCount: projection.historySections.count)
            if historyExpanded {
                ForEach(projection.historySections) { section in
                    historyRepoSection(section)
                }
            }
        }
    }

    /// v0.29.33: opt-in CTA shown under "Managed" when discovery is off.
    /// Tapping flips the shared `clawdmeter.code.discoverParallelSessions`
    /// key (RepoIndex reads it via ProviderEnablement) and refreshes, so the
    /// "Active outside Clawdmeter" / "History" sections populate from
    /// ~/.claude + ~/.codex exactly like the prior behavior. The folder /
    /// cross-app prompts then fire with clear user intent, not on launch.
    private var discoverSessionsButton: some View {
        Button(action: {
            discoverParallelSessions = true   // @AppStorage writes the shared key
            Task { await model.refresh() }
        }) {
            HStack(spacing: 8) {
                TahoeIcon("search", size: 11)
                    .foregroundStyle(t.accent)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Discover parallel sessions")
                        .font(TahoeFont.body(11.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text("Find Claude & Codex sessions outside your added repos")
                        .font(TahoeFont.body(9.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .buttonStyle(.plain)
        .help("Scan ~/.claude and ~/.codex for recent sessions. Folder/data access is requested only when you tap this.")
    }

    /// Collapsed-by-default "History" row. Looks like a sidebar item so
    /// it sits cleanly at the bottom of the list; tapping toggles the
    /// `historyExpanded` AppStorage which conditionally renders the
    /// historyRepoSection list above this row.
    private func historyToggle(repoCount: Int) -> some View {
        Button(action: {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                historyExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                TahoeIcon(historyExpanded ? "chevD" : "chevR", size: 10)
                    .foregroundStyle(t.fg3)
                    .frame(width: 10)
                Text("History")
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !historyExpanded && repoCount > 0 {
                    Text("\(repoCount)")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(t.hair2, in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
        }
        .buttonStyle(.plain)
        .help(historyExpanded ? "Hide older external sessions" : "Show older external sessions")
    }

    private func priorityLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private var historyDivider: some View {
        Rectangle()
            .fill(t.hairline)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("No matching sessions")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Try a different search or status filter.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private func workspaceSection(_ section: SidebarWorkspaceSection) -> some View {
        let sectionID = "workspace:\(section.id)"
        let isExpanded = isPrioritySectionExpanded(sectionID)
        // v0.29.29: import-a-repo should be a clean slate. Earlier v0.29.28
        // rendered the repo's historical JSONLs underneath the workspace
        // header so users wouldn't lose access to past sessions; turns
        // out the user expects "import" to mean "start fresh here." Only
        // Clawdmeter-spawned `AgentSession` rows render under Managed
        // now. Historical JSONLs remain reachable from the History
        // section at the bottom of the sidebar when the user expands
        // it — but only when the repo is NOT workspace-managed
        // (managed repos skip the external/history split entirely so
        // their recents stay out of sight).
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(
                section.repo,
                isExpanded: isExpanded,
                sessionCount: section.sessions.count,
                subtitle: workspaceSubtitle(for: section.workspacePath),
                onToggle: { togglePrioritySection(sectionID) }
            )
            if isExpanded {
                ForEach(section.sessions) { session in
                    sessionRow(session, isOpen: model.openSessionId == session.id, depth: 0)
                }
            }
        }
    }

    private func externalRepoSection(_ section: SidebarExternalRepoSection) -> some View {
        let sectionID = "external:\(section.repo.key)"
        let isExpanded = isPrioritySectionExpanded(sectionID)
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(
                section.repo,
                isExpanded: isExpanded,
                sessionCount: section.recents.count,
                subtitle: "Active in the last 5 min",
                onToggle: { togglePrioritySection(sectionID) }
            )
            if isExpanded {
                ForEach(section.recents) { recent in
                    externalRecentButton(recent, repo: section.repo)
                }
            }
        }
    }

    private func historyRepoSection(_ section: SidebarHistoryRepoSection) -> some View {
        let sectionID = "history:\(section.repo.key)"
        let isExpanded = isPrioritySectionExpanded(sectionID)
        let count = section.dateGroups.reduce(0) { $0 + $1.recents.count }
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(
                section.repo,
                isExpanded: isExpanded,
                sessionCount: count,
                subtitle: "Older external sessions",
                onToggle: { togglePrioritySection(sectionID) }
            )
            if isExpanded {
                ForEach(section.dateGroups) { dateGroup in
                    Text(dateGroup.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 28)
                        .padding(.top, 5)
                    ForEach(dateGroup.recents) { recent in
                        externalRecentButton(recent, repo: section.repo)
                    }
                }
            }
        }
    }

    private func externalRecentButton(_ recent: RecentSession, repo: AgentRepo) -> some View {
        Button(action: {
            model.openOutsideSession(
                recent: recent,
                repoKey: repo.key,
                repoDisplayName: repo.displayName
            )
        }) {
            recentSessionRow(recent, isOpen: model.openOutsideJSONLPath == recent.path, repo: repo)
        }
        .buttonStyle(.plain)
    }

    private func isPrioritySectionExpanded(_ id: String) -> Bool {
        !collapsedPrioritySectionIDs.contains(id)
    }

    private func togglePrioritySection(_ id: String) {
        if collapsedPrioritySectionIDs.contains(id) {
            collapsedPrioritySectionIDs.remove(id)
        } else {
            collapsedPrioritySectionIDs.insert(id)
        }
    }

    private func workspaceSubtitle(for workspacePath: String) -> String {
        let last = (workspacePath as NSString).lastPathComponent
        return last.isEmpty ? workspacePath : "Workspace \(last)"
    }

    /// Pin-aware sort used by the legacy repo-grouped path's per-repo
    /// `repoSection(...)` lookups. The non-repo path receives this sort
    /// already applied via `currentProjection.visibleSessions`, but the
    /// repo path looks up sessions per-repo from the registry and needs
    /// to re-apply the same ordering locally.
    private func presentationSorted(_ sessions: [AgentSession]) -> [AgentSession] {
        let pins = presentationStore.snapshot.pinnedSessionIds
        return sessions.sorted { lhs, rhs in
            let lhsPin = pins.firstIndex(of: lhs.id)
            let rhsPin = pins.firstIndex(of: rhs.id)
            switch (lhsPin, rhsPin) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.lastEventAt > rhs.lastEventAt
            }
        }
    }

    /// Generic group renderer for non-Repo groupings. Header is a plain
    /// label (no expand toggle — flatter taxonomy than repos). Session
    /// rows reuse `sessionRow`; recent rows reuse `recentSessionRow`.
    @ViewBuilder
    private func groupSection(_ group: SessionSidebarGroup) -> some View {
        if group.id.hasPrefix("status:") {
            DisclosureGroup(isExpanded: statusGroupExpandedBinding(group.id)) {
                groupRows(group)
            } label: {
                statusGroupHeader(group)
            }
            .disclosureGroupStyle(QuietDisclosure())
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                plainGroupHeader(group)
                groupRows(group)
            }
        }
    }

    private func statusGroupExpandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedStatusGroupIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedStatusGroupIDs.remove(id)
                } else {
                    collapsedStatusGroupIDs.insert(id)
                }
            }
        )
    }

    private func plainGroupHeader(_ group: SessionSidebarGroup) -> some View {
        HStack(spacing: 6) {
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            let count = group.sessions.count + group.recents.count
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func statusGroupHeader(_ group: SessionSidebarGroup) -> some View {
        let count = group.sessions.count + group.recents.count
        return HStack(spacing: 6) {
            StatusPulseDot(
                color: statusGroupTint(group),
                isLive: group.id == "status:active" && count > 0
            )
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(count == 0 ? .tertiary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(count == 0 ? 0.06 : 0.12), in: Capsule())
        }
        .contentShape(Rectangle())
    }

    private func statusGroupTint(_ group: SessionSidebarGroup) -> Color {
        switch group.id {
        case "status:active": return .green
        case "status:inReview": return .orange
        case "status:done": return terraCotta
        case "status:archived": return .secondary
        default: return .secondary
        }
    }

    @ViewBuilder
    private func groupRows(_ group: SessionSidebarGroup) -> some View {
        ForEach(group.sessions) { s in
            sessionRow(s, isOpen: model.openSessionId == s.id, depth: 0)
        }
        ForEach(group.recents) { recent in
            Button(action: {
                // Resolve the repo display name from the recent's path.
                let repo = model.repos.first(where: { $0.recentSessions.contains(recent) })
                model.openOutsideSession(
                    recent: recent,
                    repoKey: repo?.key ?? recent.path,
                    repoDisplayName: repo?.displayName ?? "Recent"
                )
            }) {
                // Non-Repo grouping (Date / Status / Agent / None):
                // no repo section header above this row, so surface
                // the repo as an inline chip in the subtitle.
                recentSessionRow(
                    recent,
                    isOpen: model.openOutsideJSONLPath == recent.path,
                    repo: model.repos.first(where: { $0.recentSessions.contains(recent) })
                        ?? AgentRepo(key: recent.path, displayName: "Recent", hasActiveSessions: false),
                    showRepoChip: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func repoSection(_ repo: AgentRepo, keyAliases: [String: String] = [:]) -> some View {
        let allSessions = model.registry.sessions.filter { session in
            guard let key = session.repoKey else { return false }
            guard (keyAliases[key] ?? key) == repo.key else { return false }
            if !model.showArchived, session.archivedAt != nil { return false }
            return true
        }
        let visibleSessions = presentationSorted(model.filter(sessions: allSessions).filter(sidebarStatusPasses))
        let rootSessions = visibleSessions.filter { $0.parentSessionId == nil }
        let isExpanded = model.expandedRepoKeys.contains(repo.key)
        let recentSessions = repo.recentSessions
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(repo, isExpanded: isExpanded, sessionCount: visibleSessions.count + recentSessions.count)
            if isExpanded {
                ForEach(rootSessions) { root in
                    sessionTree(root: root, depth: 0)
                }
                if !recentSessions.isEmpty {
                    Text("Recent (last 30 days)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 24)
                        .padding(.top, 4)
                    ForEach(recentSessions) { recent in
                        Button(action: {
                            model.openOutsideSession(
                                recent: recent,
                                repoKey: repo.key,
                                repoDisplayName: repo.displayName
                            )
                        }) {
                            recentSessionRow(recent, isOpen: model.openOutsideJSONLPath == recent.path, repo: repo)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if visibleSessions.isEmpty && recentSessions.isEmpty {
                    Button(action: {
                        model.quickSpawnInRepo(repo.key)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                            Text("Start a session here")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sidebarStatusPasses(_ session: AgentSession) -> Bool {
        switch statusFilter {
        case .all:
            return true
        case .active:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds) == .active
        case .inReview:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds) == .inReview
        case .done:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds) == .done
        case .archived:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds) == .archived
        }
    }

    /// One row per JSONL surfaced from `repo.recentSessions` — these were
    /// not spawned by Clawdmeter (Conductor / Cursor / Terminal). Click
    /// promotes them via `Continue here`. v0.4.6: matches the iOS row
    /// treatment — provider badge on the leading edge, color-tinted
    /// provider name in the subtitle, optional repo chip (for the
    /// non-Repo groupings where the row has no repo section header
    /// above it), green ring around the badge when the JSONL was
    /// touched in the last 5 minutes. The "Read-only" copy and eye
    /// icon are gone — v0.4.1 made the row continuable from the
    /// composer so calling it read-only was misleading.
    private func recentSessionRow(_ recent: RecentSession, isOpen: Bool, repo: AgentRepo, showRepoChip: Bool = false) -> some View {
        let isHovered = hoveredRecentPath == recent.path
        return HStack(alignment: .top, spacing: 8) {
            providerBadge(for: recent)
            VStack(alignment: .leading, spacing: 2) {
                Text(recentTitle(recent))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                recentSubtitleRow(recent: recent, repo: repo, showRepoChip: showRepoChip)
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(
            isOpen
                ? terraCotta.opacity(0.15)
                : (isHovered ? t.hair2.opacity(colorScheme == .dark ? 1.0 : 1.35) : Color.clear),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(isOpen ? terraCotta.opacity(0.35) : (isHovered ? t.hairline : .clear), lineWidth: 0.5)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredRecentPath = recent.path
            } else if hoveredRecentPath == recent.path {
                hoveredRecentPath = nil
            }
        }
        .help(recent.path)
        .contextMenu {
            Button("Continue here", systemImage: "play.fill") {
                Task { _ = await model.continueOutsideSession(recent: recent, repoKey: repo.key, repoDisplayName: repo.displayName) }
            }
            Button("Rename…", systemImage: "pencil") {
                renameJSONLTarget = recent
                renameJSONLInput = recent.customName ?? ""
                showingRenameJSONLAlert = true
            }
        }
    }

    /// 20pt circular provider badge with a tinted background, the
    /// shared `ProviderBadgeImage` glyph, and a green ring overlay when
    /// the JSONL is currently active.
    @ViewBuilder
    private func providerBadge(for recent: RecentSession) -> some View {
        let isLive = isRecentLive(recent)
        let rgb = AgentKindUI.accentRGB(for: recent.provider)
        let accent = Color(red: Double(rgb.r)/255, green: Double(rgb.g)/255, blue: Double(rgb.b)/255)
        ZStack {
            Circle()
                .fill(recent.provider == .claude
                      ? accent.opacity(0.18)
                      : Color.secondary.opacity(0.20))
                .frame(width: 20, height: 20)
            ProviderBadgeImage(
                assetName: AgentKindUI.assetName(for: recent.provider),
                isTemplate: AgentKindUI.isTemplate(for: recent.provider),
                size: 12
            )
            .foregroundStyle(recent.provider == .claude ? accent : .primary)
            if isLive {
                Circle()
                    .stroke(Color.green, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
            }
        }
    }

    /// Subtitle: color-tinted provider name · optional repo chip ·
    /// relative time · green `Now` capsule when live. Drops the
    /// `read-only` suffix that used to live here.
    @ViewBuilder
    private func recentSubtitleRow(recent: RecentSession, repo: AgentRepo, showRepoChip: Bool) -> some View {
        let providerName = AgentKindUI.displayName(for: recent.provider)
        let rgb = AgentKindUI.accentRGB(for: recent.provider)
        let providerColor: Color = recent.provider == .claude
            ? terraCotta
            : Color(red: Double(rgb.r)/255, green: Double(rgb.g)/255, blue: Double(rgb.b)/255)
        let rel = Self.relativeTimestampFormatter.localizedString(
            for: recent.lastModified, relativeTo: Date()
        )
        HStack(spacing: 4) {
            Text(providerName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(providerColor)
            if showRepoChip {
                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                HStack(spacing: 2) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(repo.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(rel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if isRecentLive(recent) {
                Text("Now")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.16), in: Capsule())
            }
        }
        .lineLimit(1)
    }

    private func isRecentLive(_ recent: RecentSession) -> Bool {
        Date().timeIntervalSince(recent.lastModified) < 5 * 60
    }

    private func recentTitle(_ recent: RecentSession) -> String {
        // v0.5.10 — user-supplied alias wins. Always.
        if let custom = recent.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        // Prefer the first user prompt — that's what the session was for.
        // Fall back to the generic label when we couldn't extract one
        // (empty JSONL, unparseable, all system meta).
        if let prompt = recent.firstPrompt, !prompt.isEmpty {
            return prompt
        }
        return "\(AgentKindUI.displayName(for: recent.provider)) session"
    }

    private static let relativeTimestampFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// G17: render a session row + its children indented underneath.
    /// Iterative (not recursive) so SwiftUI's opaque return type doesn't
    /// hit the self-defining-`some View` ban.
    private func sessionTree(root: AgentSession, depth: Int) -> some View {
        // Flatten the subtree depth-first into (session, depth) pairs.
        var flat: [(AgentSession, Int)] = []
        var stack: [(AgentSession, Int)] = [(root, depth)]
        var seen: Set<UUID> = []
        while let (s, d) = stack.popLast() {
            guard !seen.contains(s.id) else { continue }
            seen.insert(s.id)
            flat.append((s, d))
            // Push children in reverse so the leftmost child ends up first.
            for child in model.children(of: s.id).reversed() {
                stack.append((child, d + 1))
            }
        }
        return ForEach(Array(flat.enumerated()), id: \.element.0.id) { _, pair in
            let (s, d) = pair
            sessionRow(s, isOpen: model.openSessionId == s.id, depth: d)
        }
    }

    private func repoHeader(
        _ repo: AgentRepo,
        isExpanded: Bool,
        sessionCount: Int,
        subtitle: String? = nil,
        onToggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    TahoeIcon(isExpanded ? "chevD" : "chevR", size: 10)
                        .foregroundStyle(t.fg3)
                        .frame(width: 10)
                    projectGlyph(repo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repo.displayName)
                            .font(TahoeFont.body(13, weight: .semibold))
                            .foregroundStyle(t.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(TahoeFont.body(10))
                                .foregroundStyle(t.fg3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if sessionCount > 0 {
                Text("\(sessionCount)")
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(t.hair2, in: Capsule())
            }
            if repo.liveSessionCount > 0 {
                HStack(spacing: 2) {
                    Circle().fill(.green).frame(width: 4, height: 4)
                    Text("\(repo.liveSessionCount)")
                        .font(TahoeFont.body(9, weight: .bold))
                        .foregroundStyle(.green)
                }
                .help("\(repo.liveSessionCount) live JSONL — Conductor / Cursor / Terminal-launched agents writing now.")
            }
            Button {
                model.quickSpawnInRepo(repo.key)
            } label: {
                TahoeIcon("plus", size: 11, weight: .bold)
                    .foregroundStyle(t.fg3)
                    .frame(width: 22, height: 22)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("New workspace — Codex · gpt-5.5 · max effort · plan mode (option-click to customize)")
            // Option/Alt-click escape hatch: power users who want to
            // pick a different agent/model/effort/path get the full
            // sheet by holding Option while clicking the "+".
            .simultaneousGesture(TapGesture().modifiers(.option).onEnded {
                model.prepareNewSession(in: repo.key)
            })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, subtitle == nil ? 6 : 5)
    }

    private func repoHeader(_ repo: AgentRepo, isExpanded: Bool, sessionCount: Int) -> some View {
        repoHeader(
            repo,
            isExpanded: isExpanded,
            sessionCount: sessionCount,
            onToggle: {
                if isExpanded { model.expandedRepoKeys.remove(repo.key) }
                else { model.expandedRepoKeys.insert(repo.key) }
            }
        )
    }

    private func projectGlyph(_ repo: AgentRepo) -> some View {
        let hueSeed = repo.key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let hue = Double(hueSeed % 360) / 360.0
        let tint = Color(hue: hue, saturation: 0.52, brightness: colorScheme == .dark ? 0.86 : 0.78)
        let initial = repo.displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)?.uppercased() ?? "*"
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(colorScheme == .dark ? 0.28 : 0.20))
            .overlay(
                Text(initial)
                    .font(TahoeFont.body(10, weight: .bold))
                    .foregroundStyle(tint)
            )
            .frame(width: 22, height: 22)
    }

    private func sessionRow(_ session: AgentSession, isOpen: Bool, depth: Int = 0) -> some View {
        let isHovered = hoveredSessionId == session.id
        let isPinned = presentationStore.snapshot.pinnedSessionIds.contains(session.id)
        let isUnread = presentationStore.snapshot.unreadSessionIds.contains(session.id)
        let isMuted = presentationStore.snapshot.mutedSessionIds.contains(session.id)
        let tag = presentationStore.snapshot.colorTags[session.id]
        let reasons = attentionReasons(for: session)
        let repoBadge = repoIdentityBadge(for: session)
        return Button(action: {
            model.openSession(session)
            try? presentationStore.markUnread(session.id, unread: false)
        }) {
            HStack(alignment: .top, spacing: 8) {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(depth - 1) * 12)
                }
                RepoIdentityBadgeView(badge: repoBadge, size: 22)
                    .overlay(alignment: .bottomTrailing) {
                        TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 11)
                            .padding(2)
                            .background(.regularMaterial, in: Circle())
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(statusColor(session.status))
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: 3)
                            .shadow(color: session.status == .running ? statusColor(session.status).opacity(0.75) : .clear, radius: 4)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionTitle(session))
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor(session.status))
                            .frame(width: 5, height: 5)
                        Text(sessionSubtitle(session))
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                        if let tag, !tag.isEmpty {
                            Text(tag)
                                .font(TahoeFont.body(9.5, weight: .semibold))
                                .foregroundStyle(colorTagTint(tag))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(colorTagTint(tag).opacity(0.14), in: Capsule())
                        }
                    }
                    // Daemon-computed "progress vs approved plan" bar.
                    // Appears only when the session has an approved plan
                    // AND the daemon has produced its first compute (see
                    // `PlanProgressTracker`). The fraction comes straight
                    // from the wire field, so iOS and Mac sidebars agree.
                    //
                    // Uses `TahoePillBar` (not native ProgressView) so the
                    // bar inherits provider-tinted gradient + halo shadow
                    // and matches the rest of the Tahoe bar fleet.
                    // Font and 32pt min-width on the count match the row's
                    // subtitle typography so the bar doesn't break density.
                    if let progress = session.planProgress {
                        // Defensive clamp: the daemon enforces completed ≤ total,
                        // but a future schema bump or a race could violate it. We
                        // clamp here rather than render "7/6" to the sidebar.
                        let safeCompleted = max(0, min(progress.completed, progress.total))
                        let isComplete = safeCompleted >= progress.total && progress.total > 0
                        let provider = session.agent.tahoeProvider
                        // Use provider.halo (the same color the bar gradient
                        // anchors on) so the milestone state stays inside the
                        // bar's two-color vocabulary and reads correctly in
                        // dark mode (provider.deep collapses to near-black for
                        // Codex/Cursor, which is invisible against dark popovers).
                        let completeTint = provider.halo.color
                        HStack(spacing: 6) {
                            TahoePillBar(
                                percent: Double(safeCompleted) /
                                          max(1, Double(progress.total)) * 100,
                                provider: provider,
                                height: 6
                            )
                            .frame(maxWidth: .infinity)
                            if isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(completeTint)
                                    .padding(.leading, 2)
                                    .transition(.scale.combined(with: .opacity))
                                    .accessibilityHidden(true)
                            }
                            Text("\(safeCompleted)/\(progress.total)")
                                .font(TahoeFont.body(10.5, weight: isComplete ? .bold : .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isComplete ? completeTint : t.fg2)
                                .frame(minWidth: 44, alignment: .trailing)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                        }
                        .padding(.top, 4)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: isComplete)
                        .help(isComplete
                              ? "Plan complete — \(safeCompleted) of \(progress.total) steps"
                              : "Plan progress — \(safeCompleted) of \(progress.total) steps complete")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Plan progress")
                        .accessibilityValue("\(safeCompleted) of \(progress.total) steps complete")
                        .accessibilityHint(isComplete ? "Plan complete" : "")
                    }
                }
                Spacer()
                if isHovered {
                    SessionHoverActions(
                        isPinned: isPinned,
                        isMuted: isMuted,
                        onPin: { try? presentationStore.togglePin(session.id) },
                        onMute: { try? presentationStore.setMuted(session.id, muted: !isMuted) },
                        onArchive: {
                            // F2-wire: registry mutation is now async
                            // throws. SwiftUI button closures are sync,
                            // so wrap in Task. Best-effort — failures
                            // surface as a missed archive (the row
                            // stays in the sidebar; user can retry).
                            Task { @MainActor in
                                try? await model.registry.archive(id: session.id)
                            }
                            postArchiveUndoToast(for: session)
                        }
                    )
                }
                if isUnread {
                    Circle()
                        .fill(t.accent)
                        .frame(width: 7, height: 7)
                        .help("Unread")
                        .accessibilityLabel("Unread")
                }
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(t.accent)
                        .help("Pinned")
                        .accessibilityLabel("Pinned")
                }
                if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Muted")
                        .accessibilityLabel("Muted")
                }
                ForEach(reasons.prefix(2), id: \.self) { reason in
                    AttentionBadge(reason: reason)
                }
                if session.archivedAt != nil {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Archived")
                        .accessibilityLabel("Archived")
                }
                if session.planText != nil {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(terraCotta)
                        .help("Plan approval pending")
                        .accessibilityLabel("Plan approval pending")
                }
                if model.chatStore(for: session)?.pendingPermissionPrompt != nil {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("User input required")
                        .accessibilityLabel("User input required")
                }
                let queued = workbenchState.queuedSendCount(for: session.id)
                if queued > 0 {
                    Text("\(queued)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(terraCotta, in: Capsule())
                        .help("\(queued) queued follow-up\(queued == 1 ? "" : "s")")
                }
            }
            .padding(.leading, 24 + CGFloat(depth) * 6)
            .padding(.trailing, 24)
            .padding(.vertical, 7)
            .background(isOpen
                ? t.accentAlpha(colorScheme == .dark ? 0.18 : 0.12)
                : (isHovered ? t.hair2.opacity(colorScheme == .dark ? 1.0 : 1.35) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isOpen ? t.accentAlpha(0.35) : (isHovered ? t.hairline : .clear), lineWidth: 0.5)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredSessionId = session.id
            } else if hoveredSessionId == session.id {
                hoveredSessionId = nil
            }
        }
        .opacity(session.archivedAt != nil ? 0.6 : 1.0)
        .animation(.easeOut(duration: 0.18), value: session.status)
        .help(hoverHelp(for: session, reasons: reasons))
        .contextMenu {
            sessionContextMenu(session)
        }
        .onAppear {
            resolveRepoIdentityIfNeeded(for: session)
        }
    }

    private func repoIdentityBadge(for session: AgentSession) -> RepoIdentityBadge {
        let key = repoIdentityKey(for: session)
        if let cached = presentationStore.snapshot.repoIdentityBadges[key] {
            return cached
        }
        return RepoIdentityResolver.badge(repoKey: key, displayName: session.repoDisplayName)
    }

    private func repoIdentityKey(for session: AgentSession) -> String {
        session.repoKey ?? session.runtimeCwd ?? session.worktreePath ?? session.repoDisplayName
    }

    private func resolveRepoIdentityIfNeeded(for session: AgentSession) {
        let key = repoIdentityKey(for: session)
        guard presentationStore.snapshot.repoIdentityBadges[key]?.remoteSlug == nil else { return }
        guard !requestedRepoIdentityKeys.contains(key) else { return }
        requestedRepoIdentityKeys.insert(key)

        let displayName = session.repoDisplayName
        let candidateRoots = remoteOriginCandidateRoots(for: session)
        let store = presentationStore
        Task.detached(priority: .utility) {
            guard let remoteURL = Self.gitRemoteOriginURL(candidateRoots: candidateRoots) else { return }
            let badge = RepoIdentityResolver.badge(
                repoKey: key,
                displayName: displayName,
                remoteURL: remoteURL
            )
            await MainActor.run {
                try? store.cacheRepoIdentity(badge)
            }
        }
    }

    private func remoteOriginCandidateRoots(for session: AgentSession) -> [String] {
        var roots: [String] = []
        var seen = Set<String>()
        for raw in [session.effectiveCwd, session.worktreePath, session.runtimeCwd, session.repoKey] {
            guard let root = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { continue }
            let expanded = NSString(string: root).expandingTildeInPath
            guard !seen.contains(expanded) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            seen.insert(expanded)
            roots.append(expanded)
        }
        return roots
    }

    private nonisolated static func gitRemoteOriginURL(candidateRoots: [String]) -> String? {
        for repoRoot in candidateRoots {
            if let remote = gitRemoteOriginURL(repoRoot: repoRoot) {
                return remote
            }
        }
        return nil
    }

    private nonisolated static func gitRemoteOriginURL(repoRoot: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", NSString(string: repoRoot).expandingTildeInPath, "config", "--get", "remote.origin.url"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        } catch {
            return nil
        }
    }

    @ViewBuilder
    private func sessionContextMenu(_ session: AgentSession) -> some View {
        let isPinned = presentationStore.snapshot.pinnedSessionIds.contains(session.id)
        let isUnread = presentationStore.snapshot.unreadSessionIds.contains(session.id)
        let isMuted = presentationStore.snapshot.mutedSessionIds.contains(session.id)
        Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin.fill") {
            try? presentationStore.togglePin(session.id)
        }
        if isPinned {
            Button("Move Pin Up", systemImage: "arrow.up") {
                try? presentationStore.movePinnedSession(session.id, offset: -1)
            }
            Button("Move Pin Down", systemImage: "arrow.down") {
                try? presentationStore.movePinnedSession(session.id, offset: 1)
            }
        }
        Button(isUnread ? "Mark Read" : "Mark Unread", systemImage: isUnread ? "circle" : "circle.fill") {
            try? presentationStore.markUnread(session.id, unread: !isUnread)
        }
        Button(isMuted ? "Unmute Session" : "Mute Session", systemImage: isMuted ? "bell" : "bell.slash") {
            try? presentationStore.setMuted(session.id, muted: !isMuted)
        }
        Menu("Snooze", systemImage: "moon.zzz") {
            Button("1 hour") { try? presentationStore.snooze(session.id, until: Date().addingTimeInterval(60 * 60)) }
            Button("Today") { try? presentationStore.snooze(session.id, until: Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)) }
            Button("Clear Snooze") { try? presentationStore.snooze(session.id, until: nil) }
        }
        Button("Color Tag…", systemImage: "tag") {
            colorTagTarget = session
            colorTagInput = presentationStore.snapshot.colorTags[session.id] ?? ""
            showingColorTagAlert = true
        }
        Divider()
        Button("Pop out", systemImage: "rectangle.portrait.on.rectangle.portrait") {
            NotificationCenter.default.post(
                name: .popOutSession,
                object: nil,
                userInfo: ["sessionId": session.id]
            )
        }
        Button("Compare with Open Session", systemImage: "rectangle.split.2x1") {
            if let open = model.openSession, open.id != session.id {
                comparisonPair = SessionComparisonPair(left: open, right: session)
            }
        }
        .disabled(model.openSession == nil || model.openSession?.id == session.id)
        Button("Copy session ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.id.uuidString, forType: .string)
        }
        Button("Reveal JSONL in Finder", systemImage: "doc.text.magnifyingglass") {
            if let url = model.chatStore(for: session)?.currentFileURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .disabled(model.chatStore(for: session)?.currentFileURL == nil)
        if let raw = session.prMirrorState?.prURL, let url = URL(string: raw) {
            Button("Open Pull Request", systemImage: "arrow.up.right.square") {
                NSWorkspace.shared.open(url)
            }
        }
        Divider()
        Button("Rename…", systemImage: "pencil") {
            renameTarget = session
            renameInput = session.customName ?? presentationStore.snapshot.titleOverrides[session.id] ?? ""
            showingRenameAlert = true
        }
        if session.archivedAt == nil {
            Button("Archive", systemImage: "archivebox") {
                Task { @MainActor in
                    try? await model.registry.archive(id: session.id)
                }
                postArchiveUndoToast(for: session)
            }
        } else {
            Button("Unarchive", systemImage: "archivebox.fill") {
                Task { @MainActor in
                    try? await model.registry.unarchive(id: session.id)
                }
            }
        }
        Button("New sub-chat (⌘;)", systemImage: "bubble.left.and.bubble.right") {
            Task { _ = await model.spawnSubchat(parentId: session.id) }
        }
        Divider()
        Button("End session", role: .destructive) {
            Task { await model.endSession(id: session.id) }
        }
    }

    private func attentionReasons(for session: AgentSession) -> [AttentionReason] {
        AttentionReasonResolver.reasons(
            for: session,
            unread: presentationStore.snapshot.unreadSessionIds.contains(session.id),
            outboxPending: workbenchState.queuedSendCount(for: session.id) > 0,
            providerBlocked: model.chatStore(for: session)?.pendingPermissionPrompt != nil,
            snoozedUntil: presentationStore.snapshot.snoozedUntil[session.id]
        )
    }

    private func hoverHelp(for session: AgentSession, reasons: [AttentionReason]) -> String {
        var rows = [
            sessionTitle(session),
            "\(session.repoDisplayName) · \(session.agent.rawValue.capitalized) · \(session.status.rawValue)",
            "Updated \(session.lastEventAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        if !reasons.isEmpty {
            rows.append("Attention: \(reasons.map(\.label).joined(separator: ", "))")
        }
        if let tag = presentationStore.snapshot.colorTags[session.id], !tag.isEmpty {
            rows.append("Tag: \(tag)")
        }
        return rows.joined(separator: "\n")
    }

    private func colorTagTint(_ tag: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, terraCotta]
        let seed = tag.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) }
        return palette[abs(seed) % palette.count]
    }

    private func sessionTitle(_ session: AgentSession) -> String {
        if let custom = session.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let title = presentationStore.snapshot.titleOverrides[session.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let goal = Self.cleanSidebarTitle(session.goal) { return goal }
        if let branch = branchLikeTitle(for: session) { return branch }
        if let summary = latestAssistantSummary(for: session) { return summary }
        return "\(session.agent.rawValue.capitalized) · \(session.status.rawValue)"
    }

    private func commitSessionRename(_ session: AgentSession, name: String?) {
        let sessionID = session.id
        Task { @MainActor in
            _ = await model.renameSession(id: sessionID, name: name)
            // Older builds wrote Rename into the client-local presentation store.
            // Clear that shadow value so the registry-backed customName drives all
            // surfaces after this edit.
            if presentationStore.snapshot.titleOverrides[sessionID] != nil {
                try? presentationStore.setTitleOverride(sessionID, title: nil)
            }
            resetSessionRenameState()
        }
    }

    private func resetSessionRenameState() {
        showingRenameAlert = false
        renameTarget = nil
        renameInput = ""
    }

    private func latestAssistantSummary(for session: AgentSession) -> String? {
        guard let store = model.chatStore(for: session) else { return nil }
        for message in store.snapshot.messages.reversed() where message.kind == .assistantText {
            if let title = Self.cleanSidebarTitle(message.body) {
                return title
            }
        }
        return nil
    }

    private func branchLikeTitle(for session: AgentSession) -> String? {
        for raw in [session.worktreePath, session.runtimeCwd] {
            guard let raw, let title = Self.branchLikeTitle(fromPath: raw, repoDisplayName: session.repoDisplayName) else {
                continue
            }
            return title
        }
        return nil
    }

    private static func branchLikeTitle(fromPath path: String, repoDisplayName: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, last != "/", last != repoDisplayName else { return nil }
        let lower = last.lowercased()
        if path.contains("/.claude/worktrees/") || path.contains("/.git/worktrees/") {
            return last
        }
        if lower.contains("-") || lower.contains("_") || lower.contains("/") {
            return last
        }
        return nil
    }

    private static func cleanSidebarTitle(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if let citationRange = text.range(of: "<oai-mem-citation>") {
            text.removeSubrange(citationRange.lowerBound..<text.endIndex)
        }
        text = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'")))
        guard !text.isEmpty else { return nil }
        if text.count > 96 {
            let idx = text.index(text.startIndex, offsetBy: 96)
            text = String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }

    private func sessionSubtitle(_ session: AgentSession) -> String {
        var bits: [String] = []
        bits.append(session.agent.rawValue.capitalized)
        bits.append(session.mode.rawValue.capitalized)
        bits.append(session.status.rawValue)
        return bits.joined(separator: " · ")
    }

    private func statusColor(_ status: AgentSessionStatus) -> Color {
        switch status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return terraCotta
        case .degraded: return .secondary
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No repos yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Run Claude / Codex in a repo and it'll appear here.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        Button(action: { model.prepareNewSession(in: nil) }) {
            HStack(spacing: 6) {
                TahoeIcon("plus", size: 12, weight: .bold)
                Text("New session")
                    .font(TahoeFont.body(12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom),
                in: Capsule(style: .continuous)
            )
            .overlay(Capsule(style: .continuous).stroke(t.accentDeepC, lineWidth: 0.5))
            .shadow(color: t.accentDeep.color(opacity: 0.25), radius: 8, x: 0, y: 5)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: [.command])
        .padding(10)
    }

    private var sidebarBg: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.94, green: 0.94, blue: 0.94)
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}

// `SessionComparisonPair` + `SessionComparisonSheet` live in
// `SessionComparisonSheet.swift` (A6 foundation extraction).
//
// `StatusPulseDot` + `AttentionBadge` + `SessionHoverActions` +
// `ConnectingTranscriptState` live in `SessionStatusBadges.swift`
// (A6 foundation extraction).
//
// `WorkspaceSwitcherSheet` lives in `WorkspaceSwitcherSheet.swift`
// (A6 foundation extraction).

// MARK: - Center thread

private struct CenterThread: View {
    let session: AgentSession
    let isReadOnly: Bool
    @ObservedObject var model: SessionsModel
    let catalog: ModelCatalog
    @ObservedObject var workbenchState: WorkbenchState
    @ObservedObject var presentationStore: SessionPresentationStore
    let density: TranscriptDensity
    let onDensityChange: (TranscriptDensity) -> Void
    let onModeSwitch: (SessionMode) -> Void

    @StateObject private var composerStore: ComposerStore
    /// PR mirror for the open session — drives the header branch chip's
    /// color (open/merged/closed). Synthetic read-only sessions get a
    /// mirror too; it just never resolves a PR URL.
    @ObservedObject private var prMirror: PRMirror
    /// Observed so the permission-mode chip re-renders when the user
    /// flips bypass or accept-edits from another surface. AutopilotState
    /// is a singleton without ObservableObject conformance; all autopilot
    /// flips go through `PermissionModeStore.setBypass` below so this one
    /// observer is enough.
    @ObservedObject private var permissionModeStore = PermissionModeStore.shared
    @State private var showingScheduler = false
    @State private var showingTerminalOverlay = false
    @State private var showingAutopilotConfirm = false
    @State private var isDispatchingQueuedSend = false
    @State private var dispatchedQueuedTurnForCurrentIdle = false
    @State private var checkpointStatusText: String?
    @State private var restorePlan: CheckpointRestorePlan?
    @State private var isPreparingCheckpointRestore = false
    @State private var isRestoringCheckpoint = false
    /// Captured target mode for the bypass-mode trust-grant confirm sheet.
    /// When the user picks `.bypass` from the chip we stash it here and
    /// surface the existing autopilot confirm sheet, then commit on
    /// approval.
    @State private var pendingBypassMode = false

    init(
        session: AgentSession,
        isReadOnly: Bool,
        model: SessionsModel,
        catalog: ModelCatalog,
        workbenchState: WorkbenchState,
        presentationStore: SessionPresentationStore,
        density: TranscriptDensity,
        onDensityChange: @escaping (TranscriptDensity) -> Void,
        onModeSwitch: @escaping (SessionMode) -> Void
    ) {
        self.session = session
        self.isReadOnly = isReadOnly
        self.model = model
        self.catalog = catalog
        self.workbenchState = workbenchState
        self.presentationStore = presentationStore
        self.density = density
        self.onDensityChange = onDensityChange
        self.onModeSwitch = onModeSwitch
        let store = ComposerStore(mode: .bound(sessionId: session.id))
        let resolvedModel = Self.effectiveModelId(for: session, catalog: catalog)
        store.modelId = resolvedModel
        store.effort = Self.effectiveEffort(for: session, modelId: resolvedModel, catalog: catalog)
        store.mode = session.mode
        store.agent = session.agent
        store.planMode = session.status == .planning
        store.repoKey = session.repoKey
        store.autopilotEnabled = AutopilotState.shared.isEnabled(sessionId: session.id)
        _composerStore = StateObject(wrappedValue: store)
        _prMirror = ObservedObject(wrappedValue: model.prMirror(for: session))
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 0) {
            if let workspaceKey = WorkspaceKey.of(session) {
                WorkspaceTabStrip(
                    model: model,
                    workspaceKey: workspaceKey,
                    activeSession: session,
                    activeSessionId: session.id,
                    draftTab: model.draftWorkspaceTab,
                    terminalTabs: model.workspaceTerminalTabs(in: workspaceKey),
                    activeTerminalTabId: nil,
                    documentTabs: model.workspaceDocumentTabs(in: workspaceKey),
                    activeDocumentTabId: model.selectedWorkspaceDocumentTab?.id,
                    terminalAvailable: model.canOpenWorkspaceTerminalTab(from: session),
                    onNewChat: {
                        model.openDraftWorkspaceTab(from: session, defaults: workspaceDraftDefaults)
                    },
                    onNewTerminal: {
                        Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
                    },
                    onSelectTerminal: { model.selectWorkspaceTerminalTab($0) },
                    onCloseTerminal: { terminalTab in
                        Task { await model.closeWorkspaceTerminalTab(terminalTab) }
                    },
                    onSelectDocument: { model.selectWorkspaceDocumentTab($0) },
                    onCloseDocument: { model.closeWorkspaceDocumentTab($0) }
                )
            }
            header
            Divider()
            chatPane
        }
        .onAppear {
            applyPendingFirstSendRecovery()
        }
        .onChange(of: model.pendingFirstSendRecoveryVersion) { _, _ in
            applyPendingFirstSendRecovery()
        }
        .sheet(isPresented: $showingScheduler) {
            FollowUpSchedulerSheet(session: session, registry: model.registry)
        }
        .sheet(isPresented: $showingTerminalOverlay) {
            terminalOverlay
        }
        .sheet(isPresented: $showingAutopilotConfirm) {
            autopilotConfirm
        }
        .sheet(item: $restorePlan) { plan in
            CheckpointRestoreSheet(
                plan: plan,
                isRestoring: isRestoringCheckpoint,
                onCancel: { restorePlan = nil },
                onRestore: { Task { await restoreCheckpoint(plan) } }
            )
        }
        .onChange(of: session.status) { _, newValue in
            if newValue == .running {
                dispatchedQueuedTurnForCurrentIdle = false
            }
        }
        .task(id: queueDrainKey) {
            await drainQueuedSendsIfPossible()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                // v0.5.4: user-supplied customName takes precedence
                // over the session's goal in the chat header.
                Text(headerLabel(for: session))
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(sessionConfigurationSummary)
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                    if let checkpointStatusText {
                        Text("· \(checkpointStatusText)")
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if let branch = branchLabel {
                TahoePill(tone: .chip) {
                    HStack(spacing: 5) {
                        Image(systemName: prBranchIcon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(branch)
                            .font(TahoeFont.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(prBranchColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                }
                .frame(maxWidth: 190)
                .help(branchTooltip)
            }
            // v0.29.25: header `⚡ ask` permission-mode pill removed per
            // user feedback. The composer's `PermissionModeChip` already
            // sits to the right of the model+effort chip and exposes the
            // same `ask / accept edits / plan / bypass` Menu plus the
            // ⇧⌘1-4 shortcuts — so the header copy was just a duplicate
            // floating to the right of the branch chip. Keeping the
            // composer pill keeps mode-selection adjacent to where the
            // user is about to type, which is the better mental model.
            // v0.5.2: the prominent "Read-only" pill was dropped per user
            // feedback — the composer's "Continue here" placeholder + the
            // disabled-action menu state already signal read-only mode.
            // Carrying a third badge in the header for the same fact
            // doubled the visual noise.
            if isReadOnly {
                EmptyView()
            } else {
                Menu {
                    ForEach(TranscriptDensity.allCases, id: \.self) { option in
                        Button {
                            onDensityChange(option)
                        } label: {
                            if option == density {
                                Label(densityLabel(option), systemImage: "checkmark")
                            } else {
                                Text(densityLabel(option))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .help("Transcript density")
                .accessibilityLabel("Transcript density")
                Menu {
                    Button("Open terminal tab (⇧⌘T)") {
                        Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
                    }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                        .disabled(!model.canOpenWorkspaceTerminalTab(from: session))
                    Button("Schedule follow-up…", systemImage: "clock") {
                        showingScheduler = true
                    }
                    Button("Create checkpoint", systemImage: "bookmark") {
                        Task { await createCheckpoint() }
                    }
                    if let latest = workbenchState.latestCheckpoint(for: session.id) {
                        Button("Restore latest checkpoint…", systemImage: "arrow.uturn.backward") {
                            Task { await prepareCheckpointRestore(latest) }
                        }
                    }
                    Button("Pop out window", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                        NotificationCenter.default.post(
                            name: .popOutSession,
                            object: nil,
                            userInfo: ["sessionId": session.id]
                        )
                    }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    Divider()
                    if session.archivedAt == nil {
                        Button("Archive") {
                            Task { @MainActor in
                                try? await model.registry.archive(id: session.id)
                            }
                            postArchiveUndoToast(for: session)
                            workbenchState.clearSessionState(sessionId: session.id)
                            AttachmentStaging.cleanup(sessionId: session.id)
                            if let wt = session.worktreePath {
                                AttachmentStaging.cleanupWorktree(at: wt, sessionId: session.id)
                            }
                        }
                    }
                    Button("End session", role: .destructive) {
                        Task {
                            await model.endSession(id: session.id)
                            workbenchState.clearSessionState(sessionId: session.id)
                            AttachmentStaging.cleanup(sessionId: session.id)
                            if let wt = session.worktreePath {
                                AttachmentStaging.cleanupWorktree(at: wt, sessionId: session.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .accessibilityLabel("More actions")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // v0.29.25: `permissionModeLabel` + `headerPermissionModes` deleted
    // alongside the redundant header pill. Composer's `PermissionModeChip`
    // owns mode-selection now.

    private var workspaceDraftDefaults: ComposerStore.ChipDefaults {
        ComposerStore.ChipDefaults(
            agent: session.agent,
            modelId: session.model ?? Self.effectiveModelId(for: session, catalog: catalog),
            effort: session.effort ?? Self.effectiveEffort(
                for: session,
                modelId: session.model ?? Self.effectiveModelId(for: session, catalog: catalog),
                catalog: catalog
            ),
            mode: session.mode,
            planMode: false
        )
    }

    private func densityLabel(_ density: TranscriptDensity) -> String {
        switch density {
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }

    /// v0.5.4 header-label helper. User-set `customName` wins over the
    /// session's goal, with the repo name as the final fallback. Mirrors
    /// `AgentSession.displayLabel` but keeps the existing "goal" tier
    /// because the chat header has historically preferred the user-typed
    /// prompt as a label.
    private func headerLabel(for session: AgentSession) -> String {
        if let custom = session.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let goal = session.goal, !goal.isEmpty { return goal }
        return session.repoDisplayName
    }

    @ViewBuilder
    private var terminalOverlay: some View {
        TahoeGlass(radius: 18, tone: .raised, shadow: .prominent) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(t.accent)
                        .frame(width: 26, height: 26)
                        .background(t.accentAlpha(t.dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raw terminal")
                            .font(TahoeFont.body(12.5, weight: .semibold))
                            .foregroundStyle(t.fg)
                        Text(headerLabel(for: session))
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { showingTerminalOverlay = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(t.fg3)
                    .background(t.surfaceSolid2.opacity(0.70), in: RoundedRectangle(cornerRadius: 8))
                    .keyboardShortcut(.cancelAction)
                    .help("Close terminal")
                }
                .padding(12)
                TahoeHairline()
                if let runtime = AppDelegate.runtime,
                   let port = runtime.agentControlServer.boundWsPort {
                    TerminalTabContainer(
                        session: session,
                        model: model,
                        wsPort: Int(port),
                        token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? "")
                    )
                } else {
                    ContentUnavailableView(
                        "Daemon offline",
                        systemImage: "wifi.exclamationmark",
                        description: Text("Restart Clawdmeter to reconnect.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    @ViewBuilder
    private var autopilotConfirm: some View {
        // The sheet is only invoked when the user picks `.bypass` from the
        // PermissionModeChip — we're always asking to ENABLE bypass here.
        // Disabling is a safe direct setPermissionMode call (no sheet).
        // v0.8: chat sessions have no repoKey and bypass-mode doesn't
        // apply; `?? ""` evaluates as untrusted, which is the right
        // default for any chat session that somehow reaches this sheet.
        let repoTrusted = AutopilotState.shared.isRepoTrusted(session.repoKey ?? "")
        let needsTrustGrant = !repoTrusted
        VStack(alignment: .leading, spacing: 12) {
            Label(
                needsTrustGrant ? "Trust this repo for bypass mode?" : "Enable bypass mode?",
                systemImage: needsTrustGrant ? "lock.shield.fill" : "bolt.fill"
            )
            .font(.system(size: 14, weight: .semibold))
            Text(autopilotConfirmBody(willEnable: true, needsTrustGrant: needsTrustGrant))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if needsTrustGrant, let repoKey = session.repoKey {
                Text("Repo: \((repoKey as NSString).lastPathComponent)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    showingAutopilotConfirm = false
                    pendingBypassMode = false
                }
                .keyboardShortcut(.cancelAction)
                Button(autopilotConfirmCTA(willEnable: true, needsTrustGrant: needsTrustGrant)) {
                    showingAutopilotConfirm = false
                    pendingBypassMode = false
                    if needsTrustGrant, let repoKey = session.repoKey {
                        AutopilotState.shared.trustRepo(repoKey)
                    }
                    Task { await model.setPermissionMode(sessionId: session.id, to: .bypass) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func autopilotConfirmBody(willEnable: Bool, needsTrustGrant: Bool) -> String {
        if needsTrustGrant {
            return "Bypass mode respawns the CLI with --dangerously-skip-permissions (Claude) or --dangerously-bypass-approvals-and-sandbox (Codex). It skips every tool-call approval prompt in this session, and any future session in this repo can be flipped to bypass with one click. Grant trust only if you intend to give agents free rein in this repo."
        }
        return "This will interrupt the current turn to respawn the CLI with the dangerously-* flags. The repo is already on your trust list."
    }

    private func autopilotConfirmCTA(willEnable: Bool, needsTrustGrant: Bool) -> String {
        if needsTrustGrant { return "Trust repo + enable bypass" }
        return "Enable + respawn"
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            messageList
            if !workbenchState.queuedSends(for: session.id).isEmpty {
                Divider()
                queuedSendsPanel
            }
            if let latest = workbenchState.latestCheckpoint(for: session.id) {
                Divider()
                checkpointStrip(latest)
            }
            // Always render the composer — even for read-only synthetic
            // Recent-JSONL rows. Sending text on a read-only row
            // implicitly promotes it to a live `--resume`/`resume` spawn
            // via SessionsModel.continueCurrentReadOnly (Wave A redesign).
            Divider()
            composerArea
        }
    }

    private var shouldShowInlinePlanHalo: Bool {
        guard let plan = session.planText?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !plan.isEmpty
    }

    private func primePlanRefinement() {
        if composerStore.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerStore.text = "Refine the plan above: "
        }
    }

    private var queuedSendsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Queued follow-ups", systemImage: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    workbenchState.clearQueuedSends(sessionId: session.id)
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            ForEach(workbenchState.queuedSends(for: session.id)) { draft in
                queuedDraftRow(draft)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.035))
    }

    private func queuedDraftRow(_ draft: QueuedWorkbenchSend) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(
                "Queued prompt",
                text: Binding(
                    get: { draft.text },
                    set: { workbenchState.updateQueuedSend(id: draft.id, text: $0) }
                ),
                axis: .vertical
            )
            .font(.system(size: 11))
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            if !draft.attachmentPaths.isEmpty {
                Label("\(draft.attachmentPaths.count)", systemImage: "paperclip")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .help(draft.attachmentPaths.joined(separator: "\n"))
            }
            Button {
                Task { await dispatchQueuedDraft(draft, manual: true) }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(session.status == .running || isDispatchingQueuedSend)
            .help(session.status == .running ? "Dispatches when the current turn finishes" : "Send queued follow-up now")
            .padding(.top, 6)
            Button(role: .destructive) {
                workbenchState.removeQueuedSend(id: draft.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Delete queued follow-up")
            .padding(.top, 6)
        }
    }

    private func checkpointStrip(_ checkpoint: CheckpointStateSnapshot) -> some View {
        HStack(spacing: 8) {
            Label("Checkpoint", systemImage: "bookmark.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            if let summary = checkpoint.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Restore") {
                Task { await prepareCheckpointRestore(checkpoint) }
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.plain)
            .help("Preview and restore this checkpoint")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.03))
    }

    @ViewBuilder
    private var messageList: some View {
        if let store = model.chatStore(for: session) {
            ChatThreadScroll(
                store: store,
                session: session,
                model: model,
                presentationStore: presentationStore,
                density: density,
                showPlanHalo: shouldShowInlinePlanHalo,
                canApprovePlan: !isReadOnly,
                // v0.29.25: thread the right-pane visibility flag in so
                // ChatThreadScroll can re-anchor to the bottom sentinel
                // after the workspace width changes. Without this, the
                // scroll view kept its absolute offset and the user
                // landed mid-history every time they toggled the pane.
                isReviewPaneVisible: workbenchState.showingReviewPane,
                onPlanRefine: primePlanRefinement,
                onPlanApprove: {
                    Task {
                        guard await createLifecycleCheckpoint(summary: "Before plan approval") else { return }
                        await model.approvePlan(id: session.id)
                    }
                }
            )
                .id(session.id)
                .onAppear {
                    // T8 wiring: push session.planText into the store so
                    // the staging actor's precompute can mark steps
                    // referenced from the plan as found.
                    store.setPlanText(session.planText)
                }
                .onChange(of: session.planText) { _, newValue in
                    store.setPlanText(newValue)
                }
        } else {
            ConnectingTranscriptState(session: session)
        }
    }

    private var composerArea: some View {
        ComposerInputCore(
            store: composerStore,
            presentationStore: presentationStore,
            catalog: catalog,
            agentForModelPicker: session.agent,
            modelSupportsEffort: modelSupportsEffort,
            onSend: { Task { await performBoundSend() } },
            onQueue: { queueCurrentDraft() },
            onInterrupt: { Task { await performInterrupt() } },
            onToggleAutopilot: { showingAutopilotConfirm = true },
            onChangePermissionMode: { newMode in
                Task { await changePermissionMode(to: newMode) }
            },
            permissionMode: PermissionModeStore.shared.currentMode(for: session),
            onApprovePlan: {
                Task {
                    guard await createLifecycleCheckpoint(summary: "Before plan approval") else { return }
                    await model.approvePlan(id: session.id)
                }
            },
            showApprovePlan: session.planText != nil,
            sessionIsRunning: session.status == .running && !composerStore.isSending,
            isReadOnly: isReadOnly,
            mentionSourceProvider: {
                let openSessions = model.registry.sessions.filter { $0.id != session.id && $0.archivedAt == nil }
                let store = model.chatStore(for: session)
                let sourceEntries = store?.snapshot.sourceEntries ?? []
                let recents = model.repos.flatMap { $0.recentSessions }
                return (openSessions, sourceEntries, Array(recents.prefix(30)))
            },
            usageStatus: usageStatusInfo,
            projectSkillsRoot: URL(fileURLWithPath: session.effectiveCwd).appendingPathComponent(".claude/skills", isDirectory: true),
            chatStore: model.chatStore(for: session),
            onRetryPending: { Task { await performPendingRetry() } }
        )
        // Read-only synthetic sessions have no live tmux pane to respawn,
        // so we skip the swap-on-change handlers. The model/effort chips
        // still update the local ComposerStore state for visual feedback,
        // but no async respawn fires until the user actually sends —
        // which calls `continueCurrentReadOnly()` first and promotes the
        // synthetic into a real session. Keeps typing zero-overhead.
        .onChange(of: composerStore.modelId) { _, new in
            guard !isReadOnly, let new, new != session.model else { return }
            if let entry = catalog.entry(forId: new) {
                Task { await model.switchModel(sessionId: session.id, to: entry, effort: composerStore.effort) }
            }
        }
        .onChange(of: composerStore.effort) { _, new in
            guard !isReadOnly, let new, new != session.effort else { return }
            Task { await model.switchEffort(sessionId: session.id, to: new) }
        }
        .onChange(of: composerStore.mode) { _, new in
            guard !isReadOnly, new != session.mode else { return }
            onModeSwitch(new)
        }
    }

    // MARK: - Send / interrupt / autopilot via daemon (P0 fixes)

    private var queueDrainKey: String {
        "\(session.id.uuidString):\(session.status.rawValue):\(workbenchState.queuedSendCount(for: session.id))"
    }

    private func queueCurrentDraft() {
        guard composerStore.canSend else { return }
        let draft = QueuedWorkbenchSend(
            sessionId: session.id,
            text: composerStore.text,
            attachmentPaths: composerStore.attachments.map { $0.sourceURL.path }
        )
        workbenchState.queueSend(draft)
        composerStore.clearAfterSend()
    }

    private func drainQueuedSendsIfPossible() async {
        guard session.status != .running,
              !isDispatchingQueuedSend,
              !dispatchedQueuedTurnForCurrentIdle,
              let draft = workbenchState.nextQueuedSend(for: session.id)
        else { return }
        dispatchedQueuedTurnForCurrentIdle = true
        await dispatchQueuedDraft(draft, manual: false)
    }

    private func dispatchQueuedDraft(_ draft: QueuedWorkbenchSend, manual: Bool) async {
        guard session.status != .running else { return }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachmentPaths.isEmpty else {
            workbenchState.removeQueuedSend(id: draft.id)
            return
        }
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else {
            composerStore.endSend(error: .offline)
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
            return
        }
        isDispatchingQueuedSend = true
        composerStore.beginSend()
        defer {
            isDispatchingQueuedSend = false
        }

        let target = session
        var stagedPaths: [URL] = []
        if !draft.attachmentPaths.isEmpty {
            guard let dir = AttachmentStaging.stagingDir(for: target) else {
                composerStore.endSend(error: .daemonError(message: "Couldn't create attachment staging directory."))
                if !manual { dispatchedQueuedTurnForCurrentIdle = false }
                return
            }
            for path in draft.attachmentPaths {
                do {
                    let staged = try AttachmentStaging.stage(
                        source: URL(fileURLWithPath: path),
                        into: dir,
                        attachmentId: UUID()
                    )
                    stagedPaths.append(staged)
                } catch {
                    composerStore.endSend(error: .daemonError(message: "Couldn't stage queued attachment: \(error.localizedDescription)"))
                    if !manual { dispatchedQueuedTurnForCurrentIdle = false }
                    return
                }
            }
        }

        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        let body = QueuedPromptRenderer.render(text: draft.text, attachmentPaths: stagedPaths)
        do {
            guard await createLifecycleCheckpoint(summary: "Before queued prompt") else {
                composerStore.endSend(error: .daemonError(message: "Safety checkpoint failed. Prompt was not sent."))
                if !manual { dispatchedQueuedTurnForCurrentIdle = false }
                return
            }
            try await sender.send(sessionId: target.id, body: body, asFollowUp: true)
            workbenchState.removeQueuedSend(id: draft.id)
            composerStore.endSend()
        } catch MacComposerSender.Error.http(let status, let retry) {
            switch status {
            case 401: composerStore.endSend(error: .unauthorized)
            case 404: composerStore.endSend(error: .sessionGone)
            case 429: composerStore.endSend(error: .rateLimited(retryAfter: retry))
            default: composerStore.endSend(error: .daemonError(message: "HTTP \(status)"))
            }
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
        } catch MacComposerSender.Error.transport(let message) {
            composerStore.endSend(error: .daemonError(message: message))
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
        } catch {
            composerStore.endSend(error: .daemonError(message: error.localizedDescription))
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
        }
    }

    private func createCheckpoint() async {
        let service = CheckpointService()
        do {
            let checkpoint = try await service.createCheckpoint(
                session: session,
                summary: "Manual checkpoint"
            )
            workbenchState.recordCheckpoint(checkpoint)
            checkpointStatusText = "checkpoint saved"
        } catch {
            checkpointStatusText = error.localizedDescription
        }
    }

    private func prepareCheckpointRestore(_ checkpoint: CheckpointStateSnapshot) async {
        let service = CheckpointService()
        isPreparingCheckpointRestore = true
        checkpointStatusText = "preparing restore preview"
        defer { isPreparingCheckpointRestore = false }
        do {
            let plan = try await service.prepareRestore(checkpoint, session: session)
            workbenchState.recordCheckpoint(plan.safety)
            restorePlan = plan
            checkpointStatusText = plan.isBlocked ? "restore blocked" : "restore preview ready"
        } catch {
            checkpointStatusText = error.localizedDescription
        }
    }

    private func restoreCheckpoint(_ plan: CheckpointRestorePlan) async {
        let service = CheckpointService()
        isRestoringCheckpoint = true
        defer { isRestoringCheckpoint = false }
        do {
            try await service.restore(plan, in: session.effectiveCwd)
            restorePlan = nil
            checkpointStatusText = "checkpoint restored"
        } catch {
            checkpointStatusText = error.localizedDescription
        }
    }

    private func createLifecycleCheckpoint(summary: String, for targetSession: AgentSession? = nil) async -> Bool {
        let service = CheckpointService()
        let checkpointSession = targetSession ?? session
        do {
            let checkpoint = try await service.createCheckpoint(session: checkpointSession, summary: summary)
            workbenchState.recordCheckpoint(checkpoint)
            checkpointStatusText = "checkpoint saved"
            return true
        } catch {
            checkpointStatusText = "checkpoint failed: \(error.localizedDescription)"
            return false
        }
    }

    private func performBoundSend() async {
        composerStore.beginSend()
        let draftText = composerStore.text
        let draftAttachments = composerStore.attachments
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else {
            composerStore.endSend(error: .offline)
            // A13: optimistic pending becomes "queued offline" so the user
            // can see their message is staged for replay when the daemon
            // returns. Retry triggers another performBoundSend() pass.
            model.chatStore(for: session)?.markPendingQueuedOffline(
                error: "Daemon offline — tap retry when it returns."
            )
            return
        }
        // Read-only Recent-JSONL rows: implicitly promote the synthetic
        // session to a live --resume spawn before sending. The model
        // updates `openSessionId` to the new live session, the parent view
        // re-renders, and the existing post-send `endSend()` clears this
        // store. The new CenterThread mounts with a fresh empty composer.
        let target: AgentSession
        var promotedReadOnlyTarget: AgentSession?
        if isReadOnly {
            guard let live = await model.continueCurrentReadOnly() else {
                // v0.5.0 — surface the JSONL path in the error message so
                // a failed extract can be diagnosed. The most common
                // failure mode pre-v0.5.0 was the 64KB header read missing
                // the sessionId-bearing line; `JSONLSessionId.extract` now
                // streams up to 1MB. If this error still fires, the path
                // points to the specific file where extract returned nil
                // (file missing, unreadable, or genuinely malformed).
                let jsonlPath = model.openOutsideJSONLPath ?? "(unknown)"
                composerStore.endSend(error: .daemonError(
                    message: "Couldn't resume this session — no session id in the JSONL header.\n\nPath: \(jsonlPath)"
                ))
                return
            }
            // Match EmptyStateCenteredComposer's pane-readiness wait — tmux
            // needs a beat to wire up the pane and the CLI to swallow the
            // resume argv before paste-buffer hits.
            try? await Task.sleep(nanoseconds: 600_000_000)
            promotedReadOnlyTarget = live
            target = live
        } else {
            target = session
        }

        guard await createLifecycleCheckpoint(summary: "Before prompt", for: target) else {
            finishBoundSendWithError(
                .daemonError(message: "Safety checkpoint failed. Prompt was not sent."),
                promotedTarget: promotedReadOnlyTarget,
                draftText: draftText,
                draftAttachments: draftAttachments
            )
            return
        }

        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        var stagedPaths: [URL] = []
        if let dir = AttachmentStaging.stagingDir(for: target) {
            for att in composerStore.attachments {
                do {
                    let staged = try AttachmentStaging.stage(source: att.sourceURL, into: dir, attachmentId: att.id)
                    stagedPaths.append(staged)
                } catch {
                    finishBoundSendWithError(
                        .daemonError(message: "Couldn't stage \(att.displayName): \(error.localizedDescription)"),
                        promotedTarget: promotedReadOnlyTarget,
                        draftText: draftText,
                        draftAttachments: draftAttachments
                    )
                    return
                }
            }
        }
        let body = composerStore.renderPromptBody(attachmentPaths: stagedPaths)
        do {
            try await sender.send(sessionId: target.id, body: body, asFollowUp: true)
            composerStore.endSend()
            // A13: daemon accepted the send. The auto-reconcile in
            // SessionChatStore clears the pending bubble once the real
            // user line lands in the JSONL — typically within a few
            // hundred ms. If the JSONL tail is slow, leaving the bubble
            // up as "Sending…" is still correct UX (the message IS in
            // flight). We do NOT clear it here proactively because the
            // ack-vs-JSONL race could flicker the bubble out and back in.
            // A13: drain any messages that piled up while the daemon was
            // offline — now that one send succeeded, the daemon is reachable.
            await drainOfflineQueueIfAny(target: target, port: Int(port))
        } catch MacComposerSender.Error.http(let status, let retry) {
            finishBoundSendWithError(
                sendError(forHTTPStatus: status, retryAfter: retry),
                promotedTarget: promotedReadOnlyTarget,
                draftText: draftText,
                draftAttachments: draftAttachments
            )
        } catch MacComposerSender.Error.transport(let m) {
            finishBoundSendWithError(
                .daemonError(message: m),
                promotedTarget: promotedReadOnlyTarget,
                draftText: draftText,
                draftAttachments: draftAttachments
            )
        } catch {
            finishBoundSendWithError(
                .daemonError(message: error.localizedDescription),
                promotedTarget: promotedReadOnlyTarget,
                draftText: draftText,
                draftAttachments: draftAttachments
            )
        }
    }

    /// A13 — Retry handler for the failed/queued pending bubble in the
    /// composer. Flips the chat store's pending slot back to `.sending`
    /// (no flicker) and re-runs the regular send path against the
    /// existing pending body. When the bubble is in `.failed` we don't
    /// have the composer text anymore (the user already cleared it on
    /// the first send) — but `performBoundSend` reads from
    /// `composerStore.text`. We re-seed the composer with the pending
    /// body so the existing pipeline can replay it, then restore the
    /// user's in-flight draft if they typed something new during the
    /// failure window.
    @MainActor
    private func performPendingRetry() async {
        guard let chatStore = model.chatStore(for: session),
              let pending = chatStore.pendingMessage,
              pending.canRetry
        else { return }

        // Preserve any new draft the user typed since the failure.
        let liveDraft = composerStore.text
        let liveDraftAttachments = composerStore.attachments

        composerStore.text = pending.body
        chatStore.markPendingRetrying()
        await performBoundSend()

        // Restore the user's in-flight draft if they typed something new
        // during the failure window. `performBoundSend` clears the
        // composer on success, so we only restore when the slot was
        // already populated by something other than the pending body.
        let trimmedLive = liveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLive.isEmpty, trimmedLive != pending.body {
            composerStore.restoreDraft(text: liveDraft, attachments: liveDraftAttachments)
        }
    }

    /// A13 — drain queued pending messages onto the daemon. Best-effort:
    /// each queued body is sent in FIFO order; on the first failure the
    /// failing entry + every un-drained entry behind it are re-queued
    /// at the head so the next successful send picks up where this one
    /// left off. Runs after a successful primary send (signal that the
    /// daemon is reachable again).
    @MainActor
    private func drainOfflineQueueIfAny(target: AgentSession, port: Int) async {
        guard let chatStore = model.chatStore(for: session) else { return }
        let queued = chatStore.dequeueOfflineQueue()
        guard !queued.isEmpty else { return }
        let sender = MacComposerSender(port: port, token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        for (index, entry) in queued.enumerated() {
            // Bodies in the offline queue were captured pre-trim, so
            // re-add the terminal newline tmux paste-buffer requires.
            let body = entry.body.isEmpty ? "\n" : entry.body + "\n"
            do {
                try await sender.send(sessionId: target.id, body: body, asFollowUp: true)
            } catch {
                // Failed to drain — re-queue the failing entry + every
                // remaining entry behind it so we don't lose them on the
                // next successful primary send. The pending slot
                // mutation here describes the failure on the *current*
                // pending bubble (which is the user-visible context for
                // the drain), but the actual un-drained bodies are
                // preserved in `queuedPendingMessages`.
                let remaining = Array(queued[index..<queued.count])
                chatStore.requeueOfflinePending(remaining)
                chatStore.markPendingFailed(
                    error: "Couldn't replay queued message: \(error.localizedDescription)"
                )
                break
            }
        }
    }

    private func sendError(forHTTPStatus status: Int, retryAfter retry: Int?) -> ComposerStore.SendError {
        switch status {
        case 401: return .unauthorized
        case 404: return .sessionGone
        case 429: return .rateLimited(retryAfter: retry)
        default: return .daemonError(message: "HTTP \(status)")
        }
    }

    private func finishBoundSendWithError(
        _ error: ComposerStore.SendError,
        promotedTarget: AgentSession?,
        draftText: String,
        draftAttachments: [ComposerStore.Attachment]
    ) {
        if let promotedTarget {
            model.queueFirstSendRecovery(
                sessionId: promotedTarget.id,
                text: draftText,
                attachments: draftAttachments,
                error: error
            )
        }
        composerStore.endSend(error: error)
        // A13 (D24 rejection handling): the daemon rejected the send. The
        // optimistic pending bubble stays visible with a chip + retry
        // affordance — NOT silently dropped. Offline transport gets a
        // distinct state so the chip can offer "will retry when daemon
        // returns" copy instead of the explicit-error copy.
        let chatStore = model.chatStore(for: session)
        switch error {
        case .offline:
            chatStore?.markPendingQueuedOffline(
                error: "Daemon offline — tap retry when it returns."
            )
        default:
            chatStore?.markPendingFailed(error: error.errorDescription ?? "Send failed.")
        }
    }

    private func performInterrupt() async {
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else { return }
        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        try? await sender.interrupt(sessionId: session.id)
    }

    /// Translate a `PermissionMode` pick into an argv respawn. Picks of
    /// `.bypass` re-use the existing autopilot trust-grant sheet — for
    /// untrusted repos we surface the same confirm UX before flipping
    /// the daemon-side bypass flag.
    private func changePermissionMode(to newMode: PermissionMode) async {
        // `.bypass` is the trust-gated path; defer to the existing
        // autopilot confirm sheet so the user explicitly opts in.
        if newMode == .bypass {
            // Only show the confirm if we're moving INTO bypass — flipping
            // back out is always safe.
            pendingBypassMode = true
            showingAutopilotConfirm = true
            return
        }
        await model.setPermissionMode(sessionId: session.id, to: newMode)
    }

    /// Right-side composer chip data: model + effort label, single-turn
    /// context window utilisation, running session cost, and the live
    /// Claude plan-window percentages from AppModel.
    ///
    /// **Context window math**: uses the SNAPSHOT's `contextWindowUsedTokens`
    /// (single-turn `last*` fields) — NOT the cumulative `totalTokens`. A
    /// long-running session re-counts cache reads on every turn, so the
    /// cumulative totals balloon to 100s of M and produce 1500% readings
    /// against a 1M window. The single-turn number is the model's actual
    /// working-memory size for the next prompt.
    ///
    /// **Model resolution**: trusts `session.model` over `snapshot.modelHint`
    /// because the user explicitly selected the session model — the JSONL
    /// hint can lag the chip selection and may report `claude-opus-4-7`
    /// (200K) when the user is actually running the 1M variant.
    private var usageStatusInfo: UsageStatusInfo? {
        let modelId = effectiveModelId ?? model.chatStore(for: session)?.snapshot.modelHint
        guard let modelId, !modelId.isEmpty else { return nil }
        let entry = catalog.entry(forId: modelId)
        let snap = model.chatStore(for: session)?.snapshot
        let effort = effectiveEffort(forModelId: modelId)
        let used = snap?.contextWindowUsedTokens ?? 0
        let totals = TokenTotals(
            inputTokens: snap?.totalInputTokens ?? 0,
            outputTokens: snap?.totalOutputTokens ?? 0,
            cacheCreationTokens: snap?.totalCacheCreationTokens ?? 0,
            cacheReadTokens: snap?.totalCacheReadTokens ?? 0
        )
        let dollar = Pricing.shared.cost(for: modelId, tokens: totals)
        let claudePlan = (session.agent == .claude) ? AppDelegate.runtime?.claudeModel.usage : nil
        return UsageStatusInfo(
            modelDisplay: entry?.displayName ?? modelId,
            effortDisplay: effort.map(effortLabel) ?? "Default",
            contextUsedTokens: used,
            contextLimitTokens: entry?.contextWindow,
            costDollar: dollar,
            sessionPct: claudePlan?.sessionPct,
            sessionResetMins: claudePlan?.sessionResetMins,
            weeklyPct: claudePlan?.weeklyPct,
            weeklyResetMins: claudePlan?.weeklyResetMins
        )
    }

    /// Display label for a ReasoningEffort — friendlier than `.rawValue`
    /// for `xhigh`/`max`. Matches Claude Code's "Extra high"/"Max" copy.
    private func effortLabel(_ e: ReasoningEffort) -> String {
        switch e {
        case .minimal: return "Minimal"
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        case .xhigh:   return "Extra high"
        case .max:     return "Max"
        }
    }

    private var effectiveModelId: String? {
        Self.effectiveModelId(for: session, catalog: catalog)
    }

    private func effectiveEffort(forModelId modelId: String?) -> ReasoningEffort? {
        Self.effectiveEffort(for: session, modelId: modelId, catalog: catalog)
    }

    private var sessionConfigurationSummary: String {
        let modelText: String
        if let id = effectiveModelId, !id.isEmpty {
            modelText = catalog.entry(forId: id)?.displayName ?? id
        } else {
            modelText = "default model"
        }
        let effortText = effectiveEffort(forModelId: effectiveModelId).map(effortLabel) ?? "Default effort"
        return "\(session.agent.tahoeProvider.displayName) · \(modelText) · \(effortText) · \(session.mode.rawValue) mode"
    }

    private static func effectiveModelId(for session: AgentSession, catalog: ModelCatalog) -> String? {
        let candidates = [
            session.runtimeBinding?.providerModelId,
            session.model
        ]
        if let explicit = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
            return explicit
        }
        return ComposerStore.ChipDefaults.for(agent: session.agent, catalog: catalog).modelId
    }

    private static func effectiveEffort(
        for session: AgentSession,
        modelId: String?,
        catalog: ModelCatalog
    ) -> ReasoningEffort? {
        if let effort = session.effort { return effort }
        if let modelId,
           let entry = catalog.entry(forId: modelId),
           !entry.supportsEffort {
            return nil
        }
        return ComposerStore.ChipDefaults.for(agent: session.agent, catalog: catalog).effort
    }

    private func toggleAutopilot(enable: Bool, grantingTrust: Bool = false) async {
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else { return }
        // E7: enable requires the repo to be on the autopilot trust list.
        // The confirm sheet asks for trust grant explicitly; if the user
        // accepted, record it before the wire-level enforcement kicks in.
        if grantingTrust, let repoKey = session.repoKey {
            // Chat sessions have no repo and can't grant trust; guard
            // here so we never persist trust for an empty string.
            AutopilotState.shared.trustRepo(repoKey)
        }
        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        // Daemon-side: flip state. We then respawn via SessionConfigChanger so
        // the running CLI restarts with the appropriate --dangerously-* flags.
        do {
            try await sender.setAutopilot(sessionId: session.id, enabled: enable)
            composerStore.autopilotEnabled = enable
            let changer = SessionConfigChanger(
                registry: model.registry,
                tmux: runtime.tmuxClient,
                repoEnvResolver: runtime.repoEnvRuntimeResolver
            )
            _ = await changer.swap(sessionId: session.id)
        } catch MacComposerSender.Error.http(let status, _) where status == 403 {
            composerStore.endSend(error: .daemonError(message: "Repo not trusted for autopilot. (You can grant trust from this dialog.)"))
        } catch {
            composerStore.endSend(error: .daemonError(message: "Autopilot toggle failed: \(error.localizedDescription)"))
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return terraCotta
        case .degraded: return .secondary
        }
    }

    /// Header branch chip label. Falls back to the worktree segment when
    /// `session.mode == .worktree`; otherwise hidden.
    private var branchLabel: String? {
        if let wt = session.worktreePath {
            return (wt as NSString).lastPathComponent
        }
        return nil
    }

    /// Icon for the branch chip. Filled when a PR is open or merged so the
    /// chip reads at a glance — empty branch glyph when no PR is linked.
    private var prBranchIcon: String {
        guard let state = prMirror.state?.state.uppercased() else {
            return "arrow.triangle.branch"
        }
        switch state {
        case "OPEN", "MERGED": return "arrow.triangle.pull"
        default: return "arrow.triangle.branch"
        }
    }

    /// Branch-chip color follows GitHub's PR badge palette: green for an
    /// open PR, purple for a merged PR, dark red for a closed-without-merge
    /// PR, and the Clawdmeter terra-cotta when no PR has been detected yet.
    private var prBranchColor: Color {
        guard let state = prMirror.state?.state.uppercased() else {
            return terraCotta
        }
        switch state {
        case "OPEN":   return .green
        case "MERGED": return Color(red: 0x8A / 255.0, green: 0x3F / 255.0, blue: 0xFC / 255.0)
        case "CLOSED": return .red
        default:       return terraCotta
        }
    }

    private var branchTooltip: String {
        var pieces: [String] = []
        if let wt = session.worktreePath {
            pieces.append("Worktree: \(wt)")
        }
        if let pr = prMirror.state {
            pieces.append("PR #\(pr.number) · \(pr.state.lowercased())")
            if !pr.title.isEmpty {
                pieces.append(pr.title)
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// Whether the current model supports an effort dial. Uses the live
    /// launcher catalog so account-scoped Cursor models get the same
    /// effort semantics in bound sessions as they do at launch.
    private var modelSupportsEffort: Bool {
        guard let id = composerStore.modelId ?? effectiveModelId,
              let entry = catalog.entry(forId: id)
        else { return true }
        return entry.supportsEffort
    }

    private func applyPendingFirstSendRecovery() {
        guard let recovery = model.takeFirstSendRecovery(sessionId: session.id) else { return }
        composerStore.restoreDraft(
            text: recovery.text,
            attachments: recovery.attachments,
            error: recovery.error
        )
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}

// `InlinePlanHalo` lives in `InlinePlanHalo.swift` (A6 foundation extraction).

// MARK: - Chat thread scroll

private struct ChatThreadScroll: View {
    // A5 — `store` is held as a plain `let` (no observation). Body
    // invalidations come from the per-concern slices below, which
    // publish only on changes to their own concern. The transcript
    // ForEach binds to `messagesSlice`; the activity indicator + the
    // load-earlier button bind to `liveStatusSlice`. Token deltas land
    // on `composerSlice` and do NOT invalidate this view's body.
    let store: SessionChatStore
    @ObservedObject var messagesSlice: ChatMessagesSlice
    @ObservedObject var liveStatusSlice: ChatLiveStatusSlice
    let session: AgentSession
    let model: SessionsModel
    @ObservedObject var presentationStore: SessionPresentationStore
    let density: TranscriptDensity
    let showPlanHalo: Bool
    let canApprovePlan: Bool
    /// v0.29.25: track the right-pane visibility so a toggle can re-anchor
    /// the scroll view to the bottom sentinel. The chat list's
    /// `userPinnedToBottom` state survives the width change, but the
    /// scroll position itself doesn't — the LazyVStack relays out at the
    /// new width, item heights shift, and the absolute content offset
    /// the scroll view kept now points mid-history.
    let isReviewPaneVisible: Bool
    let onPlanRefine: () -> Void
    let onPlanApprove: () -> Void
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: SessionChatStore,
        session: AgentSession,
        model: SessionsModel,
        presentationStore: SessionPresentationStore,
        density: TranscriptDensity,
        showPlanHalo: Bool,
        canApprovePlan: Bool,
        isReviewPaneVisible: Bool,
        onPlanRefine: @escaping () -> Void,
        onPlanApprove: @escaping () -> Void
    ) {
        self.store = store
        _messagesSlice = ObservedObject(wrappedValue: store.messagesSlice)
        _liveStatusSlice = ObservedObject(wrappedValue: store.liveStatusSlice)
        self.session = session
        self.model = model
        self.presentationStore = presentationStore
        self.density = density
        self.showPlanHalo = showPlanHalo
        self.canApprovePlan = canApprovePlan
        self.isReviewPaneVisible = isReviewPaneVisible
        self.onPlanRefine = onPlanRefine
        self.onPlanApprove = onPlanApprove
    }

    /// IDs of expanded disclosure groups. Per-row `@State` would be ideal
    /// (A5 codex finding) but with LazyVStack recycling that loses state
    /// across scroll; this set is the simplest path that survives recycling.
    /// Tests confirm tapping one row only invalidates that row when reads
    /// flow through `messagesSlice.items` (T5).
    @State private var expanded: Set<String> = []
    /// v0.5.6: per-tool_use_id selection state for AskUserQuestion trays.
    /// `[toolUseId: [questionHeader: Set<optionLabel>]]`. Lives at the
    /// scroll-view level so picks survive list recycling during
    /// streaming bumps.
    @State private var askUserQuestionSelections: [String: [String: Set<String>]] = [:]
    @State private var showingFindBar = false
    @State private var findQuery = ""
    @State private var selectedMatchIndex: Int?
    @State private var projectionCache = SingleSlotProjectionCache<TranscriptProjectionCacheKey, TranscriptProjection>()
    // Caches the find-bar scan keyed on (query, transcript cursor). The
    // find result was previously a plain computed var recomputed up to
    // 3× per body render PLUS once per visible message row (highlightState),
    // i.e. O(rows × messages). Now a single full O(messages) scan per
    // query/transcript change feeds every reader, with an id Set for O(1)
    // per-row membership.
    @State private var findMatchCache = SingleSlotProjectionCache<FindMatchKey, FindMatchResult>()
    @FocusState private var findFocused: Bool

    var body: some View {
        // A9: tap the body-invalidation counter so the per-burst
        // measurement test can assert "ChatThreadScroll re-renders
        // ONCE per token tick" (the price of binding to
        // `messagesSlice.items`) but the historical row views — now
        // extracted to `ChatItemRowView` with Equatable conformance —
        // stay flat across the burst. No-op when
        // `BodyInvalidationCounter.enabled` is false (production).
        let _ = BodyInvalidationCounter.bump("ChatThreadScroll")
        let streamingTailId = streamingTailItemId
        let projection = transcriptProjection
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if liveStatusSlice.hasOlderHistory {
                            loadEarlierButton
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                        if projection.turns.isEmpty && !liveStatusSlice.isLoading {
                            emptyState
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(projection.turns) { turn in
                                collapsedTurnView(turn, streamingTailId: streamingTailId)
                                    .id(turn.id)
                                    .padding(rowInsets)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if showPlanHalo {
                            InlinePlanHalo(
                                session: session,
                                onRefine: onPlanRefine,
                                onApprove: onPlanApprove,
                                canApprove: canApprovePlan
                            )
                            .padding(rowInsets)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            LiveSessionActivityIndicator(
                                agent: session.agent,
                                lastEventAt: liveStatusSlice.lastEventAt,
                                // v0.29.4: anchor the elapsed counter to
                                // the most recent user prompt so the
                                // pill shows "how long has the model been
                                // working on this task", not "how long
                                // since I clicked into the session".
                                activityStartedAt: liveStatusSlice.currentTurnStartedAt
                            )
                            Spacer()
                        }
                        .padding(rowInsets)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomSentinelId)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                    return visibleBottom >= geometry.contentSize.height - 120
                } action: { _, isAtBottom in
                    if isAtBottom || Date() < suppressBottomGeometryUntil {
                        userPinnedToBottom = true
                    } else {
                        userPinnedToBottom = false
                    }
                }
                .onChange(of: messagesSlice.updateCounter) { _, counter in
                    stickToBottomIfPinned(proxy, updateCounter: counter)
                }
                .onChange(of: isReviewPaneVisible) { _, _ in
                    // v0.29.25: width change relays the LazyVStack at a
                    // different per-row height (text wraps differently),
                    // so the absolute content offset that was bottom-
                    // anchored now lands mid-history. Re-pin only when
                    // the user was already at the bottom; respect the
                    // jump-to-latest CTA otherwise.
                    guard userPinnedToBottom else { return }
                    autoScrollTask?.cancel()
                    autoScrollTask = Task { @MainActor in
                        // One yield lets SwiftUI commit the new layout
                        // before we ask the proxy to scroll, otherwise
                        // we measure pre-resize geometry.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        await jumpToBottom(proxy, animated: false)
                    }
                }
                .onAppear {
                    userPinnedToBottom = true
                    lastScrollItemCount = messagesSlice.items.count
                    autoScrollTask?.cancel()
                    autoScrollTask = Task { @MainActor in
                        await jumpToBottom(proxy, animated: false)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        guard !Task.isCancelled else { return }
                        await jumpToBottom(proxy, animated: false)
                    }
                }
                .onDisappear {
                    autoScrollTask?.cancel()
                    autoScrollTask = nil
                    userPinnedToBottom = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptFind)) { _ in
                    showingFindBar = true
                    findFocused = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptNextMatch)) { _ in
                    jumpToFindMatch(proxy, delta: 1)
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptPreviousMatch)) { _ in
                    jumpToFindMatch(proxy, delta: -1)
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptLatest)) { _ in
                    Task { @MainActor in await jumpToBottom(proxy, animated: true) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptLastUser)) { _ in
                    jumpToLastUserMessage(proxy)
                }

                if showingFindBar {
                    VStack {
                        transcriptFindBar(proxy)
                            .padding(.top, 10)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Jump-to-latest CTA. Visible whenever the user has
                // scrolled away from the bottom (a new turn lands while
                // they're reading history). Click → scroll-to-last-item.
                if !userPinnedToBottom, !projection.turns.isEmpty {
                    Button(action: {
                        autoScrollTask?.cancel()
                        autoScrollTask = Task { @MainActor in
                            await jumpToBottom(proxy, animated: true)
                        }
                    }) {
                        Label(
                            unreadWhileReading > 0 ? "Jump to latest (\(unreadWhileReading))" : "Jump to latest",
                            systemImage: "arrow.down.circle.fill"
                        )
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                    .help("Jump to latest message (⌘↓)")
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                // v0.7.16: thinking-indicator overlay removed. It's now
                // a footer row inside the transcript flow above.
            }
        }
        // A9: bridge `presentationStore` into the SwiftUI environment so
        // the extracted `ChatItemRowView` can resolve path-link clicks
        // without holding an `@ObservedObject` reference to the store.
        // The row needs the store only on user action (tap), not on
        // every body — pulling it through the environment lets the row
        // stay Equatable on its value payload.
        .environment(\.sessionPresentationStore, presentationStore)
    }

    /// Stable sentinel id used by ScrollViewReader to scroll to the tail.
    /// Held as a static so the id reference doesn't recompute per-render.
    private static let bottomSentinelId = "mac-chat-bottom-sentinel"

    /// Tracks whether the user is reading the tail (last item visible).
    /// When false, auto-scroll stops yanking on new turns and the "Jump
    /// to latest" button surfaces. Updated by the per-row appear/disappear.
    @State private var userPinnedToBottom: Bool = true

    @State private var lastScrollItemCount: Int = 0
    @State private var unreadWhileReading: Int = 0
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var isLoadingEarlierHistory: Bool = false
    @State private var suppressBottomGeometryUntil: Date = .distantPast

    private var transcriptProjection: TranscriptProjection {
        projectionCache.value(
            for: TranscriptProjectionCacheKey(
                updateCounter: messagesSlice.updateCounter,
                mode: .latestAnswerOnly
            )
        ) {
            TranscriptTurnProjector.project(
                items: messagesSlice.items,
                messages: messagesSlice.messages,
                mode: .latestAnswerOnly
            )
        }
    }

    private var rowInsets: EdgeInsets {
        switch density {
        case .compact:
            return EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14)
        case .balanced:
            return EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16)
        case .detailed:
            return EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        }
    }

    // A9: per-row `bodyFontSize` + `toolOutputLineLimit` now live in
    // `ChatItemRowContent` (in `ChatItemRowView.swift`) — derived from
    // the passed-in density. Kept out of ChatThreadScroll so the row
    // doesn't need a reference back to the parent.

    /// Cache key for the find scan: the trimmed query + the transcript
    /// cursor. A stable (query, cursor) pair is a cache hit, so the scan
    /// runs once even though several readers ask for it within one render.
    private struct FindMatchKey: Equatable {
        let query: String
        let updateCounter: UInt64
    }

    private struct FindMatchResult {
        let matches: [SessionChatStore.ChatMessage]
        let matchedIds: Set<String>
    }

    private var findResult: FindMatchResult {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return findMatchCache.value(
            for: FindMatchKey(query: q, updateCounter: messagesSlice.updateCounter)
        ) {
            guard !q.isEmpty else { return FindMatchResult(matches: [], matchedIds: []) }
            let matches = messagesSlice.messages.filter {
                $0.body.localizedCaseInsensitiveContains(q)
                    || $0.title.localizedCaseInsensitiveContains(q)
                    || ($0.detail?.localizedCaseInsensitiveContains(q) == true)
            }
            return FindMatchResult(matches: matches, matchedIds: Set(matches.map(\.id)))
        }
    }

    private var findMatches: [SessionChatStore.ChatMessage] {
        findResult.matches
    }

    private func transcriptFindBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.fg3)
            TextField("Find in transcript", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { jumpToFindMatch(proxy, delta: 1) }
                .accessibilityLabel("Find in transcript")
            Text(findStatusLabel)
                .font(TahoeFont.mono(10.5))
                .foregroundStyle(t.fg3)
                .frame(minWidth: 54, alignment: .trailing)
            Button(action: { jumpToFindMatch(proxy, delta: -1) }) {
                Image(systemName: "chevron.up")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(findMatches.isEmpty)
            .help("Previous match (⌘⇧G)")
            .accessibilityLabel("Previous match")
            Button(action: { jumpToFindMatch(proxy, delta: 1) }) {
                Image(systemName: "chevron.down")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(findMatches.isEmpty)
            .help("Next match (⌘G)")
            .accessibilityLabel("Next match")
            Button(action: {
                findQuery = ""
                selectedMatchIndex = nil
                showingFindBar = false
            }) {
                Image(systemName: "xmark")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close find")
            .accessibilityLabel("Close find")
        }
        .font(TahoeFont.body(12))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        )
        .frame(maxWidth: 460)
        .accessibilityElement(children: .contain)
    }

    private var findStatusLabel: String {
        let matches = findMatches
        guard !matches.isEmpty else {
            return findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "0"
        }
        let current = (selectedMatchIndex ?? 0) + 1
        return "\(current)/\(matches.count)"
    }

    private func jumpToFindMatch(_ proxy: ScrollViewProxy, delta: Int) {
        let matches = findMatches
        guard !matches.isEmpty else {
            showingFindBar = true
            findFocused = true
            return
        }
        let current = selectedMatchIndex ?? (delta < 0 ? 0 : -1)
        let next = (current + delta + matches.count) % matches.count
        selectedMatchIndex = next
        userPinnedToBottom = false
        let message = matches[next]
        if let anchor = transcriptProjection.anchorByMessageId[message.id] {
            if anchor.isHidden {
                expanded.insert(anchor.turnId)
                if let runId = anchor.runId {
                    expanded.insert("run:\(runId)")
                }
                if let pairId = anchor.pairId {
                    expanded.insert("pair:\(pairId)")
                }
            }
            Task { @MainActor in
                await Task.yield()
                scrollTranscript(proxy, to: anchor.itemId, anchor: .center)
            }
        } else {
            scrollTranscript(proxy, to: message.id, anchor: .center)
        }
    }

    private func jumpToLastUserMessage(_ proxy: ScrollViewProxy) {
        var previous: SessionChatStore.ChatMessage?
        var lastPrompt: SessionChatStore.ChatMessage?
        for message in messagesSlice.messages {
            if PromptBoundary.isRealPrompt(message, previous: previous) {
                lastPrompt = message
            }
            previous = message
        }
        guard let message = lastPrompt else { return }
        userPinnedToBottom = false
        if let anchor = transcriptProjection.anchorByMessageId[message.id] {
            if anchor.isHidden {
                expanded.insert(anchor.turnId)
            }
            Task { @MainActor in
                await Task.yield()
                scrollTranscript(proxy, to: anchor.itemId, anchor: .center)
            }
        } else {
            scrollTranscript(proxy, to: message.id, anchor: .center)
        }
    }

    private func scrollTranscript(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    private var loadEarlierButton: some View {
        HStack {
            Spacer()
            Button {
                guard !isLoadingEarlierHistory else { return }
                isLoadingEarlierHistory = true
                userPinnedToBottom = false
                Task {
                    await store.loadOlderHistory()
                    await MainActor.run {
                        isLoadingEarlierHistory = false
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isLoadingEarlierHistory {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(isLoadingEarlierHistory ? "Loading earlier…" : "Load earlier messages")
                        .font(TahoeFont.body(11, weight: .semibold))
                }
                .foregroundStyle(t.fg3)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(t.hair2, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(isLoadingEarlierHistory)
            .help("Load the previous 200 messages")
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func stickToBottomIfPinned(_ proxy: ScrollViewProxy, updateCounter: UInt64) {
        let items = messagesSlice.items.count
        let previousItems = lastScrollItemCount
        lastScrollItemCount = items
        guard !isLoadingEarlierHistory else { return }
        if !userPinnedToBottom && items > previousItems {
            unreadWhileReading += items - previousItems
        }
        guard userPinnedToBottom, items >= previousItems else { return }
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await jumpToBottom(proxy, animated: false)
        }
    }

    @MainActor
    private func jumpToBottom(_ proxy: ScrollViewProxy, animated: Bool) async {
        suppressBottomGeometryUntil = Date().addingTimeInterval(0.35)
        userPinnedToBottom = true
        unreadWhileReading = 0
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
            }
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        userPinnedToBottom = true
    }

    /// One row in the thread. Either a plain user/assistant/meta message, or
    // ChatItem + ToolPair now live in ClawdmeterShared (T1 extraction).
    // Views read `store.snapshot.items` directly — no per-render walk.

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No messages yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - A9 row construction
    //
    // Rendering of a single `ChatItem` row was lifted into
    // `ChatItemRowView` (and its streaming-tail twin
    // `StreamingMessageView`) in `ChatItemRowView.swift`. The helpers
    // below build the value-typed payload + closure surface those
    // views need, projecting the parent's `@State` / `@ObservedObject`
    // dependencies into a flat snapshot the row can compare via `==`.
    //
    // The streaming tail is the LAST item in `messagesSlice.items`
    // when `liveStatusSlice.currentTurnState == .streaming`. We
    // surface its id once per body pass (see `streamingTailItemId`
    // below) and route the matching row through `StreamingMessageView`
    // so its body invalidations land under a distinct counter label.

    /// The id of the actively-streaming row, if any. `nil` when the
    /// turn is idle or completed — i.e., when no row should be
    /// treated specially.
    ///
    /// Computed once per parent body pass so we don't re-walk
    /// `items` per row. Cheap: `items.last?.id` is O(1), and
    /// `currentTurnState` is a plain enum read off the slice.
    private var streamingTailItemId: String? {
        guard liveStatusSlice.currentTurnState == .streaming else { return nil }
        return messagesSlice.items.last?.id
    }

    /// Build the SwiftUI view for one row. Returns either a
    /// `StreamingMessageView` (the tail row during an active turn)
    /// or a `ChatItemRowView` (everything else). Both delegate to
    /// the same `ChatItemRowContent` so visual presentation is
    /// identical.
    @ViewBuilder
    private func rowView(for item: ChatItem, streamingTailId: String?) -> some View {
        let payload = makeRowPayload(item: item, isStreamingTail: item.id == streamingTailId)
        let actions = rowActions
        if item.id == streamingTailId {
            StreamingMessageView(payload: payload, actions: actions)
        } else {
            ChatItemRowView(payload: payload, actions: actions)
        }
    }

    @ViewBuilder
    private func collapsedTurnView(_ turn: TranscriptTurn, streamingTailId: String?) -> some View {
        if turn.prompt == nil {
            ForEach(turn.visibleItems) { item in
                rowView(for: item, streamingTailId: streamingTailId)
                    .id(item.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(turnPromptItems(turn)) { item in
                    rowView(for: item, streamingTailId: streamingTailId)
                        .id(item.id)
                }
                collapsedDisclosureRow(turn)
                    .id("\(turn.id):disclosure")
                if turn.hasCollapsedContent, expanded.contains(turn.id) {
                    ForEach(turn.hiddenItems) { item in
                        rowView(for: item, streamingTailId: streamingTailId)
                            .id(item.id)
                    }
                }
                ForEach(turnFinalItems(turn)) { item in
                    rowView(for: item, streamingTailId: streamingTailId)
                        .id(item.id)
                }
                turnChipStrip(turn)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func turnPromptItems(_ turn: TranscriptTurn) -> [ChatItem] {
        guard let promptId = turn.prompt?.id else { return [] }
        return turn.visibleItems.filter { item in
            if case .message(let message) = item { return message.id == promptId }
            return false
        }
    }

    private func turnFinalItems(_ turn: TranscriptTurn) -> [ChatItem] {
        let promptId = turn.prompt?.id
        guard let finalId = turn.finalAssistant?.id, finalId != promptId else {
            return turn.visibleItems.filter { item in
                if case .message(let message) = item { return message.id != promptId }
                return true
            }
        }
        return turn.visibleItems.filter { item in
            if case .message(let message) = item { return message.id != promptId }
            return true
        }
    }

    @ViewBuilder
    private func collapsedDisclosureRow(_ turn: TranscriptTurn) -> some View {
        let isOpen = expanded.contains(turn.id)
        if turn.hasCollapsedContent {
            Button {
                if isOpen {
                    expanded.remove(turn.id)
                } else {
                    expanded.insert(turn.id)
                }
            } label: {
                collapsedDisclosureLabel(
                    turn,
                    icon: isOpen ? "chevron.down" : "chevron.right"
                )
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Collapse hidden transcript rows" : "Show hidden transcript rows")
        } else {
            collapsedDisclosureLabel(turn, icon: "clock")
                .help(turn.summary.disclosureLabel)
        }
    }

    private func collapsedDisclosureLabel(_ turn: TranscriptTurn, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(t.fg4)
                .frame(width: 10)
            Text(turn.summary.disclosureLabel)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg3)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(t.hair2, in: Capsule(style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func turnChipStrip(_ turn: TranscriptTurn) -> some View {
        let artifacts = turn.outputArtifacts
        let files = turn.editedFiles
        if !artifacts.isEmpty || !files.isEmpty {
            HStack(spacing: 8) {
                ForEach(artifacts.prefix(6)) { artifact in
                    Button {
                        openTranscriptArtifact(artifact)
                    } label: {
                        transcriptChip(
                            icon: iconName(for: artifact.kind),
                            title: artifact.filename,
                            tint: artifact.kind == .markdown ? t.accent : t.fg3
                        )
                    }
                    .buttonStyle(.plain)
                    .help(helpText(for: artifact))
                }
                ForEach(files.prefix(6)) { file in
                    transcriptChip(
                        icon: "pencil.and.scribble",
                        title: "\(file.basename) \(editDeltaLabel(file))",
                        tint: SessionsV2Theme.success
                    )
                    .help(file.filePath)
                }
            }
            .padding(.leading, 38)
            .padding(.top, 2)
        }
    }

    private func transcriptChip(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(t.hair2, in: Capsule(style: .continuous))
    }

    /// Project the parent's observed state into a value-typed
    /// payload the row view can compare via `==`. Building this once
    /// per row per body pass is cheap — every field is either a
    /// direct property read or a small dict subscript.
    private func makeRowPayload(item: ChatItem, isStreamingTail: Bool) -> ChatItemRowPayload {
        let isBookmarked: Bool
        let highlight: ChatItemRowPayload.HighlightState
        switch item {
        case .message(let m):
            isBookmarked = presentationStore.snapshot.messageBookmarks[session.id]?.contains(m.id) == true
            highlight = highlightState(for: m)
        case .toolRun:
            isBookmarked = false
            highlight = .none
        }

        // Project per-row tool-run / pair expansion state. Restricting
        // to keys we care about keeps the row's `==` cheap and means
        // toggling an unrelated row's disclosure doesn't bump this
        // row's equality fingerprint.
        let isToolRunOpen: Bool
        let pairsOpen: [String: Bool]
        if case .toolRun(let runId, let pairs) = item {
            isToolRunOpen = expanded.contains("run:\(runId)")
            var open: [String: Bool] = [:]
            for pair in pairs {
                open[pair.id] = expanded.contains("pair:\(pair.id)")
            }
            pairsOpen = open
        } else {
            isToolRunOpen = false
            pairsOpen = [:]
        }

        // AskUserQuestion selections — only the entries that belong
        // to this row's tool pairs. Same per-row narrowing as above.
        var askForRow: [String: [String: Set<String>]] = [:]
        if case .toolRun(_, let pairs) = item {
            for pair in pairs where pair.call.askUserQuestion != nil {
                if let sel = askUserQuestionSelections[pair.id] {
                    askForRow[pair.id] = sel
                }
            }
        }

        return ChatItemRowPayload(
            item: item,
            density: density,
            isBookmarked: isBookmarked,
            highlight: highlight,
            providerGlyph: session.agent.tahoeProvider,
            repoRoot: transcriptPathRoot,
            syntaxTheme: presentationStore.snapshot.syntaxTheme,
            isToolRunOpen: isToolRunOpen,
            toolPairsOpen: pairsOpen,
            askSelections: askForRow,
            isStreamingTail: isStreamingTail
        )
    }

    /// Closures the row fires for user interactions. We bind to the
    /// `@State` projections (`$expanded`, `$askUserQuestionSelections`)
    /// via local Bindings captured by the closures — Bindings are
    /// reference-stable wrappers around the @State storage, so the
    /// closure can mutate the state without itself being a mutating
    /// function. Same pattern SwiftUI uses everywhere for "set my
    /// state from a child view's action."
    ///
    /// The closures themselves are reference-stable across body re-
    /// evals (no @State observed inside them), so they're SAFE to
    /// exclude from `ChatItemRowView`'s `==` — and we MUST exclude
    /// them, otherwise the row would never short-circuit body
    /// re-evaluation.
    private var rowActions: ChatItemRowActions {
        let expandedBinding = $expanded
        let askBinding = $askUserQuestionSelections
        let presentationStore = self.presentationStore
        let sessionId = session.id
        let session = self.session
        let model = self.model
        return ChatItemRowActions(
            onToggleToolRun: { runId, shouldOpen in
                let key = "run:\(runId)"
                if shouldOpen {
                    expandedBinding.wrappedValue.insert(key)
                } else {
                    expandedBinding.wrappedValue.remove(key)
                }
            },
            onToggleToolPair: { pairId, shouldOpen in
                let key = "pair:\(pairId)"
                if shouldOpen {
                    expandedBinding.wrappedValue.insert(key)
                } else {
                    expandedBinding.wrappedValue.remove(key)
                }
            },
            onUpdateAskSelections: { pairId, sel in
                askBinding.wrappedValue[pairId] = sel
            },
            onAnswerAsk: { answer in
                Self.sendAnswerToSession(answer, sessionId: sessionId)
            },
            onCopy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            onQuoteReply: { body in
                let quoted = body
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                ComposerInsertionInbox.shared.enqueue(text: "\(quoted)\n\n", autoSend: false)
            },
            onToggleBookmark: { messageId in
                try? presentationStore.toggleMessageBookmark(sessionId: sessionId, messageId: messageId)
            },
            onOpenMarkdownDocument: { path in
                model.openWorkspaceDocumentTab(from: session, path: path)
            }
        )
    }

    /// Project the find-bar highlight state for a message to one of
    /// three discrete cases. Pre-computed once per body pass so the
    /// row's `==` doesn't have to walk the full match array.
    private func highlightState(for msg: SessionChatStore.ChatMessage) -> ChatItemRowPayload.HighlightState {
        let result = findResult
        guard !result.matchedIds.isEmpty,
              result.matchedIds.contains(msg.id)
        else { return .none }
        if let selectedMatchIndex,
           result.matches.indices.contains(selectedMatchIndex),
           result.matches[selectedMatchIndex].id == msg.id {
            return .selectedMatch
        }
        return .match
    }

    private var transcriptPathRoot: URL? {
        for raw in [session.runtimeCwd, session.worktreePath, session.repoKey] {
            guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            if path.hasPrefix("/") || path.hasPrefix("~") {
                return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            }
        }
        return nil
    }

    private func openTranscriptArtifact(_ artifact: TranscriptOutputArtifact) {
        if artifact.kind == .markdown {
            model.openWorkspaceDocumentTab(from: session, path: artifact.path)
            return
        }
        guard let url = resolvedTranscriptArtifactURL(artifact.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func resolvedTranscriptArtifactURL(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if let root = transcriptPathRoot {
            return root.appendingPathComponent(trimmed)
        }
        return URL(fileURLWithPath: trimmed)
    }

    private func helpText(for artifact: TranscriptOutputArtifact) -> String {
        switch artifact.kind {
        case .markdown:
            return "Open Markdown document in Code tab"
        case .html, .image, .pdf, .document, .spreadsheet, .presentation, .media, .archive, .data:
            return "Open \(artifact.path)"
        }
    }

    private func iconName(for kind: TranscriptArtifactKind) -> String {
        switch kind {
        case .markdown: return "doc.richtext"
        case .html: return "safari"
        case .image: return "photo"
        case .pdf: return "doc.text.magnifyingglass"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .media: return "play.rectangle"
        case .archive: return "archivebox"
        case .data: return "tablecells.badge.ellipsis"
        }
    }

    private func editDeltaLabel(_ file: TranscriptEditedFile) -> String {
        let additions = file.additions > 0 ? "+\(file.additions)" : ""
        let deletions = file.deletions > 0 ? "-\(file.deletions)" : ""
        return [additions, deletions].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// v0.5.6 — fire-and-forget answer send for AskUserQuestion. Mirrors
    /// the existing MacComposerSender path used by the main composer;
    /// loopback HTTP to the local daemon's `/sessions/:id/send`, which
    /// routes through the same rate-limit + audit-log path as a typed
    /// prompt.
    ///
    /// Static so the row's action closure can call it without holding
    /// a reference back to `ChatThreadScroll` — the closure captures
    /// only `sessionId: UUID`, a value type.
    private static func sendAnswerToSession(_ answer: String, sessionId: UUID) {
        guard !answer.isEmpty,
              let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort else { return }
        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        Task {
            try? await sender.send(sessionId: sessionId, body: answer, asFollowUp: true)
        }
    }
}

// `CheckpointRestoreSheet` lives in `CheckpointRestoreSheet.swift`
// (A6 foundation extraction).
//
// `ReviewPaneGutter` lives in `ReviewPaneGutter.swift`,
// `TahoeHairline` lives in `TahoeHairline.swift`, and
// `QuietDisclosure` lives in `QuietDisclosure.swift`
// (A6 foundation extraction).

// MARK: - Review pane (right)

private struct ReviewPane: View {
    let session: AgentSession
    let chatStore: SessionChatStore?
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
    @ObservedObject var presentationStore: SessionPresentationStore
    @Binding var selectedTab: WorkbenchPaneTab
    let onClose: () -> Void
    let onApprove: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            TahoeHairline()
            tabContent
        }
        .background(Color.clear)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Self.primaryTabs) { tab in
                tabChip(tab)
            }
        }
        .contextMenu {
            Button {
                selectedTab = .artifacts
            } label: {
                Label("Artifacts", systemImage: WorkbenchPaneTab.artifacts.systemImage)
            }
            Button {
                selectedTab = .browser
            } label: {
                Label("Browser", systemImage: WorkbenchPaneTab.browser.systemImage)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private static let primaryTabs: [WorkbenchPaneTab] = [.plan, .diff, .sources, .pr, .terminal]

    private func tabChip(_ tab: WorkbenchPaneTab) -> some View {
        let isSelected = (selectedTab == tab)
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(tabLabel(tab))
                    .font(TahoeFont.body(11.5, weight: isSelected ? .bold : .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? t.fg : t.fg3)
            .background(isSelected ? (t.dark ? Color.white.opacity(0.10) : Color.white) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: isSelected ? Color.black.opacity(0.10) : .clear, radius: 2, x: 0, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? t.hairline : .clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tabLabel(_ tab: WorkbenchPaneTab) -> String {
        tab == .terminal ? "Term" : tab.rawValue
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .plan:
            TahoeReviewPlanPane(
                pendingPlanText: session.planText,
                approvedPlanText: session.approvedPlanText,
                chatStore: chatStore
            )
        case .diff:
            TahoeDiffPreviewPane(
                sessionId: session.id,
                repoCwd: session.effectiveCwd,
                presentationStore: presentationStore
            )
        case .sources:
            TahoeSourcesPreviewPane(chatStore: chatStore)
        case .artifacts:
            TahoeReviewContentShell(title: "Artifacts", icon: "doc", padded: false) {
                if let chatStore {
                    ArtifactsPane(session: session, chatStore: chatStore)
                } else {
                    placeholder(text: "Waiting for agent JSONL…")
                }
            }
        case .browser:
            InAppBrowser(session: session, model: model, workbenchState: workbenchState)
        case .pr:
            TahoePRCompactPane(
                coordinator: model.prCoordinator(for: session),
                chatStore: chatStore,
                onBeforeMerge: {
                    await createCheckpoint(summary: "Before PR merge")
                }
            )
        case .terminal:
            // Real PTY-backed terminal pointed at the session's repo.
            // Reuses the same `TerminalTabContainer` (G12 multi-pane)
            // wired to the daemon's WS port + bearer token, so the user
            // gets a live shell instead of an echoed bash-tool summary.
            terminalTab
        }
    }

    /// Live tmux terminal in the review pane. Reuses the same
    /// `TerminalTabContainer` that the Cmd+T overlay shows, but inline
    /// so the user can keep the chat and the raw shell side-by-side
    /// without juggling a sheet.
    @ViewBuilder
    private var terminalTab: some View {
        if let runtime = AppDelegate.runtime,
           let port = runtime.agentControlServer.boundWsPort {
            TerminalTabContainer(
                session: session,
                model: model,
                wsPort: Int(port),
                token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? "")
            )
        } else {
            placeholder(text: "Daemon offline — restart Clawdmeter.")
        }
    }

    private func placeholder(text: String) -> some View {
        VStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createCheckpoint(summary: String) async -> Bool {
        let service = CheckpointService()
        do {
            let checkpoint = try await service.createCheckpoint(session: session, summary: summary)
            workbenchState.recordCheckpoint(checkpoint)
            return true
        } catch {
            return false
        }
    }

    private var paneBg: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.95, green: 0.95, blue: 0.95)
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}

private struct TahoeReviewContentShell<Content: View>: View {
    @Environment(\.tahoe) private var t
    let title: String
    let icon: String
    let padded: Bool
    let content: Content

    init(title: String, icon: String, padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.padded = padded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                TahoeIcon(icon, size: 12)
                    .foregroundStyle(t.fg3)
                Text(title)
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(t.fg3)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            TahoeHairline()
            content
                .padding(padded ? 16 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TahoeReviewPlanPane: View {
    @Environment(\.tahoe) private var t
    let pendingPlanText: String?
    let approvedPlanText: String?
    let chatStore: SessionChatStore?

    private var explicitPlanText: String? {
        for candidate in [pendingPlanText, approvedPlanText] {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else { continue }
            return trimmed
        }
        return nil
    }

    private var steps: [String] {
        if let planText = explicitPlanText {
            return TahoePlanParser.steps(from: planText, cap: 8)
        }
        return chatStore?.snapshot.codexTodos.prefix(8).map(\.text) ?? []
    }

    private var emptyCopy: String {
        "No approved plan file has been captured for this session."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Plan · \(steps.count) steps")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(t.fg3)
                    .padding(.bottom, 10)
                if steps.isEmpty {
                    TahoeEmptyReviewState(icon: "doc", title: "No approved plan", body: emptyCopy)
                } else {
                    TahoeReviewPlanRows(steps: steps)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct TahoeReviewPlanRows: View {
    @Environment(\.tahoe) private var t
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == 0 ? t.accentAlpha(0.18) : t.hair2)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Text("\(index + 1)")
                                .font(TahoeFont.mono(11, weight: .bold))
                                .foregroundStyle(index == 0 ? t.accent : t.fg2)
                        )
                    Text(step)
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
                if index < steps.count - 1 {
                    TahoeHairline()
                }
            }
        }
    }
}

private struct TahoeDiffPreviewPane: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessionId: UUID
    let repoCwd: String
    @ObservedObject var presentationStore: SessionPresentationStore
    @State private var lines: [DiffLine] = []
    // A12 — derived indices built once per `load()` so the hover summary
    // (diffSummary), mark-all-viewed (contentHash), file-list (changedPaths),
    // and intra-line highlighting (nearestOppositeLine) read O(1)/bounded
    // lookups instead of re-scanning the whole `lines` array per file/row.
    @State private var index = DiffIndex()
    @State private var isLoading = false
    @State private var focusedPath: String?
    @State private var hoveredPath: String?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                diffToolbar(proxy: proxy)
                TahoeHairline()
                ScrollView([.vertical, .horizontal]) {
                    // A12 — virtualized rows. LazyVStack only materializes
                    // rows in view, so 50k-line diffs no longer force
                    // SwiftUI to lay out every line up front. Critical
                    // for the <500ms acceptance budget.
                    LazyVStack(alignment: .leading, spacing: 0) {
                    if isLoading {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Loading diff...")
                                .font(TahoeFont.body(11.5))
                                .foregroundStyle(t.fg3)
                        }
                        .padding(16)
                    } else if lines.isEmpty {
                        TahoeEmptyReviewState(icon: "diff", title: "No local diff", body: "The worktree has no visible git diff.")
                            .frame(minWidth: 330)
                            .padding(16)
                    } else {
                        ForEach(visibleLines) { line in
                            diffLineRow(line)
                        }
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(t.dark ? Color.black.opacity(0.18) : Color.black.opacity(0.03))
        }
        .task(id: repoCwd) { await load() }
    }

    private func diffToolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Text("\(changedPaths.count) files")
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg3)
            Text("\(unviewedPaths.count) unviewed")
                .font(TahoeFont.body(11))
                .foregroundStyle(unviewedPaths.isEmpty ? t.fg4 : t.accent)
            Spacer()
            Picker("Diff layout", selection: diffModeBinding) {
                ForEach(DiffDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 132)
            .labelsHidden()
            Button("Next") { jumpToNextUnviewed(proxy: proxy) }
                .font(TahoeFont.body(11, weight: .semibold))
                .buttonStyle(.plain)
                .disabled(unviewedPaths.isEmpty)
                .help("Jump to the next unviewed file")
            Button("Mark all viewed") { markAllViewed() }
                .font(TahoeFont.body(11, weight: .semibold))
                .buttonStyle(.plain)
                .disabled(changedPaths.isEmpty)
                .help("Persist viewed state for all changed files")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func diffLineRow(_ line: DiffLine) -> some View {
        // A12 — use the precomputed header flag + path instead of
        // re-parsing the line text per rendered row.
        if line.isFileHeader, let path = line.path {
            let viewed = isViewed(path)
            let focused = focusedPath == path
            HStack(spacing: 8) {
                Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewed ? .green : t.fg3)
                Text(path)
                    .font(TahoeFont.mono(11.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .textSelection(.enabled)
                if let disposition = presentationStore.snapshot.fileReviewDispositions[sessionId]?[path] {
                    Text(disposition.label)
                        .font(TahoeFont.body(10, weight: .bold))
                        .foregroundStyle(disposition == .approved ? .green : .orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(t.hair2, in: Capsule(style: .continuous))
                }
                Spacer()
                if hoveredPath == path {
                    Text(diffSummary(for: path))
                        .font(TahoeFont.mono(10))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                }
                Button("Mark reviewed") {
                    try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: .approved)
                }
                .font(TahoeFont.body(10.5, weight: .semibold))
                .buttonStyle(.plain)
                Button("Flag changes") {
                    try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: .changesRequested)
                }
                .font(TahoeFont.body(10.5, weight: .semibold))
                .buttonStyle(.plain)
                Button(viewed ? "Viewed" : "Mark viewed") {
                    markViewed(path)
                }
                .font(TahoeFont.body(10.5, weight: .semibold))
                .buttonStyle(.plain)
                .disabled(viewed)
                Button("Open") { open(path) }
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .buttonStyle(.plain)
            }
            .id(Self.headerID(for: path))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(focused ? t.accentAlpha(0.18) : (viewed ? t.hair2.opacity(0.45) : t.accentAlpha(0.10)))
            .onHover { inside in
                hoveredPath = inside ? path : (hoveredPath == path ? nil : hoveredPath)
            }
            .contextMenu {
                Button("Mark viewed") { markViewed(path) }.disabled(viewed)
                Button("Mark file reviewed") { try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: .approved) }
                Button("Flag file changes") { try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: .changesRequested) }
                Button("Clear review disposition") { try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: nil) }
                Button("Copy path") { copy(path) }
                Button("Open file") { open(path) }
            }
        } else if line.kind == .hunk, let hunkId = line.hunkId {
            let collapsed = isHunkCollapsed(hunkId)
            HStack(spacing: 8) {
                Button {
                    try? presentationStore.setDiffHunkCollapsed(sessionId: sessionId, hunkId: hunkId, collapsed: !collapsed)
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                Text(line.text)
                    .font(TahoeFont.mono(11.5, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .textSelection(.enabled)
                Spacer()
                Button("Explain") {
                    ComposerInsertionInbox.shared.enqueue(text: "Explain this diff hunk:\n\n```diff\n\(hunkText(hunkId))\n```\n", autoSend: false)
                }
                .font(TahoeFont.body(10.5, weight: .semibold))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(t.hair2)
            .contextMenu {
                Button(collapsed ? "Expand hunk" : "Collapse hunk") {
                    try? presentationStore.setDiffHunkCollapsed(sessionId: sessionId, hunkId: hunkId, collapsed: !collapsed)
                }
                Button("Copy hunk") { copy(hunkText(hunkId)) }
                Button("Explain hunk") {
                    ComposerInsertionInbox.shared.enqueue(text: "Explain this diff hunk:\n\n```diff\n\(hunkText(hunkId))\n```\n", autoSend: false)
                }
            }
        } else if presentationStore.snapshot.diffDisplayMode == .split {
            splitDiffLineRow(line)
        } else {
            HStack(spacing: 0) {
                Text(line.sign)
                    .frame(width: 14, alignment: .leading)
                    .opacity(0.75)
                diffContentView(line)
            }
            .font(TahoeFont.mono(11.5))
            .foregroundStyle(diffForeground(for: line))
            .padding(.horizontal, 16)
            .padding(.vertical, 1)
            .background(diffBackground(for: line))
            .contextMenu {
                Button("Copy line") { copy(line.text) }
                Button("Explain hunk") {
                    ComposerInsertionInbox.shared.enqueue(text: "Explain this diff hunk:\n\n```diff\n\(line.text)\n```\n", autoSend: false)
                }
            }
        }
    }

    private func splitDiffLineRow(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            diffSplitCell(line, shows: line.kind == .del || line.kind == .context, isAddition: false)
            diffSplitCell(line, shows: line.kind == .add || line.kind == .context, isAddition: true)
        }
        .contextMenu {
            Button("Copy line") { copy(line.text) }
            Button("Explain line") {
                ComposerInsertionInbox.shared.enqueue(text: "Explain this diff line:\n\n```diff\n\(line.text)\n```\n", autoSend: false)
            }
        }
    }

    private func diffSplitCell(_ line: DiffLine, shows: Bool, isAddition: Bool) -> some View {
        Group {
            if shows {
                diffContentView(line)
            } else {
                Text("")
            }
        }
        .font(TahoeFont.mono(11.5))
        .foregroundStyle((line.kind == .add && isAddition) ? additionForeground : (line.kind == .del && !isAddition) ? removalForeground : diffForeground(for: line))
        .frame(width: 420, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background((line.kind == .add && isAddition) ? additionBackground : (line.kind == .del && !isAddition) ? removalBackground : Color.clear)
    }

    @ViewBuilder
    private func diffContentView(_ line: DiffLine) -> some View {
        if let segments = intraLineSegments(for: line) {
            HStack(spacing: 0) {
                Text(segments.prefix)
                Text(segments.changed)
                    .background(intraLineHighlight(for: line), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(segments.suffix)
            }
            .textSelection(.enabled)
        } else {
            Text(line.displayText)
                .textSelection(.enabled)
        }
    }

    private var syntaxTheme: CodeSyntaxTheme {
        presentationStore.snapshot.syntaxTheme
    }

    private var additionForeground: Color {
        switch syntaxTheme {
        case .tahoe: return Color(.sRGB, red: 0.32, green: 0.92, blue: 0.66)
        case .graphite: return t.dark ? Color(.sRGB, red: 0.76, green: 0.88, blue: 0.76) : Color(.sRGB, red: 0.10, green: 0.45, blue: 0.20)
        case .xcode: return t.dark ? Color(.sRGB, red: 0.46, green: 0.95, blue: 0.60) : Color(.sRGB, red: 0.03, green: 0.45, blue: 0.18)
        }
    }

    private var removalForeground: Color {
        switch syntaxTheme {
        case .tahoe: return Color(.sRGB, red: 1.0, green: 0.48, blue: 0.54)
        case .graphite: return t.dark ? Color(.sRGB, red: 0.92, green: 0.72, blue: 0.72) : Color(.sRGB, red: 0.58, green: 0.16, blue: 0.18)
        case .xcode: return t.dark ? Color(.sRGB, red: 1.0, green: 0.50, blue: 0.60) : Color(.sRGB, red: 0.70, green: 0.04, blue: 0.16)
        }
    }

    private var additionBackground: Color {
        switch syntaxTheme {
        case .tahoe: return Color.green.opacity(t.dark ? 0.16 : 0.10)
        case .graphite: return Color.gray.opacity(t.dark ? 0.18 : 0.12)
        case .xcode: return Color(.sRGB, red: 0.18, green: 0.72, blue: 0.36, opacity: t.dark ? 0.18 : 0.12)
        }
    }

    private var removalBackground: Color {
        switch syntaxTheme {
        case .tahoe: return Color.red.opacity(t.dark ? 0.16 : 0.10)
        case .graphite: return Color.gray.opacity(t.dark ? 0.16 : 0.10)
        case .xcode: return Color(.sRGB, red: 0.86, green: 0.12, blue: 0.20, opacity: t.dark ? 0.18 : 0.12)
        }
    }

    private func diffForeground(for line: DiffLine) -> Color {
        switch line.kind {
        case .add: return additionForeground
        case .del: return removalForeground
        case .hunk, .meta: return t.fg3
        case .context:
            switch syntaxTheme {
            case .tahoe: return t.dark ? Color(.sRGB, red: 0.78, green: 0.90, blue: 0.90) : Color(.sRGB, red: 0.14, green: 0.26, blue: 0.28)
            case .graphite: return t.fg2
            case .xcode: return t.dark ? Color(.sRGB, red: 0.74, green: 0.80, blue: 0.94) : Color(.sRGB, red: 0.08, green: 0.18, blue: 0.38)
            }
        }
    }

    private func diffBackground(for line: DiffLine) -> Color {
        switch line.kind {
        case .add: return additionBackground
        case .del: return removalBackground
        case .hunk: return t.hair2
        default:
            switch syntaxTheme {
            case .tahoe: return t.dark ? Color(.sRGB, red: 0.05, green: 0.09, blue: 0.10, opacity: 0.35) : Color(.sRGB, red: 0.90, green: 0.97, blue: 0.98, opacity: 0.45)
            case .graphite: return t.dark ? Color.white.opacity(0.025) : Color.black.opacity(0.025)
            case .xcode: return t.dark ? Color(.sRGB, red: 0.05, green: 0.06, blue: 0.10, opacity: 0.42) : Color(.sRGB, red: 0.95, green: 0.98, blue: 1.0, opacity: 0.50)
            }
        }
    }

    private func intraLineHighlight(for line: DiffLine) -> Color {
        switch line.kind {
        case .add: return additionForeground.opacity(0.28)
        case .del: return removalForeground.opacity(0.28)
        default: return t.accentAlpha(0.18)
        }
    }

    private func intraLineSegments(for line: DiffLine) -> (prefix: String, changed: String, suffix: String)? {
        guard line.kind == .add || line.kind == .del,
              let counterpart = nearestOppositeLine(for: line)
        else { return nil }
        let old = Array(line.displayText)
        let other = Array(counterpart.displayText)
        guard !old.isEmpty, !other.isEmpty else { return nil }

        var prefixCount = 0
        while prefixCount < old.count,
              prefixCount < other.count,
              old[prefixCount] == other[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount + prefixCount < old.count,
              suffixCount + prefixCount < other.count,
              old[old.count - 1 - suffixCount] == other[other.count - 1 - suffixCount] {
            suffixCount += 1
        }

        let changedEnd = max(prefixCount, old.count - suffixCount)
        guard changedEnd > prefixCount else { return nil }
        return (
            String(old[..<prefixCount]),
            String(old[prefixCount..<changedEnd]),
            suffixCount == 0 ? "" : String(old[(old.count - suffixCount)...])
        )
    }

    private func nearestOppositeLine(for line: DiffLine) -> DiffLine? {
        // A12 — bounded lookup over only this hunk's add/del lines (built
        // once per load) instead of filtering the entire `lines` array on
        // every rendered add/del row.
        guard let hunkId = line.hunkId else { return nil }
        let opposite: DiffLine.Kind = line.kind == .add ? .del : .add
        let candidates = opposite == .add ? index.hunkAdds[hunkId] : index.hunkDels[hunkId]
        return candidates?
            .filter { abs($0.index - line.index) <= 6 }
            .min { abs($0.index - line.index) < abs($1.index - line.index) }
    }

    private func diffSummary(for path: String) -> String {
        // A12 — precomputed once per load; hovering a file row no longer
        // re-walks the whole diff to recount hunks/additions/removals.
        index.pathSummaries[path] ?? ""
    }

    @MainActor
    private func load() async {
        isLoading = true
        let cwd = repoCwd
        let (loaded, builtIndex) = await Task.detached(priority: .utility) { () -> ([DiffLine], DiffIndex) in
            let lines = Self.loadGitDiff(cwd: cwd)
            // Build the derived indices on the same background hop so the
            // O(files × lines) summary/block/opposite-line work happens
            // once off-main, not per-render on the main actor.
            return (lines, Self.buildIndex(lines))
        }.value
        lines = loaded
        index = builtIndex
        isLoading = false
    }

    nonisolated private static func loadGitDiff(cwd: String) -> [DiffLine] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "diff", "--no-ext-diff", "--unified=3", "--"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            // A12 — annotate is the legacy classify-and-track-hunk-
            // path pass. It's a single linear walk (O(N)) but for a
            // 50k-line diff that's still ~50k String allocations +
            // ~50k DiffLine allocations on the hot path. We cache the
            // result keyed on the raw text so re-opening the pane
            // with an unchanged worktree skips the walk entirely.
            //
            // The shared `ParsedDiffCache` keeps the structured
            // representation around for any future workbench renderer
            // that wants to render directly off `ParsedDiff`; we keep
            // a parallel in-process `[DiffLine]` cache for the legacy
            // renderer here so this PR doesn't have to rewrite the
            // split-view + intra-line + hunk-collapse machinery.
            _ = ParsedDiffCache.shared.parsed(input: text)
            return Self.annotatedDiffLineCache.lookupOrCompute(text: text) {
                let rawLines = text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                return annotate(rawLines)
            }
        } catch {
            return [DiffLine("Unable to load diff: \(error.localizedDescription)", index: 0, forcedKind: .meta)]
        }
    }

    nonisolated private static func annotate(_ rawLines: [String]) -> [DiffLine] {
        var currentPath: String?
        var currentHunk: String?
        return rawLines.enumerated().map { index, text in
            var isHeader = false
            if let path = path(fromDiffHeader: text) {
                currentPath = path
                currentHunk = nil
                isHeader = true
            } else if text.hasPrefix("@@") {
                currentHunk = "\(currentPath ?? "diff"):\(text)"
            }
            return DiffLine(text, index: index, hunkId: currentHunk, path: currentPath, isFileHeader: isHeader)
        }
    }

    private var visibleLines: [DiffLine] {
        var output: [DiffLine] = []
        output.reserveCapacity(lines.count)
        var skippingHunk: String?
        for line in lines {
            // A12 — precomputed header flag instead of re-parsing the line
            // text (hasPrefix + split) for every line on every body render.
            if line.isFileHeader {
                skippingHunk = nil
                output.append(line)
                continue
            }
            if line.kind == .hunk, let hunkId = line.hunkId {
                output.append(line)
                skippingHunk = isHunkCollapsed(hunkId) ? hunkId : nil
                continue
            }
            if let skippingHunk, line.hunkId == skippingHunk {
                continue
            }
            output.append(line)
        }
        return output
    }

    private var diffModeBinding: Binding<DiffDisplayMode> {
        Binding(
            get: { presentationStore.snapshot.diffDisplayMode },
            set: { try? presentationStore.setDiffDisplayMode($0) }
        )
    }

    private var changedPaths: [String] {
        // A12 — read the precomputed ordered path list instead of
        // re-scanning + re-parsing every line on each access.
        index.orderedPaths
    }

    private var unviewedPaths: [String] {
        changedPaths.filter { !isViewed($0) }
    }

    private func isViewed(_ path: String) -> Bool {
        let hash = contentHash(for: path)
        return presentationStore.snapshot.viewedFiles[sessionId]?.contains {
            $0.path == path && $0.contentHash == hash
        } == true
    }

    private func markViewed(_ path: String) {
        try? presentationStore.recordViewedFile(sessionId: sessionId, path: path, contentHash: contentHash(for: path))
    }

    private func markAllViewed() {
        for path in changedPaths {
            markViewed(path)
        }
    }

    private func jumpToNextUnviewed(proxy: ScrollViewProxy) {
        guard let path = unviewedPaths.first else { return }
        focusedPath = path
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.headerID(for: path), anchor: .top)
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.headerID(for: path), anchor: .top)
            }
        }
    }

    private func contentHash(for path: String) -> String {
        let text = diffBlock(for: path).joined(separator: "\n")
        return ClawdmeterTextUtilities.stableContentHash(text)
    }

    private func isHunkCollapsed(_ hunkId: String) -> Bool {
        presentationStore.snapshot.collapsedDiffHunks[sessionId]?.contains(hunkId) == true
    }

    private func hunkText(_ hunkId: String) -> String {
        lines.filter { $0.hunkId == hunkId }.map(\.text).joined(separator: "\n")
    }

    private func diffBlock(for path: String) -> [String] {
        // A12 — precomputed per-path block; avoids an O(lines) walk +
        // per-line `path(fromDiffHeader:)` reparse on every call (the
        // hover summary + mark-all-viewed hot paths hit this per file).
        index.pathBlocks[path] ?? []
    }

    private func open(_ path: String) {
        try? presentationStore.recordPathAction(path)
        let url = URL(fileURLWithPath: repoCwd).appendingPathComponent(path)
        NSWorkspace.shared.open(url)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    nonisolated private static func path(fromDiffHeader line: String) -> String? {
        guard line.hasPrefix("diff --git ") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        let raw = String(parts[3])
        if raw.hasPrefix("b/") { return String(raw.dropFirst(2)) }
        return raw
    }

    nonisolated private static func headerID(for path: String) -> String {
        "diff-header-\(path)"
    }

    private struct DiffLine: Identifiable {
        enum Kind { case meta, hunk, add, del, context }
        /// A12 — `index` is unique within a single load, so we can use
        /// it directly as `Identifiable.id`. The previous
        /// `"\(index)-\(text)"` formulation allocated a String per
        /// row on every layout pass — a 50k-line diff burned ~50k
        /// allocations + interpolation work just to compare identity.
        var id: Int { index }
        let text: String
        let index: Int
        let kind: Kind
        let hunkId: String?
        let path: String?
        // A12 — precomputed once in `annotate` so the hot-path body
        // checks ("is this row a `diff --git` file header?") are O(1)
        // field reads instead of re-running `path(fromDiffHeader:)`
        // (hasPrefix + split) per visible row on every layout pass.
        let isFileHeader: Bool

        init(_ text: String, index: Int, hunkId: String? = nil, path: String? = nil, isFileHeader: Bool = false, forcedKind: Kind? = nil) {
            self.text = text
            self.index = index
            self.hunkId = hunkId
            self.path = path
            self.isFileHeader = isFileHeader
            if let forcedKind {
                self.kind = forcedKind
            } else if text.hasPrefix("@@") {
                self.kind = .hunk
            } else if text.hasPrefix("+") && !text.hasPrefix("+++") {
                self.kind = .add
            } else if text.hasPrefix("-") && !text.hasPrefix("---") {
                self.kind = .del
            } else if text.hasPrefix("diff --git") || text.hasPrefix("+++") || text.hasPrefix("---") {
                self.kind = .meta
            } else {
                self.kind = .context
            }
        }

        var sign: String {
            switch kind {
            case .add: return "+"
            case .del: return "-"
            default: return ""
            }
        }

        var displayText: String {
            switch kind {
            case .add, .del:
                return text.isEmpty ? text : String(text.dropFirst())
            default:
                return text
            }
        }

        func foreground(_ t: TahoeTokens) -> Color {
            switch kind {
            case .add: return t.dark ? Color.green.opacity(0.86) : Color.green.opacity(0.72)
            case .del: return t.dark ? Color.red.opacity(0.86) : Color.red.opacity(0.74)
            case .hunk, .meta: return t.fg3
            case .context: return t.fg2
            }
        }

        func background(_ t: TahoeTokens) -> Color {
            switch kind {
            case .add: return Color.green.opacity(t.dark ? 0.16 : 0.10)
            case .del: return Color.red.opacity(t.dark ? 0.16 : 0.10)
            case .hunk: return t.hair2
            default: return .clear
            }
        }
    }

    /// A12 — derived view of `[DiffLine]` precomputed once per `load()`.
    /// Collapses the per-render O(files × lines) scans (hover summary,
    /// mark-all-viewed content hashing, file-list, intra-line opposite
    /// lookup) into single linear-build lookups so re-renders stay cheap.
    private struct DiffIndex {
        /// File paths in diff order (replaces the per-access scan in `changedPaths`).
        var orderedPaths: [String] = []
        /// path → raw line texts for that file's block (replaces `diffBlock`'s walk).
        var pathBlocks: [String: [String]] = [:]
        /// path → "N hunks · +A -D" summary (replaces `diffSummary`'s recount).
        var pathSummaries: [String: String] = [:]
        /// hunkId → its `.add` lines, in `index` order (bounded ±6 lookup in `nearestOppositeLine`).
        var hunkAdds: [String: [DiffLine]] = [:]
        /// hunkId → its `.del` lines, in `index` order.
        var hunkDels: [String: [DiffLine]] = [:]
    }

    nonisolated private static func buildIndex(_ lines: [DiffLine]) -> DiffIndex {
        var index = DiffIndex()
        var currentPath: String?
        for line in lines {
            if line.isFileHeader, let path = line.path {
                currentPath = path
                if index.pathBlocks[path] == nil {
                    index.orderedPaths.append(path)
                    index.pathBlocks[path] = []
                }
            }
            if let currentPath {
                index.pathBlocks[currentPath, default: []].append(line.text)
            }
            if let hunkId = line.hunkId {
                switch line.kind {
                case .add: index.hunkAdds[hunkId, default: []].append(line)
                case .del: index.hunkDels[hunkId, default: []].append(line)
                default: break
                }
            }
        }
        for (path, block) in index.pathBlocks {
            let additions = block.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let removals = block.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            let hunks = block.filter { $0.hasPrefix("@@") }.count
            index.pathSummaries[path] = "\(hunks) hunk\(hunks == 1 ? "" : "s") · +\(additions) -\(removals)"
        }
        return index
    }

    /// A12 — in-process cache for the legacy `[DiffLine]` shape this
    /// pane consumes. Mirrors the shared `ParsedDiffCache` but with a
    /// smaller capacity (each entry is a per-render data structure).
    ///
    /// Re-mounts of the diff pane (Cmd-tab back into the workbench,
    /// presentationStore changes that re-create the view) skip the
    /// linear annotate walk when the underlying `git diff` text
    /// hasn't changed.
    private final class DiffLineCache: @unchecked Sendable {
        private struct Key: Hashable {
            let textHash: String
        }
        private let lock = NSLock()
        private var storage: [Key: [DiffLine]] = [:]
        private var order: [Key] = []
        private let capacity = 8

        func lookupOrCompute(
            text: String,
            compute: () -> [DiffLine]
        ) -> [DiffLine] {
            let key = Key(textHash: UnifiedDiffParser.sha256Hex(text))
            lock.lock()
            if let cached = storage[key] {
                if let existing = order.firstIndex(of: key) {
                    order.remove(at: existing)
                }
                order.append(key)
                lock.unlock()
                return cached
            }
            lock.unlock()

            // Compute outside the lock — a 50k-line annotate is ~tens
            // of ms and we don't want concurrent diff-pane mounts to
            // serialize behind one another.
            let computed = compute()

            lock.lock()
            // A12 review fix — drop any prior recency entry for this
            // key before appending so concurrent misses (both threads
            // parsed, both reach this branch) don't leave duplicate
            // keys in `order`. Duplicates would let a later eviction
            // remove a still-warm entry from `storage`, forcing a
            // wasteful re-parse on the next lookup.
            if storage[key] != nil, let existing = order.firstIndex(of: key) {
                order.remove(at: existing)
            }
            storage[key] = computed
            order.append(key)
            while storage.count > capacity, let oldest = order.first {
                order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
            lock.unlock()
            return computed
        }
    }

    /// Process-lifetime cache. Diff-pane mounts are short-lived; a
    /// long-lived cache here means a Cmd-tab cycle hits warm data.
    private static let annotatedDiffLineCache = DiffLineCache()
}

private struct TahoeSourcesPreviewPane: View {
    @Environment(\.tahoe) private var t
    let chatStore: SessionChatStore?

    private var entries: [SourceEntry] {
        Array((chatStore?.snapshot.sourceEntries ?? []).prefix(14))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    TahoeEmptyReviewState(icon: "search", title: "No sources yet", body: "Files and URLs referenced by tools will appear here.")
                        .padding(16)
                } else {
                    ForEach(entries) { entry in
                        Button(action: { open(entry) }) {
                            HStack(alignment: .top, spacing: 10) {
                                TahoeIcon(entry.kind == .url ? "link" : "doc", size: 13)
                                    .foregroundStyle(t.accent)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                        .font(TahoeFont.mono(11.5))
                                        .foregroundStyle(t.fg)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(entry.kind == .url ? "Fetched URL" : "Referenced \(entry.count)x")
                                        .font(TahoeFont.body(11))
                                        .foregroundStyle(t.fg3)
                                }
                                Spacer(minLength: 6)
                                if entry.count > 1 {
                                    Text("×\(entry.count)")
                                        .font(TahoeFont.mono(10.5, weight: .bold))
                                        .foregroundStyle(t.fg3)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func open(_ entry: SourceEntry) {
        switch entry.kind {
        case .url:
            if let url = URL(string: entry.payload) {
                NSWorkspace.shared.open(url)
            }
        case .file:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.payload)])
        }
    }
}

private struct TahoePRCompactPane: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var coordinator: PRCoordinator
    let chatStore: SessionChatStore?
    let onBeforeMerge: (() async -> Bool)?
    @State private var localActionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let state = coordinator.snapshot {
                    Text(state.title)
                        .font(TahoeFont.body(13, weight: .bold))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(state.url.host() ?? "github.com") · #\(state.number) · \(state.state.lowercased())")
                        .font(TahoeFont.mono(11.5))
                        .foregroundStyle(t.fg3)
                        .contextMenu {
                            Button("Copy PR URL") { copy(state.url.absoluteString) }
                            Button("Copy PR Number") { copy("#\(state.number)") }
                        }

                    TahoeGlass(radius: 12, tone: .chip) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Checks")
                                .font(TahoeFont.body(11, weight: .semibold))
                                .foregroundStyle(t.fg3)
                                .padding(.bottom, 6)
                            prStatusRow("review", state.reviewState ?? "pending", state.reviewState == "APPROVED")
                            prStatusRow("ci", state.checksRollup ?? "unknown", state.checksRollup == "success")
                            prStatusRow("changes", "+\(state.additions) -\(state.deletions)", true)
                            prStatusRow("todos", todoGateLabel, todoGatePassed)
                            if !state.checks.isEmpty {
                                TahoeHair().padding(.vertical, 6)
                                ForEach(state.checks) { check in
                                    prCheckRow(check)
                                }
                            }
                        }
                        .padding(12)
                    }

                    Menu {
                        Button("Open on GitHub") { NSWorkspace.shared.open(state.url) }
                        Button("Open checks") { openChecks(state) }
                        Button("Open deployments") { openDeployments(state) }
                        Button("Copy URL") { copy(state.url.absoluteString) }
                        Button("Copy Number") { copy("#\(state.number)") }
                        Button("Rerun failed checks") { Task { await rerunFailedChecks(state) } }
                            .disabled(PRCoordinator.repoSlug(from: state.url) == nil || failedCheckRunIDs(state).isEmpty)
                        Button("Ask agent to fix checks") { enqueueFixChecksPrompt(state) }
                    } label: {
                        HStack(spacing: 6) {
                            TahoeIcon("pull", size: 12)
                            Text("PR Actions")
                                .font(TahoeFont.body(12, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .foregroundStyle(.white)

                    if state.state == "OPEN", coordinator.canUseDaemonActions {
                        HStack(spacing: 8) {
                            TahoeGhostButton(size: .m, action: { Task { await coordinator.approve() } }) {
                                Text("Approve")
                            }
                            TahoeGhostButton(size: .m, action: { enqueueReviewRequestPrompt(state) }) {
                                Text("Request changes")
                            }
                            TahoeGhostButton(size: .m, action: { Task { await merge(state) } }) {
                                Text(canMerge(state) ? "Merge" : "Merge blocked")
                            }
                            .disabled(!canMerge(state))
                            .help(todoGatePassed ? "Merge this PR" : "Open TODOs must be completed before merge")
                        }
                    }
                } else {
                    TahoeEmptyReviewState(icon: "pull", title: "No PR detected", body: "Paste a PR URL or let the agent create one.")
                    TextField("https://github.com/owner/repo/pull/123", text: $coordinator.manualURL)
                        .textFieldStyle(.roundedBorder)
                        .font(TahoeFont.mono(11.5))
                        .accessibilityLabel("Pull request URL")
                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .m, action: { coordinator.loadFromManualURL() }) {
                            Text("Load")
                        }
                        if coordinator.canUseDaemonActions {
                            TahoeGhostButton(size: .m, action: { Task { await coordinator.createPR() } }) {
                                TahoeIcon("pull", size: 11)
                                Text("Create PR")
                            }
                            TahoeGhostButton(size: .m, action: { enqueueDraftPRPrompt() }) {
                                TahoeIcon("doc", size: 11)
                                Text("Draft PR")
                            }
                        }
                    }
                }
                if coordinator.isRefreshing || coordinator.isMutating {
                    ProgressView().controlSize(.small)
                }
                if let err = coordinator.lastError ?? localActionError {
                    Text(err)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { coordinator.startWatching() }
        .onDisappear { coordinator.stopWatching() }
    }

    private func prStatusRow(_ name: String, _ status: String, _ passed: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(passed ? SessionsV2Theme.success : SessionsV2Theme.warn)
                .frame(width: 14, height: 14)
                .overlay {
                    if passed {
                        TahoeIcon("check", size: 8, weight: .bold).foregroundStyle(.white)
                    }
                }
            Text(name)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg)
            Spacer()
            Text(status)
                .font(TahoeFont.mono(11))
                .foregroundStyle(t.fg3)
        }
        .padding(.vertical, 6)
    }

    private func prCheckRow(_ check: PRCheckMirror) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(check.state == .success ? Color.green : (check.state == .failure ? Color.red : Color.yellow))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.name)
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                if let url = check.url {
                    Text(url)
                        .font(TahoeFont.mono(9.5))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(check.state.rawValue)
                .font(TahoeFont.mono(10.5))
                .foregroundStyle(t.fg3)
        }
        .padding(.vertical, 5)
        .contextMenu {
            if let raw = check.url, let url = URL(string: raw) {
                Button("Open check") { NSWorkspace.shared.open(url) }
            }
            Button("Copy check name") { copy(check.name) }
            if let runID = runID(from: check.url) {
                Button("Rerun this check") { Task { await rerunCheck(runID: runID, state: coordinator.snapshot) } }
            }
        }
    }

    private var todoGateLabel: String {
        let todos = chatStore?.snapshot.codexTodos ?? []
        guard !todos.isEmpty else { return "none" }
        let open = todos.filter { $0.status != "completed" }.count
        return open == 0 ? "clear" : "\(open) open"
    }

    private var todoGatePassed: Bool {
        (chatStore?.snapshot.codexTodos ?? []).allSatisfy { $0.status == "completed" }
    }

    private func canMerge(_ state: PRCoordinator.Snapshot) -> Bool {
        PRCoordinator.canMerge(snapshot: state, canUseDaemonActions: coordinator.canUseDaemonActions)
            && todoGatePassed
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openChecks(_ state: PRCoordinator.Snapshot) {
        guard let identity = PRCoordinator.approvalIdentity(for: state),
              let url = URL(string: "https://github.com/\(identity.repo)/pull/\(identity.number)/checks")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openDeployments(_ state: PRCoordinator.Snapshot) {
        guard let identity = PRCoordinator.approvalIdentity(for: state),
              let url = URL(string: "https://github.com/\(identity.repo)/deployments")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func enqueueFixChecksPrompt(_ state: PRCoordinator.Snapshot) {
        ComposerInsertionInbox.shared.enqueue(text: "Inspect PR #\(state.number), read the failing checks, fix the errors, and rerun the focused tests.\n", autoSend: false)
    }

    private func enqueueReviewRequestPrompt(_ state: PRCoordinator.Snapshot) {
        ComposerInsertionInbox.shared.enqueue(text: "Review PR #\(state.number) and leave a concise request-changes summary covering the unresolved issues.\n", autoSend: false)
    }

    private func enqueueDraftPRPrompt() {
        ComposerInsertionInbox.shared.enqueue(text: "Create a draft PR with a concise title, a tested-change summary, verification steps, and known risks.\n", autoSend: false)
    }

    @MainActor
    private func rerunFailedChecks(_ state: PRCoordinator.Snapshot) async {
        for runID in failedCheckRunIDs(state) {
            await rerunCheck(runID: runID, state: state)
        }
        coordinator.refreshNow()
    }

    @MainActor
    private func rerunCheck(runID: String, state: PRCoordinator.Snapshot?) async {
        guard let state, let identity = PRCoordinator.approvalIdentity(for: state) else { return }
        // Root cause: `process.waitUntilExit()` does NOT suspend the actor, so
        // running the `gh run rerun` subprocess inline froze the UI for the full
        // network round-trip. Mirror `load()` and run it off the main actor.
        let repo = identity.repo
        localActionError = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh", "run", "rerun", runID, "--repo", repo]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return nil
                }
                let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return stderr.isEmpty ? "Failed to rerun check \(runID)." : String(stderr.prefix(220))
            } catch {
                return "Failed to run gh: \(error.localizedDescription)"
            }
        }.value
    }

    private func failedCheckRunIDs(_ state: PRCoordinator.Snapshot) -> [String] {
        state.checks
            .filter { $0.state == .failure }
            .compactMap { runID(from: $0.url) }
    }

    private func runID(from rawURL: String?) -> String? {
        guard let rawURL, let range = rawURL.range(of: #"/actions/runs/([0-9]+)"#, options: .regularExpression) else { return nil }
        let match = String(rawURL[range])
        return match.split(separator: "/").last.map(String.init)
    }

    private func merge(_ state: PRCoordinator.Snapshot) async {
        guard canMerge(state) else {
            localActionError = todoGatePassed ? "Merge is blocked by checks." : "Merge is blocked until open TODOs are completed."
            return
        }
        if let onBeforeMerge {
            guard await onBeforeMerge() else {
                localActionError = "Safety checkpoint failed. Merge cancelled."
                return
            }
        }
        localActionError = nil
        await coordinator.merge()
    }
}

// TahoeTerminalCompactPane was a static summary of past bash tool calls
// (echoed `$ cmd` / `stdout` / `exit N` lines). The Term workbench tab
// now embeds the live `TerminalTabContainer` instead — see the
// `.terminal` case in `tabContent`. The compact summary is gone for now;
// if a passive read-only summary is ever needed again, lift it from git
// history.


private struct TahoeEmptyReviewState: View {
    @Environment(\.tahoe) private var t
    let icon: String
    let title: String
    let message: String

    init(icon: String, title: String, body: String) {
        self.icon = icon
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(spacing: 8) {
            TahoeIcon(icon, size: 22)
                .foregroundStyle(t.fg4)
            Text(title)
                .font(TahoeFont.body(13, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text(message)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}


// MARK: - G12 multi-terminal tab strip

private struct WorkspaceTerminalPane: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    let terminalTab: WorkspaceTerminalTab
    let wsPort: Int
    let token: String

    @State private var sawOutput = false

    var body: some View {
        ZStack {
            Color.black
            if terminalTab.paneRefId == nil || paneId != nil {
                MacTerminalView(
                    sessionId: session.id,
                    host: "127.0.0.1",
                    wsPort: wsPort,
                    token: token,
                    paneId: paneId,
                    onFirstOutput: { sawOutput = true }
                )
                .id(paneId ?? "primary")
                if !sawOutput {
                    terminalPendingOverlay
                }
            } else {
                ContentUnavailableView(
                    "Terminal pane unavailable",
                    systemImage: "terminal",
                    description: Text("This pane no longer exists on the Mac.")
                )
                .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            terminalStatusBadge
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: terminalTab.id) { _, _ in
            sawOutput = false
        }
    }

    private var paneId: String? {
        guard let paneRefId = terminalTab.paneRefId,
              let pane = session.terminalPanes.first(where: { $0.id == paneRefId })
        else { return nil }
        return pane.paneId
    }

    private var activePaneTitle: String {
        guard let paneRefId = terminalTab.paneRefId,
              let pane = session.terminalPanes.first(where: { $0.id == paneRefId })
        else { return "\(session.agent.rawValue.capitalized)" }
        let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Terminal" : title
    }

    private var terminalCwdLabel: String {
        let last = (session.effectiveCwd as NSString).lastPathComponent
        return last.isEmpty ? session.repoDisplayName : last
    }

    private var terminalPendingOverlay: some View {
        TahoeGlass(radius: 14, tone: .raised, shadow: .subtle) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(t.accentAlpha(t.dark ? 0.20 : 0.12))
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
                .frame(width: 44, height: 44)

                VStack(spacing: 4) {
                    Text("Connecting to terminal")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text("Opening \(activePaneTitle) in \(terminalCwdLabel).")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(t.accent)
                    Text("Waiting for visible shell output")
                        .font(TahoeFont.body(10.5, weight: .medium))
                        .foregroundStyle(t.fg3)
                }
            }
            .padding(18)
            .frame(width: 300)
        }
    }

    private var terminalStatusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sawOutput ? Color.green.opacity(0.85) : t.accent)
                .frame(width: 7, height: 7)
            Text(sawOutput ? "Terminal connected" : "Terminal starting")
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(t.fg)
            TahoeHair(vertical: true).frame(height: 12)
            Text(activePaneTitle)
                .font(TahoeFont.mono(10.5, weight: .semibold))
                .foregroundStyle(t.fg2)
                .lineLimit(1)
            Text("in \(terminalCwdLabel)")
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(t.surfaceSolid2.opacity(0.94), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.75)
        )
        .padding(10)
        .help("\(activePaneTitle)\n\(session.effectiveCwd)")
    }
}

private struct TerminalTabContainer: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    let wsPort: Int
    let token: String

    /// nil = primary pane. Non-nil = a TerminalPaneRef.id from session.terminalPanes.
    @State private var selectedSecondaryId: UUID? = nil
    @State private var sawOutput = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            TahoeHairline()
            terminal
        }
        .background(t.surfaceSolid)
        .onChange(of: selectedSecondaryId) { _, _ in
            sawOutput = false
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            tabButton(id: nil, title: primaryTabTitle, isPrimary: true)
            ForEach(session.terminalPanes) { ref in
                tabButton(id: ref.id, title: ref.title, isPrimary: false, paneRef: ref)
            }
            Button(action: {
                Task {
                    if let _ = await model.addTerminalPane(sessionId: session.id) {
                        // Switch to the new tab — pick the last added.
                        if let last = model.registry.session(id: session.id)?.terminalPanes.last {
                            selectedSecondaryId = last.id
                        }
                    }
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(t.fg3)
                    .background(t.surfaceSolid2.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("New terminal pane")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(t.surfaceSolid2.opacity(0.45))
    }

    private var primaryTabTitle: String {
        // Agent pane gets a nicer label than just the tmux id.
        "\(session.agent.rawValue.capitalized)"
    }

    private func tabButton(
        id: UUID?,
        title: String,
        isPrimary: Bool,
        paneRef: TerminalPaneRef? = nil
    ) -> some View {
        let isSelected = (id == selectedSecondaryId)
        return HStack(spacing: 4) {
            Button(action: { selectedSecondaryId = id }) {
                HStack(spacing: 4) {
                    Image(systemName: isPrimary ? "sparkle" : "terminal")
                        .font(.system(size: 9))
                    Text(title)
                        .font(TahoeFont.body(11, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? t.fg : t.fg3)
                .background(
                    isSelected
                        ? t.accentAlpha(t.dark ? 0.18 : 0.12)
                        : t.surfaceSolid2.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? t.accentAlpha(0.45) : t.hairline, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            if let paneRef, !isPrimary {
                Button(action: {
                    Task {
                        await model.closeTerminalPane(sessionId: session.id, paneRef: paneRef)
                        if selectedSecondaryId == paneRef.id {
                            selectedSecondaryId = nil
                        }
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(t.fg4)
                }
                .buttonStyle(.plain)
                .help("Close pane")
            }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        let targetPaneId: String? = {
            guard let sid = selectedSecondaryId,
                  let ref = session.terminalPanes.first(where: { $0.id == sid })
            else { return nil }
            return ref.paneId
        }()
        // SwiftUI re-creates the view (and the WS connection) when the
        // .id() changes. That's what we want: switching tabs hangs up the
        // previous WS and opens one for the new pane.
        ZStack {
            Color.black
            MacTerminalView(
                sessionId: session.id,
                host: "127.0.0.1",
                wsPort: wsPort,
                token: token,
                paneId: targetPaneId,
                onFirstOutput: { sawOutput = true }
            )
            .id(targetPaneId ?? "primary")
            if !sawOutput {
                terminalPendingOverlay
            }
        }
        .overlay(alignment: .topLeading) {
            terminalStatusBadge
        }
    }

    private var terminalPendingOverlay: some View {
        TahoeGlass(radius: 14, tone: .raised, shadow: .subtle) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(t.accentAlpha(t.dark ? 0.20 : 0.12))
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
                .frame(width: 44, height: 44)

                VStack(spacing: 4) {
                    Text("Connecting to raw terminal")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text("Opening \(activePaneTitle) in \(terminalCwdLabel).")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(t.accent)
                    Text("Waiting for visible shell output")
                        .font(TahoeFont.body(10.5, weight: .medium))
                        .foregroundStyle(t.fg3)
                }
            }
            .padding(18)
            .frame(width: 300)
        }
    }

    private var terminalStatusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sawOutput ? Color.green.opacity(0.85) : t.accent)
                .frame(width: 7, height: 7)
            Text(sawOutput ? "Terminal connected" : "Terminal starting")
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(t.fg)
            TahoeHair(vertical: true).frame(height: 12)
            Text(activePaneTitle)
                .font(TahoeFont.mono(10.5, weight: .semibold))
                .foregroundStyle(t.fg2)
                .lineLimit(1)
            Text("in \(terminalCwdLabel)")
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(t.surfaceSolid2.opacity(0.94), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.75)
        )
        .padding(10)
        .help("\(activePaneTitle)\n\(session.effectiveCwd)")
    }

    private var activePaneTitle: String {
        guard let selectedSecondaryId,
              let pane = session.terminalPanes.first(where: { $0.id == selectedSecondaryId })
        else { return primaryTabTitle }
        return pane.title
    }

    private var terminalCwdLabel: String {
        let last = (session.effectiveCwd as NSString).lastPathComponent
        return last.isEmpty ? session.repoDisplayName : last
    }
}

// MARK: - Cross-pane notifications (keyboard shortcuts)

// Workspace `Notification.Name`s live in `SessionWorkspaceNotifications.swift`
// (A6 foundation extraction).

private func postArchiveUndoToast(for session: AgentSession) {
    let toast = TransientToast(
        title: "Archived \(session.displayLabel)",
        actionTitle: "Undo",
        actionID: "unarchive:\(session.id.uuidString)",
        duration: 5,
        isDestructiveRecovery: true
    )
    NotificationCenter.default.post(
        name: .clawdmeterShowTransientToast,
        object: nil,
        userInfo: ["toast": toast]
    )
}

// Preference keys (`WorkspaceWidthKey`, `SidebarViewportHeightKey`,
// `SidebarContentHeightKey`) live in `SessionWorkspacePreferenceKeys.swift`
// (A6 foundation extraction).

// `TranscriptPathLinkStrip` + `TranscriptPathLinkButton` live in
// `TranscriptPathLinks.swift` (A6 foundation extraction).

// `FollowUpSchedulerSheet` lives in `FollowUpSchedulerSheet.swift`
// (A6 foundation extraction).
