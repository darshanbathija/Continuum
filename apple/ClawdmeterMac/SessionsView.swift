import SwiftUI
import ClawdmeterShared

/// Sessions tab. List of repos with sessions nested underneath; click into
/// a session → chat-style detail with explicit back chrome (state-driven
/// view swap, NOT NavigationStack — on macOS that splits into columns +
/// hides the back affordance).
///
/// Design reference: Anthropic's Claude Code desktop redesign (April 2026)
/// — left sidebar of sessions + central conversational thread + chat tab
/// with markdown / tool-call cards. We render the same primitives.
struct SessionsView: View {

    @ObservedObject var model: SessionsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let session = model.openSession {
                SessionChatView(
                    session: session,
                    isReadOnly: model.openSessionIsReadOnly,
                    onBack: { model.closeChatView() },
                    model: model
                )
            } else {
                listView
            }
        }
        .background(backgroundColor)
        .sheet(isPresented: $model.showingNewSessionSheet) {
            NewSessionMacSheet(model: model)
        }
    }

    // MARK: - List

    private var listView: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
            Divider()
            newSessionButton
        }
    }

    private var headerBar: some View {
        HStack {
            Text("Sessions")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(secondaryText)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button(action: { Task { await model.refresh() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh repo list")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.repos.isEmpty && model.registry.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.repos, id: \.key) { repo in
                        repoSection(repo)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(secondaryText)
            Text("No repos detected yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(primaryText)
            Text("Once you run Claude or Codex in a repo, it'll show up here. You can also add a scan root in Settings → Sessions, or click ＋ New session below to enter a path directly.")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func repoSection(_ repo: AgentRepo) -> some View {
        let sessions = model.sessions(for: repo.key)
        let isExpanded = model.expandedRepoKeys.contains(repo.key)
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(repo, isExpanded: isExpanded, sessionCount: sessions.count)
            if isExpanded {
                // Clawdmeter-spawned sessions (controllable).
                ForEach(sessions) { session in
                    Button(action: { model.openSessionId = session.id }) {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                }
                // Outside-Clawdmeter activity: show as a read-only row that
                // opens the newest JSONL.
                if repo.liveSessionCount > 0 {
                    Button(action: { model.openOutsideSession(repoKey: repo.key) }) {
                        outsideSessionRow(repo)
                    }
                    .buttonStyle(.plain)
                }
                // Empty / always-available "start a session here" row.
                if sessions.isEmpty && repo.liveSessionCount == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(secondaryText)
                        Text("Start a session here")
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectedRepoKey = repo.key
                        model.showingNewSessionSheet = true
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func repoHeader(_ repo: AgentRepo, isExpanded: Bool, sessionCount: Int) -> some View {
        Button(action: {
            if isExpanded { model.expandedRepoKeys.remove(repo.key) }
            else { model.expandedRepoKeys.insert(repo.key) }
        }) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .frame(width: 12)
                Text(repo.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryText)
                if sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(secondaryText.opacity(0.15), in: Capsule())
                }
                if repo.liveSessionCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text("\(repo.liveSessionCount) live")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .help("\(repo.liveSessionCount) JSONL file(s) modified in the last 5 minutes — Conductor, Cursor, or a Terminal-launched agent is writing here right now. Clawdmeter doesn't control these directly; click to open the latest session as read-only chat.")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func outsideSessionRow(_ repo: AgentRepo) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Latest session (outside Clawdmeter)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primaryText)
                Text("\(repo.liveSessionCount) JSONL touched recently · read-only chat")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "eye")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .help("Open as read-only chat. Clawdmeter can't control sessions it didn't spawn — composer is disabled.")
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(secondaryText)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(session.status))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle(session))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primaryText)
                Text(sessionSubtitle(session))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if session.planText != nil {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(terraCotta)
                    .help("Plan ready for approval")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(secondaryText)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func sessionTitle(_ session: AgentSession) -> String {
        if let goal = session.goal, !goal.isEmpty { return goal }
        return "\(session.agent.rawValue.capitalized) · \(session.status.rawValue)"
    }

    private func sessionSubtitle(_ session: AgentSession) -> String {
        if let goal = session.goal, !goal.isEmpty {
            return "\(session.agent.rawValue.capitalized) · \(session.status.rawValue)"
        }
        return session.tmuxWindowId.map { "tmux \($0)" } ?? "starting…"
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

    private var newSessionButton: some View {
        Button(action: { model.showingNewSessionSheet = true }) {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("New session")
                    .fontWeight(.semibold)
                Spacer()
                if model.repos.isEmpty {
                    Text("(empty index — paste a path)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(terraCotta)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(16)
    }

    // MARK: - Theme

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.96, green: 0.96, blue: 0.96)
    }
    private var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }
    private var secondaryText: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.55)
    }
}

// MARK: - Chat-style detail

/// Per-session detail. Top: back button + repo + status. Middle: chat
/// thread (user / assistant / tool calls / tool results, dense Cursor-/
/// Claude-desktop-style rendering). Bottom: composer with paperclip +
/// input + send. Side toggle to swap to the raw terminal pane.
struct SessionChatView: View {
    let session: AgentSession
    let isReadOnly: Bool
    let onBack: () -> Void
    @ObservedObject var model: SessionsModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewMode: ViewMode = .chat
    @State private var chatStore: SessionChatStore?
    @State private var composerText: String = ""

    enum ViewMode: String, CaseIterable {
        case chat = "Chat"
        case terminal = "Terminal"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                switch viewMode {
                case .chat: chatPane
                case .terminal: terminalPane
                }
            }
        }
        .onAppear { ensureChatStore() }
        .onDisappear { chatStore?.stop() }
        .background(bg)
    }

    private func ensureChatStore() {
        guard chatStore == nil else { return }
        if let url = SessionChatStore.resolveSessionFileURL(repoCwd: session.repoKey) {
            let store = SessionChatStore(sessionId: session.id, sessionFileURL: url)
            store.start()
            self.chatStore = store
        }
    }

    // MARK: - Header (back chrome — the bug was no back affordance)

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Sessions")
                        .font(.system(size: 12))
                }
                .foregroundStyle(secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: [.command])

            Spacer().frame(width: 4)

            Circle().fill(statusColor).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 0) {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                Text("\(session.repoDisplayName) · \(session.agent.rawValue.capitalized) · \(session.status.rawValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
            Spacer()

            if isReadOnly {
                Text("Read-only")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
                    .help("This session was started outside Clawdmeter. We can show its JSONL but can't control it.")
            } else {
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()

                Menu {
                    Button("End session", role: .destructive) {
                        Task {
                            await model.endSession(id: session.id)
                            onBack()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerTitle: String {
        session.goal ?? session.repoDisplayName
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

    // MARK: - Chat pane

    private var chatPane: some View {
        VStack(spacing: 0) {
            messageList
            if !isReadOnly {
                Divider()
                composer
            } else {
                Divider()
                readOnlyFooter
            }
        }
    }

    private var readOnlyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
            Text("Read-only view of a session started outside Clawdmeter. Composer is disabled because we'd be writing into a tmux pane we don't own.")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var messageList: some View {
        if let store = chatStore {
            ChatMessagesScroll(store: store, session: session, model: model)
        } else {
            ContentUnavailableView {
                Label("No JSONL yet", systemImage: "ellipsis.bubble")
            } description: {
                Text("Waiting for the agent to write its first message. If this session was just spawned, it may take a few seconds.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: {}) {
                Image(systemName: "paperclip")
                    .font(.system(size: 14))
                    .foregroundStyle(secondaryText)
            }
            .buttonStyle(.plain)
            .help("Attach (not yet wired)")
            .disabled(true)

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
                    .foregroundStyle(composerText.isEmpty ? secondaryText : terraCotta)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(composerText.isEmpty)
            .help("Send (⌘↩)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        guard let runtime = AppDelegate.runtime,
              let pane = session.tmuxPaneId ?? session.tmuxWindowId else { return }
        // Send the text + newline. The pane is running an interactive TUI;
        // most TUIs accept stdin via a paste.
        let bytes = Data((text + "\n").utf8)
        Task {
            do {
                try await runtime.tmuxClient.pasteBytes(paneId: pane, bytes: bytes)
            } catch {
                // Surface in a future iteration.
            }
        }
    }

    // MARK: - Terminal pane

    @ViewBuilder
    private var terminalPane: some View {
        if let runtime = AppDelegate.runtime,
           let port = runtime.agentControlServer.boundWsPort {
            MacTerminalView(
                sessionId: session.id,
                host: "127.0.0.1",
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

    // MARK: - Theme

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
    private var bg: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.08)
            : Color(red: 0.98, green: 0.98, blue: 0.98)
    }
    private var composerBg: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }
    private var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }
    private var secondaryText: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.55)
    }
}

/// The actual scrollable thread, observing the chat store's messages.
/// Auto-scrolls to bottom on new messages (chat-app behavior).
private struct ChatMessagesScroll: View {
    @ObservedObject var store: SessionChatStore
    let session: AgentSession
    let model: SessionsModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Plan card pinned at top when present.
                    if let planText = session.planText, !planText.isEmpty {
                        PlanCardView(
                            goal: session.goal,
                            planSummary: planText,
                            files: [],
                            onApprove: {
                                Task { await model.approvePlan(id: session.id) }
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    }

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
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No messages yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Type below to talk to the agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Message rendering

    @ViewBuilder
    private func messageRow(_ msg: SessionChatStore.ChatMessage) -> some View {
        switch msg.kind {
        case .userText:
            userBubble(msg)
        case .assistantText:
            assistantBubble(msg)
        case .toolCall:
            toolCallCard(msg)
        case .toolResult:
            toolResultCard(msg)
        case .meta:
            metaRow(msg)
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
                    .background(terraCotta.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
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
                Text(msg.body)
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
        .background(toolTint(msg.title).opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func toolResultCard(_ msg: SessionChatStore.ChatMessage) -> some View {
        let trimmed = msg.body.split(whereSeparator: \.isNewline).prefix(3).joined(separator: "\n")
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

// MARK: - New session sheet (Mac)

struct NewSessionMacSheet: View {
    @ObservedObject var model: SessionsModel
    @Environment(\.dismiss) private var dismiss

    @State private var repoPath: String = ""
    @State private var agent: AgentKind = .claude
    @State private var goal: String = ""
    @State private var planMode: Bool = true
    @State private var useWorktree: Bool = false
    @State private var isSpawning: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New session")
                .font(.system(size: 18, weight: .semibold))

            Form {
                Picker("Pick a repo", selection: $repoPath) {
                    Text("(custom path)").tag("")
                    ForEach(model.repos, id: \.key) { repo in
                        let suffix = repo.liveSessionCount > 0 ? "  • live" : ""
                        Text("\(repo.displayName)\(suffix)").tag(repo.key)
                    }
                }
                .pickerStyle(.menu)

                TextField("Or enter a path", text: $repoPath,
                          prompt: Text("/Users/.../my-repo"))

                Picker("Agent", selection: $agent) {
                    Text("Claude").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                }
                .pickerStyle(.segmented)

                TextField("Goal", text: $goal,
                          prompt: Text("Optional. Used by done-detector + worktree slug."))

                Toggle("Plan mode (Claude only)", isOn: $planMode)
                    .disabled(agent != .claude)

                Toggle("Branch off main (new worktree)", isOn: $useWorktree)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSpawning ? "Starting…" : "Start") {
                    Task { await startSession() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
                .disabled(repoPath.isEmpty || isSpawning)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if let selected = model.selectedRepoKey { repoPath = selected }
        }
    }

    private func startSession() async {
        isSpawning = true
        errorMessage = nil
        defer { isSpawning = false }
        guard let runtime = AppDelegate.runtime else {
            errorMessage = "Daemon not started — relaunch Clawdmeter."
            return
        }
        do {
            _ = try await model.spawnSession(
                repoPath: repoPath,
                agent: agent,
                planMode: agent == .claude && planMode,
                goal: goal.isEmpty ? nil : goal,
                useWorktree: useWorktree,
                tmux: runtime.tmuxClient
            )
            dismiss()
        } catch {
            errorMessage = (error as? TmuxControlClient.TmuxError).map(humanize)
                ?? error.localizedDescription
        }
    }

    private func humanize(_ err: TmuxControlClient.TmuxError) -> String {
        switch err {
        case .notStarted: return "tmux not started — try again in a moment"
        case .commandFailed(let s): return "tmux: \(s)"
        case .serverExited: return "tmux server exited"
        case .ptyClosed: return "PTY closed unexpectedly"
        }
    }
}

// MARK: - Model

@MainActor
public final class SessionsModel: ObservableObject {

    @Published public var repos: [AgentRepo] = []
    @Published public var selectedRepoKey: String?
    @Published public var isRefreshing: Bool = false
    @Published public var showingNewSessionSheet: Bool = false
    @Published public var expandedRepoKeys: Set<String> = []
    /// The session currently pushed open in the chat detail view. nil = list mode.
    @Published public var openSessionId: UUID?

    /// When the user opens a repo's outside-Clawdmeter latest session, we
    /// synthesize a read-only AgentSession instance and route the chat view
    /// at it. Stored here so it survives the SessionChatView render cycle.
    @Published public var openOutsideRepoKey: String?
    private var syntheticOutsideSessions: [String: AgentSession] = [:]

    public var openSession: AgentSession? {
        if let id = openSessionId, let s = registry.sessions.first(where: { $0.id == id }) {
            return s
        }
        if let key = openOutsideRepoKey, let s = syntheticOutsideSessions[key] {
            return s
        }
        return nil
    }

    /// Open a read-only chat view for a repo whose live activity is from
    /// outside Clawdmeter (Conductor / Cursor / Terminal-launched agent).
    /// Synthesizes a non-registry AgentSession so SessionChatView can render
    /// the JSONL but composer + actions are disabled (see `isReadOnly`).
    public func openOutsideSession(repoKey: String) {
        let displayName = repos.first { $0.key == repoKey }?.displayName
            ?? (repoKey as NSString).lastPathComponent
        let synth = AgentSession(
            id: UUID(),
            repoKey: repoKey,
            repoDisplayName: displayName,
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,    // nil = composer disabled
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0
        )
        syntheticOutsideSessions[repoKey] = synth
        openOutsideRepoKey = repoKey
        openSessionId = nil
    }

    public func closeChatView() {
        openSessionId = nil
        openOutsideRepoKey = nil
    }

    /// True when the currently-open session is a synthetic outside-Clawdmeter
    /// one. Composer / End-session menu / Approve buttons are hidden in
    /// that case.
    public var openSessionIsReadOnly: Bool {
        openOutsideRepoKey != nil && openSessionId == nil
    }

    public let repoIndex: RepoIndex
    public let registry: AgentSessionRegistry
    public let supervisor: TmuxSupervisor
    private var refreshTask: Task<Void, Never>?

    public init(
        repoIndex: RepoIndex,
        registry: AgentSessionRegistry,
        supervisor: TmuxSupervisor
    ) {
        self.repoIndex = repoIndex
        self.registry = registry
        self.supervisor = supervisor
    }

    public func sessions(for repoKey: String) -> [AgentSession] {
        registry.sessions.filter { $0.repoKey == repoKey }
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await repoIndex.refresh()
        self.repos = snapshot
        for repo in snapshot {
            if !sessions(for: repo.key).isEmpty || repo.liveSessionCount > 0 {
                expandedRepoKeys.insert(repo.key)
            }
        }
    }

    public func startPeriodicRefresh() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    public func spawnSession(
        repoPath: String,
        agent: AgentKind,
        planMode: Bool,
        goal: String?,
        useWorktree: Bool,
        tmux: TmuxControlClient
    ) async throws -> AgentSession {
        try await tmux.start()
        var cwd = repoPath
        var worktreePath: String? = nil
        if useWorktree {
            let slug = WorktreeManager.slug(goal: goal, sessionId: UUID())
            worktreePath = try await WorktreeManager.shared.add(
                repoRoot: repoPath, slug: slug
            )
            cwd = worktreePath!
        }
        let argv = AgentSpawner.argv(for: NewSessionRequest(
            repoKey: repoPath,
            agent: agent,
            model: nil,
            planMode: planMode,
            goal: goal,
            useWorktree: useWorktree
        ))
        let windowId = try await tmux.newWindow(cwd: cwd, child: argv)
        let session = registry.create(
            repoKey: repoPath,
            repoDisplayName: (repoPath as NSString).lastPathComponent,
            agent: agent,
            model: nil,
            goal: goal,
            worktreePath: worktreePath,
            tmuxWindowId: windowId,
            tmuxPaneId: nil,
            planMode: planMode
        )
        expandedRepoKeys.insert(repoPath)
        await self.refresh()
        return session
    }

    public func endSession(id: UUID) async {
        guard let session = registry.session(id: id),
              let runtime = AppDelegate.runtime,
              let windowId = session.tmuxWindowId
        else { return }
        do { try await runtime.tmuxClient.killWindow(windowId) } catch {}
        if let worktreePath = session.worktreePath {
            _ = try? await WorktreeManager.shared.delete(
                repoRoot: session.repoKey,
                worktreePath: worktreePath,
                registryOwned: true,
                attachedPanePaths: []
            )
        }
        registry.delete(id: id)
    }

    public func approvePlan(id: UUID) async {
        guard let runtime = AppDelegate.runtime,
              let session = registry.session(id: id),
              let windowId = session.tmuxWindowId
        else { return }
        do {
            try await runtime.tmuxClient.killWindow(windowId)
            let argv = [
                "/Users/darshanbathija_1/.local/bin/claude",
                "--permission-mode", "acceptEdits",
            ]
            let cwd = session.worktreePath ?? session.repoKey
            _ = try await runtime.tmuxClient.newWindow(cwd: cwd, child: argv)
            registry.updateStatus(id: id, status: .running)
        } catch {}
    }
}
