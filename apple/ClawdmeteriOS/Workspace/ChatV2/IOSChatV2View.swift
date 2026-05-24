import SwiftUI
import UniformTypeIdentifiers
import ClawdmeterShared

public struct IOSChatV2View: View {
    @ObservedObject var client: AgentControlClient
    @StateObject private var chatStore: ChatV2Store
    @StateObject private var sendCtl: ComposerSendController
    @State private var openTarget: ChatOpenTarget?
    @State private var historyPresented = false

    public init(agentClient: AgentControlClient) {
        self._client = ObservedObject(wrappedValue: agentClient)
        _chatStore = StateObject(wrappedValue: ChatV2Store())
        _sendCtl = StateObject(wrappedValue: ComposerSendController(client: agentClient))
    }

    public var body: some View {
        ChatBody(
            client: client,
            chatStore: chatStore,
            sendCtl: sendCtl,
            openTarget: $openTarget,
            historyPresented: $historyPresented
        )
    }
}

@available(iOS 17, *)
private struct ChatBody: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    @ObservedObject var chatStore: ChatV2Store
    @ObservedObject var sendCtl: ComposerSendController
    @Binding var openTarget: ChatOpenTarget?
    @Binding var historyPresented: Bool
    @State private var providerMatrix: ChatProvidersResponse?

    var body: some View {
        ZStack {
            TahoeWallpaperView()
            VStack(spacing: 0) {
                header
                if !client.isConfigured {
                    UnpairedState()
                } else {
                    broadcastStrip
                    transcript
                }
                Composer(
                    store: chatStore,
                    sendCtl: sendCtl,
                    openTarget: $openTarget,
                    client: client,
                    providerMatrix: providerMatrix
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $historyPresented) {
            HistorySheet(
                sessions: client.chatSessions,
                selected: $openTarget,
                client: client,
                onDismiss: { historyPresented = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task {
            await client.refreshSessions()
            providerMatrix = await client.fetchChatProviders()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CLAWDMETER")
                    .font(TahoeFont.body(10, weight: .bold))
                    .foregroundStyle(t.fg4)
                Text("Chat")
                    .font(TahoeFont.body(22, weight: .semibold))
                    .foregroundStyle(t.fg)
            }
            Spacer()
            Button { historyPresented = true } label: {
                TahoeIcon("archive", size: 17).foregroundStyle(t.fg2)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            Button {
                openTarget = nil
                sendCtl.reset()
                chatStore.clearAttachments()
            } label: {
                TahoeIcon("plus", size: 17).foregroundStyle(t.fg2)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var broadcastStrip: some View {
        TahoeGlass(radius: 18, tone: .chip) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(openTarget?.isReadOnlyTranscript == true ? "Archived transcript" : (openTarget?.isFrontier == true || chatStore.mode == .broadcast ? "Broadcast to all selected" : "Solo reply"))
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(openTarget?.isReadOnlyTranscript == true ? "Read-only history result" : (openTarget?.isFrontier == true || chatStore.mode == .broadcast ? "Compare answers · tap a model to read its reply" : "One provider answers this thread"))
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { chatStore.mode == .broadcast },
                    set: { chatStore.mode = $0 ? .broadcast : .solo; chatStore.persist() }
                ))
                .labelsHidden()
                .disabled(openTarget != nil)
            }
            .padding(12)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var transcript: some View {
        switch openTarget {
        case .solo(let id):
            if let session = client.chatSessions.first(where: { $0.id == id }) {
                SoloTranscript(session: session, client: client)
            } else {
                EmptyState(title: "Conversation not loaded", subtitle: "Open a recent chat or start a new one.")
            }
        case .frontier(let groupId):
            FrontierTranscript(
                groupId: groupId,
                client: client,
                selectedProvider: $chatStore.selectedReplyProvider,
                onContinueWinner: { winner in
                    // P1 fix (v0.23.9): server promoted the winner out
                    // of the broadcast group; flip the iOS UI to Solo
                    // so follow-ups go through /sessions/:id/send (not
                    // Frontier fan-out hitting archived losers).
                    openTarget = .solo(winner.id)
                    Task { await client.refreshSessions() }
                }
            )
                .id(groupId)
        case .transcript(_, let path):
            ReadOnlyTranscript(path: path, client: client)
        case nil:
            EmptyState(title: chatStore.mode == .broadcast ? "Ask selected providers" : "Start a solo chat",
                       subtitle: chatStore.mode == .broadcast ? "Selected providers will answer together." : "Pick a provider and send the first prompt.")
        }
    }
}

@available(iOS 17, *)
private struct SoloTranscript: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    var body: some View {
        let store = iOSChatStoreCache.shared.store(for: session.id, client: client)
        TranscriptScroll(items: store.snapshot.items, updateCounter: store.snapshot.updateCounter)
    }
}

@available(iOS 17, *)
private struct FrontierTranscript: View {
    @Environment(\.tahoe) private var t
    let groupId: UUID
    @ObservedObject var client: AgentControlClient
    @Binding var selectedProvider: AgentKind
    let onContinueWinner: (AgentSession) -> Void
    @StateObject private var frontierStore: FrontierSnapshotStore
    // v0.23.9 adversarial-review fix: gate the continue button while
    // its /pick-winner POST is in flight so a double-tap doesn't
    // fire two requests (the second would 404 against an already-
    // promoted winner).
    @State private var continuing = false

    init(
        groupId: UUID,
        client: AgentControlClient,
        selectedProvider: Binding<AgentKind>,
        onContinueWinner: @escaping (AgentSession) -> Void
    ) {
        self.groupId = groupId
        self.client = client
        self._selectedProvider = selectedProvider
        self.onContinueWinner = onContinueWinner
        _frontierStore = StateObject(wrappedValue: FrontierSnapshotStore(groupId: groupId, client: client))
    }

    private var children: [AgentSession] {
        client.frontierChildren(groupId: groupId)
    }

    private var selectedChild: AgentSession? {
        children.first(where: { $0.agent == selectedProvider }) ?? children.first
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(children, id: \.id) { child in
                        Button {
                            selectedProvider = child.agent
                        } label: {
                            HStack(spacing: 6) {
                                TahoeProviderGlyph(provider: child.agent.tahoeProvider, size: 16)
                                Text(child.agent.tahoeProvider.displayName)
                                    .font(TahoeFont.body(12, weight: .semibold))
                            }
                            .foregroundStyle(selectedChild?.id == child.id ? t.fg : t.fg3)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(selectedChild?.id == child.id ? Color.white.opacity(0.12) : Color.white.opacity(0.05), in: Capsule())
                            .overlay(Capsule().stroke(selectedChild?.id == child.id ? child.agent.tahoeProvider.halo.color.opacity(0.45) : t.hairline, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            if let child = selectedChild {
                let store = iOSChatStoreCache.shared.store(for: child.id, client: client)
                let frontierChild = snapshotChild(for: child)
                let visibleItems = frontierChild?.snapshot?.items ?? store.snapshot.items
                TranscriptScroll(
                    items: visibleItems,
                    updateCounter: frontierChild?.snapshot?.updateCounter ?? store.snapshot.updateCounter
                )
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    _ = await client.setFrontierTurnWinner(
                                        groupId: groupId,
                                        turnId: frontierStore.snapshot.latestTurnId,
                                        childIndex: child.frontierChildIndex ?? 0
                                    )
                                }
                            } label: {
                                Label("Winner", systemImage: "bookmark")
                                    .font(TahoeFont.body(11, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(frontierStore.snapshot.latestTurnId == "turn-0")
                            Button {
                                guard !continuing else { return }
                                continuing = true
                                Task {
                                    defer { Task { @MainActor in continuing = false } }
                                    if let promoted = await client.continueFrontierFromWinner(
                                        groupId: groupId,
                                        childIndex: child.frontierChildIndex ?? 0
                                    ) {
                                        await MainActor.run { onContinueWinner(promoted) }
                                    }
                                }
                            } label: {
                                TahoeIcon("arrowR", size: 13)
                                    .padding(9)
                                    .background(.thinMaterial, in: Circle())
                                    .opacity(continuing ? 0.5 : 1)
                            }
                            .buttonStyle(.plain)
                            .disabled(continuing)
                        }
                        .padding(14)
                    }
            } else {
                EmptyState(title: "Broadcast is starting", subtitle: "Provider replies will appear here.")
            }
        }
        .onAppear { frontierStore.start() }
        .onDisappear { frontierStore.stop() }
    }

    private func snapshotChild(for session: AgentSession) -> FrontierChild? {
        frontierStore.snapshot.children.first { $0.sessionId == session.id }
    }
}

@available(iOS 17, *)
private struct ReadOnlyTranscript: View {
    let path: String
    @ObservedObject var client: AgentControlClient
    @State private var envelope: TranscriptEnvelope?
    @State private var failed = false

    var body: some View {
        Group {
            if let envelope {
                TranscriptScroll(
                    items: envelope.messages.map(ChatItem.message),
                    updateCounter: UInt64(envelope.messages.count)
                )
            } else if failed {
                EmptyState(title: "Transcript unavailable", subtitle: "The archived JSONL could not be loaded.")
            } else {
                ProgressView().controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            failed = false
            envelope = await client.fetchTranscript(path: path)
            failed = envelope == nil
        }
    }
}

@available(iOS 17, *)
private struct TranscriptScroll: View {
    @Environment(\.tahoe) private var t
    let items: [ChatItem]
    let updateCounter: UInt64

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        MessageRow(item: item).id(item.id)
                    }
                    Color.clear.frame(height: 70).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: updateCounter) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@available(iOS 17, *)
private struct MessageRow: View {
    @Environment(\.tahoe) private var t
    let item: ChatItem

    var body: some View {
        switch item {
        case .message(let message):
            switch message.kind {
            case .userText:
                HStack {
                    Spacer(minLength: 42)
                    Text(message.body)
                        .font(TahoeFont.body(14))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(t.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                }
            case .assistantText:
                TahoeGlass(radius: 18, tone: .raised) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !message.title.isEmpty {
                            Text(message.title.uppercased())
                                .font(TahoeFont.body(10, weight: .bold))
                                .foregroundStyle(t.fg4)
                        }
                        Text(message.body)
                            .font(TahoeFont.body(14))
                            .foregroundStyle(t.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .toolCall, .toolResult:
                HStack(alignment: .top, spacing: 8) {
                    TahoeIcon("terminal", size: 11).foregroundStyle(t.fg3)
                    Text(message.body)
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg3)
                        .lineLimit(5)
                }
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            case .meta:
                Text(message.body)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg4)
            }
        case .toolRun(_, let pairs):
            Text(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)
        }
    }
}

@available(iOS 17, *)
private struct Composer: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var store: ChatV2Store
    @ObservedObject var sendCtl: ComposerSendController
    @Binding var openTarget: ChatOpenTarget?
    @ObservedObject var client: AgentControlClient
    let providerMatrix: ChatProvidersResponse?
    @State private var fileImporterPresented = false
    @FocusState private var focused: Bool

    var body: some View {
        TahoeGlass(radius: 22, tone: .raised) {
            VStack(alignment: .leading, spacing: 8) {
                if !store.attachments.isEmpty {
                    attachmentStrip
                }
                TextField(placeholder, text: $sendCtl.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                if let err = sendCtl.lastError {
                    Text(err)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                }

                HStack(spacing: 7) {
                    if openTarget == nil {
                        providerControls
                        deepResearchButton
                    } else {
                        threadBadge
                    }
                    Button { fileImporterPresented = true } label: {
                        TahoeIcon("paperclip", size: 13).foregroundStyle(t.fg3)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    sendButton
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    store.addAttachment(ChatV2Attachment(displayName: url.lastPathComponent, localFileURL: url))
                }
            }
        }
    }

    @ViewBuilder
    private var providerControls: some View {
        if store.mode == .broadcast {
            Menu {
                ForEach(ChatV2Store.defaultBroadcastProviderOrder, id: \.self) { provider in
                    Button { store.toggleBroadcastProvider(provider) } label: {
                        HStack {
                            Text(provider.tahoeProvider.displayName)
                            if store.broadcastProviders.contains(provider) { Image(systemName: "checkmark") }
                        }
                    }
                    .disabled(!isProviderAvailable(provider))
                }
            } label: {
                HStack(spacing: 6) {
                    TahoeIcon("branch", size: 12)
                    Text("All selected")
                        .font(TahoeFont.body(11.5, weight: .semibold))
                }
                .foregroundStyle(t.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
        } else {
            Menu {
                ForEach(ChatV2Store.defaultBroadcastProviderOrder, id: \.self) { provider in
                    Button {
                        store.selectedProvider = provider
                        store.persist()
                    } label: {
                        Text(provider.tahoeProvider.displayName)
                    }
                    .disabled(!isProviderAvailable(provider))
                }
            } label: {
                HStack(spacing: 6) {
                    TahoeProviderGlyph(provider: store.selectedProvider.tahoeProvider, size: 15)
                    Text(store.selectedProvider.tahoeProvider.displayName)
                        .font(TahoeFont.body(11.5, weight: .semibold))
                }
                .foregroundStyle(t.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
        }
    }

    private var deepResearchButton: some View {
        Button {
            store.deepResearch.toggle()
            store.persist()
        } label: {
            TahoeIcon("search", size: 13)
                .foregroundStyle(store.deepResearch ? t.accent : t.fg3)
                .frame(width: 30, height: 30)
                .background(store.deepResearch ? t.accent.opacity(0.16) : Color.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var threadBadge: some View {
        HStack(spacing: 6) {
            TahoeIcon(openTarget?.isReadOnlyTranscript == true ? "doc" : (openTarget?.isFrontier == true ? "branch" : "chat"), size: 12)
            Text(openTarget?.isReadOnlyTranscript == true ? "Read-only" : (openTarget?.isFrontier == true ? "Broadcast" : "Solo"))
                .font(TahoeFont.body(11.5, weight: .semibold))
        }
        .foregroundStyle(t.fg3)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private var sendButton: some View {
        Button { Task { await dispatchSend() } } label: {
            ZStack {
                Circle().fill(sendCtl.canSend ? t.accent : Color.white.opacity(0.08))
                if sendCtl.sending {
                    ProgressView().controlSize(.mini)
                } else {
                    TahoeIcon("arrowU", size: 15).foregroundStyle(sendCtl.canSend ? .white : t.fg4)
                }
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(!sendCtl.canSend || sendCtl.sending || openTarget?.isReadOnlyTranscript == true)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.attachments) { attachment in
                    HStack(spacing: 5) {
                        TahoeIcon("doc", size: 10).foregroundStyle(t.fg3)
                        Text(attachment.displayName)
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg2)
                            .lineLimit(1)
                        Button { store.removeAttachment(id: attachment.id) } label: {
                            TahoeIcon("x", size: 9).foregroundStyle(t.fg4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 10)
    }

    private var placeholder: String {
        if openTarget?.isReadOnlyTranscript == true { return "Archived transcript is read-only" }
        if openTarget?.isFrontier == true { return "Ask all selected…" }
        if openTarget != nil { return "Reply…" }
        return store.mode == .broadcast ? "Ask selected providers…" : "Ask \(store.selectedProvider.tahoeProvider.displayName)…"
    }

    private func dispatchSend() async {
        await sendCtl.sendCustom { trimmed in
            switch openTarget {
            case .solo(let sessionId):
                let prompt = await uploadAndBuildPrompt(base: trimmed, sessionId: sessionId)
                let ok = await client.sendPrompt(sessionId: sessionId, text: prompt, asFollowUp: true)
                if ok { store.clearAttachments() }
                return ok ? nil : (client.lastError ?? "Couldn't send prompt.")
            case .frontier(let groupId):
                let children = client.frontierChildren(groupId: groupId)
                guard children.count >= 2 else {
                    return "Broadcast needs at least two live children — pick a Solo chat to continue."
                }
                let perChild = await uploadAndBuildPerChildPrompts(
                    base: trimmed,
                    sessionIds: children.map(\.id)
                )
                guard let response = await client.sendFrontierPrompt(
                    groupId: groupId,
                    text: trimmed,
                    perChildText: perChild
                ) else {
                    return client.lastError ?? "Couldn't broadcast prompt."
                }
                store.clearAttachments()
                return response.ok ? nil : response.results.compactMap(\.reason).joined(separator: "\n")
            case .transcript:
                return "Archived transcripts are read-only. Start a new chat to continue."
            case nil:
                if store.mode == .broadcast {
                    let slots = store.frontierSlots().filter { isProviderAvailable($0.provider) }
                    guard slots.count >= 2 else { return "At least two broadcast providers must be available." }
                    guard let created = await client.createBroadcastChat(slots: slots) else {
                        return client.lastError ?? "Couldn't create broadcast chat."
                    }
                    // P1 fix (v0.23.9): require at least two slots to
                    // spawn successfully before opening the broadcast
                    // surface. A single-success "broadcast" is a silent
                    // degradation.
                    guard created.hasMinimumBroadcast else {
                        let reasons = created.failedSlots.compactMap(\.reason)
                        let detail = reasons.isEmpty ? "" : "\n" + reasons.joined(separator: "\n")
                        return "Broadcast needs at least two providers; only \(created.successfulSlots.count) spawned.\(detail)"
                    }
                    openTarget = .frontier(created.groupId)
                    let sessionIds = created.successfulSlots.compactMap(\.sessionId)
                    let perChild = await uploadAndBuildPerChildPrompts(
                        base: trimmed,
                        sessionIds: sessionIds
                    )
                    guard let response = await client.sendFrontierPrompt(
                        groupId: created.groupId,
                        text: trimmed,
                        perChildText: perChild
                    ) else {
                        return client.lastError ?? "Couldn't broadcast prompt."
                    }
                    store.clearAttachments()
                    return response.ok ? nil : response.results.compactMap(\.reason).joined(separator: "\n")
                } else {
                    guard let session = await client.createChatSession(
                        provider: store.selectedProvider,
                        model: store.selectedModel,
                        codexBackend: store.selectedProvider == .codex ? store.codexBackendPreference : nil,
                        effort: store.selectedEffort,
                        deepResearch: store.deepResearch
                    ) else {
                        return client.lastError ?? "Couldn't create chat."
                    }
                    openTarget = .solo(session.id)
                    let prompt = await uploadAndBuildPrompt(base: trimmed, sessionId: session.id)
                    let ok = await client.sendPrompt(sessionId: session.id, text: prompt, asFollowUp: false)
                    if ok { store.clearAttachments() }
                    return ok ? nil : (client.lastError ?? "Couldn't send prompt.")
                }
            }
        }
    }

    private func isProviderAvailable(_ provider: AgentKind) -> Bool {
        guard let entries = providerMatrix?.providers.filter({ $0.provider == provider }),
              !entries.isEmpty else {
            return true
        }
        return entries.contains { $0.capabilityProbePassed }
    }

    /// Solo path: upload each attachment to one session's staging dir
    /// and prepend `@<path>` mentions to the prompt body.
    private func uploadAndBuildPrompt(base: String, sessionId: UUID) async -> String {
        var paths: [String] = []
        for attachment in store.attachments {
            if let existing = attachment.pathOnDaemon {
                paths.append(existing)
                continue
            }
            guard let url = attachment.localFileURL else { continue }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let uploaded = await client.uploadAttachment(
                      sessionId: sessionId, ext: url.pathExtension, data: data
                  )
            else { continue }
            paths.append(uploaded)
        }
        guard !paths.isEmpty else { return base }
        return paths.map { "@\($0)" }.joined(separator: " ") + " " + base
    }

    /// Broadcast path (P2 fix v0.23.9): the daemon stages attachments
    /// per session, so each Frontier child needs its own staging path
    /// for any uploaded file. Upload the same bytes once per child and
    /// build a per-child prompt with that child's `@<path>` prefix.
    /// Returns nil if there are no attachments — caller falls back to
    /// the shared text in `sendFrontierPrompt`.
    private func uploadAndBuildPerChildPrompts(
        base: String,
        sessionIds: [UUID]
    ) async -> [UUID: String]? {
        guard !store.attachments.isEmpty, !sessionIds.isEmpty else { return nil }
        struct Stagable { let url: URL; let data: Data; let ext: String }
        var stagables: [Stagable] = []
        for attachment in store.attachments {
            guard let url = attachment.localFileURL else { continue }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            stagables.append(Stagable(url: url, data: data, ext: url.pathExtension))
        }
        guard !stagables.isEmpty else { return nil }
        var perChild: [UUID: String] = [:]
        for sessionId in sessionIds {
            var paths: [String] = []
            for stagable in stagables {
                if let uploaded = await client.uploadAttachment(
                    sessionId: sessionId,
                    ext: stagable.ext,
                    data: stagable.data
                ) {
                    paths.append(uploaded)
                }
            }
            let prompt = paths.isEmpty ? base : paths.map { "@\($0)" }.joined(separator: " ") + " " + base
            perChild[sessionId] = prompt
        }
        return perChild
    }
}

@available(iOS 17, *)
private struct HistorySheet: View {
    @Environment(\.tahoe) private var t
    let sessions: [AgentSession]
    @Binding var selected: ChatOpenTarget?
    @ObservedObject var client: AgentControlClient
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var results: [ChatSessionSearchMatch] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(rows) { row in
                        Button {
                            selected = row.target
                            onDismiss()
                        } label: {
                            rowLabel(row)
                        }
                    }
                } else {
                    ForEach(results) { match in
                        Button {
                            Task { await open(match: match) }
                        } label: {
                            Text(match.snippet).lineLimit(3)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search chats")
            .navigationTitle("Chats")
            .onChange(of: query) { _, value in scheduleSearch(value) }
        }
    }

    private var rows: [HistoryRowModel] {
        var seen = Set<UUID>()
        var out: [HistoryRowModel] = []
        for session in sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt }) {
            if let groupId = session.frontierGroupId {
                guard !seen.contains(groupId) else { continue }
                seen.insert(groupId)
                let children = sessions.filter { $0.frontierGroupId == groupId }
                out.append(HistoryRowModel(
                    id: groupId,
                    target: .frontier(groupId),
                    title: "Broadcast comparison",
                    subtitle: children.map { $0.agent.tahoeProvider.displayName }.joined(separator: " / "),
                    providers: children.map(\.agent)
                ))
            } else {
                out.append(HistoryRowModel(
                    id: session.id,
                    target: .solo(session.id),
                    title: session.displayLabel,
                    subtitle: session.model ?? "default",
                    providers: [session.agent]
                ))
            }
        }
        return out
    }

    @MainActor
    private func open(match: ChatSessionSearchMatch) async {
        await client.refreshSessions()
        if let groupId = match.frontierGroupId {
            let liveChildren = client.frontierChildren(groupId: groupId)
            if liveChildren.count >= 2 {
                selected = .frontier(groupId)
                onDismiss()
                return
            }
            // P1 fix (v0.23.9): if the group collapsed (e.g. after
            // pick-winner promoted one child out + archived the
            // others), reopen as Solo over the matched child rather
            // than a read-only transcript.
            if let session = client.chatSessions.first(where: { $0.id == match.sessionId }) {
                selected = session.frontierGroupId.map(ChatOpenTarget.frontier) ?? .solo(session.id)
                onDismiss()
                return
            }
            if let promoted = liveChildren.first {
                selected = .solo(promoted.id)
                onDismiss()
                return
            }
            _ = await client.fetchTranscript(path: match.jsonlPath, limit: 1)
            selected = .transcript(sessionId: match.sessionId, jsonlPath: match.jsonlPath)
            onDismiss()
            return
        }
        if let session = client.chatSessions.first(where: { $0.id == match.sessionId }) {
            selected = session.frontierGroupId.map(ChatOpenTarget.frontier) ?? .solo(session.id)
            onDismiss()
            return
        }
        _ = await client.fetchTranscript(path: match.jsonlPath, limit: 1)
        selected = .transcript(sessionId: match.sessionId, jsonlPath: match.jsonlPath)
        onDismiss()
    }

    private func rowLabel(_ row: HistoryRowModel) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(row.providers.prefix(3).enumerated()), id: \.offset) { _, provider in
                TahoeProviderGlyph(provider: provider.tahoeProvider, size: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(TahoeFont.body(13.5, weight: .semibold))
                Text(row.subtitle).font(TahoeFont.body(11)).foregroundStyle(t.fg3)
            }
        }
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled,
                  let response = await client.searchChatHistory(query: trimmed, limit: 50) else { return }
            await MainActor.run { results = response.matches }
        }
    }
}

private struct HistoryRowModel: Identifiable {
    let id: UUID
    let target: ChatOpenTarget
    let title: String
    let subtitle: String
    let providers: [AgentKind]
}

@available(iOS 17, *)
private struct EmptyState: View {
    @Environment(\.tahoe) private var t
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(TahoeFont.body(18, weight: .semibold))
                .foregroundStyle(t.fg)
            Text(subtitle)
                .font(TahoeFont.body(13))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@available(iOS 17, *)
private struct UnpairedState: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 8) {
            TahoeIcon("link", size: 26).foregroundStyle(t.fg3)
            Text("Pair with Mac")
                .font(TahoeFont.body(18, weight: .semibold))
                .foregroundStyle(t.fg)
            Text("Chat uses the paired Mac daemon to run providers.")
                .font(TahoeFont.body(13))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
