import SwiftUI
import ClawdmeterShared

/// v0.23 Chat V2 — Tahoe-skinned iOS chat surface. Mirrors the
/// `ios-chat.jsx` artboard in the Tahoe redesign HTML: TahoeGlass
/// surfaces, TahoeProviderGlyph chips, accent halos drawn from the
/// user-picked `TahoeProvider.base`, no raw SwiftUI Color hardcoding.
///
/// No dead buttons:
/// - History sheet — rows tap to open (wired).
/// - New chat — clears openSessionId + resets composer.
/// - Provider chip — Menu picking AgentKind.
/// - Deep Research toggle — flips `ChatV2Store.deepResearch`,
///   persists to UserDefaults, threads into `.chatCreateV2`.
/// - Send / Stop — Send goes through ComposerSendController; Stop
///   POSTs `/sessions/:id/interrupt`, routes through
///   SessionInterruptDispatcher so it works on all 3 backends.
/// - Attachment chip — `PhotosPicker` for images + `.fileImporter`
///   for files; staged in `ChatV2Store.attachments`; `@`-mentioned
///   into the prompt body on send.
/// - "Pair with Mac" empty state — actionable copy + the existing
///   pairing surface is reachable via Settings (no dead CTA).
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
            ChatBody(
                client: client,
                chatStore: chatStore,
                sendCtl: sendCtl,
                openSessionId: $openSessionId,
                historySheetPresented: $historySheetPresented
            )
        }
    }
}

