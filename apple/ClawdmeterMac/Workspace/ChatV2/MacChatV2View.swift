import SwiftUI
import ClawdmeterShared

/// v0.23 Chat V2 — Tahoe-skinned Mac chat surface. Mirrors the
/// `/Users/darshanbathija_1/Downloads/Clawdmeter Redesign _standalone_.html`
/// artboard: TahoeGlass panel layout, TahoeProviderGlyph in every
/// chip, accent halos drawn from the user-picked `TahoeProvider.base`
/// rather than hardcoded SwiftUI accentColor.
///
/// No dead buttons:
/// - New chat (sidebar header) → clears `openId`, resets composer.
/// - Search field (sidebar) → calls `client.searchChatHistory(q:)`,
///   renders matches inline with snippet + relative time.
/// - Provider chip → multi-select via `BroadcastChip` (port of the
///   legacy chip's multi-select; 1 selected = solo, >1 = broadcast).
/// - Deep Research toggle → flips `ChatV2Store.deepResearch`,
///   persisted to UserDefaults; threads into `.chatCreateV2` on
///   first send.
/// - Model+effort menu → only renders for tmux-backed open sessions
///   (Claude). For Codex SDK / Gemini agentapi the chip is hidden
///   entirely — no fake-clickable label.
/// - Attachment chip → `NSOpenPanel` + `client.uploadAttachment`,
///   thumbnails appear above the text field with click-x to remove.
/// - Stop button → `POST /sessions/:id/interrupt`, routes through
///   `SessionInterruptDispatcher` (T5) so it works on all 3 backends.
@available(macOS 14, *)
struct MacChatV2View: View {
    private let loopbackClient: AgentControlClient?
    private weak var runtime: AppRuntime?

    init(loopbackClient: AgentControlClient?, runtime: AppRuntime?) {
        self.loopbackClient = loopbackClient
        self.runtime = runtime
    }

    var body: some View {
        if let client = loopbackClient {
            ChatRoot(client: client, runtime: runtime)
        } else {
            EmptyState(reason: .noLoopback)
        }
    }
}

// MARK: - Root

