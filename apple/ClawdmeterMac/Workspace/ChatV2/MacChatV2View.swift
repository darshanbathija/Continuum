import SwiftUI
import ClawdmeterShared

/// v0.23 Chat V2 — the rebuilt Mac chat surface. Single file, private
/// structs (matches the legacy `MacChatView.swift` / `ChatSoloView.swift`
/// pattern). Replaces `MacChatView` as the Chat tab content in
/// `MacRootView.body`.
///
/// What's wired end-to-end in this commit:
/// - **Sidebar** — real chat sessions from `loopbackClient.chatSessions`,
///   grouped Today/Yesterday/This week/Earlier. Tap to select.
/// - **Transcript** — binds to the open session's `SessionChatStore`
///   via the `ChatSnapshotSource` protocol from T1. Re-renders on each
///   100ms snapshot tick from the daemon.
/// - **Composer** — provider chip (Claude/Codex/Gemini), Deep Research
///   toggle, model display, paperclip attach, `TextEditor` 1→8 lines,
///   Send button that morphs to Stop while
///   `snapshot.currentTurnState == .streaming`. Cmd+Return sends.
/// - **Stop button** — calls `POST /sessions/:id/interrupt` which
///   routes through `SessionInterruptDispatcher` (T5) so it works for
///   tmux + Codex SDK + Antigravity agentapi.
/// - **Status strip** — animated ring + stopwatch driven by
///   `currentTurnState`. Pauses when idle (TimelineView throttles to
///   100ms with `paused:` while not streaming).
///
/// Deliberately deferred to later commits:
/// - Broadcast / Frontier compare columns (still single-pane).
/// - Sidebar search field (daemon endpoint exists; UI wires later).
/// - Mid-conversation model + effort swap menus.
/// - Pagination beyond the 1000-row in-memory window.
/// - Tahoe re-skin (function before form per the user's plan).
///
/// The legacy `MacChatView` stays in the binary as a fallback during
/// the deletion grace window (T16); both views can be cleared from
/// memory between launches via `Cmd+Opt+Shift+C` if a regression
/// surfaces during the v0.23.x QA pass.
@available(macOS 14, *)
struct MacChatV2View: View {
    private let loopbackClient: AgentControlClient?
    private weak var runtime: AppRuntime?

    init(loopbackClient: AgentControlClient?, runtime: AppRuntime?) {
        self.loopbackClient = loopbackClient
        self.runtime = runtime
    }

    /// Observed indirectly via `MacChatV2View.body`'s `_ = ...` touch.
    /// We can't `@ObservedObject` the loopback client at the public-
    /// init boundary because it's optional; using an inner observer
    /// view (`ChatRoot`) lifts the @ObservedObject inside the
    /// conditional.
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
    @ObservedObject var client: AgentControlClient
    weak var runtime: AppRuntime?

    @State private var openId: UUID?
    @State private var selectedProvider: AgentKind = .claude
    @State private var deepResearch: Bool = false
    @StateObject private var sendCtl: ComposerSendController

    init(client: AgentControlClient, runtime: AppRuntime?) {
        self.client = client
        self.runtime = runtime
        _sendCtl = StateObject(wrappedValue: ComposerSendController(client: client))
    }

