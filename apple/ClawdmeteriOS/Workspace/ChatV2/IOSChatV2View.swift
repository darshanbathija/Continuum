import SwiftUI
import ClawdmeterShared

/// v0.23 Chat V2 — iOS chat surface. Mirrors the Mac decomposition
/// (sidebar / transcript / composer / status strip) but adapts the
/// shell to phone screens:
///   - `NavigationStack` root (no NavigationSplitView on phone).
///   - History "sidebar" = `.sheet` with `.presentationDetents(.medium/.large)`
///     pulled up from a title-bar icon.
///   - Composer is sticky-bottom; broadcast comparison swipes between
///     provider panes (`TabView(.page)`).
///
/// Wired pieces:
/// - Binds the open session's `iOSChatStore` via the `ChatSnapshotSource`
///   protocol from T1 — same view code as Mac.
/// - Composer state lives in `ChatV2Store` (T10) + `ComposerSendController`.
/// - Deep Research toggle threads through `.chatCreateV2` so the user's
///   pick reaches the daemon.
/// - Permission prompts overlay the lifted Shared `PermissionPromptCard`
///   (T11) with `IOSPermissionResponder`.
/// - Stop button posts `/sessions/:id/interrupt` which routes through
///   the SessionInterruptDispatcher (T5) — works on all 3 backends.
///
/// Deferred (per the plan's "out of scope" list):
///   - Mid-conversation model swap on Codex SDK / Gemini agentapi.
///   - Inline image attachments (Photos picker stub for now).
///   - Tahoe re-skin (function before form).
public struct IOSChatV2View: View {
    @ObservedObject var client: AgentControlClient
    @StateObject private var chatStore: ChatV2Store
    @StateObject private var sendCtl: ComposerSendController

    @State private var openSessionId: UUID?
    @State private var historySheetPresented: Bool = false

    public init(agentClient: AgentControlClient) {
        self._client = ObservedObject(wrappedValue: agentClient)
        _sendCtl = StateObject(wrappedValue: ComposerSendController(client: agentClient))
        _chatStore = StateObject(wrappedValue: ChatV2Store())
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !client.isConfigured {
                    UnpairedBanner()
                } else if let openSessionId,
                          let session = client.chatSessions.first(where: { $0.id == openSessionId }) {
                    Transcript(session: session, client: client)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                Composer(
                    sendCtl: sendCtl,
                    store: chatStore,
                    client: client,
                    openSession: openSessionId.flatMap { id in client.chatSessions.first(where: { $0.id == id }) },
                    onCreated: { id in openSessionId = id }
                )
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        historySheetPresented = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("History")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openSessionId = nil
                        sendCtl.reset()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .sheet(isPresented: $historySheetPresented) {
                HistorySheet(
                    sessions: client.chatSessions,
                    selected: $openSessionId,
                    onDismiss: { historySheetPresented = false }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .task {
                await client.refreshSessions()
            }
        }
    }
}

// MARK: - Transcript

private struct Transcript: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    var body: some View {
        let store = iOSChatStoreCache.shared.store(for: session.id, client: client)
        TranscriptScroll(store: store, sessionId: session.id, client: client)
    }
}

private struct TranscriptScroll: View {
    @ObservedObject var store: iOSChatStore
    let sessionId: UUID
    @ObservedObject var client: AgentControlClient