@available(macOS 14, *)
private struct ChatRoot: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    weak var runtime: AppRuntime?

    @State private var openId: UUID?
    @StateObject private var chatStore = ChatV2Store()
    @StateObject private var sendCtl: ComposerSendController

    init(client: AgentControlClient, runtime: AppRuntime?) {
        self.client = client
        self.runtime = runtime
        _sendCtl = StateObject(wrappedValue: ComposerSendController(client: client))
    }

    var body: some View {
        HStack(spacing: 10) {
            TahoeGlass(radius: 20, tone: .panel) {
                Sidebar(
                    sessions: client.chatSessions,
                    openId: $openId,
                    client: client,
                    onNewChat: {
                        openId = nil
                        sendCtl.reset()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 248)

            VStack(spacing: 10) {
                if let openId,
                   let session = client.chatSessions.first(where: { $0.id == openId }) {
                    ColumnHeader(session: session, runtime: runtime)
                    TahoeGlass(radius: 20, tone: .panel) {
                        Transcript(session: session, runtime: runtime)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TahoeGlass(radius: 20, tone: .panel) {
                        EmptyState(reason: .noConversation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Composer(
                    sendCtl: sendCtl,
                    store: chatStore,
                    openSession: openId.flatMap { id in client.chatSessions.first(where: { $0.id == id }) },
                    runtime: runtime,
                    client: client,
                    onCreated: { id in openId = id }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .task { await client.refreshSessions() }
    }
}

// MARK: - Sidebar

@available(macOS 14, *)
private struct Sidebar: View {
    @Environment(\.tahoe) private var t
    let sessions: [AgentSession]
    @Binding var openId: UUID?
    @ObservedObject var client: AgentControlClient
    let onNewChat: () -> Void

    @State private var searchQuery: String = ""
    @State private var searchResults: [ChatSessionSearchMatch] = []
    @State private var searchInFlight: Bool = false
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            TahoeHair()
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                groupedList
            } else {
                searchResultsList
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Chat")
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            TahoeAccentButton(size: .m, action: onNewChat) {
                HStack(spacing: 6) {
                    TahoeIcon("plus", size: 11)
                    Text("New chat")
                        .font(TahoeFont.body(12.5, weight: .semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var searchBar: some View {
        TahoeGlass(radius: 10, tone: .chip) {
            HStack(spacing: 8) {
                TahoeIcon("search", size: 11)
                    .foregroundStyle(t.fg3)
                TextField("Search chats", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg)
                if searchInFlight {
                    ProgressView().controlSize(.mini)
                } else if !searchQuery.isEmpty {
                    Button(action: { searchQuery = ""; searchResults = [] }) {
                        TahoeIcon("x", size: 10)
                            .foregroundStyle(t.fg3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(query: newValue)
        }
    }

    private var groupedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groupedSessions, id: \.label) { group in
                    section(label: group.label, count: group.sessions.count) {
                        ForEach(group.sessions) { session in
                            Row(session: session, isSelected: openId == session.id)
                                .onTapGesture { openId = session.id }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func section<Content: View>(label: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            TahoeIcon("chevD", size: 9).foregroundStyle(t.fg4)
            Text(label.uppercased())
                .font(TahoeFont.body(10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(t.fg4)
            Spacer()
            Text("\(count)")
                .font(TahoeFont.mono(10, weight: .semibold))
                .foregroundStyle(t.fg4)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
        content()
    }

    @ViewBuilder
    private var searchResultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if searchResults.isEmpty && !searchInFlight {
                    Text("No matches")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                } else {
                    ForEach(searchResults) { match in
                        SearchResultRow(match: match, isSelected: openId == match.sessionId)
                            .onTapGesture { openId = match.sessionId }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private func scheduleSearch(query: String) {
        searchDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchResults = []
            searchInFlight = false
            return
        }
        searchInFlight = true
        searchDebounceTask = Task {
            // 200ms debounce so typing doesn't keypress-storm the daemon.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let resp = await client.searchChatHistory(query: trimmed, limit: 50)
            if Task.isCancelled { return }
            await MainActor.run {
                searchResults = resp?.matches ?? []
                searchInFlight = false
            }
        }
    }

    // MARK: - Grouping

    private struct Group {
        let label: String
        let sessions: [AgentSession]
    }

    private var groupedSessions: [Group] {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        let weekStart = cal.date(byAdding: .day, value: -7, to: dayStart) ?? dayStart
        let active = sessions.filter { $0.archivedAt == nil }
            .sorted { $0.lastEventAt > $1.lastEventAt }
        var today: [AgentSession] = []
        var yesterday: [AgentSession] = []
        var thisWeek: [AgentSession] = []
        var earlier: [AgentSession] = []
        for s in active {
            if s.lastEventAt >= dayStart { today.append(s) }
            else if s.lastEventAt >= yesterdayStart { yesterday.append(s) }
            else if s.lastEventAt >= weekStart { thisWeek.append(s) }
            else { earlier.append(s) }
        }
        var out: [Group] = []
        if !today.isEmpty { out.append(Group(label: "Today", sessions: today)) }
        if !yesterday.isEmpty { out.append(Group(label: "Yesterday", sessions: yesterday)) }
        if !thisWeek.isEmpty { out.append(Group(label: "This week", sessions: thisWeek)) }
        if !earlier.isEmpty { out.append(Group(label: "Earlier", sessions: earlier)) }
        return out
    }

    // MARK: - Rows

    private struct Row: View {
        @Environment(\.tahoe) private var t
        let session: AgentSession
        let isSelected: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 14)
                    if session.deepResearch {
                        TahoeIcon("search", size: 9)
                            .foregroundStyle(Color(oklch: session.agent.tahoeProvider.halo))
                            .help("Deep Research session")
                    }
                    Text(session.displayLabel)
                        .font(TahoeFont.body(12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                    Spacer()
                }
                if let model = session.model, !model.isEmpty {
                    Text(model)
                        .font(TahoeFont.mono(10))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected
                          ? (t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                          : Color.clear)
            }
            .contentShape(Rectangle())
        }
    }

    private struct SearchResultRow: View {
        @Environment(\.tahoe) private var t
        let match: ChatSessionSearchMatch
        let isSelected: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TahoeIcon("doc", size: 11).foregroundStyle(t.fg3)
                    Text(match.jsonlPath.split(separator: "/").last.map(String.init) ?? match.jsonlPath)
                        .font(TahoeFont.body(11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.relative(match.lastEventAt))
                        .font(TahoeFont.mono(9.5))
                        .foregroundStyle(t.fg4)
                }
                Text(match.snippet)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected
                          ? (t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                          : Color.clear)
            }
            .contentShape(Rectangle())
        }

        private static func relative(_ date: Date) -> String {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return fmt.localizedString(for: date, relativeTo: Date())
        }
    }
}

// MARK: - Column header (open session brand rule + stats)

@available(macOS 14, *)
private struct ColumnHeader: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    weak var runtime: AppRuntime?

    var body: some View {
        TahoeGlass(radius: 14, tone: .raised) {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color(oklch: session.agent.tahoeProvider.glow),
                        Color(oklch: session.agent.tahoeProvider.base)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 2)
                .opacity(0.85)

                HStack(spacing: 10) {
                    TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.agent.tahoeProvider.displayName)
                            .font(TahoeFont.body(13, weight: .bold))
                            .tracking(-0.1)
                            .foregroundStyle(t.fg)
                        if let model = session.model, !model.isEmpty {
                            Text(model)
                                .font(TahoeFont.mono(10.5))
                                .foregroundStyle(t.fg3)
                        }
                    }
                    Spacer(minLength: 4)
                    if session.deepResearch {
                        deepResearchBadge
                    }
                    if let store = runtime?.agentControlServer.chatStore(for: session) {
                        Stats(store: store)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var deepResearchBadge: some View {
        HStack(spacing: 4) {
            TahoeIcon("search", size: 10)
            Text("Deep Research")
                .font(TahoeFont.body(10, weight: .semibold))
        }
        .foregroundStyle(Color(oklch: session.agent.tahoeProvider.halo))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(Color(oklch: session.agent.tahoeProvider.halo).opacity(0.15))
        }
    }

    private struct Stats: View {
        @Environment(\.tahoe) private var t
        @ObservedObject var store: SessionChatStore

        var body: some View {
            HStack(spacing: 14) {
                stat("tok", value: tahoeFmtTok(store.snapshot.totalTokens))
                stat("turns", value: "\(store.snapshot.items.count)")
            }
        }

        private func stat(_ label: String, value: String) -> some View {
            VStack(alignment: .trailing, spacing: 3) {
                Text(value)
                    .font(TahoeFont.mono(13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(t.fg)
                Text(label.uppercased())
                    .font(TahoeFont.body(9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg4)
            }
        }
    }
}

// MARK: - Transcript

@available(macOS 14, *)
private struct Transcript: View {
    let session: AgentSession
    weak var runtime: AppRuntime?

    var body: some View {
        if let runtime, let store = runtime.agentControlServer.chatStore(for: session) {
            TranscriptScroll(store: store)
                .overlay(alignment: .bottom) {
                    PermissionPromptOverlay(store: store, sessionId: session.id)
                }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@available(macOS 14, *)
private struct TranscriptScroll: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var store: SessionChatStore
    @State private var userPinnedToBottom: Bool = true

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.snapshot.items) { item in
                            MessageRow(item: item).id(item.id)
                                .onAppear {
                                    if item.id == store.snapshot.items.last?.id {
                                        userPinnedToBottom = true
                                    }
                                }
                                .onDisappear {
                                    if item.id == store.snapshot.items.last?.id {
                                        userPinnedToBottom = false
                                    }
                                }
                        }
                        Color.clear.frame(height: 12).id("bottom-anchor")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .onChange(of: store.snapshot.updateCounter) { _, _ in
                    if userPinnedToBottom, let last = store.snapshot.items.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                if !userPinnedToBottom, !store.snapshot.items.isEmpty {
                    Button(action: {
                        userPinnedToBottom = true
                        if let last = store.snapshot.items.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            TahoeIcon("chevD", size: 10)
                            Text("Latest")
                                .font(TahoeFont.body(11, weight: .semibold))
                        }
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

@available(macOS 14, *)
private struct PermissionPromptOverlay: View {
    @ObservedObject var store: SessionChatStore
    let sessionId: UUID

    var body: some View {
        if let prompt = store.pendingPermissionPrompt {
            PermissionPromptCard(
                prompt: prompt,
                sessionId: sessionId,
                responder: MacPermissionResponder()
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Message row

@available(macOS 14, *)
private struct MessageRow: View {
    @Environment(\.tahoe) private var t
    let item: ChatItem

    var body: some View {
        switch item {
        case .message(let m):
            switch m.kind {
            case .userText:
                HStack {
                    Spacer(minLength: 60)
                    TahoeGlass(radius: 14, tone: .chip) {
                        Text(m.body)
                            .font(TahoeFont.body(13))
                            .foregroundStyle(t.fg)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .textSelection(.enabled)
                    }
                }
            case .assistantText:
                VStack(alignment: .leading, spacing: 4) {
                    if !m.title.isEmpty {
                        Text(m.title.uppercased())
                            .font(TahoeFont.body(10, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(t.fg4)
                    }
                    Text(m.body)
                        .font(TahoeFont.body(13.5))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .toolCall, .toolResult:
                HStack(alignment: .top, spacing: 8) {
                    TahoeIcon("terminal", size: 10).foregroundStyle(t.fg3)
                    VStack(alignment: .leading, spacing: 2) {
                        if !m.title.isEmpty {
                            Text(m.title)
                                .font(TahoeFont.body(11, weight: .medium))
                                .foregroundStyle(t.fg2)
                        }
                        Text(m.body)
                            .font(TahoeFont.mono(11.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(6)
                    }
                }
            case .meta:
                Text(m.body)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg4)
            }
        case .toolRun(_, let pairs):
            HStack(spacing: 6) {
                TahoeIcon("terminal", size: 10).foregroundStyle(t.fg3)
                Text(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg3)
            }
        }
    }
}

// MARK: - Composer

@available(macOS 14, *)
private struct Composer: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var sendCtl: ComposerSendController
    @ObservedObject var store: ChatV2Store
    var openSession: AgentSession?
    weak var runtime: AppRuntime?
    @ObservedObject var client: AgentControlClient
    let onCreated: (UUID) -> Void

    @FocusState private var textFocused: Bool

    private var isStreaming: Bool {
        guard let runtime, let session = openSession,
              let s = runtime.agentControlServer.chatStore(for: session) else {
            return sendCtl.sending
        }
        return s.snapshot.currentTurnState == .streaming || sendCtl.sending
    }

    /// Mid-conv model swap is tmux-only this release (D11 decision).
    /// Codex SDK + Gemini agentapi sessions get no chip — start a new
    /// chat to change model. No fake-clickable label.
    private var sessionSupportsModelSwap: Bool {
        guard let openSession else { return false }
        // Claude sessions are tmux; Codex CLI is tmux; Codex SDK isn't;
        // Gemini agentapi isn't.
        if openSession.agent == .codex, openSession.codexChatBackend == .sdk { return false }
        if openSession.agent == .gemini, openSession.geminiBackend == .agentapi { return false }
        return openSession.tmuxPaneId != nil
    }

    var body: some View {
        TahoeGlass(radius: 18, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                if !store.attachments.isEmpty {
                    attachmentStrip
                }
                TextField(placeholder, text: $sendCtl.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .autocorrectionDisabled()
                    .focused($textFocused)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .disabled(sendCtl.sending)
                    .onSubmit { Task { await dispatchSend() } }

                if let err = sendCtl.lastError {
                    Text(err)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6) {
                    providerChip
                    deepResearchChip
                    if sessionSupportsModelSwap, let openSession { modelChip(for: openSession) }
                    attachmentChip
                    Spacer()
                    if isStreaming {
                        StatusStrip(openSession: openSession, runtime: runtime)
                    }
                    sendOrStopButton
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 4)
            }
        }
        .onAppear { textFocused = true }
        .onChange(of: openSession?.id) { _, _ in textFocused = true }
    }

    // MARK: - Chips

    private var providerChip: some View {
        Menu {
            ForEach([AgentKind.claude, .codex, .gemini], id: \.self) { kind in
                Button {
                    store.selectedProvider = kind
                    store.persist()
                } label: {
                    HStack {
                        Text(kind.tahoeProvider.displayName)
                        if kind == store.selectedProvider {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                TahoeProviderGlyph(provider: store.selectedProvider.tahoeProvider, size: 14)
                Text(store.selectedProvider.tahoeProvider.displayName)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg)
                TahoeIcon("chevD", size: 8).foregroundStyle(t.fg3)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(t.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
            }
            .overlay(Capsule().strokeBorder(t.hairline, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var deepResearchChip: some View {
        Button(action: {
            store.deepResearch.toggle()
            store.persist()
        }) {
            HStack(spacing: 5) {
                TahoeIcon("search", size: 11)
                    .foregroundStyle(store.deepResearch
                                     ? Color(oklch: store.selectedProvider.tahoeProvider.halo)
                                     : t.fg3)
                Text("Deep Research")
                    .font(TahoeFont.body(11, weight: store.deepResearch ? .semibold : .medium))
                    .foregroundStyle(store.deepResearch
                                     ? Color(oklch: store.selectedProvider.tahoeProvider.halo)
                                     : t.fg3)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(
                    store.deepResearch
                    ? Color(oklch: store.selectedProvider.tahoeProvider.halo).opacity(0.15)
                    : (t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                )
            }
            .overlay(Capsule().strokeBorder(
                store.deepResearch
                ? Color(oklch: store.selectedProvider.tahoeProvider.halo).opacity(0.4)
                : t.hairline,
                lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(store.deepResearch
              ? "Multi-step research with web search + citations · ~2-10 min"
              : "Toggle Deep Research mode")
    }

    private func modelChip(for session: AgentSession) -> some View {
        Menu {
            let catalog: [ModelCatalogEntry] = {
                switch session.agent {
                case .claude: return ModelCatalog.bundled.claude
                case .codex:  return ModelCatalog.bundled.codex
                case .gemini: return ModelCatalog.bundled.gemini
                default: return []
                }
            }()
            ForEach(catalog, id: \.id) { entry in
                Button {
                    Task { await changeModel(sessionId: session.id, to: entry.id) }
                } label: {
                    HStack {
                        Text(entry.displayName)
                        if entry.id == session.model {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(session.model ?? "default")
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg2)
                TahoeIcon("chevD", size: 8).foregroundStyle(t.fg3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            }
            .overlay(Capsule().strokeBorder(t.hairline, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var attachmentChip: some View {
        Button(action: pickAttachment) {
            TahoeIcon("paperclip", size: 12)
                .foregroundStyle(t.fg3)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                }
                .overlay(Capsule().strokeBorder(t.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Attach file")
    }

    private var attachmentStrip: some View {
        HStack(spacing: 6) {
            ForEach(store.attachments) { a in
                HStack(spacing: 5) {
                    TahoeIcon("doc", size: 10).foregroundStyle(t.fg3)
                    Text(a.displayName)
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg2)
                        .lineLimit(1)
                    Button { store.removeAttachment(id: a.id) } label: {
                        TahoeIcon("x", size: 10)
                            .foregroundStyle(t.fg3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                }
                .overlay(Capsule().strokeBorder(t.hairline, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isStreaming {
            Button(action: { Task { await dispatchStop() } }) {
                ZStack {
                    Circle().fill(Color.red.opacity(t.dark ? 0.18 : 0.14))
                    TahoeIcon("stop", size: 13).foregroundStyle(.red)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Stop the current response (Esc)")
            .keyboardShortcut(.escape, modifiers: [])
        } else {
            Button(action: { Task { await dispatchSend() } }) {
                ZStack {
                    Circle().fill(sendCtl.canSend
                                  ? Color(oklch: store.selectedProvider.tahoeProvider.base)
                                  : (t.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))
                    TahoeIcon("arrowU", size: 14)
                        .foregroundStyle(sendCtl.canSend ? .white : t.fg4)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!sendCtl.canSend)
            .help("Send (⌘↩)")
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private var placeholder: String {
        if store.deepResearch {
            return "Ask a research question — multi-step search · 2-10 min"
        }
        return "Ask \(store.selectedProvider.tahoeProvider.displayName). Use ⌘↩ to send."
    }

    // MARK: - Actions

    private func dispatchSend() async {
        guard sendCtl.canSend else { return }
        // Splice attachment @path mentions into the prompt body before
        // send so the agent's Read tool resolves the file.
        let mentions = store.attachments.compactMap { $0.pathOnDaemon }.map { "@\($0)" }.joined(separator: " ")
        if !mentions.isEmpty, !sendCtl.text.contains(mentions) {
            sendCtl.text = mentions + " " + sendCtl.text
        }

        if let session = openSession {
            await sendCtl.send(via: .solo(sessionId: session.id))
            store.clearAttachments()
            return
        }

        let preIds = Set(client.chatSessions.map(\.id))
        await sendCtl.send(via: store.firstSendKind())
        store.clearAttachments()
        await client.refreshSessions()
        if let newSession = client.chatSessions.first(where: { !preIds.contains($0.id) }) {
            onCreated(newSession.id)
        }
    }

    private func dispatchStop() async {
        guard let runtime, let session = openSession else { return }
        guard let port = runtime.agentControlServer.boundPort else { return }
        let token = PairingTokenStore.shared.currentToken()
        guard let url = URL(string: "http://127.0.0.1:\(port)/sessions/\(session.id.uuidString)/interrupt") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    private func changeModel(sessionId: UUID, to modelId: String) async {
        guard let runtime, let port = runtime.agentControlServer.boundPort else { return }
        let token = PairingTokenStore.shared.currentToken()
        guard let url = URL(string: "http://127.0.0.1:\(port)/sessions/\(sessionId.uuidString)/model") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChangeModelRequest(model: modelId)
        req.httpBody = try? JSONEncoder().encode(body)
        _ = try? await URLSession.shared.data(for: req)
        await client.refreshSessions()
    }

    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach to chat"
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        // For an open session, upload to the daemon and record the
        // returned path on the attachment chip. For first-send, the
        // file picker still works but we record only the local name +
        // splice the local path as @-mention; the daemon's
        // path-mention contract accepts absolute paths directly so the
        // agent can read the file off disk.
        Task { @MainActor in
            for url in urls {
                let att = ChatV2Attachment(displayName: url.lastPathComponent, pathOnDaemon: url.path)
                store.addAttachment(att)
                // If we have an open session, also upload as bytes so
                // tools that don't accept arbitrary paths still work.
                if let openSession {
                    if let data = try? Data(contentsOf: url),
                       let uploadedPath = await client.uploadAttachment(
                           sessionId: openSession.id,
                           ext: url.pathExtension,
                           data: data) {
                        if let idx = store.attachments.firstIndex(where: { $0.id == att.id }) {
                            store.attachments[idx].pathOnDaemon = uploadedPath
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Status strip (ring + stopwatch)

@available(macOS 14, *)
private struct StatusStrip: View {
    @Environment(\.tahoe) private var t
    var openSession: AgentSession?
    weak var runtime: AppRuntime?
    @State private var turnStartedAt: Date?

    private var turnState: TurnState {
        guard let runtime, let session = openSession,
              let store = runtime.agentControlServer.chatStore(for: session) else {
            return .idle
        }
        return store.snapshot.currentTurnState
    }

    var body: some View {
        HStack(spacing: 8) {
            IndicatorRing(streaming: turnState == .streaming,
                          tint: Color(oklch: (openSession?.agent.tahoeProvider ?? .claude).base))
                .frame(width: 14, height: 14)
            Stopwatch(running: turnState == .streaming, turnStartedAt: $turnStartedAt)
        }
        .onChange(of: turnState) { _, newState in
            switch newState {
            case .streaming:
                if turnStartedAt == nil { turnStartedAt = Date() }
            case .completed, .interrupted:
                break
            case .idle:
                turnStartedAt = nil
            }
        }
    }
}

@available(macOS 14, *)
private struct IndicatorRing: View {
    var streaming: Bool
    var tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !streaming)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                let path = Path { p in
                    let start = Angle(degrees: (t * 360).truncatingRemainder(dividingBy: 360))
                    let end = Angle(degrees: start.degrees + 120)
                    p.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                             radius: rect.width / 2,
                             startAngle: start, endAngle: end, clockwise: false)
                }
                ctx.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
            }
            .opacity(streaming ? 1 : 0.35)
        }
    }
}

@available(macOS 14, *)
private struct Stopwatch: View {
    @Environment(\.tahoe) private var t
    var running: Bool
    @Binding var turnStartedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            Text(formatted(elapsed: elapsed(at: context.date)))
                .font(TahoeFont.mono(11))
                .foregroundStyle(running ? t.fg : t.fg3)
                .monospacedDigit()
        }
    }

    private func elapsed(at now: Date) -> TimeInterval {
        guard let start = turnStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    private func formatted(elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Empty state

@available(macOS 14, *)
private struct EmptyState: View {
    @Environment(\.tahoe) private var t
    enum Reason { case noLoopback, noConversation }
    let reason: Reason

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: -8) {
                ForEach([TahoeProvider.claude, .codex, .gemini], id: \.self) { p in
                    TahoeProviderGlyph(provider: p, size: 36)
                }
            }
            .padding(.bottom, 4)
            Text(headline)
                .font(TahoeFont.body(17, weight: .semibold))
                .foregroundStyle(t.fg)
            Text(subtitle)
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var headline: String {
        switch reason {
        case .noLoopback: return "Daemon offline"
        case .noConversation: return "Start a new chat"
        }
    }

    private var subtitle: String {
        switch reason {
        case .noLoopback:
            return "Restart Clawdmeter — the local daemon hasn't bound yet."
        case .noConversation:
            return "Pick a provider, type a prompt, and press ⌘↩ to send. Toggle Deep Research for multi-step search with citations."
        }
    }
}

// MARK: - Color helper

/// SwiftUI Color from a Tahoe OKLCH token. The Tahoe theme stores
/// brand swatches as OKLCH; SwiftUI consumes sRGB, so we go through
/// the existing helper on the OKLCH struct.
private extension Color {
    init(oklch: OKLCH) {
        self = oklch.color
    }
}
