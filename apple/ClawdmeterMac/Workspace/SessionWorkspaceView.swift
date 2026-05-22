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

    @State private var rightPaneTab: RightPaneTab = .plan
    /// User's explicit toggle for the review pane. Default OFF so Sessions
    /// + chat get the full window by default; the user opts into the
    /// review pane via the right-edge gutter (CTA) or the toolbar button.
    @State private var showingReviewPane: Bool = false
    @State private var showingModeSwitchOverlay: Bool = false
    @State private var modeSwitchLabel: String = ""
    /// Workspace-level width, measured via GeometryReader. Drives responsive
    /// pane collapsing so even when the user opens the review pane it only
    /// renders if the window has room for it without clipping content.
    @State private var workspaceWidth: CGFloat = 1400

    @Environment(\.colorScheme) private var colorScheme

    /// Minimum width required to render the review pane at its full
    /// content-respecting width (≥440pt) without crushing sidebar + chat.
    /// 220 (sidebar min) + 480 (center min) + 440 (review min) + chrome.
    private static let reviewPaneThreshold: CGFloat = 1200

    /// Minimum width required to render even the right-edge gutter CTA.
    /// Below this, the workspace is just sidebar + chat — the user can
    /// resize to summon the gutter back.
    private static let gutterThreshold: CGFloat = 900

    private var effectiveShowReviewPane: Bool {
        showingReviewPane && workspaceWidth >= Self.reviewPaneThreshold
    }

    private var effectiveShowGutter: Bool {
        !effectiveShowReviewPane && workspaceWidth >= Self.gutterThreshold
    }

    enum RightPaneTab: String, CaseIterable, Identifiable {
        case plan = "Plan"
        case diff = "Diff"
        case sources = "Sources"
        case artifacts = "Artifacts"
        case browser = "Browser"
        case pr = "PR"
        case terminal = "Terminal"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .plan:      return "list.bullet.rectangle"
            case .diff:      return "arrow.triangle.swap"
            case .sources:   return "doc.text.magnifyingglass"
            case .artifacts: return "paperclip"
            case .browser:   return "safari"
            case .pr:        return "arrow.triangle.pull"
            case .terminal:  return "terminal"
            }
        }
    }

    var body: some View {
        HSplitView {
            SidebarPane(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 380)

            // Center pane carries the chat AND, when the review pane is
            // collapsed, a thin right-edge gutter that doubles as the
            // expand CTA. Keeping the gutter inside the center column
            // (instead of as its own HSplitView child) means the user
            // can't accidentally drag-resize it.
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    if let session = model.openSession {
                        CenterThread(
                            session: session,
                            isReadOnly: model.openSessionIsReadOnly,
                            model: model,
                            onModeSwitch: { newMode in
                                Task { await switchMode(session: session, to: newMode) }
                            }
                        )
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
                    Divider()
                    ReviewPaneGutter(
                        selectedTab: $rightPaneTab,
                        onExpand: { tab in
                            rightPaneTab = tab
                            withAnimation(.easeOut(duration: 0.18)) {
                                showingReviewPane = true
                            }
                        }
                    )
                }
            }
            .frame(minWidth: 420, idealWidth: 600)

            if effectiveShowReviewPane, let session = model.openSession {
                ReviewPane(
                    session: session,
                    chatStore: model.chatStore(for: session),
                    model: model,
                    selectedTab: $rightPaneTab,
                    onClose: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showingReviewPane = false
                        }
                    },
                    onApprove: {
                        Task { await model.approvePlan(id: session.id) }
                    }
                )
                .frame(minWidth: 440, idealWidth: 520, maxWidth: 620)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(backgroundColor)
        .background(
            // Measure the actual workspace width. Don't use GeometryReader
            // as the root because HSplitView misbehaves inside it.
            GeometryReader { proxy in
                Color.clear
                    .preference(key: WorkspaceWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(WorkspaceWidthKey.self) { workspaceWidth = $0 }
        .sheet(isPresented: $model.showingNewSessionSheet) {
            NewSessionMacSheet(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        showingReviewPane.toggle()
                    }
                }) {
                    Image(systemName: showingReviewPane
                        ? "sidebar.right"
                        : "sidebar.squares.right")
	                        .help(effectiveShowReviewPane
	                            ? "Hide review pane"
	                            : workspaceWidth < Self.reviewPaneThreshold
	                                ? "Widen the window to show the review pane"
	                                : "Show review pane")
	                }
	                .disabled(workspaceWidth < Self.reviewPaneThreshold)
            }
        }
        .background(KeyboardShortcuts(model: model))
    }

    /// Hidden buttons that own the Cmd+1..9 + Cmd+Shift+F + Cmd+;
    /// keyboard shortcuts. SwiftUI's `.keyboardShortcut` only fires when
    /// the view is in the focus chain; attaching to `Color.clear` in a
    /// background layer keeps them globally active without stealing focus.
    private struct KeyboardShortcuts: View {
        @ObservedObject var model: SessionsModel
        var body: some View {
            ZStack {
                ForEach(1...9, id: \.self) { index in
                    Button("") {
                        model.openVisibleSession(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")),
                                      modifiers: [.command])
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
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Center empty state — Codex-style centered composer

    private var centerEmpty: some View {
        EmptyStateCenteredComposer(model: model)
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
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool

    /// Persisted sidebar grouping + sorting + status-filter preferences.
    /// All three are local to the Mac UI — iOS has its own equivalents.
    @AppStorage("clawdmeter.sidebar.grouping") private var groupingRaw: String = SessionGrouping.repo.rawValue
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
            sidebarHeader
            Divider()
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .background(sidebarBg)
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
            Text("Code")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            filterMenu
            Button(action: { Task { await model.refresh() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh repo list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Linear-style filter / group / sort menu. Active non-default
    /// selections paint the chip terra-cotta so the user knows the
    /// sidebar is filtered without opening the menu.
    @ViewBuilder
    private var filterMenu: some View {
        let isCustomised =
            grouping != .repo
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
            if isCustomised {
                Divider()
                Button("Reset filters") {
                    statusRaw = SessionStatusFilter.all.rawValue
                    groupingRaw = SessionGrouping.repo.rawValue
                    sortingRaw = SessionSorting.recency.rawValue
                }
            }
        } label: {
            Image(systemName: isCustomised ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isCustomised ? terraCotta : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group, sort, and filter sessions")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search…", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !model.searchQuery.isEmpty {
                Button(action: { model.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Toggle("", isOn: $model.showArchived)
                .toggleStyle(.button)
                .controlSize(.mini)
                .help(model.showArchived ? "Hide archived" : "Show archived")
                .overlay(
                    Image(systemName: "archivebox")
                        .font(.system(size: 9))
                        .foregroundStyle(model.showArchived ? .primary : .secondary)
                        .allowsHitTesting(false)
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onReceive(NotificationCenter.default.publisher(for: .focusSidebarSearch)) { _ in
            searchFocused = true
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
                        ForEach(filteredReposForGrouping, id: \.key) { repo in
                            repoSection(repo)
                        }
                    } else {
                        // Date / Status / Agent / None — flatten across repos
                        // and let the grouper bucket by the chosen field.
                        let groups = SessionSidebarGrouper.group(
                            sessions: filteredVisibleSessions,
                            repos: filteredReposForGrouping,
                            grouping: grouping,
                            sorting: sorting,
                            statusFilter: statusFilter
                        )
                        ForEach(groups) { group in
                            groupSection(group)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
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
            if !model.showArchived, s.archivedAt != nil { return false }
            return true
        }
        return model.filter(sessions: all)
    }

    /// Generic group renderer for non-Repo groupings. Header is a plain
    /// label (no expand toggle — flatter taxonomy than repos). Session
    /// rows reuse `sessionRow`; recent rows reuse `recentSessionRow`.
    @ViewBuilder
    private func groupSection(_ group: SessionSidebarGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
    }

    private func repoSection(_ repo: AgentRepo) -> some View {
        let allSessions = model.sessions(for: repo.key, includeArchived: model.showArchived)
        let visibleSessions = model.filter(sessions: allSessions)
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
        HStack(alignment: .top, spacing: 8) {
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
        .background(isOpen ? terraCotta.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
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
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(repo.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
                if repo.liveSessionCount > 0 {
                    HStack(spacing: 2) {
                        Circle().fill(.green).frame(width: 4, height: 4)
                        Text("\(repo.liveSessionCount)")
                            .font(.system(size: 9, weight: .medium))
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

    private func sessionRow(_ session: AgentSession, isOpen: Bool, depth: Int = 0) -> some View {
        Button(action: {
            model.openSessionId = session.id
            model.openOutsideJSONLPath = nil
        }) {
            HStack(spacing: 8) {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(depth - 1) * 12)
                }
                Circle()
                    .fill(statusColor(session.status))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sessionTitle(session))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(sessionSubtitle(session))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                }
            }
            .padding(.leading, 24 + CGFloat(depth) * 6)
            .padding(.trailing, 24)
            .padding(.vertical, 5)
            .background(isOpen
                ? terraCotta.opacity(0.15)
                : Color.clear,
                in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(session.archivedAt != nil ? 0.6 : 1.0)
    }

    private func sessionTitle(_ session: AgentSession) -> String {
        // v0.5.4 — user-supplied customName wins. Fall back to the
        // session's stated goal, then to a synthesized provider+status
        // label so brand-new sessions are still identifiable.
        if let custom = session.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let goal = session.goal, !goal.isEmpty { return goal }
        return "\(session.agent.rawValue.capitalized) · \(session.status.rawValue)"
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
                Image(systemName: "plus.circle.fill")
                Text("New session")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(terraCotta, in: RoundedRectangle(cornerRadius: 7))
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

// MARK: - Center thread

private struct CenterThread: View {
    let session: AgentSession
    let isReadOnly: Bool
    @ObservedObject var model: SessionsModel
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
    /// Captured target mode for the bypass-mode trust-grant confirm sheet.
    /// When the user picks `.bypass` from the chip we stash it here and
    /// surface the existing autopilot confirm sheet, then commit on
    /// approval.
    @State private var pendingBypassMode = false

    init(session: AgentSession, isReadOnly: Bool, model: SessionsModel, onModeSwitch: @escaping (SessionMode) -> Void) {
        self.session = session
        self.isReadOnly = isReadOnly
        self.model = model
        self.onModeSwitch = onModeSwitch
        let store = ComposerStore(mode: .bound(sessionId: session.id))
        store.modelId = session.model
        store.effort = session.effort
        store.mode = session.mode
        store.agent = session.agent
        store.planMode = session.status == .planning
        store.repoKey = session.repoKey
        store.autopilotEnabled = AutopilotState.shared.isEnabled(sessionId: session.id)
        _composerStore = StateObject(wrappedValue: store)
        _prMirror = ObservedObject(wrappedValue: model.prMirror(for: session))
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            chatPane
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
        .onReceive(NotificationCenter.default.publisher(for: .showRawTerminal)) { note in
            if let id = note.userInfo?["sessionId"] as? UUID, id == session.id {
                showingTerminalOverlay = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                // v0.5.4: user-supplied customName takes precedence
                // over the session's goal in the chat header.
                Text(headerLabel(for: session))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(session.repoDisplayName) · \(session.agent.rawValue.capitalized) · \(session.status.rawValue)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let branch = branchLabel {
                        HStack(spacing: 3) {
                            Image(systemName: prBranchIcon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(branch)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(prBranchColor)
                        .help(branchTooltip)
                    }
                }
            }
            Spacer()
            // v0.5.2: the prominent "Read-only" pill was dropped per user
            // feedback — the composer's "Continue here" placeholder + the
            // disabled-action menu state already signal read-only mode.
            // Carrying a third badge in the header for the same fact
            // doubled the visual noise.
            if isReadOnly {
                EmptyView()
            } else {
                Menu {
                    Button("Show raw terminal (⌘T)") { showingTerminalOverlay = true }
                        .keyboardShortcut("t", modifiers: [.command])
                    Button("Schedule follow-up…", systemImage: "clock") {
                        showingScheduler = true
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
                            AttachmentStaging.cleanup(sessionId: session.id)
                            if let wt = session.worktreePath {
                                AttachmentStaging.cleanupWorktree(at: wt)
                            }
                        }
                    }
                    Button("End session", role: .destructive) {
                        Task {
                            await model.endSession(id: session.id)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            // Activity strip — time / tokens / cost / live indicator.
            // Sits between the message list and the composer so the user
            // always knows what the agent is doing without having to
            // switch to the Analytics tab.
            if let store = model.chatStore(for: session) {
                Divider()
                SessionActivityStrip(session: session, chatStore: store)
            }
            // Always render the composer — even for read-only synthetic
            // Recent-JSONL rows. Sending text on a read-only row
            // implicitly promotes it to a live `--resume`/`resume` spawn
            // via SessionsModel.continueCurrentReadOnly (Wave A redesign).
            Divider()
            composerArea
        }
    }

    @ViewBuilder
    private var messageList: some View {
        if let store = model.chatStore(for: session) {
            ChatThreadScroll(store: store, session: session, model: model)
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
            ContentUnavailableView {
                Label("No JSONL yet", systemImage: "ellipsis.bubble")
            } description: {
                Text("Waiting for the agent to write its first message…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var composerArea: some View {
        ComposerInputCore(
            store: composerStore,
            catalog: .bundled,
            agentForModelPicker: session.agent,
            modelSupportsEffort: modelSupportsEffort,
            onSend: { Task { await performBoundSend() } },
            onInterrupt: { Task { await performInterrupt() } },
            onToggleAutopilot: { showingAutopilotConfirm = true },
            onChangePermissionMode: { newMode in
                Task { await changePermissionMode(to: newMode) }
            },
            permissionMode: PermissionModeStore.shared.currentMode(for: session),
            onApprovePlan: { Task { await model.approvePlan(id: session.id) } },
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
            if let entry = ModelCatalog.bundled.entry(forId: new) {
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

    private func performBoundSend() async {
        composerStore.beginSend()
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
            target = live
        } else {
            target = session
        }

        let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
        var stagedPaths: [URL] = []
        if let dir = AttachmentStaging.stagingDir(for: target) {
            for att in composerStore.attachments {
                do {
                    let staged = try AttachmentStaging.stage(source: att.sourceURL, into: dir, attachmentId: att.id)
                    stagedPaths.append(staged)
                } catch {
                    composerStore.endSend(error: .daemonError(message: "Couldn't stage \(att.displayName): \(error.localizedDescription)"))
                    return
                }
            }
        }
        let body = composerStore.renderPromptBody(attachmentPaths: stagedPaths)
        do {
            try await sender.send(sessionId: target.id, body: body, asFollowUp: true)
            composerStore.endSend()
        } catch MacComposerSender.Error.http(let status, let retry) {
            switch status {
            case 401: composerStore.endSend(error: .unauthorized)
            case 404: composerStore.endSend(error: .sessionGone)
            case 429: composerStore.endSend(error: .rateLimited(retryAfter: retry))
            default: composerStore.endSend(error: .daemonError(message: "HTTP \(status)"))
            }
        } catch MacComposerSender.Error.transport(let m) {
            composerStore.endSend(error: .daemonError(message: m))
        } catch {
            composerStore.endSend(error: .daemonError(message: error.localizedDescription))
        }
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
        let modelId = session.model ?? model.chatStore(for: session)?.snapshot.modelHint
        guard let modelId, !modelId.isEmpty else { return nil }
        let entry = ModelCatalog.bundled.entry(forId: modelId)
        let snap = model.chatStore(for: session)?.snapshot
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
            effortDisplay: session.effort.map(effortLabel),
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

    /// Whether the current model supports an effort dial. Haiku 4.5 does
    /// not (supportsEffort=false in the bundled catalog); the dial renders
    /// disabled with an explanatory tooltip when this is false.
    private var modelSupportsEffort: Bool {
        guard let id = session.model,
              let entry = ModelCatalog.bundled.entry(forId: id)
        else { return true }
        return entry.supportsEffort
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

// MARK: - Chat thread scroll

private struct ChatThreadScroll: View {
    @ObservedObject var store: SessionChatStore
    let session: AgentSession
    let model: SessionsModel

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
                // Phase 1 of the WhatsApp-smooth Sessions plan: migrated
                // from `ScrollView { LazyVStack }` with per-row `.id(item.id)`
                // + per-row .onAppear/.onDisappear pin tracking to native
                // `List`. AppKit List backs this on macOS; if pin behavior
                // degrades on very long sessions (5k+ items), the
                // documented fall-back is `LazyVStack` WITHOUT `.id` per row
                // — keep identity stable via ForEach `id: \.id` and drive
                // pin state from the single bottom sentinel below.
                List {
                    if store.snapshot.items.isEmpty && !store.isLoading {
                        emptyState
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(store.snapshot.items) { item in
                            itemRow(item)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                    }
                    // v0.7.16: thinking-indicator is now a footer row in
                    // the List instead of a floating overlay. The old
                    // overlay sat on top of the chat content at the
                    // bottom-leading corner with `.allowsHitTesting(false)`
                    // — when the user scrolled to the tail, the pill
                    // covered the last 1-2 lines of the most recent
                    // message. Inline-as-footer means the indicator
                    // takes its own band below the last bubble and
                    // scrolls with the content. The view self-hides
                    // when `isActive` is false, so idle sessions get
                    // zero vertical space.
                    HStack {
                        LiveSessionActivityIndicator(
                            agent: session.agent,
                            lastEventAt: store.snapshot.lastEventAt
                        )
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    // Single-row pin sentinel — replaces the per-row
                    // .onAppear/.onDisappear pin tracking that fired on
                    // every chat-item row. One callback per scroll-edge
                    // event instead of N per scroll-frame.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomSentinelId)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .onAppear { userPinnedToBottom = true }
                        .onDisappear { userPinnedToBottom = false }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: store.snapshot.items.count) { _, _ in
                    stickToBottomIfPinned(proxy, items: store.snapshot.items.count)
                }
                .onAppear {
                    proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                    lastScrollItemCount = store.snapshot.items.count
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                    }
                }

                // Jump-to-latest CTA. Visible whenever the user has
                // scrolled away from the bottom (a new turn lands while
                // they're reading history). Click → scroll-to-last-item.
                if !userPinnedToBottom, !store.snapshot.items.isEmpty {
                    Button(action: {
                        userPinnedToBottom = true
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
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
                // a footer row inside the List above (see comment there).
            }
            .animation(.easeOut(duration: 0.18), value: userPinnedToBottom)
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

    private func stickToBottomIfPinned(_ proxy: ScrollViewProxy, items: Int) {
        let delta = items - lastScrollItemCount
        lastScrollItemCount = items
        // Only auto-scroll when the user is currently watching the tail.
        // Reading history shouldn't be interrupted by a new agent turn.
        guard userPinnedToBottom else { return }
        // Skip animation for big jumps (paste-of-history) or while the
        // store is still doing its initial backfill — animating each step
        // produces a visible scroll-blur.
        let animate = !(delta > 5 || store.isLoading)
        // Coalesce rapid bumps via a 50ms debounce so a streaming reply
        // that grows the items array on every commit doesn't animate
        // scroll-to-latest per token. The single belt-and-suspenders
        // re-scroll after 100ms catches late-arriving layout passes.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard userPinnedToBottom else { return }
            if animate {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
            }
        }
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
        case .toolRun(let id, let pairs):
            // v0.5.5/v0.5.6: partition by tool kind:
            //   • Edit/MultiEdit/Write → inline EditDiffRow chips
            //   • AskUserQuestion       → interactive AskUserQuestionTray
            //   • everything else       → "Ran N commands" disclosure
            let editPairs = pairs.filter { $0.call.editStats != nil }
            let askPairs  = pairs.filter { $0.call.askUserQuestion != nil }
            let otherPairs = pairs.filter {
                $0.call.editStats == nil && $0.call.askUserQuestion == nil
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(editPairs) { pair in
                    if let stats = pair.call.editStats {
                        EditDiffRow(stats: stats, resultBody: pair.result?.body)
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
                    toolRunGroup(id: id, pairs: otherPairs)
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
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Ran \(pairs.count) command\(pairs.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(alignment: .leading, spacing: 6) {
                if let detail = pair.call.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                if let result = pair.result, !result.body.isEmpty {
                    Text(result.body)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(40)
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
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(toolTint(pair.call.title))
                Text(pair.call.body)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }
            }
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(QuietDisclosure())
    }

    private func userBubble(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 4) {
                Text(msg.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(terraCotta.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func assistantBubble(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11))
                .foregroundStyle(terraCotta)
                .frame(width: 18, height: 18)
                .padding(.top, 3)
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
        switch name {
        case "Read", "Glob", "Grep": return "doc.text.magnifyingglass"
        case "Write": return "pencil"
        case "Edit": return "pencil.line"
        case "Bash": return "terminal"
        case "WebFetch", "WebSearch": return "globe"
        case "Task": return "person.fill.questionmark"
        default: return "wrench.adjustable"
        }
    }

    private func toolTint(_ name: String) -> Color {
        switch name {
        case "Read", "Glob", "Grep": return .blue
        case "Write", "Edit": return terraCotta
        case "Bash": return .green
        case "WebFetch", "WebSearch": return .purple
        default: return .secondary
        }
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

// MARK: - Review-pane gutter (collapsed CTA)

/// Thin vertical strip on the right edge of the center pane shown when the
/// review pane is collapsed. Each icon is a tap target that opens the
/// review pane focused on that tab — the CTA the user asked for. When the
/// pane is expanded the gutter hides; the pane's own × button collapses
/// it back to this strip.
private struct ReviewPaneGutter: View {
    @Binding var selectedTab: SessionWorkspaceView.RightPaneTab
    let onExpand: (SessionWorkspaceView.RightPaneTab) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            ForEach(SessionWorkspaceView.RightPaneTab.allCases) { tab in
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
        .background(gutterBg)
    }

    private var gutterBg: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.95, green: 0.95, blue: 0.95)
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
    @Binding var selectedTab: SessionWorkspaceView.RightPaneTab
    let onClose: () -> Void
    let onApprove: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
        }
        .background(paneBg)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            // The chip strip scrolls horizontally if there's not enough
            // room — keeps each chip at natural width instead of letting
            // SwiftUI squeeze the text into per-character wrapping.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(SessionWorkspaceView.RightPaneTab.allCases) { tab in
                        tabChip(tab)
                    }
                }
            }
            .scrollClipDisabled()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide review pane (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func tabChip(_ tab: SessionWorkspaceView.RightPaneTab) -> some View {
        let isSelected = (selectedTab == tab)
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 9))
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(isSelected ? terraCotta.opacity(0.20) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .plan:
            if let chatStore {
                // v0.7.8: Codex SDK sessions get the dedicated
                // CodexPlanPane that reads the structured todo_list
                // events the ingestor stores on the snapshot. Claude
                // + Antigravity + Codex-CLI keep the existing
                // PlanTrackerPane (which mines steps from chat text).
                if session.agent == .codex {
                    CodexPlanPane(chatStore: chatStore)
                } else {
                    PlanTrackerPane(session: session, chatStore: chatStore, onApprove: onApprove)
                }
            } else {
                placeholder(text: "Waiting for agent JSONL…")
            }
        case .diff:
            GitDiffPane(repoCwd: session.effectiveCwd)
        case .sources:
            if let chatStore {
                SourcesPane(session: session, chatStore: chatStore)
            } else {
                placeholder(text: "Waiting for agent JSONL…")
            }
        case .artifacts:
            if let chatStore {
                ArtifactsPane(session: session, chatStore: chatStore)
            } else {
                placeholder(text: "Waiting for agent JSONL…")
            }
        case .browser:
            InAppBrowser(session: session, model: model)
        case .pr:
            PRReviewPane(session: session, mirror: model.prMirror(for: session))
        case .terminal:
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

    private var paneBg: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.95, green: 0.95, blue: 0.95)
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
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
