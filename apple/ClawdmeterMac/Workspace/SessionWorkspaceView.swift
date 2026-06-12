import SwiftUI
import AppKit
import ClawdmeterShared


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
/// Uses a custom three-column `HStack` with draggable resize handles so
/// sidebar and review widths persist and feel intentional. NavSplitView
/// was tried first; it column-folds on narrow widths and hides the back
/// chrome (the same bug that caused the pre-G0 blank-detail regression).
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
    @ObservedObject var workbenchState: WorkbenchState
    @StateObject private var browserControllers = BrowserWorkspaceControllerStore()
    /// Workspace-level width, measured via GeometryReader. Drives responsive
    /// pane collapsing so even when the user opens the review pane it only
    /// renders if the window has room for it without clipping content.

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Minimum width required to render the review pane without crushing
    /// sidebar + chat. 180 (sidebar min) + 420 (center min) + 280 (review
    /// min) + resize handles + chrome.
    private static let reviewPaneThreshold: CGFloat = 1000

    /// Minimum width required to render even the right-edge gutter CTA.
    /// Below this, the workspace is just sidebar + chat — the user can
    /// resize to summon the gutter back.
    private static let gutterThreshold: CGFloat = 900
    private static let reviewPaneToggleAnimation = Animation.easeOut(duration: 0.22)

    private var effectiveShowReviewPane: Bool {
        !isImmersiveBrowserActive
            && workbenchState.showingReviewPane
            && workbenchState.workspaceWidth >= Self.reviewPaneThreshold
    }

    private var effectiveShowGutter: Bool {
        !isImmersiveBrowserActive
            && !effectiveShowReviewPane
            && workbenchState.workspaceWidth >= Self.gutterThreshold
    }

    private var canHostReviewPaneColumn: Bool {
        !isImmersiveBrowserActive
            && workbenchState.workspaceWidth >= Self.reviewPaneThreshold
            && model.activeWorkspaceKey != nil
    }

    /// Session backing the review pane. When the foreground tab is a draft
    /// (openSessionId cleared) we still resolve a sibling session from the
    /// active workspace, or synthesize a workspace anchor when only drafts
    /// remain, so the right gutter (Plan/Diff/Sources/…) stays visible.
    private var resolvedReviewPaneSession: AgentSession? {
        model.reviewPaneSession()
    }

    private var animatedReviewPaneWidth: CGFloat {
        effectiveShowReviewPane ? effectiveReviewPaneWidth : 0
    }

    /// User-resized width wins when set; otherwise fall back to the tab-aware
    /// default (Diff bumps to ~58% of the workspace).
    private var effectiveReviewPaneWidth: CGFloat {
        if let stored = workbenchState.storedReviewWidth {
            return stored
        }
        return calculatedReviewPaneWidth
    }

    private var isImmersiveBrowserActive: Bool {
        guard let session = model.openSession else { return false }
        return workbenchState.immersiveBrowserSessionId == session.id
            && workbenchState.selectedRightPane == .browser
    }

    private var activeBrowserControllerKeys: [String] {
        model.registry.sessions
            .map { BrowserWorkspaceControllerStore.identityKey(for: $0) }
            .sorted()
    }

    /// Diff needs space — bump the review pane to ~58% of the workspace
    /// width when Diff is the selected tab. Other tabs stay at the
    /// compact 380pt so the center chat keeps its breathing room.
    private var calculatedReviewPaneWidth: CGFloat {
        let workspace = CGFloat(workbenchState.workspaceWidth)
        let isDiff = workbenchState.selectedRightPane == .diff
        guard isDiff, workspace > 0 else { return WorkbenchState.defaultReviewWidth }
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
            HStack(spacing: 0) {
                TahoeGlass(radius: 8, tone: .panel) {
                    SidebarPane(
                        model: model,
                        workbenchState: workbenchState,
                        presentationStore: presentationStore
                    )
                }
                .frame(width: workbenchState.sidebarWidth)
                .padding(.trailing, 5)

                WorkbenchPaneResizeHandle(
                    getWidth: { workbenchState.sidebarWidth },
                    setWidth: { workbenchState.setSidebarWidth($0) },
                    minWidth: WorkbenchState.minSidebarWidth,
                    maxWidth: WorkbenchState.maxSidebarWidth,
                    accessibilityIdentifier: "code.workspace.resize.sidebar"
                )
                .padding(.trailing, 5)

                // Center pane carries the chat AND, when the review pane is
                // collapsed, a thin right-edge gutter that doubles as the
                // expand CTA. Keeping the gutter inside the center column
                // (instead of as its own split child) means the user can't
                // accidentally drag-resize it.
                TahoeGlass(radius: 8, tone: .panel) {
                    HStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            if isImmersiveBrowserActive, let session = model.openSession {
                                InAppBrowser(
                                    session: session,
                                    model: model,
                                    workbenchState: workbenchState,
                                    controller: browserController(for: session),
                                    isFullWorkspace: true,
                                    onCloseFullWorkspace: {
                                        workbenchState.exitImmersiveBrowser()
                                    }
                                )
                                .id("browser-\(session.id.uuidString)")
                            } else if let documentTab = model.selectedWorkspaceDocumentTab,
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
                                    },
                                    onPreviewRequested: {
                                        workbenchState.requestPreview(sessionId: session.id)
                                    }
                                )
                                // No `.id(session.id)` here (deliberately): the
                                // center thread keeps SwiftUI identity across
                                // tab switches so it diffs in place instead of
                                // a full teardown + ComposerStore rebuild. The
                                // composer/prMirror are sourced from per-session
                                // model caches and the inner ChatThreadScroll
                                // still carries its own `.id(session.id)` to
                                // re-bind the transcript correctly. See
                                // CenterThread's `.onChange(of: session.id)`
                                // reset for the @State that must not leak.
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
                        if effectiveShowGutter, model.activeWorkspaceKey != nil {
                            TahoeHairline(vertical: true)
                                .transition(.opacity)
                            ReviewPaneGutter(
                                selectedTab: selectedRightPaneBinding,
                                onExpand: { tab in
                                    workbenchState.selectRightPane(tab)
                                    animateWorkspaceChange(Self.reviewPaneToggleAnimation) {
                                        workbenchState.setReviewPaneVisible(true)
                                    }
                                }
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(reduceMotion ? nil : Self.reviewPaneToggleAnimation, value: effectiveShowGutter)
                }
                .frame(minWidth: WorkbenchState.minCenterWidth, maxWidth: .infinity)
                .padding(.horizontal, 5)

                if effectiveShowReviewPane {
                    WorkbenchPaneResizeHandle(
                        getWidth: { effectiveReviewPaneWidth },
                        setWidth: { workbenchState.setReviewWidth($0) },
                        minWidth: WorkbenchState.minReviewWidth,
                        maxWidth: WorkbenchState.maxReviewWidth,
                        invertDrag: true,
                        accessibilityIdentifier: "code.workspace.resize.review"
                    )
                    .padding(.leading, 5)
                }

                if canHostReviewPaneColumn, let session = resolvedReviewPaneSession {
                    TahoeGlass(radius: 8, tone: .panel) {
                        if effectiveShowReviewPane {
                            WorkspaceReviewPane(
                                session: session,
                                chatStore: model.chatStore(for: session),
                                model: model,
                                workbenchState: workbenchState,
                                presentationStore: presentationStore,
                                browserControllerProvider: {
                                    browserController(for: session)
                                },
                                selectedTab: selectedRightPaneBinding,
                                onClose: {
                                    animateWorkspaceChange(Self.reviewPaneToggleAnimation) {
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
                    }
                    // Diff is the one pane that's useless at the default
                    // 380pt width — readers need to see ±50 cols at once.
                    // Bump it to ~58% of the workspace when Diff is the
                    // selected tab; the other tabs (Plan / Sources / PR /
                    // Terminal) stay compact so the center chat keeps its
                    // breathing room.
                    .frame(width: animatedReviewPaneWidth)
                    .clipped()
                    .opacity(effectiveShowReviewPane ? 1 : 0)
                    .allowsHitTesting(effectiveShowReviewPane)
                    // P7: animate the Diff width morph (~58% expand) on tab
                    // switch. Keyed on the selected pane — NOT workspaceWidth —
                    // so window resizes still track the cursor instantly.
                    .animation(reduceMotion ? nil : Self.reviewPaneToggleAnimation,
                               value: effectiveShowReviewPane)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2),
                               value: workbenchState.selectedRightPane)
                    .padding(.leading, effectiveShowReviewPane ? 5 : 0)
                }
            }
            .animation(reduceMotion ? nil : Self.reviewPaneToggleAnimation, value: effectiveShowReviewPane)
            .padding(10)
        }
        .background(Color.clear)
        .background(
            // Measure the actual workspace width for responsive pane thresholds.
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
                    .background(ContinuumTokens.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
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
            browserControllers.prune(keeping: model.registry.sessions)
        }
        .onChange(of: model.openSessionId) { _, newValue in
            workbenchState.selectSession(newValue)
        }
        .onChange(of: activeBrowserControllerKeys) { _, _ in
            browserControllers.prune(keeping: model.registry.sessions)
        }
        .onChange(of: workbenchState.previewIntent?.id) { _, _ in
            Task { await handlePreviewIntent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCodeReviewPane)) { _ in
            animateWorkspaceChange(Self.reviewPaneToggleAnimation) {
                workbenchState.setReviewPaneVisible(!workbenchState.showingReviewPane)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeReviewPane)) { note in
            if let raw = note.userInfo?["tab"] as? String,
               let tab = WorkbenchPaneTab(rawValue: raw) {
                workbenchState.selectRightPane(tab)
            }
            animateWorkspaceChange(Self.reviewPaneToggleAnimation) {
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
        .onReceive(NotificationCenter.default.publisher(for: ProviderEnablement.changedNotification)) { _ in
            Task { await launcher.refreshProviderAvailability() }
        }
        .background(KeyboardShortcuts(
            model: model,
            workbenchState: workbenchState
        ))
    }

    private var selectedRightPaneBinding: Binding<WorkbenchPaneTab> {
        Binding(
            get: { workbenchState.selectedRightPane },
            set: { workbenchState.selectRightPane($0) }
        )
    }

    private func browserController(for session: AgentSession) -> BrowserWorkspaceController {
        browserControllers.controller(for: session, model: model, workbenchState: workbenchState)
    }

    @MainActor
    private func handlePreviewIntent() async {
        guard let intent = workbenchState.previewIntent else { return }
        let session = model.registry.session(id: intent.sessionId) ?? model.openSession
        guard let session else { return }
        await browserController(for: session).launchPreview(
            session: session,
            workbenchState: workbenchState,
            forceRestart: intent.forceRestart
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
        } else if let draft = model.draftWorkspaceTab {
            model.openDraftWorkspaceTab(from: draft)
        }
    }

    /// Shared helper for the terminal-tab posters — `clawdmeterOpenWorkspaceTerminalTab`
    /// (#174) and `newCodeTerminalTab` (#185). Mirrors the original inline
    /// fallback that hops onto a sibling session when the foreground tab is a
    /// chat draft with no terminal of its own.
    private func openNewWorkspaceTerminalTab() {
        guard let source = model.sourceForNewWorkspaceTerminalTab() else { return }
        Task { await model.openOrCreateWorkspaceTerminalTab(from: source) }
    }

    /// Hidden buttons that own Option+Cmd+1..9 + Cmd+Shift+F + Cmd+;
    /// keyboard shortcuts. SwiftUI's `.keyboardShortcut` only fires when
    /// the view is in the focus chain; attaching to `Color.clear` in a
    /// background layer keeps them globally active without stealing focus.
    /// The number chords intentionally include Option because the app-level
    /// View menu reserves Cmd+1..5 for top-level tab switching.
    private struct KeyboardShortcuts: View {
        @ObservedObject var model: SessionsModel
        @ObservedObject var workbenchState: WorkbenchState

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
                    } else if let draft = model.draftWorkspaceTab {
                        model.openDraftWorkspaceTab(from: draft)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command])
                .opacity(0)
                .frame(width: 0, height: 0)

                Button("") {
                    guard let source = model.sourceForNewWorkspaceTerminalTab() else { return }
                    Task { await model.openOrCreateWorkspaceTerminalTab(from: source) }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)

                Button("") {
                    guard model.openSession != nil else { return }
                    workbenchState.selectRightPane(.terminal)
                    workbenchState.setReviewPaneVisible(true)
                }
                .keyboardShortcut("`", modifiers: [.control])
                .opacity(0)
                .frame(width: 0, height: 0)

                Button("") {
                    NotificationCenter.default.post(name: .renameOpenSession, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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
                draftTabs: model.workspaceDraftTabs(in: draft.workspaceKey),
                activeDraftTabId: draft.id,
                terminalTabs: model.workspaceTerminalTabs(in: draft.workspaceKey),
                activeTerminalTabId: nil,
                documentTabs: model.workspaceDocumentTabs(in: draft.workspaceKey),
                activeDocumentTabId: model.selectedWorkspaceDocumentTab?.id,
                terminalAvailable: WorkspaceKey.siblings(of: draft.workspaceKey, in: model.registry.sessions)
                    .contains(where: { model.canOpenWorkspaceTerminalTab(from: $0) }),
                onNewChat: {
                    model.openDraftWorkspaceTab(from: draft)
                },
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
            WorkspaceContextHeader(draft: draft, catalog: launcher.modelCatalog)
            Divider()
            CodeWorkspaceDraftComposer(
                model: model,
                launcher: launcher,
                presentationStore: presentationStore,
                workspaceDraft: draft
            )
            .id(draft.id)
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
                draftTabs: model.workspaceDraftTabs(in: tab.workspaceKey),
                activeDraftTabId: model.draftWorkspaceTab?.id,
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
                draftTabs: model.workspaceDraftTabs(in: tab.workspaceKey),
                activeDraftTabId: model.draftWorkspaceTab?.id,
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
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
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


// `SessionComparisonPair` + `SessionComparisonSheet` live in
// `SessionComparisonSheet.swift` (A6 foundation extraction).
//
// `StatusPulseDot` + `AttentionBadge` + `SessionHoverActions` +
// `TranscriptEmptyState` live in `SessionStatusBadges.swift`
// (A6 foundation extraction).
//
// `WorkspaceSwitcherSheet` lives in `WorkspaceSwitcherSheet.swift`
// (A6 foundation extraction).

// MARK: - Center thread


// `InlinePlanHalo` lives in `InlinePlanHalo.swift` (A6 foundation extraction).

// MARK: - Chat thread scroll


// `CheckpointRestoreSheet` lives in `CheckpointRestoreSheet.swift`
// (A6 foundation extraction).
//
// `ReviewPaneGutter` lives in `ReviewPaneGutter.swift`,
// `TahoeHairline` lives in `TahoeHairline.swift`, and
// `QuietDisclosure` lives in `QuietDisclosure.swift`
// (A6 foundation extraction).

// MARK: - Workspace context header (draft / non-session foreground tabs)

/// Repo title, provider/model/effort row, and branch chip shown below the
/// workspace tab strip. Session chat tabs render the same chrome via
/// `CenterThread.header`; draft tabs were missing it, which made closing the
/// last session tab feel like the branch disappeared even though it didn't.
struct WorkspaceContextHeader: View {
    let provider: TahoeProvider
    let title: String
    let configurationSummary: String
    let branchLabel: String?

    @Environment(\.tahoe) private var t

    init(draft: WorkspaceDraftTab, catalog: ModelCatalog) {
        provider = TahoeProvider.resolved(agent: draft.agent, modelId: draft.modelId)
        title = RepoIdentity.displayName(for: draft.workspaceKey.repoKey)
        configurationSummary = Self.configurationSummary(
            agent: draft.agent,
            modelId: draft.modelId,
            effort: draft.effort,
            catalog: catalog
        )
        branchLabel = Self.branchLabel(for: draft.workspaceKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            TahoeProviderGlyph(provider: provider, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                    .accessibilityIdentifier("code.center.header.title")
                Text(configurationSummary)
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
                    .lineLimit(1)
                    .accessibilityIdentifier("code.center.header.configuration")
            }
            Spacer()
            if let branchLabel {
                TahoePill(tone: .chip) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                        Text(branchLabel)
                            .font(TahoeFont.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(SessionsV2Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                }
                .frame(maxWidth: 190)
                .help("Worktree: \(branchLabel)")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.center.header")
    }

    private static func branchLabel(for key: WorkspaceKey) -> String? {
        let branch = (key.workspacePath as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    private static func configurationSummary(
        agent: AgentKind,
        modelId: String?,
        effort: ReasoningEffort?,
        catalog: ModelCatalog
    ) -> String {
        let modelText: String
        if let id = modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            modelText = catalog.entry(forId: id)?.displayName ?? id
        } else {
            modelText = "default model"
        }
        let effortText = effort.map(effortLabel) ?? "Default effort"
        return "\(agent.tahoeProvider.displayName) · \(modelText) · \(effortText)"
    }

    private static func effortLabel(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .minimal: return "Minimal"
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        case .xhigh:   return "Extra high"
        case .max:     return "Max"
        }
    }
}

// MARK: - Review pane (right)








// TahoeTerminalCompactPane was a static summary of past bash tool calls
// (echoed `$ cmd` / `stdout` / `exit N` lines). The Term workbench tab
// now embeds the live `TerminalTabContainer` instead — see the
// `.terminal` case in `tabContent`. The compact summary is gone for now;
// if a passive read-only summary is ever needed again, lift it from git
// history.




// MARK: - G12 multi-terminal tab strip



// MARK: - Cross-pane notifications (keyboard shortcuts)

// Workspace `Notification.Name`s live in `SessionWorkspaceNotifications.swift`
// (A6 foundation extraction).

func postArchiveUndoToast(for session: AgentSession) {
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
