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
/// Uses `HSplitView` so column widths persist and can be dragged. NavSplitView
/// was tried first; it column-folds on narrow widths and hides the back chrome
/// (the same bug that caused the pre-G0 blank-detail regression).
struct SessionWorkspaceView: View {
    @ObservedObject var model: SessionsModel

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

    var body: some View {
        ZStack {
            t.pageBg.opacity(t.dark ? 0.35 : 0.18)
            HSplitView {
                TahoeGlass(radius: 20, tone: .panel) {
                    SidebarPane(model: model, workbenchState: workbenchState)
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
                            if let session = model.openSession {
                                CenterThread(
                                    session: session,
                                    isReadOnly: model.openSessionIsReadOnly,
                                    model: model,
                                    catalog: launcher.modelCatalog,
                                    workbenchState: workbenchState,
                                    density: workbenchState.density,
                                    onDensityChange: { workbenchState.setDensity($0) },
                                    onModeSwitch: { newMode in
                                        Task { await switchMode(session: session, to: newMode) }
                                    }
                                )
                                .id(session.id)
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
                            if let session = model.openSession,
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
                                    withAnimation(.easeOut(duration: 0.18)) {
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
                            selectedTab: selectedRightPaneBinding,
                            onClose: {
                                withAnimation(.easeOut(duration: 0.18)) {
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
                    }
                    .frame(width: 380)
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
        .animation(.easeOut(duration: 0.16), value: showingWorkspaceSwitcher)
        .onAppear {
            restorePersistedSessionSelectionIfPossible()
        }
        .onChange(of: model.openSessionId) { _, newValue in
            workbenchState.selectSession(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCodeReviewPane)) { _ in
            guard workbenchState.workspaceWidth >= Self.reviewPaneThreshold else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                workbenchState.setReviewPaneVisible(!workbenchState.showingReviewPane)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeReviewPane)) { note in
            if let raw = note.userInfo?["tab"] as? String,
               let tab = WorkbenchPaneTab(rawValue: raw) {
                workbenchState.selectRightPane(tab)
            }
            withAnimation(.easeOut(duration: 0.18)) {
                workbenchState.setReviewPaneVisible(true)
            }
        }
        .task {
            await launcher.refreshProviderAvailability()
        }
        .background(KeyboardShortcuts(
            model: model,
            onWorkspaceSwitcher: { showingWorkspaceSwitcher = true }
        ))
    }

    private var selectedRightPaneBinding: Binding<WorkbenchPaneTab> {
        Binding(
            get: { workbenchState.selectedRightPane },
            set: { workbenchState.selectRightPane($0) }
        )
    }

    private func restorePersistedSessionSelectionIfPossible() {
        guard model.openSessionId == nil,
              let selected = workbenchState.selectedSessionId,
              model.registry.sessions.contains(where: { $0.id == selected && $0.archivedAt == nil })
        else {
            return
        }
        model.openSessionId = selected
    }

    /// Hidden buttons that own Option+Cmd+1..9 + Cmd+Shift+F + Cmd+;
    /// keyboard shortcuts. SwiftUI's `.keyboardShortcut` only fires when
    /// the view is in the focus chain; attaching to `Color.clear` in a
    /// background layer keeps them globally active without stealing focus.
    /// The number chords intentionally include Option because the app-level
    /// View menu reserves Cmd+1..5 for top-level tab switching.
    private struct KeyboardShortcuts: View {
        @ObservedObject var model: SessionsModel
        let onWorkspaceSwitcher: () -> Void
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
                    NotificationCenter.default.post(
                        name: .focusSidebarSearch, object: nil
                    )
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                // G17 sub-chat: Cmd+; branches off the open session.
                Button("") {
                    guard let parentId = model.openSessionId else { return }
                    Task { _ = await model.spawnSubchat(parentId: parentId) }
                }
                .keyboardShortcut(";", modifiers: [.command])
                .opacity(0)
                .frame(width: 0, height: 0)
                Button("") {
                    onWorkspaceSwitcher()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .opacity(0)
                .frame(width: 0, height: 0)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Center empty state — Codex-style centered composer

    private var centerEmpty: some View {
        EmptyStateCenteredComposer(model: model, launcher: launcher)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

// MARK: - Sidebar (left pane)

private struct SidebarPane: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t
    @FocusState private var searchFocused: Bool

    /// Persisted sidebar grouping + sorting + status-filter preferences.
    /// All three are local to the Mac UI — iOS has its own equivalents.
    @AppStorage("clawdmeter.sidebar.grouping") private var groupingRaw: String = SessionGrouping.status.rawValue
    @AppStorage("clawdmeter.sidebar.sorting")  private var sortingRaw: String  = SessionSorting.recency.rawValue
    @AppStorage("clawdmeter.sidebar.status")   private var statusRaw: String   = SessionStatusFilter.all.rawValue

    /// v0.5.4: rename sheet state. v0.5.9: split into a dedicated bool
    /// + data target — the `Binding(get:set:)` pattern for `isPresented:`
    /// didn't reliably trigger alert presentation; the canonical pattern
    /// is `@State Bool` + `presenting:` payload.
    @State private var renameTarget: AgentSession?
    @State private var renameInput: String = ""
    @State private var showingRenameAlert: Bool = false
    // v0.5.10 — parallel state for Recent JSONL row rename. Keyed by path
    // (not session id) because these rows aren't Clawdmeter-owned
    // sessions; they're files we surface.
    @State private var renameJSONLTarget: RecentSession?
    @State private var renameJSONLInput: String = ""
    @State private var showingRenameJSONLAlert: Bool = false
    @State private var collapsedStatusGroupIDs: Set<String> = []
    @State private var sidebarViewportHeight: CGFloat = 0
    @State private var sidebarContentHeight: CGFloat = 0
    @State private var hoveredSessionId: UUID?
    @State private var hoveredRecentPath: String?

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
                model.registry.rename(id: target.id, name: renameInput)
                showingRenameAlert = false
                renameTarget = nil
                renameInput = ""
            }
            Button("Clear name", role: .destructive) {
                model.registry.rename(id: target.id, name: nil)
                showingRenameAlert = false
                renameTarget = nil
                renameInput = ""
            }
            Button("Cancel", role: .cancel) {
                showingRenameAlert = false
                renameTarget = nil
                renameInput = ""
            }
        } message: { target in
            Text("Currently: \(target.displayLabel)")
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
            Button(action: { model.showingNewSessionSheet = true }) {
                TahoeIcon("folderPlus", size: 12)
                    .foregroundStyle(t.fg3)
                    .frame(width: 24, height: 24)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("New session")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    if grouping == .repo {
                        // Legacy repo-grouped path — preserves the existing
                        // expand/collapse + "Recent (last 30 days)" + empty-
                        // state CTA chrome that's threaded through SessionsModel.
                        let canonical = SessionSidebarGrouper.canonicalizeRepos(filteredReposForGrouping)
                        ForEach(canonical.repos, id: \.key) { repo in
                            repoSection(repo, keyAliases: canonical.keyAliases)
                        }
                    } else {
                        // Date / Status / Agent / None — flatten across repos
                        // and let the grouper bucket by the chosen field.
                        let groups = SessionSidebarGrouper.group(
                            sessions: filteredVisibleSessions,
                            repos: filteredReposForGrouping,
                            grouping: grouping,
                            sorting: sorting,
                            statusFilter: statusFilter,
                            reviewSessionIds: reviewSessionIds
                        )
                        ForEach(groups) { group in
                            groupSection(group)
                        }
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

    private var filteredVisibleSessions: [AgentSession] {
        let all = model.registry.sessions.filter { s in
            // Match the existing search behaviour: search filters apply
            // to both sessions AND repos. SessionsModel.filter handles
            // archive visibility based on `showArchived`.
            if grouping != .status && statusFilter != .archived && !model.showArchived && s.archivedAt != nil { return false }
            return true
        }
        return model.filter(sessions: all)
    }

    private var reviewSessionIds: Set<UUID> {
        Set(model.registry.sessions.compactMap { session in
            if session.planText != nil { return session.id }
            if let state = session.prMirrorState?.state,
               state == .open || state == .draft {
                return session.id
            }
            if let state = workbenchState.snapshot.prCache[session.id]?.state?.lowercased(),
               state == "open" || state == "draft" || state == "pending" {
                return session.id
            }
            return nil
        })
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
        let visibleSessions = model.filter(sessions: allSessions).filter(sidebarStatusPasses)
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
                        model.selectedRepoKey = repo.key
                        model.showingNewSessionSheet = true
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
                .contextMenu {
                    Button("Pop out", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                        NotificationCenter.default.post(
                            name: .popOutSession,
                            object: nil,
                            userInfo: ["sessionId": s.id]
                        )
                    }
                    Button("Copy session ID", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s.id.uuidString, forType: .string)
                    }
                    Button("Reveal JSONL in Finder", systemImage: "doc.text.magnifyingglass") {
                        if let url = model.chatStore(for: s)?.currentFileURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Divider()
                    Button("Rename…") {
                        renameTarget = s
                        renameInput = s.customName ?? ""
                        showingRenameAlert = true
                    }
                    if s.archivedAt == nil {
                        Button("Archive") { model.registry.archive(id: s.id) }
                    } else {
                        Button("Unarchive") { model.registry.unarchive(id: s.id) }
                    }
                    Button("New sub-chat (⌘;)") {
                        Task { _ = await model.spawnSubchat(parentId: s.id) }
                    }
                    Divider()
                    Button("End session", role: .destructive) {
                        Task { await model.endSession(id: s.id) }
                    }
                }
        }
    }

    private func repoHeader(_ repo: AgentRepo, isExpanded: Bool, sessionCount: Int) -> some View {
        Button(action: {
            if isExpanded { model.expandedRepoKeys.remove(repo.key) }
            else { model.expandedRepoKeys.insert(repo.key) }
        }) {
            HStack(spacing: 8) {
                TahoeIcon(isExpanded ? "chevD" : "chevR", size: 10)
                    .foregroundStyle(t.fg3)
                    .frame(width: 10)
                projectGlyph(repo)
                Text(repo.displayName)
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        return Button(action: {
            model.openSessionId = session.id
            model.openOutsideJSONLPath = nil
        }) {
            HStack(alignment: .top, spacing: 8) {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(depth - 1) * 12)
                }
                TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 20)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(statusColor(session.status))
                            .frame(width: 6, height: 6)
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
                    }
                }
                Spacer()
                if session.archivedAt != nil {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if session.planText != nil {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(terraCotta)
                        .help("Plan approval pending")
                }
                if model.chatStore(for: session)?.pendingPermissionPrompt != nil {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("User input required")
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
    }

    private func sessionTitle(_ session: AgentSession) -> String {
        if let custom = session.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let goal = Self.cleanSidebarTitle(session.goal) { return goal }
        if let branch = branchLikeTitle(for: session) { return branch }
        if let summary = latestAssistantSummary(for: session) { return summary }
        return "\(session.agent.rawValue.capitalized) · \(session.status.rawValue)"
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
        Button(action: { model.showingNewSessionSheet = true }) {
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

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

private struct StatusPulseDot: View {
    let color: Color
    let isLive: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isLive {
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 1.5)
                    .frame(width: pulse ? 14 : 7, height: pulse ? 14 : 7)
                    .opacity(pulse ? 0 : 1)
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard isLive else { return }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .onChange(of: isLive) { _, newValue in
            pulse = false
            guard newValue else { return }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct WorkspaceSwitcherSheet: View {
    @ObservedObject var model: SessionsModel
    let focusedSession: AgentSession?
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filteredSessions: [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sessions = model.registry.sessions
            .filter { $0.archivedAt == nil }
            .sorted { $0.lastEventAt > $1.lastEventAt }
        guard !q.isEmpty else { return Array(sessions.prefix(50)) }
        return sessions.filter { session in
            session.displayLabel.lowercased().contains(q)
                || session.repoDisplayName.lowercased().contains(q)
                || session.agent.rawValue.lowercased().contains(q)
        }
    }

    private var filteredRepos: [AgentRepo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let repos = model.repos
        guard !q.isEmpty else { return Array(repos.prefix(20)) }
        return repos.filter { repo in
            repo.displayName.lowercased().contains(q)
                || repo.key.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch workspace or session", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { activateDefaultResult() }
                Button("New") {
                    model.showingNewSessionSheet = true
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            Divider()
            List {
                if let focusedSession,
                   let repoKey = focusedSession.repoKey {
                    Section("Current Repo") {
                        Button {
                            model.selectedRepoKey = repoKey
                            model.showingNewSessionSheet = true
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Start new session in \(focusedSession.repoDisplayName)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Text(repoKey)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !filteredSessions.isEmpty {
                    Section("Sessions") {
                        ForEach(filteredSessions) { session in
                            Button {
                                model.openOutsideJSONLPath = nil
                                model.openSessionId = session.id
                                isPresented = false
                            } label: {
                                workspaceSessionRow(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !filteredRepos.isEmpty {
                    Section("Repos") {
                        ForEach(filteredRepos, id: \.key) { repo in
                            Button {
                                model.selectedRepoKey = repo.key
                                model.showingNewSessionSheet = true
                                isPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(repo.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        Text(repo.key)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Button("Open") {
                activateDefaultResult()
            }
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear {
            searchFocused = true
        }
    }

    private func activateDefaultResult() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty,
           let focusedSession,
           let repoKey = focusedSession.repoKey {
            openRepo(repoKey)
            return
        }
        if let session = filteredSessions.first {
            openSession(session)
            return
        }
        if let repo = filteredRepos.first {
            openRepo(repo.key)
        }
    }

    private func openSession(_ session: AgentSession) {
        model.openOutsideJSONLPath = nil
        model.openSessionId = session.id
        isPresented = false
    }

    private func openRepo(_ repoKey: String) {
        model.selectedRepoKey = repoKey
        model.showingNewSessionSheet = true
        isPresented = false
    }

    private func workspaceSessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            StatusPulseDot(
                color: session.status == .running ? .green : .secondary,
                isLive: session.status == .running
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(session.repoDisplayName) · \(session.agent.rawValue.capitalized) · \(session.status.rawValue)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.lastEventAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct ConnectingTranscriptState: View {
    let session: AgentSession

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                StatusPulseDot(color: .green, isLive: true)
                    .scaleEffect(1.8)
                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            Text("Connecting to \(session.agent.rawValue.capitalized)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(session.effectiveCwd)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 440)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Center thread

private struct CenterThread: View {
    let session: AgentSession
    let isReadOnly: Bool
    @ObservedObject var model: SessionsModel
    let catalog: ModelCatalog
    @ObservedObject var workbenchState: WorkbenchState
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
        density: TranscriptDensity,
        onDensityChange: @escaping (TranscriptDensity) -> Void,
        onModeSwitch: @escaping (SessionMode) -> Void
    ) {
        self.session = session
        self.isReadOnly = isReadOnly
        self.model = model
        self.catalog = catalog
        self.workbenchState = workbenchState
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
        .onReceive(NotificationCenter.default.publisher(for: .showRawTerminal)) { note in
            if let id = note.userInfo?["sessionId"] as? UUID, id == session.id {
                showingTerminalOverlay = true
            }
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
            TahoePill(tone: .chip) {
                HStack(spacing: 5) {
                    TahoeIcon("bolt", size: 10)
                        .foregroundStyle(t.fg2)
                    Text(permissionModeLabel)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg2)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
            }
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
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
                .help("Transcript density")
                Menu {
                    Button("Show raw terminal (⌘T)") { showingTerminalOverlay = true }
                        .keyboardShortcut("t", modifiers: [.command])
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
                            model.registry.archive(id: session.id)
                            workbenchState.clearSessionState(sessionId: session.id)
                            AttachmentStaging.cleanup(sessionId: session.id)
                            if let wt = session.worktreePath {
                                AttachmentStaging.cleanupWorktree(at: wt)
                            }
                        }
                    }
                    Button("End session", role: .destructive) {
                        Task {
                            await model.endSession(id: session.id)
                            workbenchState.clearSessionState(sessionId: session.id)
                            AttachmentStaging.cleanup(sessionId: session.id)
                            if let wt = session.worktreePath {
                                AttachmentStaging.cleanupWorktree(at: wt)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var permissionModeLabel: String {
        switch permissionModeStore.currentMode(for: session) {
        case .ask: return "ask"
        case .acceptEdits: return "accept edits"
        case .plan: return "plan"
        case .bypass: return "bypass"
        }
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
        VStack(spacing: 0) {
            HStack {
                Text("Raw terminal — \(headerLabel(for: session))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Close (Esc)") { showingTerminalOverlay = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if let runtime = AppDelegate.runtime,
               let port = runtime.agentControlServer.boundWsPort {
                TerminalTabContainer(
                    session: session,
                    model: model,
                    wsPort: Int(port),
                    token: PairingTokenStore.shared.currentToken()
                )
            } else {
                ContentUnavailableView(
                    "Daemon offline",
                    systemImage: "wifi.exclamationmark",
                    description: Text("Restart Clawdmeter to reconnect.")
                )
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
                density: density,
                showPlanHalo: shouldShowInlinePlanHalo,
                canApprovePlan: !isReadOnly,
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
            projectSkillsRoot: URL(fileURLWithPath: session.effectiveCwd).appendingPathComponent(".claude/skills", isDirectory: true)
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

        let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
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

        let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
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
    }

    private func performInterrupt() async {
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else { return }
        let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
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
        let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
        // Daemon-side: flip state. We then respawn via SessionConfigChanger so
        // the running CLI restarts with the appropriate --dangerously-* flags.
        do {
            try await sender.setAutopilot(sessionId: session.id, enabled: enable)
            composerStore.autopilotEnabled = enable
            let changer = SessionConfigChanger(registry: model.registry, tmux: runtime.tmuxClient)
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

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

private struct InlinePlanHalo: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    let onRefine: () -> Void
    let onApprove: () -> Void
    let canApprove: Bool
    @State private var auraGlow = false

    private var steps: [String] {
        guard let plan = session.planText else { return [] }
        return TahoePlanParser.steps(from: plan, cap: 8)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [t.accentGlow.color(opacity: t.muted ? 0.10 : 0.30), .clear],
                        center: .init(x: 0.5, y: 0.30),
                        startRadius: 0,
                        endRadius: 520
                    )
                )
                .blur(radius: 8)
                .padding(-28)
                .opacity(auraGlow ? 1 : 0.82)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: auraGlow)
                .onAppear { auraGlow = true }

            TahoeGlass(radius: 20, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom)
                            )
                            .frame(width: 28, height: 28)
                            .overlay(TahoeIcon("sparkles", size: 14).foregroundStyle(.white))
                            .shadow(color: t.accentDeep.color(opacity: 0.35), radius: 6, x: 0, y: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Plan ready · review before run")
                                .font(TahoeFont.body(11.5, weight: .semibold))
                                .tracking(0.4)
                                .textCase(.uppercase)
                                .foregroundStyle(t.fg3)
                            Text("\(steps.count) steps · est. \(estimatedToolCalls) tool calls · \(estimatedCost)")
                                .font(TahoeFont.body(14, weight: .bold))
                                .foregroundStyle(t.fg)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(t.hair2)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Text("\(index + 1)")
                                            .font(TahoeFont.mono(11, weight: .bold))
                                            .foregroundStyle(t.fg2)
                                    )
                                Text(step)
                                    .font(TahoeFont.body(13))
                                    .foregroundStyle(t.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 14)

                    TahoeHairline()

                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .m, action: onRefine) {
                            TahoeIcon("chat", size: 11)
                            Text("Refine")
                        }
                        TahoeGhostButton(size: .m, action: onRefine) {
                            Text("Edit plan")
                        }
                        Spacer(minLength: 10)
                        if let branch = session.worktreePath.map({ URL(fileURLWithPath: $0).lastPathComponent }), !branch.isEmpty {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("Will commit to")
                                    .font(TahoeFont.body(10.5, weight: .semibold))
                                    .foregroundStyle(t.fg4)
                                HStack(spacing: 5) {
                                    TahoeIcon("branch", size: 10)
                                    Text(branch)
                                        .font(TahoeFont.mono(11))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .foregroundStyle(t.fg3)
                            }
                            .frame(maxWidth: 190)
                        }
                        TahoeAccentButton(size: .m, disabled: !canApprove, action: onApprove) {
                            Text("Approve & run")
                            Text("⇧⏎")
                                .fontWeight(.regular)
                                .opacity(0.75)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var estimatedToolCalls: Int {
        max(3, min(12, steps.count + 3))
    }

    private var estimatedCost: String {
        if session.agent == .codex { return "~$0.12" }
        if session.agent == .gemini { return "~$0.08" }
        return "~$0.18"
    }
}

// MARK: - Chat thread scroll

private struct ChatThreadScroll: View {
    @ObservedObject var store: SessionChatStore
    let session: AgentSession
    let model: SessionsModel
    let density: TranscriptDensity
    let showPlanHalo: Bool
    let canApprovePlan: Bool
    let onPlanRefine: () -> Void
    let onPlanApprove: () -> Void
    @Environment(\.tahoe) private var t

    /// IDs of expanded disclosure groups. Per-row `@State` would be ideal
    /// (A5 codex finding) but with LazyVStack recycling that loses state
    /// across scroll; this set is the simplest path that survives recycling.
    /// Tests confirm tapping one row only invalidates that row when reads
    /// flow through `snapshot.items` (T5).
    @State private var expanded: Set<String> = []
    /// v0.5.6: per-tool_use_id selection state for AskUserQuestion trays.
    /// `[toolUseId: [questionHeader: Set<optionLabel>]]`. Lives at the
    /// scroll-view level so picks survive list recycling during
    /// streaming bumps.
    @State private var askUserQuestionSelections: [String: [String: Set<String>]] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.hasOlderHistory {
                            loadEarlierButton
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                        if store.snapshot.items.isEmpty && !store.isLoading {
                            emptyState
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(store.snapshot.items) { item in
                                itemRow(item)
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
                                lastEventAt: store.snapshot.lastEventAt,
                                // v0.29.4: anchor the elapsed counter to
                                // the most recent user prompt so the
                                // pill shows "how long has the model been
                                // working on this task", not "how long
                                // since I clicked into the session".
                                activityStartedAt: store.snapshot.currentTurnStartedAt
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
                .onChange(of: store.snapshot.updateCounter) { _, counter in
                    stickToBottomIfPinned(proxy, updateCounter: counter)
                }
                .onAppear {
                    userPinnedToBottom = true
                    lastScrollItemCount = store.snapshot.items.count
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

                // Jump-to-latest CTA. Visible whenever the user has
                // scrolled away from the bottom (a new turn lands while
                // they're reading history). Click → scroll-to-last-item.
                if !userPinnedToBottom, !store.snapshot.items.isEmpty {
                    Button(action: {
                        autoScrollTask?.cancel()
                        autoScrollTask = Task { @MainActor in
                            await jumpToBottom(proxy, animated: true)
                        }
                    }) {
                        Label("Jump to latest", systemImage: "arrow.down.circle.fill")
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
    }

    /// Stable sentinel id used by ScrollViewReader to scroll to the tail.
    /// Held as a static so the id reference doesn't recompute per-render.
    private static let bottomSentinelId = "mac-chat-bottom-sentinel"

    /// Tracks whether the user is reading the tail (last item visible).
    /// When false, auto-scroll stops yanking on new turns and the "Jump
    /// to latest" button surfaces. Updated by the per-row appear/disappear.
    @State private var userPinnedToBottom: Bool = true

    @State private var lastScrollItemCount: Int = 0
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var isLoadingEarlierHistory: Bool = false
    @State private var suppressBottomGeometryUntil: Date = .distantPast

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

    private var bodyFontSize: CGFloat {
        switch density {
        case .compact: return 12
        case .balanced: return 13
        case .detailed: return 14
        }
    }

    private var toolOutputLineLimit: Int? {
        switch density {
        case .compact: return 16
        case .balanced: return 40
        case .detailed: return nil
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
        let items = store.snapshot.items.count
        lastScrollItemCount = items
        guard !isLoadingEarlierHistory else { return }
        guard userPinnedToBottom else { return }
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
        if animated {
            withAnimation(.easeInOut(duration: 0.32)) {
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

    @ViewBuilder
    private func itemRow(_ item: ChatItem) -> some View {
        switch item {
        case .message(let m):
            messageRow(m)
        case .toolRun(let runId, let pairs):
            // v0.5.5/v0.5.6: partition by tool kind:
            //   • Edit/MultiEdit/Write → inline EditDiffRow chips
            //   • AskUserQuestion       → interactive AskUserQuestionTray
            //   • everything else       → "Ran N commands" disclosure
            //
            // v0.29.4: the "everything else" bucket previously rendered
            // each tool pair as its own row, which meant a long agent
            // burst (50 sed/rg/cat probes) flooded the transcript with
            // 50 individual exec_command rows. Wrap that bucket in
            // `toolRunGroup` so it shows as one collapsed "Ran N
            // commands" pill that expands on click — matches the
            // existing MacChatV2View behavior and what users expect
            // from Claude Code's CLI rendering.
            let editPairs = pairs.filter { $0.call.editStats != nil }
            let askPairs  = pairs.filter { $0.call.askUserQuestion != nil }
            let otherPairs = pairs.filter {
                $0.call.editStats == nil && $0.call.askUserQuestion == nil
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(editPairs) { pair in
                    if let stats = pair.call.editStats {
                        EditDiffRow(
                            stats: stats,
                            editDiff: pair.call.editDiff,
                            resultBody: pair.result?.body,
                            density: density
                        )
                    }
                }
                ForEach(askPairs) { pair in
                    if let q = pair.call.askUserQuestion {
                        AskUserQuestionTray(
                            question: q,
                            answered: pair.result != nil,
                            selections: Binding(
                                get: { askUserQuestionSelections[pair.id] ?? [:] },
                                set: { askUserQuestionSelections[pair.id] = $0 }
                            )
                        ) { _, options in
                            // Paste the chosen labels into the session's
                            // tmux pane via the daemon's existing send
                            // endpoint. Trailing newline is added by the
                            // server-side paste-buffer handler so Claude
                            // Code's picker treats it as Enter.
                            let answer = options.map(\.label).joined(separator: ", ")
                            sendAnswerToSession(answer)
                        }
                    }
                }
                if !otherPairs.isEmpty {
                    toolRunGroup(id: runId, pairs: otherPairs)
                }
            }
        }
    }

    /// v0.5.6 — fire-and-forget answer send. Mirrors the existing
    /// MacComposerSender path used by the main composer; loopback HTTP
    /// to the local daemon's `/sessions/:id/send`, which routes through
    /// the same rate-limit + audit-log path as a typed prompt.
    private func sendAnswerToSession(_ answer: String) {
        guard !answer.isEmpty,
              let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort else { return }
        let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
        let sessionId = session.id
        Task {
            try? await sender.send(sessionId: sessionId, body: answer, asFollowUp: true)
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: SessionChatStore.ChatMessage) -> some View {
        switch msg.kind {
        case .userText:      userBubble(msg)
        case .assistantText: assistantBubble(msg)
        case .toolCall, .toolResult:
            // Should never hit: tool messages are folded into ChatItem.toolRun.
            EmptyView()
        case .meta:          metaRow(msg)
        }
    }

    // MARK: - Tool run rendering

    private func toolRunGroup(id: String, pairs: [ToolPair]) -> some View {
        let runKey = "run:\(id)"
        let isOpen = Binding<Bool>(
            get: { expanded.contains(runKey) },
            set: { if $0 { expanded.insert(runKey) } else { expanded.remove(runKey) } }
        )
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pairs) { pair in
                    toolPairRow(pair)
                }
            }
            .padding(.leading, 16)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                TahoeIcon("terminal", size: 10)
                    .foregroundStyle(t.fg3)
                Text("Ran \(pairs.count) command\(pairs.count == 1 ? "" : "s")")
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(t.hair2, in: Capsule(style: .continuous))
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(QuietDisclosure())
    }

    private func toolPairRow(_ pair: ToolPair) -> some View {
        let key = "pair:\(pair.id)"
        let isOpen = Binding<Bool>(
            get: { expanded.contains(key) },
            set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } }
        )
        let isError = pair.result?.isError ?? false
        let bashResult = pair.result?.bashResult ?? pair.call.bashResult
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(alignment: .leading, spacing: 6) {
                if let bashResult {
                    bashResultView(bashResult, isError: isError)
                } else if let detail = pair.call.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                if let result = pair.result,
                   !result.body.isEmpty,
                   bashResult == nil || (bashResult?.stdout == nil && bashResult?.stderr == nil) {
                    Text(result.body)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(toolOutputLineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6))
                } else if pair.result == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for result…")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(pair.call.title))
                    .font(.system(size: 10))
                    .foregroundStyle(toolTint(pair.call.title))
                Text(pair.call.title)
                    .font(TahoeFont.mono(11, weight: .semibold))
                    .foregroundStyle(toolTint(pair.call.title))
                Text(pair.call.body)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(t.hair2, in: Capsule(style: .continuous))
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(QuietDisclosure())
    }

    @ViewBuilder
    private func bashResultView(_ bash: BashResult, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let command = bash.command, !command.isEmpty {
                    Label(command, systemImage: "terminal")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if let exitCode = bash.exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                }
                if let durationMS = bash.durationMS {
                    Text("\(durationMS) ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if let cwd = bash.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let stdout = bash.stdout, !stdout.isEmpty {
                monoBlock(title: "stdout", text: stdout, tint: .secondary)
            }
            if let stderr = bash.stderr, !stderr.isEmpty {
                monoBlock(title: "stderr", text: stderr, tint: .red)
            }
            if bash.isTruncated {
                Text("Output truncated")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if bash.stdout == nil, bash.stderr == nil, bash.exitCode == nil {
                Text("Waiting for result...")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background((isError ? Color.red : t.hair2).opacity(isError ? 0.08 : 0.85),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func monoBlock(title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .lineLimit(toolOutputLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private func userBubble(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 4) {
                TahoeGlass(radius: 20, tone: .raised) {
                    Text(msg.body)
                        .font(TahoeFont.body(bodyFontSize))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 640, alignment: .trailing)
            }
        }
    }

    private func assistantBubble(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                MarkdownRenderer(source: msg.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 64)
        }
    }

    // toolCallCard / toolResultCard removed — replaced by toolRunGroup +
    // toolPairRow above, which fold consecutive tool messages into a two-
    // level DisclosureGroup ("Ran N commands" → per-tool → command/result).

    private func metaRow(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack {
            Spacer()
            Text(msg.body)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func toolIcon(_ name: String) -> String {
        ToolPresentationCatalog.presentation(for: name).systemImageName
    }

    private func toolTint(_ name: String) -> Color {
        switch ToolPresentationCatalog.presentation(for: name).tone {
        case .read: return .blue
        case .write: return terraCotta
        case .shell: return .green
        case .web: return .purple
        case .agent: return .orange
        case .warning: return .red
        case .neutral: return .secondary
        }
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

private struct CheckpointRestoreSheet: View {
    let plan: CheckpointRestorePlan
    let isRestoring: Bool
    let onCancel: () -> Void
    let onRestore: () -> Void

    private var diffBody: String {
        let stat = plan.diffStat.isEmpty ? "No tracked file changes." : plan.diffStat
        let patch = plan.diffPatch.isEmpty ? "" : "\n\n\(plan.diffPatch)"
        let suffix = plan.patchTruncated ? "\n\n[Diff preview truncated]" : ""
        return stat + patch + suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: plan.isBlocked ? "exclamationmark.triangle.fill" : "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(plan.isBlocked ? .orange : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore Checkpoint")
                        .font(.system(size: 15, weight: .semibold))
                    Text(plan.target.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                labeledRef("Target", plan.target.refName)
                labeledRef("Safety", plan.safety.refName)
                if !plan.untrackedSnapshotPaths.isEmpty {
                    Text("Restores \(plan.untrackedSnapshotPaths.count) untracked file\(plan.untrackedSnapshotPaths.count == 1 ? "" : "s") from the checkpoint sidecar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if !plan.blockingReasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.blockingReasons, id: \.self) { reason in
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    if !plan.dirtyStatusLines.isEmpty {
                        Text(plan.dirtyStatusLines.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            Text("Preview")
                .font(.system(size: 12, weight: .semibold))
            ScrollView {
                Text(diffBody)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 240)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onRestore) {
                    Text(isRestoring ? "Restoring…" : "Restore to checkpoint")
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isBlocked || isRestoring)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
    }

    private func labeledRef(_ label: String, _ ref: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(ref)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Review-pane gutter (collapsed CTA)

/// Thin vertical strip on the right edge of the center pane shown when the
/// review pane is collapsed. Each icon is a tap target that opens the
/// review pane focused on that tab — the CTA the user asked for. When the
/// pane is expanded the gutter hides; the pane's own × button collapses
/// it back to this strip.
private struct ReviewPaneGutter: View {
    @Binding var selectedTab: WorkbenchPaneTab
    let onExpand: (WorkbenchPaneTab) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 6) {
            ForEach(WorkbenchPaneTab.allCases) { tab in
                Button(action: { onExpand(tab) }) {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13))
                        Text(tab.rawValue)
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(
                        selectedTab == tab
                            ? Color.secondary.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(tab.rawValue) pane")
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(width: 52)
        .background(t.glassTintHi.opacity(0.55))
    }

    private var gutterBg: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.95, green: 0.95, blue: 0.95)
    }
}

private struct TahoeHairline: View {
    @Environment(\.tahoe) private var t
    var vertical: Bool = false

    var body: some View {
        Rectangle()
            .fill(t.hairline)
            .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}

// MARK: - Quiet disclosure style

/// Custom DisclosureGroup style with a tighter chevron + no default
/// "Show more / Show less" hover chrome. Matches the Codex-desktop
/// "Ran N commands ⌄" / "Ran <description> ⌄" look.
private struct QuietDisclosure: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

// MARK: - Review pane (right)

private struct ReviewPane: View {
    let session: AgentSession
    let chatStore: SessionChatStore?
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
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
            TahoeDiffPreviewPane(repoCwd: session.effectiveCwd)
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
                onBeforeMerge: {
                    await createCheckpoint(summary: "Before PR merge")
                }
            )
        case .terminal:
            TahoeTerminalCompactPane(session: session, chatStore: chatStore)
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
                token: PairingTokenStore.shared.currentToken()
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

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
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
    let repoCwd: String
    @State private var lines: [DiffLine] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if isLoading {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Loading diff…")
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                    }
                    .padding(16)
                } else if lines.isEmpty {
                    TahoeEmptyReviewState(icon: "diff", title: "No local diff", body: "The worktree has no visible git diff.")
                        .frame(minWidth: 330)
                        .padding(16)
                } else {
                    ForEach(lines) { line in
                        HStack(spacing: 0) {
                            Text(line.sign)
                                .frame(width: 14, alignment: .leading)
                                .opacity(0.75)
                            Text(line.text)
                                .textSelection(.enabled)
                        }
                        .font(TahoeFont.mono(11.5))
                        .foregroundStyle(line.foreground(t))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 1)
                        .background(line.background(t))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(t.dark ? Color.black.opacity(0.18) : Color.black.opacity(0.03))
        .task(id: repoCwd) { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        let cwd = repoCwd
        let loaded = await Task.detached(priority: .utility) {
            Self.loadGitDiff(cwd: cwd)
        }.value
        lines = loaded
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
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(220)
                .map { DiffLine(String($0)) }
        } catch {
            return [DiffLine("Unable to load diff: \(error.localizedDescription)", forcedKind: .meta)]
        }
    }

    private struct DiffLine: Identifiable {
        enum Kind { case meta, hunk, add, del, context }
        let id = UUID()
        let text: String
        let kind: Kind

        init(_ text: String, forcedKind: Kind? = nil) {
            self.text = text
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

                    TahoeGlass(radius: 12, tone: .chip) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Checks")
                                .font(TahoeFont.body(11, weight: .semibold))
                                .foregroundStyle(t.fg3)
                                .padding(.bottom, 6)
                            prStatusRow("review", state.reviewState ?? "pending", state.reviewState == "APPROVED")
                            prStatusRow("ci", state.checksRollup ?? "unknown", state.checksRollup == "success")
                            prStatusRow("changes", "+\(state.additions) -\(state.deletions)", true)
                        }
                        .padding(12)
                    }

                    Button(action: { NSWorkspace.shared.open(state.url) }) {
                        HStack(spacing: 6) {
                            TahoeIcon("pull", size: 12)
                            Text("Open PR on GitHub")
                                .font(TahoeFont.body(12, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
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
                            TahoeGhostButton(size: .m, action: { Task { await merge(state) } }) {
                                Text(PRCoordinator.canMerge(snapshot: state, canUseDaemonActions: true) ? "Merge" : "Merge blocked")
                            }
                            .disabled(!PRCoordinator.canMerge(snapshot: state, canUseDaemonActions: true))
                        }
                    }
                } else {
                    TahoeEmptyReviewState(icon: "pull", title: "No PR detected", body: "Paste a PR URL or let the agent create one.")
                    TextField("https://github.com/owner/repo/pull/123", text: $coordinator.manualURL)
                        .textFieldStyle(.roundedBorder)
                        .font(TahoeFont.mono(11.5))
                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .m, action: { coordinator.loadFromManualURL() }) {
                            Text("Load")
                        }
                        if coordinator.canUseDaemonActions {
                            TahoeGhostButton(size: .m, action: { Task { await coordinator.createPR() } }) {
                                TahoeIcon("pull", size: 11)
                                Text("Create PR")
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
                .fill(passed ? Color.green : Color.yellow)
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

    private func merge(_ state: PRCoordinator.Snapshot) async {
        guard PRCoordinator.canMerge(snapshot: state, canUseDaemonActions: coordinator.canUseDaemonActions) else { return }
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

private struct TahoeTerminalCompactPane: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    let chatStore: SessionChatStore?

    private var lines: [TerminalLine] {
        let pairs = (chatStore?.snapshot.items ?? []).flatMap { item -> [ToolPair] in
            if case .toolRun(_, let pairs) = item { return pairs }
            return []
        }
        return pairs.suffix(6).flatMap { pair -> [TerminalLine] in
            let bash = pair.result?.bashResult ?? pair.call.bashResult
            let command = bash?.command ?? pair.call.detail ?? pair.call.body
            var out: [TerminalLine] = [TerminalLine(text: "$ \(command)", color: .muted)]
            if let stdout = bash?.stdout?.split(separator: "\n").prefix(2), !stdout.isEmpty {
                out.append(contentsOf: stdout.map { TerminalLine(text: String($0), color: .normal) })
            }
            if let stderr = bash?.stderr?.split(separator: "\n").prefix(1), !stderr.isEmpty {
                out.append(contentsOf: stderr.map { TerminalLine(text: String($0), color: .error) })
            }
            if let exit = bash?.exitCode {
                out.append(TerminalLine(text: "exit \(exit)", color: exit == 0 ? .success : .error))
            }
            return out
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if lines.isEmpty {
                    TerminalLine(text: "$ _", color: .muted).view(t)
                } else {
                    ForEach(lines) { line in
                        line.view(t)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(t.dark ? Color.black.opacity(0.30) : Color.black.opacity(0.04))
        .contextMenu {
            Button("Open live terminal") {
                NotificationCenter.default.post(name: .showRawTerminal, object: nil, userInfo: ["sessionId": session.id])
            }
        }
    }

    private struct TerminalLine: Identifiable {
        enum LineColor { case muted, normal, success, error }
        let id = UUID()
        let text: String
        let color: LineColor

        func view(_ t: TahoeTokens) -> some View {
            Text(text)
                .font(TahoeFont.mono(11.5))
                .foregroundStyle(foreground(t))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .padding(.vertical, 2)
        }

        private func foreground(_ t: TahoeTokens) -> Color {
            switch color {
            case .muted: return t.fg3
            case .normal: return t.fg2
            case .success: return Color.green
            case .error: return Color.red
            }
        }
    }
}

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

private struct TerminalTabContainer: View {
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    let wsPort: Int
    let token: String

    /// nil = primary pane. Non-nil = a TerminalPaneRef.id from session.terminalPanes.
    @State private var selectedSecondaryId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            terminal
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New terminal pane")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
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
                        .foregroundStyle(.secondary)
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
        MacTerminalView(
            sessionId: session.id,
            host: "127.0.0.1",
            wsPort: wsPort,
            token: token,
            paneId: targetPaneId
        )
        .id(targetPaneId ?? "primary")
    }
}

// MARK: - Cross-pane notifications (keyboard shortcuts)

extension Notification.Name {
    static let focusSidebarSearch = Notification.Name("clawdmeter.workspace.focusSidebarSearch")
    static let toggleCodeReviewPane = Notification.Name("clawdmeter.workspace.toggleCodeReviewPane")
    static let openCodeReviewPane = Notification.Name("clawdmeter.workspace.openCodeReviewPane")
    static let popOutSession = Notification.Name("clawdmeter.workspace.popOutSession")
    /// Posted to open the raw tmux Cmd+T overlay on a specific session.
    /// (Wave B: chat-first; terminal demoted to overlay.)
    static let showRawTerminal = Notification.Name("clawdmeter.workspace.showRawTerminal")
    /// Posted by iOS via the daemon's compose-draft WS event to seed the
    /// Mac empty-state composer with iPhone-typed prompt text (X1).
    static let composeDraftIncoming = Notification.Name("clawdmeter.workspace.composeDraftIncoming")
}

/// Workspace-level width preference. Drives responsive collapsing of the
/// review pane (and at very narrow widths, the sidebar).
private struct WorkspaceWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct SidebarViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct SidebarContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

// MARK: - G15 scheduler sheet

private struct FollowUpSchedulerSheet: View {
    let session: AgentSession
    let registry: AgentSessionRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var fireAt: Date = Date().addingTimeInterval(5 * 60)
    @State private var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule follow-up")
                .font(.system(size: 16, weight: .semibold))
            Text("Sends the prompt as a fresh message into this session at the chosen time.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            DatePicker("Fire at", selection: $fireAt, in: Date()...)
                .datePickerStyle(.field)
            TextField("Prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
            if !session.scheduledFollowUps.isEmpty {
                Divider()
                Text("Pending")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(session.scheduledFollowUps.filter { $0.firedAt == nil }) { up in
                    HStack {
                        Text(up.fireAt, style: .time)
                            .font(.system(size: 11, design: .monospaced))
                        Text(up.prompt)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Button(action: {
                            registry.removeScheduledFollowUp(sessionId: session.id, followUpId: up.id)
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Schedule") {
                    let up = ScheduledFollowUp(fireAt: fireAt, prompt: prompt)
                    registry.addScheduledFollowUp(sessionId: session.id, followUp: up)
                    prompt = ""
                    fireAt = Date().addingTimeInterval(5 * 60)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }
}