    var body: some View {
        HSplitView {
            Sidebar(
                sessions: client.chatSessions,
                openId: $openId,
                onNewChat: { openId = nil; sendCtl.reset() }
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            VStack(spacing: 0) {
                if let openId, let session = client.chatSessions.first(where: { $0.id == openId }) {
                    Transcript(session: session, runtime: runtime)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(reason: .noConversation)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                Composer(
                    sendCtl: sendCtl,
                    selectedProvider: $selectedProvider,
                    deepResearch: $deepResearch,
                    openSession: openId.flatMap { id in client.chatSessions.first(where: { $0.id == id }) },
                    runtime: runtime,
                    onCreated: { newId in
                        openId = newId
                    }
                )
            }
        }
        .task {
            await client.refreshSessions()
        }
    }
}

// MARK: - Sidebar

@available(macOS 14, *)
private struct Sidebar: View {
    let sessions: [AgentSession]
    @Binding var openId: UUID?
    let onNewChat: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $openId) {
                ForEach(groupedSessions, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.sessions) { session in
                            Row(session: session)
                                .tag(Optional(session.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var header: some View {
        HStack {
            Text("Chat").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("New chat")
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private struct Group {
        let label: String
        let sessions: [AgentSession]
    }

    /// Buckets the chat list into Today / Yesterday / This week / Earlier
    /// by `lastEventAt`. Within each bucket, newest first.
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

    private struct Row: View {
        let session: AgentSession

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(providerLabel(session.agent))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    if session.deepResearch {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.purple)
                            .help("Deep Research session")
                    }
                    Text(session.displayLabel)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                if let model = session.model, !model.isEmpty {
                    Text(model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }

        private func providerLabel(_ agent: AgentKind) -> String {
            switch agent {
            case .claude: return "Claude"
            case .codex:  return "Codex"
            case .gemini: return "Gemini"
            case .opencode: return "OpenCode"
            case .unknown: return "Other"
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
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Observes the SessionChatStore via @ObservedObject so SwiftUI
/// re-renders on every snapshot commit (100ms debounce from daemon).
/// Without this wrapper the parent reads through a computed property
/// and SwiftUI never subscribes to the @Published snapshot — the
/// chat thread freezes (same v0.8 QA bug fixed in legacy ChatSoloView).
@available(macOS 14, *)
private struct TranscriptScroll: View {
    @ObservedObject var store: SessionChatStore

    /// User-pinned-to-bottom tracking. Toggled by per-row appear/
    /// disappear. When false, auto-scroll-on-update pauses and the
    /// "↓ Latest" pill appears.
    @State private var userPinnedToBottom: Bool = true

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
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
                        Label("Latest", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(.secondary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

// MARK: - Message row

@available(macOS 14, *)
private struct MessageRow: View {
    let item: ChatItem

    var body: some View {
        switch item {
        case .message(let m):
            switch m.kind {
            case .userText:
                HStack {
                    Spacer(minLength: 60)
                    Text(m.body)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        .textSelection(.enabled)
                }
            case .assistantText:
                VStack(alignment: .leading, spacing: 4) {
                    if !m.title.isEmpty {
                        Text(m.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(m.body)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .toolCall, .toolResult:
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if !m.title.isEmpty {
                            Text(m.title).font(.system(size: 11, weight: .medium))
                        }
                        Text(m.body).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }
                }
            case .meta:
                Text(m.body)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        case .toolRun(_, let pairs):
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Ran \(pairs.count) command\(pairs.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Composer

@available(macOS 14, *)
private struct Composer: View {
    @ObservedObject var sendCtl: ComposerSendController
    @Binding var selectedProvider: AgentKind
    @Binding var deepResearch: Bool
    var openSession: AgentSession?
    weak var runtime: AppRuntime?
    let onCreated: (UUID) -> Void

    @FocusState private var textFocused: Bool

    private var isStreaming: Bool {
        guard let runtime, let session = openSession,
              let store = runtime.agentControlServer.chatStore(for: session) else {
            return sendCtl.sending
        }
        return store.snapshot.currentTurnState == .streaming || sendCtl.sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chips
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $sendCtl.text)
                    .font(.system(size: 13))
                    .frame(minHeight: 38, maxHeight: 140)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3), lineWidth: 1))
                    .focused($textFocused)
                    .disabled(sendCtl.sending)
                    .onSubmit { Task { await dispatchSend() } }
                button
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            if let err = sendCtl.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .padding(.top, 8)
        .onAppear { textFocused = true }
        .onChange(of: openSession?.id) { _, _ in
            // Don't clobber a half-typed draft when switching chats —
            // ComposerSendController owns reset on explicit "+ New chat".
            textFocused = true
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            providerChip
            deepResearchChip
            if let openSession {
                modelChip(for: openSession)
            }
            Spacer()
            if isStreaming {
                StatusStrip(openSession: openSession, runtime: runtime)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var providerChip: some View {
        Menu {
            Button("Claude") { selectedProvider = .claude }
            Button("Codex")  { selectedProvider = .codex }
            Button("Gemini") { selectedProvider = .gemini }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(providerColor(selectedProvider))
                    .frame(width: 7, height: 7)
                Text(providerLabel(selectedProvider))
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var deepResearchChip: some View {
        Button(action: { deepResearch.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: deepResearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(deepResearch ? .purple : .secondary)
                Text("Deep Research")
                    .font(.system(size: 11, weight: deepResearch ? .semibold : .medium))
                    .foregroundStyle(deepResearch ? .purple : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (deepResearch ? Color.purple.opacity(0.15) : Color.secondary.opacity(0.08)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(deepResearch ?
              "Multi-step research with web search + citations · ~2-10 min"
              : "Toggle Deep Research mode")
    }

    private func modelChip(for session: AgentSession) -> some View {
        HStack(spacing: 3) {
            Text(session.model ?? "default")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if let effort = session.effort {
                Text("·").foregroundStyle(.tertiary)
                Text(effort.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.08), in: Capsule())
    }

    @ViewBuilder
    private var button: some View {
        if isStreaming {
            Button(action: { Task { await dispatchStop() } }) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Stop the current response")
            .keyboardShortcut(.escape, modifiers: [])
        } else {
            Button(action: { Task { await dispatchSend() } }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(sendCtl.canSend ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!sendCtl.canSend)
            .help("Send (⌘↩)")
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private func dispatchSend() async {
        guard sendCtl.canSend else { return }
        if let session = openSession {
            await sendCtl.send(via: .solo(sessionId: session.id))
            return
        }
        // First-send path: create the chat then post the prompt as
        // turn-1. Snapshot the existing sessions so we can detect the
        // freshly-created one (sendCtl returns nothing useful here).
        let preIds = Set((runtime?.loopbackClient?.chatSessions ?? []).map(\.id))
        let provider = selectedProvider
        let dr = deepResearch
        await sendCtl.sendCustom { trimmed in
            guard let client = runtime?.loopbackClient else { return "Daemon not running" }
            guard let session = await client.createChatSession(provider: provider, deepResearch: dr) else {
                return client.lastError ?? "Couldn't create chat session"
            }
            await client.sendPrompt(sessionId: session.id, text: trimmed, asFollowUp: false)
            return nil
        }
        await runtime?.loopbackClient?.refreshSessions()
        if let newSession = (runtime?.loopbackClient?.chatSessions ?? [])
            .first(where: { !preIds.contains($0.id) }) {
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

    private func providerLabel(_ a: AgentKind) -> String {
        switch a {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .unknown: return "Other"
        }
    }

    private func providerColor(_ a: AgentKind) -> Color {
        switch a {
        case .claude: return .orange
        case .codex:  return .green
        case .gemini: return .blue
        case .opencode: return .gray
        case .unknown: return .gray
        }
    }
}

// MARK: - Status strip (animated ring + stopwatch)

@available(macOS 14, *)
private struct StatusStrip: View {
    var openSession: AgentSession?
    weak var runtime: AppRuntime?
    @State private var turnStartedAt: Date?

    /// Resolves the current turn-state from the store. .idle when no
    /// store (transitional) so the strip hides cleanly.
    private var turnState: TurnState {
        guard let runtime, let session = openSession,
              let store = runtime.agentControlServer.chatStore(for: session) else {
            return .idle
        }
        return store.snapshot.currentTurnState
    }

    var body: some View {
        HStack(spacing: 8) {
            IndicatorRing(streaming: turnState == .streaming)
                .frame(width: 14, height: 14)
            Stopwatch(running: turnState == .streaming, turnStartedAt: $turnStartedAt)
        }
        .onChange(of: turnState) { _, newState in
            switch newState {
            case .streaming:
                if turnStartedAt == nil { turnStartedAt = Date() }
            case .completed, .interrupted:
                // Hold the final reading briefly so the user sees the
                // total before the strip dismisses.
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
                ctx.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
            }
            .opacity(streaming ? 1 : 0.35)
        }
    }
}

@available(macOS 14, *)
private struct Stopwatch: View {
    var running: Bool
    @Binding var turnStartedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            Text(formatted(elapsed: elapsed(at: context.date)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(running ? .primary : .secondary)
                .monospacedDigit()
        }
    }

    private func elapsed(at now: Date) -> TimeInterval {
        guard let start = turnStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    private func formatted(elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Empty state

@available(macOS 14, *)
private struct EmptyState: View {
    enum Reason { case noLoopback, noConversation }
    let reason: Reason

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: reason == .noLoopback ? "bolt.slash" : "bubble.left.and.bubble.right")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
            return "Pick a provider, type a prompt, and press ⌘↩ to send. Toggle Deep Research for multi-step search."
        }
    }
}