@available(iOS 17, *)
private struct ChatBody: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    @ObservedObject var chatStore: ChatV2Store
    @ObservedObject var sendCtl: ComposerSendController
    @Binding var openSessionId: UUID?
    @Binding var historySheetPresented: Bool

    var body: some View {
        ZStack {
            TahoeWallpaperView()
            VStack(spacing: 0) {
                if !client.isConfigured {
                    UnpairedState()
                } else if let openSessionId,
                          let session = client.chatSessions.first(where: { $0.id == openSessionId }) {
                    Transcript(session: session, client: client)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Composer(
                    sendCtl: sendCtl,
                    store: chatStore,
                    client: client,
                    openSession: openSessionId.flatMap { id in client.chatSessions.first(where: { $0.id == id }) },
                    onCreated: { id in openSessionId = id }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { historySheetPresented = true } label: {
                    TahoeIcon("sidebar", size: 16).foregroundStyle(t.fg2)
                }
                .accessibilityLabel("History")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openSessionId = nil
                    sendCtl.reset()
                    chatStore.clearAttachments()
                } label: {
                    TahoeIcon("plus", size: 16).foregroundStyle(t.fg2)
                }
                .accessibilityLabel("New chat")
            }
        }
        .sheet(isPresented: $historySheetPresented) {
            HistorySheet(
                sessions: client.chatSessions,
                client: client,
                selected: $openSessionId,
                onDismiss: { historySheetPresented = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task { await client.refreshSessions() }
    }
}

// MARK: - Transcript

@available(iOS 17, *)
private struct Transcript: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    var body: some View {
        let store = iOSChatStoreCache.shared.store(for: session.id, client: client)
        TranscriptScroll(store: store, sessionId: session.id, client: client)
    }
}

@available(iOS 17, *)
private struct TranscriptScroll: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var store: iOSChatStore
    let sessionId: UUID
    @ObservedObject var client: AgentControlClient
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
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
                        HStack(spacing: 4) {
                            TahoeIcon("chevD", size: 10)
                            Text("Latest")
                                .font(TahoeFont.body(11.5, weight: .semibold))
                        }
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
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

@available(iOS 17, *)
private struct MessageRow: View {
    @Environment(\.tahoe) private var t
    let item: ChatItem

    var body: some View {
        switch item {
        case .message(let m):
            switch m.kind {
            case .userText:
                HStack {
                    Spacer(minLength: 40)
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
            case .meta:
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(t.fg3)
                    Text(m.body)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                }
            case .toolCall, .toolResult:
                HStack(alignment: .top, spacing: 8) {
                    TahoeIcon("terminal", size: 11).foregroundStyle(t.fg3)
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

@available(iOS 17, *)
private struct Composer: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var sendCtl: ComposerSendController
    @ObservedObject var store: ChatV2Store
    @ObservedObject var client: AgentControlClient
    var openSession: AgentSession?
    let onCreated: (UUID) -> Void

    @FocusState private var textFocused: Bool
    @State private var fileImporterPresented: Bool = false

    private var isStreaming: Bool {
        if sendCtl.sending { return true }
        guard let session = openSession else { return false }
        let store = iOSChatStoreCache.shared.store(for: session.id, client: client)
        return store.snapshot.currentTurnState == .streaming
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
                    .focused($textFocused)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .disabled(sendCtl.sending)

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
                    attachmentChip
                    Spacer()
                    if isStreaming {
                        StatusStrip(openSession: openSession, client: client)
                    }
                    sendOrStopButton
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 4)
            }
        }
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await stageAttachments(urls: urls) }
            case .failure:
                break
            }
        }
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
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                TahoeIcon("chevD", size: 9).foregroundStyle(t.fg3)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(t.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
            }
            .overlay(Capsule().strokeBorder(t.hairline, lineWidth: 0.5))
        }
    }

    private var deepResearchChip: some View {
        Button {
            store.deepResearch.toggle()
            store.persist()
        } label: {
            HStack(spacing: 5) {
                TahoeIcon("search", size: 11)
                    .foregroundStyle(store.deepResearch
                                     ? haloColor
                                     : t.fg3)
                Text("Deep Research")
                    .font(TahoeFont.body(11.5, weight: store.deepResearch ? .semibold : .medium))
                    .foregroundStyle(store.deepResearch ? haloColor : t.fg3)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(
                    store.deepResearch
                    ? haloColor.opacity(0.15)
                    : (t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                )
            }
            .overlay(Capsule().strokeBorder(
                store.deepResearch ? haloColor.opacity(0.4) : t.hairline,
                lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var attachmentChip: some View {
        Button { fileImporterPresented = true } label: {
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
                        TahoeIcon("x", size: 10).foregroundStyle(t.fg3)
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
            Button { Task { await dispatchStop() } } label: {
                ZStack {
                    Circle().fill(Color.red.opacity(t.dark ? 0.18 : 0.14))
                    TahoeIcon("stop", size: 14).foregroundStyle(.red)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        } else {
            Button { Task { await dispatchSend() } } label: {
                ZStack {
                    Circle().fill(sendCtl.canSend
                                  ? providerBaseColor
                                  : (t.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))
                    TahoeIcon("arrowU", size: 15)
                        .foregroundStyle(sendCtl.canSend ? Color.white : t.fg4)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(!sendCtl.canSend)
        }
    }

    private var placeholder: String {
        if store.deepResearch {
            return "Ask a research question — multi-step search · 2-10 min"
        }
        return "Ask \(store.selectedProvider.tahoeProvider.displayName)…"
    }

    private var providerBaseColor: Color {
        store.selectedProvider.tahoeProvider.base.color
    }

    private var haloColor: Color {
        store.selectedProvider.tahoeProvider.halo.color
    }

    // MARK: - Send / stop / attach

    private func dispatchSend() async {
        guard sendCtl.canSend else { return }
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
        guard let session = openSession else { return }
        await client.interruptSession(sessionId: session.id)
    }

    private func stageAttachments(urls: [URL]) async {
        for url in urls {
            let _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            // Upload to the open session if we have one; otherwise the
            // attachment lands as a local file ref and the daemon
            // accepts the absolute `@<path>` mention.
            let att = ChatV2Attachment(displayName: url.lastPathComponent, pathOnDaemon: url.path)
            store.addAttachment(att)
            if let openSession,
               let data = try? Data(contentsOf: url),
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

// MARK: - Status strip

@available(iOS 17, *)
private struct StatusStrip: View {
    @Environment(\.tahoe) private var t
    var openSession: AgentSession?
    @ObservedObject var client: AgentControlClient
    @State private var turnStartedAt: Date?

    private var turnState: TurnState {
        guard let session = openSession else { return .idle }
        return iOSChatStoreCache.shared.store(for: session.id, client: client).snapshot.currentTurnState
    }

    var body: some View {
        HStack(spacing: 8) {
            IndicatorRing(
                streaming: turnState == .streaming,
                tint: (openSession?.agent.tahoeProvider ?? .claude).base.color
            )
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

@available(iOS 17, *)
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

@available(iOS 17, *)
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

// MARK: - History sheet

@available(iOS 17, *)
private struct HistorySheet: View {
    @Environment(\.tahoe) private var t
    let sessions: [AgentSession]
    @ObservedObject var client: AgentControlClient
    @Binding var selected: UUID?
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var results: [ChatSessionSearchMatch] = []
    @State private var searchInFlight: Bool = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TahoeGlass(radius: 10, tone: .chip) {
                    HStack(spacing: 8) {
                        TahoeIcon("search", size: 12).foregroundStyle(t.fg3)
                        TextField("Search chats", text: $query)
                            .textFieldStyle(.plain)
                            .font(TahoeFont.body(13))
                            .foregroundStyle(t.fg)
                        if searchInFlight {
                            ProgressView().controlSize(.mini)
                        } else if !query.isEmpty {
                            Button { query = ""; results = [] } label: {
                                TahoeIcon("x", size: 11).foregroundStyle(t.fg3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }

                List {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if sessions.isEmpty {
                            Text("No chats yet")
                                .font(TahoeFont.body(13))
                                .foregroundStyle(t.fg3)
                        } else {
                            ForEach(sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt })) { session in
                                Button { selected = session.id; onDismiss() } label: {
                                    sessionRow(session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if results.isEmpty && !searchInFlight {
                        Text("No matches")
                            .font(TahoeFont.body(13))
                            .foregroundStyle(t.fg3)
                    } else {
                        ForEach(results) { match in
                            Button { selected = match.sessionId; onDismiss() } label: {
                                searchRow(match)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
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

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 10) {
            TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayLabel)
                    .font(TahoeFont.body(13.5, weight: .medium))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                if let model = session.model, !model.isEmpty {
                    Text(model)
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg3)
                }
            }
            Spacer()
            if session.deepResearch {
                TahoeIcon("search", size: 11)
                    .foregroundStyle(session.agent.tahoeProvider.halo.color)
            }
        }
    }

    private func searchRow(_ match: ChatSessionSearchMatch) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TahoeIcon("doc", size: 11).foregroundStyle(t.fg3)
                Text(match.jsonlPath.split(separator: "/").last.map(String.init) ?? match.jsonlPath)
                    .font(TahoeFont.body(12.5, weight: .medium))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
            }
            Text(match.snippet)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .lineLimit(2)
        }
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = []
            searchInFlight = false
            return
        }
        searchInFlight = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let resp = await client.searchChatHistory(query: trimmed, limit: 50)
            if Task.isCancelled { return }
            await MainActor.run {
                results = resp?.matches ?? []
                searchInFlight = false
            }
        }
    }
}

// MARK: - Empty / unpaired states

@available(iOS 17, *)
private struct EmptyState: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: -8) {
                ForEach([TahoeProvider.claude, .codex, .gemini], id: \.self) { p in
                    TahoeProviderGlyph(provider: p, size: 30)
                }
            }
            .padding(.bottom, 4)
            Text("Start a new chat")
                .font(TahoeFont.body(16, weight: .semibold))
                .foregroundStyle(t.fg)
            Text("Pick a provider, type a prompt. Toggle Deep Research for multi-step search with citations.")
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

@available(iOS 17, *)
private struct UnpairedState: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 12) {
            TahoeIcon("qr", size: 36).foregroundStyle(t.fg3)
            Text("Pair with your Mac")
                .font(TahoeFont.body(16, weight: .semibold))
                .foregroundStyle(t.fg)
            Text("Open Clawdmeter on Mac → Sync with iPhone, then scan or paste the URL on this device.")
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

private extension AgentControlClient {
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