    @State private var userPinnedToBottom: Bool = true

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemGroupedBackground))
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.snapshot.updateCounter) { _, _ in
                    guard userPinnedToBottom else { return }
                    if let last = store.snapshot.items.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                if !userPinnedToBottom, !store.snapshot.items.isEmpty {
                    Button {
                        userPinnedToBottom = true
                        if let last = store.snapshot.items.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    } label: {
                        Label("Latest", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                    .padding(.bottom, 14)
                }
            }
            .overlay(alignment: .bottom) {
                if let prompt = store.snapshot.pendingPermissionPrompt {
                    PermissionPromptCard(
                        prompt: prompt,
                        sessionId: sessionId,
                        responder: IOSPermissionResponder(client: client)
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

private struct MessageRow: View {
    let item: ChatItem

    var body: some View {
        switch item {
        case .message(let m):
            switch m.kind {
            case .userText:
                HStack {
                    Spacer(minLength: 40)
                    Text(m.body)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .textSelection(.enabled)
                }
            case .assistantText:
                VStack(alignment: .leading, spacing: 4) {
                    if !m.title.isEmpty {
                        Text(m.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(m.body)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
                        .textSelection(.enabled)
                }
            case .meta:
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(m.body).font(.caption).foregroundStyle(.secondary)
                }
            case .toolCall, .toolResult:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if !m.title.isEmpty {
                            Text(m.title).font(.caption2.weight(.semibold))
                        }
                        Text(m.body).font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }
        case .toolRun(_, let pairs):
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.caption2).foregroundStyle(.secondary)
                Text(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var sendCtl: ComposerSendController
    @ObservedObject var store: ChatV2Store
    @ObservedObject var client: AgentControlClient
    var openSession: AgentSession?
    let onCreated: (UUID) -> Void

    @FocusState private var textFocused: Bool

    private var isStreaming: Bool {
        guard let session = openSession else { return sendCtl.sending }
        // iOSChatStoreCache hits would be a state-dependence; use the
        // sending flag plus turn-state from a probed store if open.
        return sendCtl.sending
            || iOSChatStoreCache.shared.store(for: session.id, client: client).snapshot.currentTurnState == .streaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chips
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $sendCtl.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .focused($textFocused)
                    .disabled(sendCtl.sending)
                button
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            if let err = sendCtl.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .padding(.top, 6)
        .background(Color(.systemBackground))
    }

    private var placeholder: String {
        if store.deepResearch {
            return "Ask a research question — multi-step search · 2-10 min"
        }
        switch store.selectedProvider {
        case .claude:   return "Ask Claude…"
        case .codex:    return "Ask Codex…"
        case .gemini:   return "Ask Gemini…"
        case .opencode: return "Ask OpenCode…"
        case .unknown:  return "Ask…"
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            providerChip
            deepResearchChip
            Spacer()
            if isStreaming { StatusStrip(openSession: openSession, client: client) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var providerChip: some View {
        Menu {
            Button("Claude") { store.selectedProvider = .claude; store.persist() }
            Button("Codex")  { store.selectedProvider = .codex;  store.persist() }
            Button("Gemini") { store.selectedProvider = .gemini; store.persist() }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(providerColor(store.selectedProvider)).frame(width: 7, height: 7)
                Text(providerLabel(store.selectedProvider))
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.12), in: Capsule())
        }
    }

    private var deepResearchChip: some View {
        Button {
            store.deepResearch.toggle()
            store.persist()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.deepResearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(store.deepResearch ? .purple : .secondary)
                Text("Deep Research")
                    .font(.system(size: 12, weight: store.deepResearch ? .semibold : .medium))
                    .foregroundStyle(store.deepResearch ? .purple : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                store.deepResearch ? Color.purple.opacity(0.15) : Color.secondary.opacity(0.08),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var button: some View {
        if isStreaming {
            Button { Task { await dispatchStop() } } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        } else {
            Button { Task { await dispatchSend() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(sendCtl.canSend ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!sendCtl.canSend)
        }
    }

    private func dispatchSend() async {
        guard sendCtl.canSend else { return }
        if let session = openSession {
            await sendCtl.send(via: .solo(sessionId: session.id))
            return
        }
        let preIds = Set(client.chatSessions.map(\.id))
        await sendCtl.send(via: store.firstSendKind())
        await client.refreshSessions()
        if let newSession = client.chatSessions.first(where: { !preIds.contains($0.id) }) {
            onCreated(newSession.id)
        }
    }

    private func dispatchStop() async {
        guard let session = openSession else { return }
        await client.interruptSession(sessionId: session.id)
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

// MARK: - Status strip

private struct StatusStrip: View {
    var openSession: AgentSession?
    @ObservedObject var client: AgentControlClient
    @State private var turnStartedAt: Date?

    private var turnState: TurnState {
        guard let session = openSession else { return .idle }
        return iOSChatStoreCache.shared.store(for: session.id, client: client).snapshot.currentTurnState
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
                break
            case .idle:
                turnStartedAt = nil
            }
        }
    }
}

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
        let t = Int(elapsed)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - History sheet

private struct HistorySheet: View {
    let sessions: [AgentSession]
    @Binding var selected: UUID?
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    Text("No chats yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt })) { session in
                        Button {
                            selected = session.id
                            onDismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Text(providerLabel(session.agent))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                                Text(session.displayLabel)
                                    .lineLimit(1)
                                if session.deepResearch {
                                    Image(systemName: "magnifyingglass.circle.fill")
                                        .foregroundStyle(.purple)
                                        .font(.caption)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
        }
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
}

// MARK: - Empty / unpaired states

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Start a new chat")
                .font(.headline)
            Text("Pick a provider, type a prompt. Toggle Deep Research for multi-step search.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct UnpairedBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Pair with your Mac")
                .font(.headline)
            Text("Open Clawdmeter on Mac, tap Sync with iPhone, then scan the QR or paste the URL on this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private extension AgentControlClient {
    /// Convenience for the V2 composer's Stop button.
    @MainActor
    func interruptSession(sessionId: UUID) async {
        guard let host = host, let token = token else { return }
        guard let url = URL(string: "http://\(Self.urlHostLiteral(host)):\(httpPort)/sessions/\(sessionId.uuidString)/interrupt") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
    }
}
