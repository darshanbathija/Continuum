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
    @State private var showingReviewPane: Bool = true
    @State private var showingModeSwitchOverlay: Bool = false
    @State private var modeSwitchLabel: String = ""

    @Environment(\.colorScheme) private var colorScheme

    enum RightPaneTab: String, CaseIterable, Identifiable {
        case plan = "Plan"
        case diff = "Diff"
        case sources = "Sources"
        case artifacts = "Artifacts"
        case browser = "Browser"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .plan:      return "list.bullet.rectangle"
            case .diff:      return "arrow.triangle.swap"
            case .sources:   return "doc.text.magnifyingglass"
            case .artifacts: return "paperclip"
            case .browser:   return "safari"
            }
        }
    }

    var body: some View {
        HSplitView {
            SidebarPane(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 380)

            ZStack {
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
            }
            .frame(minWidth: 420, idealWidth: 600)

            if showingReviewPane, let session = model.openSession {
                ReviewPane(
                    session: session,
                    chatStore: model.chatStore(for: session),
                    model: model,
                    selectedTab: $rightPaneTab,
                    onClose: { showingReviewPane = false },
                    onApprove: {
                        Task { await model.approvePlan(id: session.id) }
                    }
                )
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            }
        }
        .background(backgroundColor)
        .sheet(isPresented: $model.showingNewSessionSheet) {
            NewSessionMacSheet(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showingReviewPane.toggle() }) {
                    Image(systemName: showingReviewPane ? "sidebar.right" : "sidebar.right")
                        .help(showingReviewPane ? "Hide review pane" : "Show review pane")
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
        }
        .background(KeyboardShortcuts(model: model))
    }

    /// Hidden buttons that own the Cmd+1..9 + Cmd+Shift+F keyboard
    /// shortcuts. SwiftUI's `.keyboardShortcut` only fires when the view is
    /// in the focus chain; attaching to `Color.clear` in a background layer
    /// keeps them globally active without stealing focus.
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
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Center empty state

    private var centerEmpty: some View {
        VStack(spacing: 14) {
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Pick a session to open it here")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
            Text("Or create a new one ↗")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(action: { model.showingNewSessionSheet = true }) {
                Label("New session", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(terraCotta)
            .keyboardShortcut("n", modifiers: [.command])
        }
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
    }

    private var sidebarHeader: some View {
        HStack {
            Text("Sessions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
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
                    ForEach(model.filteredRepos, id: \.key) { repo in
                        repoSection(repo)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func repoSection(_ repo: AgentRepo) -> some View {
        let allSessions = model.sessions(for: repo.key, includeArchived: model.showArchived)
        let visibleSessions = model.filter(sessions: allSessions)
        let isExpanded = model.expandedRepoKeys.contains(repo.key)
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(repo, isExpanded: isExpanded, sessionCount: visibleSessions.count)
            if isExpanded {
                ForEach(visibleSessions) { session in
                    sessionRow(session, isOpen: model.openSessionId == session.id)
                        .contextMenu {
                            if session.archivedAt == nil {
                                Button("Archive") { model.registry.archive(id: session.id) }
                            } else {
                                Button("Unarchive") { model.registry.unarchive(id: session.id) }
                            }
                            Divider()
                            Button("End session", role: .destructive) {
                                Task { await model.endSession(id: session.id) }
                            }
                        }
                }
                if repo.liveSessionCount > 0 {
                    Button(action: { model.openOutsideSession(repoKey: repo.key) }) {
                        outsideSessionRow(repo)
                    }
                    .buttonStyle(.plain)
                }
                if visibleSessions.isEmpty && repo.liveSessionCount == 0 {
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

    private func sessionRow(_ session: AgentSession, isOpen: Bool) -> some View {
        Button(action: {
            model.openSessionId = session.id
            model.openOutsideRepoKey = nil
        }) {
            HStack(spacing: 8) {
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
            .padding(.horizontal, 24)
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

    private func outsideSessionRow(_ repo: AgentRepo) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.green).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("Latest outside")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Text("read-only · \(repo.liveSessionCount) JSONL")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "eye")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func sessionTitle(_ session: AgentSession) -> String {
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

    @State private var composerText: String = ""
    @State private var composerTextBeforeDictation: String = ""
    @State private var viewMode: ViewMode = .chat
    @State private var showingScheduler = false
    @StateObject private var dictation = SpeechDictation()

    enum ViewMode: String, CaseIterable {
        case chat = "Chat"
        case terminal = "Terminal"
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                switch viewMode {
                case .chat:     chatPane
                case .terminal: terminalPane
                }
            }
        }
        .sheet(isPresented: $showingScheduler) {
            FollowUpSchedulerSheet(session: session, registry: model.registry)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.goal ?? session.repoDisplayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(session.repoDisplayName) · \(session.agent.rawValue.capitalized) · \(session.status.rawValue)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isReadOnly {
                Text("Read-only")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            } else {
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .labelsHidden()

                Menu {
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
                        }
                    }
                    Button("End session", role: .destructive) {
                        Task {
                            await model.endSession(id: session.id)
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

    private var chatPane: some View {
        VStack(spacing: 0) {
            messageList
            if !isReadOnly {
                Divider()
                composerArea
            } else {
                Divider()
                readOnlyFooter
            }
        }
    }

    @ViewBuilder
    private var messageList: some View {
        if let store = model.chatStore(for: session) {
            ChatThreadScroll(store: store, session: session, model: model)
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
        VStack(spacing: 6) {
            HStack {
                ModePicker(mode: session.mode, agent: session.agent, onChange: onModeSwitch)
                Spacer()
                if session.planText != nil {
                    Button(action: {
                        Task { await model.approvePlan(id: session.id) }
                    }) {
                        Label("Approve plan", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(terraCotta)
                    .controlSize(.small)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: {}) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .help("Attach (not yet wired)")

                Button(action: toggleDictation) {
                    Image(systemName: dictation.state == .recording ? "mic.fill" : "mic")
                        .font(.system(size: 14))
                        .foregroundStyle(dictation.state == .recording ? terraCotta : .secondary)
                        .symbolEffect(.pulse, isActive: dictation.state == .recording)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("m", modifiers: [.control])
                .help(dictationTooltip)

                TextField("Message the agent…", text: $composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(composerBg, in: RoundedRectangle(cornerRadius: 8))
                    .lineLimit(1...6)
                    .onSubmit { sendComposer() }

                Button(action: sendComposer) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(composerText.isEmpty ? .secondary : terraCotta)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(composerText.isEmpty)
                .help("Send (⌘↩)")
            }
            if case let .denied(reason) = dictation.state {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            } else if case let .unavailable(reason) = dictation.state {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onReceive(dictation.$partialTranscript) { newPartial in
            guard dictation.state == .recording, !newPartial.isEmpty else { return }
            let base = composerTextBeforeDictation
            composerText = base.isEmpty ? newPartial : "\(base) \(newPartial)"
        }
    }

    private func toggleDictation() {
        if dictation.state == .recording {
            dictation.stop()
        } else {
            composerTextBeforeDictation = composerText
            Task { await dictation.start() }
        }
    }

    private var dictationTooltip: String {
        switch dictation.state {
        case .recording: return "Stop dictation (Ctrl+M)"
        case .requestingPermission: return "Requesting permission…"
        case .denied(let r): return r
        case .unavailable(let r): return r
        case .idle: return "Dictate (Ctrl+M)"
        }
    }

    private var readOnlyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Read-only — started outside Clawdmeter.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        guard let runtime = AppDelegate.runtime,
              let pane = session.tmuxPaneId ?? session.tmuxWindowId else { return }
        let bytes = Data((text + "\n").utf8)
        Task {
            try? await runtime.tmuxClient.pasteBytes(paneId: pane, bytes: bytes)
        }
    }

    @ViewBuilder
    private var terminalPane: some View {
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

    private var statusColor: Color {
        switch session.status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return terraCotta
        case .degraded: return .secondary
        }
    }

    private var composerBg: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.messages.isEmpty && !store.isLoading {
                        emptyState
                    } else {
                        ForEach(store.messages) { msg in
                            messageRow(msg)
                                .id(msg.id)
                                .padding(.horizontal, 16)
                        }
                    }
                    Color.clear.frame(height: 12).id("bottom-anchor")
                }
                .padding(.vertical, 12)
            }
            .onChange(of: store.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }

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
    private func messageRow(_ msg: SessionChatStore.ChatMessage) -> some View {
        switch msg.kind {
        case .userText:      userBubble(msg)
        case .assistantText: assistantBubble(msg)
        case .toolCall:      toolCallCard(msg)
        case .toolResult:    toolResultCard(msg)
        case .meta:          metaRow(msg)
        }
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

    private func toolCallCard(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toolIcon(msg.title))
                .font(.system(size: 11))
                .foregroundStyle(toolTint(msg.title))
                .frame(width: 18, height: 18)
            Text(msg.title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(toolTint(msg.title))
            Text(msg.body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(toolTint(msg.title).opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func toolResultCard(_ msg: SessionChatStore.ChatMessage) -> some View {
        let trimmed = msg.body.split(whereSeparator: \.isNewline)
            .prefix(3).joined(separator: "\n")
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: msg.isError ? "exclamationmark.triangle" : "arrow.turn.down.right")
                .font(.system(size: 10))
                .foregroundStyle(msg.isError ? .red : .secondary)
                .frame(width: 18, height: 18)
            Text(trimmed)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(msg.isError ? .red : .secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

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
        HStack(spacing: 2) {
            ForEach(SessionWorkspaceView.RightPaneTab.allCases) { tab in
                tabChip(tab)
            }
            Spacer()
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
                PlanTrackerPane(session: session, chatStore: chatStore, onApprove: onApprove)
            } else {
                placeholder(text: "Waiting for agent JSONL…")
            }
        case .diff:
            GitDiffPane(repoCwd: session.worktreePath ?? session.repoKey)
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
