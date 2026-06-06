import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ClawdmeterShared

public struct IOSChatV2View: View {
    @ObservedObject var client: AgentControlClient
    @ObservedObject var outbox: MobileCommandOutbox
    @StateObject private var chatStore: ChatV2Store
    @StateObject private var sendCtl: ComposerSendController
    @State private var openTarget: ChatOpenTarget?
    @State private var historyPresented = false

    public init(agentClient: AgentControlClient, outbox: MobileCommandOutbox) {
        self._client = ObservedObject(wrappedValue: agentClient)
        self._outbox = ObservedObject(wrappedValue: outbox)
        _chatStore = StateObject(wrappedValue: ChatV2Store())
        _sendCtl = StateObject(wrappedValue: ComposerSendController(client: agentClient))
    }

    public var body: some View {
        ChatBody(
            client: client,
            chatStore: chatStore,
            sendCtl: sendCtl,
            outbox: outbox,
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
    @ObservedObject var outbox: MobileCommandOutbox
    @Binding var openTarget: ChatOpenTarget?
    @Binding var historyPresented: Bool
    @State private var providerMatrix: ChatProvidersResponse?

    var body: some View {
        ZStack {
            // A2 (v0.30.x): TahoeWallpaperView already painted by IOSRootView
            // (the parent). The local instance was a doubled Canvas draw on
            // every layout pass. Drop it; the root wallpaper bleeds through.
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
                    outbox: outbox,
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
            await client.refreshModelCatalog()
            await client.refreshProviderDefaults()
            chatStore.applyProviderDefaults(client.providerDefaults, catalog: client.modelCatalog)
            providerMatrix = await client.fetchChatProviders()
        }
        .onChange(of: client.providerDefaults) { _, defaults in
            chatStore.applyProviderDefaults(defaults, catalog: client.modelCatalog)
        }
        .onChange(of: client.modelCatalog.updatedAt) { _, _ in
            chatStore.applyProviderDefaults(client.providerDefaults, catalog: client.modelCatalog)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CONTINUUM")
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
        TahoeGlass(radius: 8, tone: .chip) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(openTarget?.isReadOnlyTranscript == true ? "Archived transcript" : (openTarget?.isFrontier == true || chatStore.selectedVendorCount > 1 ? "Broadcast to selected" : "One selected vendor"))
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(openTarget?.isReadOnlyTranscript == true ? "Read-only history result" : (openTarget?.isFrontier == true || chatStore.selectedVendorCount > 1 ? "Compare answers · tap a model to read its reply" : "\(chatStore.primaryVendor.displayName) answers this thread"))
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                }
                Spacer()
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
            EmptyState(title: chatStore.selectedVendorCount == 1 ? "Ask \(chatStore.primaryVendor.displayName)" : "Ask selected providers",
                       subtitle: chatStore.selectedVendorCount == 1 ? "One selected vendor answers this thread." : "Selected providers will answer together.")
        }
    }
}

@available(iOS 17, *)
private struct SoloTranscript: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    var body: some View {
        let store = iOSChatStoreCache.shared.store(for: session.id, client: client)
        TranscriptScroll(
            items: store.snapshot.items,
            updateCounter: store.snapshot.updateCounter,
            turnState: store.snapshot.currentTurnState
        )
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
                            .overlay(Capsule().stroke(selectedChild?.id == child.id ? child.agent.tahoeProvider.dot.opacity(0.45) : t.hairline, lineWidth: 0.5))
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
                    updateCounter: frontierChild?.snapshot?.updateCounter ?? store.snapshot.updateCounter,
                    turnState: frontierChild?.currentTurnState ?? store.snapshot.currentTurnState
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
                                    .background(ContinuumTokens.surface2, in: Capsule())
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
                                    .background(ContinuumTokens.surface2, in: Circle())
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
    @State private var isLoadingOlder = false

    var body: some View {
        Group {
            if let envelope {
                TranscriptScroll(
                    items: envelope.messages.map(ChatItem.message),
                    updateCounter: UInt64(envelope.messages.count),
                    hasOlderHistory: envelope.truncated,
                    isLoadingOlder: isLoadingOlder,
                    onLoadOlder: loadOlder
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

    private func loadOlder() async {
        guard !isLoadingOlder,
              let current = envelope,
              let oldest = current.messages.first
        else { return }
        await MainActor.run { isLoadingOlder = true }
        defer { Task { @MainActor in isLoadingOlder = false } }
        guard let older = await client.fetchTranscript(path: path, beforeId: oldest.id, limit: 200),
              !older.messages.isEmpty
        else {
            await MainActor.run {
                envelope = TranscriptEnvelope(path: current.path, messages: current.messages, truncated: false)
            }
            return
        }
        await MainActor.run {
            envelope = TranscriptEnvelope(
                path: current.path,
                messages: older.messages + current.messages,
                truncated: older.truncated
            )
        }
    }
}

@available(iOS 17, *)
private struct TranscriptScroll: View {
    @Environment(\.tahoe) private var t
    let items: [ChatItem]
    let updateCounter: UInt64
    var hasOlderHistory: Bool = false
    var isLoadingOlder: Bool = false
    var onLoadOlder: (() async -> Void)? = nil
    /// Live per-turn state. When `.streaming` with no assistant text yet, a
    /// thinking indicator renders so the user sees the model is working in the
    /// gap between sending and the first streamed token (every provider).
    var turnState: TurnState = .idle
    @State private var pinned = true
    @State private var expandedTurns: Set<String> = []
    @State private var projectionCache = SingleSlotProjectionCache<TranscriptProjectionCacheKey, TranscriptProjection>()
    private static let bottomSentinelId = "ios-chat-v2-bottom-sentinel"
    private static let thinkingRowId = "ios-chat-v2-thinking"

    /// Show the thinking dots only while a turn is streaming AND no assistant
    /// *text* has appeared yet — the growing text is its own feedback, so the
    /// indicator covers the send→first-token gap (and tool work before any
    /// answer text).
    private func isThinking(_ projection: TranscriptProjection) -> Bool {
        guard turnState == .streaming else { return false }
        for turn in projection.turns.reversed() {
            for item in turn.visibleItems.reversed() {
                switch item {
                case .message(let m): return m.kind != .assistantText
                case .toolRun: return true
                }
            }
        }
        return true   // streaming with an empty transcript → definitely thinking
    }

    private var transcriptProjection: TranscriptProjection {
        projectionCache.value(
            for: TranscriptProjectionCacheKey(
                updateCounter: updateCounter,
                mode: .latestAnswerOnly
            )
        ) {
            TranscriptTurnProjector.project(items: items, mode: .latestAnswerOnly)
        }
    }

    private func visibleTurns(_ projection: TranscriptProjection) -> ArraySlice<TranscriptTurn> {
        onLoadOlder == nil ? projection.turns.suffix(100) : projection.turns[...]
    }

    var body: some View {
        let projection = transcriptProjection
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if hasOlderHistory, let onLoadOlder {
                        Button {
                            Task { await onLoadOlder() }
                        } label: {
                            HStack(spacing: 6) {
                                if isLoadingOlder {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.up.circle")
                                }
                                Text(isLoadingOlder ? "Loading earlier…" : "Load earlier messages")
                            }
                            .font(TahoeFont.body(12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingOlder)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(visibleTurns(projection)) { turn in
                        collapsedTurnRow(turn)
                            .id(turn.id)
                    }
                    if isThinking(projection) {
                        ThinkingDotsRow()
                            .id(Self.thinkingRowId)
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 70).id(Self.bottomSentinelId)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                return visibleBottom >= geometry.contentSize.height - 48
            } action: { _, isAtBottom in
                pinned = isAtBottom
            }
            .onAppear {
                pinned = true
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                }
            }
            .onChange(of: updateCounter) { _, _ in
                guard pinned else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                }
            }
            .onChange(of: turnState) { _, _ in
                // The send→streaming flip shows the thinking row without an
                // updateCounter bump — scroll so it's visible.
                guard pinned else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func collapsedTurnRow(_ turn: TranscriptTurn) -> some View {
        if turn.prompt == nil {
            ForEach(turn.visibleItems) { item in
                MessageRow(item: item).id(item.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(promptItems(turn)) { item in
                    MessageRow(item: item).id(item.id)
                }
                disclosureButton(turn)
                if turn.hasCollapsedContent, expandedTurns.contains(turn.id) {
                    ForEach(turn.hiddenItems) { item in
                        MessageRow(item: item).id(item.id)
                    }
                }
                ForEach(finalItems(turn)) { item in
                    MessageRow(item: item).id(item.id)
                }
                compactChipStrip(turn)
            }
        }
    }

    private func promptItems(_ turn: TranscriptTurn) -> [ChatItem] {
        guard let promptId = turn.prompt?.id else { return [] }
        return turn.visibleItems.filter {
            if case .message(let message) = $0 { return message.id == promptId }
            return false
        }
    }

    private func finalItems(_ turn: TranscriptTurn) -> [ChatItem] {
        let promptId = turn.prompt?.id
        return turn.visibleItems.filter {
            if case .message(let message) = $0 { return message.id != promptId }
            return true
        }
    }

    @ViewBuilder
    private func disclosureButton(_ turn: TranscriptTurn) -> some View {
        let isOpen = expandedTurns.contains(turn.id)
        if turn.hasCollapsedContent {
            Button {
                if isOpen { expandedTurns.remove(turn.id) } else { expandedTurns.insert(turn.id) }
            } label: {
                disclosureLabel(turn, icon: isOpen ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
        } else {
            disclosureLabel(turn, icon: "clock")
        }
    }

    private func disclosureLabel(_ turn: TranscriptTurn, icon: String) -> some View {
        Label(turn.summary.disclosureLabel, systemImage: icon)
            .font(TahoeFont.body(11, weight: .semibold))
            .foregroundStyle(t.fg3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05), in: Capsule())
    }

    @ViewBuilder
    private func compactChipStrip(_ turn: TranscriptTurn) -> some View {
        if !turn.outputArtifacts.isEmpty || !turn.editedFiles.isEmpty {
            HStack(spacing: 7) {
                ForEach(turn.outputArtifacts.prefix(4)) { artifact in
                    Button {
                        UIPasteboard.general.string = artifact.path
                    } label: {
                        compactChip(icon: iconName(for: artifact.kind), title: artifact.filename)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy path \(artifact.path)")
                }
                ForEach(turn.editedFiles.prefix(4)) { file in
                    compactChip(icon: "pencil.and.scribble", title: file.basename)
                }
            }
            .padding(.leading, 24)
        }
    }

    private func compactChip(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(TahoeFont.body(11, weight: .semibold))
        .foregroundStyle(t.fg3)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.05), in: Capsule())
    }

    private func iconName(for kind: TranscriptArtifactKind) -> String {
        switch kind {
        case .markdown: return "doc.richtext"
        case .html: return "safari"
        case .image: return "photo"
        case .pdf: return "doc.text.magnifyingglass"
        case .document: return "doc.text"
        case .spreadsheet, .data: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .media: return "play.rectangle"
        case .archive: return "archivebox"
        }
    }
}

/// Animated three-dot "thinking" indicator shown in the send→first-token gap.
/// Styled as a left-aligned assistant bubble; dots pulse in a wave using the
/// heritage terra-cotta accent. Provider-agnostic — every model shows it.
@available(iOS 17, *)
private struct ThinkingDotsRow: View {
    @Environment(\.tahoe) private var t
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(t.accent)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1.0 : 0.3)
                    .scaleEffect(animating ? 1.0 : 0.65)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.hairline, lineWidth: 0.5))
        .onAppear { animating = true }
        .accessibilityLabel("Waiting for a response")
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
                        .background(t.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                }
            case .assistantText:
                TahoeGlass(radius: 8, tone: .raised) {
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
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            case .meta:
                Text(message.body)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg4)
            }
        case .toolRun(_, let pairs):
            VStack(alignment: .leading, spacing: 6) {
                Text(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg3)
                ForEach(pairs) { pair in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TahoeIcon("terminal", size: 10).foregroundStyle(t.fg3)
                            Text(pair.call.title)
                                .font(TahoeFont.mono(11, weight: .semibold))
                                .foregroundStyle(t.fg2)
                            Text(pair.call.body)
                                .font(TahoeFont.mono(11))
                                .foregroundStyle(t.fg3)
                                .lineLimit(2)
                        }
                        if let result = pair.result, !result.body.isEmpty {
                            Text(result.body)
                                .font(TahoeFont.mono(11))
                                .foregroundStyle(result.isError ? .red : t.fg3)
                                .lineLimit(6)
                        }
                    }
                    .padding(9)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .id("pair:\(pair.id)")
                }
            }
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
    @ObservedObject var outbox: MobileCommandOutbox
    let providerMatrix: ChatProvidersResponse?
    @State private var fileImporterPresented = false
    @State private var modelPickerPresented = false
    @State private var modelPickerVendor: ChatVendor = .chatgpt
    @FocusState private var focused: Bool

    var body: some View {
        TahoeGlass(radius: 8, tone: .raised) {
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
        .sheet(isPresented: $modelPickerPresented) {
            IOSChatModelSelectorSheet(
                initialVendor: modelPickerVendor,
                store: store,
                client: client,
                providerMatrix: providerMatrix
            )
        }
    }

    @ViewBuilder
    private var providerControls: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.selectedVendors, id: \.self) { vendor in
                        Button {
                            modelPickerVendor = vendor
                            modelPickerPresented = true
                        } label: {
                            HStack(spacing: 5) {
                                TahoeProviderGlyph(provider: vendor.backingProvider.tahoeProvider, size: 12)
                                Text(compactModelLabel(for: vendor) ?? vendor.displayName)
                                    .font(TahoeFont.body(11.5, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 104, alignment: .leading)
                            }
                            .foregroundStyle(isVendorAvailable(vendor) ? t.fg : t.fg4)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 138, alignment: .leading)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(vendor.backingProvider.tahoeProvider.dot.opacity(0.35), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: 168, alignment: .leading)

            Button {
                modelPickerVendor = firstConfigurableVendor
                modelPickerPresented = true
            } label: {
                TahoeIcon(store.selectedVendorCount < 3 ? "plus" : "sliders", size: 12)
                    .foregroundStyle(t.fg3)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 176, alignment: .leading)
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
            Text(openTarget?.isReadOnlyTranscript == true ? "Read-only" : (openTarget?.isFrontier == true ? "Broadcast" : "Single"))
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
        return store.selectedVendorCount == 1 ? "Ask \(store.primaryVendor.displayName)…" : "Ask selected providers…"
    }

    private func dispatchSend() async {
        await sendCtl.sendCustom { trimmed in
            switch openTarget {
            case .solo(let sessionId):
                let prompt = await uploadAndBuildPrompt(base: trimmed, sessionId: sessionId)
                outbox.enqueueSend(sessionId: sessionId, text: prompt, asFollowUp: true)
                store.clearAttachments()
                return nil
            case .frontier(let groupId):
                let children = client.frontierChildren(groupId: groupId)
                guard children.count >= 2 else {
                    return "Broadcast needs at least two live children; continue from one selected answer instead."
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
                let selectedVendors = store.selectedVendors
                let unavailableReasons = selectedVendors.compactMap { providerUnavailableReason($0) }
                guard unavailableReasons.isEmpty else {
                    return unavailableReasons.joined(separator: "\n")
                }
                if selectedVendors.count >= 2 {
                    let slots = store.frontierSlots(catalog: client.modelCatalog).filter { slot in
                        slot.chatVendor.map(isVendorAvailable(_:)) ?? isProviderAvailable(slot.provider)
                    }
                    guard slots.count >= 2 else { return "At least two selected providers must be available." }
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
                    let vendor = selectedVendors.first ?? store.primaryVendor
                    guard let session = await client.createChatSession(
                        provider: vendor.backingProvider,
                        model: store.model(for: vendor, catalog: client.modelCatalog),
                        effort: store.effort(for: vendor, catalog: client.modelCatalog),
                        chatVendor: vendor,
                        billingProvider: vendor.billingProvider,
                        deepResearch: store.deepResearch
                    ) else {
                        return client.lastError ?? "Couldn't create chat."
                    }
                    openTarget = .solo(session.id)
                    let prompt = await uploadAndBuildPrompt(base: trimmed, sessionId: session.id)
                    outbox.enqueueSend(sessionId: session.id, text: prompt, asFollowUp: false)
                    store.clearAttachments()
                    return nil
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

    private func isVendorAvailable(_ vendor: ChatVendor) -> Bool {
        let provider = vendor.backingProvider
        guard let entries = providerMatrix?.providers.filter({ $0.provider == provider }),
              !entries.isEmpty else {
            return true
        }
        return entries.contains { $0.capabilityProbePassed }
    }

    private func providerUnavailableReason(_ vendor: ChatVendor) -> String? {
        guard !isVendorAvailable(vendor) else { return nil }
        let provider = vendor.backingProvider
        return providerMatrix?.providers.first { $0.provider == provider && !$0.capabilityProbePassed }?.reason
    }

    private func modelSupportsEffort(_ vendor: ChatVendor) -> Bool {
        guard let id = store.model(for: vendor, catalog: client.modelCatalog),
              let entry = vendor.models(in: client.modelCatalog).first(where: { $0.id == id }) else {
            return vendor.defaultEffort != nil
        }
        return entry.supportsEffort
    }

    private var firstConfigurableVendor: ChatVendor {
        ChatV2Store.defaultChatVendorOrder.first { vendor in
            !store.isVendorSelected(vendor) && isVendorAvailable(vendor)
        } ?? store.primaryVendor
    }

    private func compactModelLabel(for vendor: ChatVendor) -> String? {
        guard let id = store.model(for: vendor, catalog: client.modelCatalog) else { return nil }
        if let entry = vendor.models(in: client.modelCatalog).first(where: { $0.id == id }) {
            return entry.displayName
        }
        return id
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
private struct IOSChatModelSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tahoe) private var t
    @State private var selectedVendor: ChatVendor
    @State private var query = ""
    @State private var refreshing = false
    @ObservedObject var store: ChatV2Store
    @ObservedObject var client: AgentControlClient
    let providerMatrix: ChatProvidersResponse?

    init(
        initialVendor: ChatVendor,
        store: ChatV2Store,
        client: AgentControlClient,
        providerMatrix: ChatProvidersResponse?
    ) {
        self._selectedVendor = State(initialValue: initialVendor)
        self.store = store
        self.client = client
        self.providerMatrix = providerMatrix
    }

    var body: some View {
        NavigationStack {
            List {
                vendorSection
                selectionSection
                modelSection
                effortSection
            }
            .navigationTitle("Model selector")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search model name or raw id")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selectedVendor == .cursor || selectedVendor == .openrouter {
                        Button {
                            refreshCatalog()
                        } label: {
                            if refreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    private var vendorSection: some View {
        Section("Providers") {
            ForEach(ChatV2Store.defaultChatVendorOrder, id: \.rawValue) { vendor in
                Button {
                    selectedVendor = vendor
                } label: {
                    HStack(spacing: 10) {
                        TahoeProviderGlyph(provider: vendor.backingProvider.tahoeProvider, size: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vendor.displayName)
                                .font(TahoeFont.body(14, weight: .semibold))
                                .foregroundStyle(t.fg)
                            Text(isVendorAvailable(vendor) ? "Available" : (providerUnavailableReason(vendor) ?? "Unavailable"))
                                .font(TahoeFont.body(11))
                                .foregroundStyle(isVendorAvailable(vendor) ? t.fg3 : Color.orange)
                        }
                        Spacer()
                        if selectedVendor == vendor {
                            Text("Editing")
                                .font(TahoeFont.body(10.5, weight: .semibold))
                                .foregroundStyle(t.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(t.accent.opacity(0.12), in: Capsule())
                        }
                        if store.isVendorSelected(vendor) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(t.accent)
                        }
                    }
                }
                .listRowBackground(selectedVendor == vendor ? t.accent.opacity(0.08) : Color.clear)
                .disabled(!store.isVendorSelected(vendor) && !isVendorAvailable(vendor))
            }
        }
    }

    private var selectionSection: some View {
        Section {
            Button(selectionActionLabel) {
                store.toggleVendor(selectedVendor)
            }
            .disabled(!canToggleSelectedVendor)
        } footer: {
            Text(store.selectedVendorCount == 1 ? "One provider creates a solo chat." : "Two or three providers create a broadcast.")
        }
    }

    private var selectionActionLabel: String {
        if store.isVendorSelected(selectedVendor) {
            return canToggleSelectedVendor ? "Remove \(selectedVendor.displayName)" : "\(selectedVendor.displayName) required"
        }
        return "Add \(selectedVendor.displayName)"
    }

    private var modelSection: some View {
        let sections = ProviderModelPickerSupport.sections(
            for: selectedVendor,
            catalog: client.modelCatalog,
            query: query
        )
        return Section("Model - \(selectedVendor.displayName)") {
            if sections.isEmpty {
                Text("No models match the search.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                if selectedVendor == .openrouter {
                    Text(section.title)
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(section.entries) { entry in
                    Button {
                        selectModel(entry)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.displayName)
                                    .font(TahoeFont.body(14, weight: .semibold))
                                    .foregroundStyle(t.fg)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Text(ProviderModelPickerSupport.metadataLine(for: entry))
                                    .font(TahoeFont.mono(11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                badges(for: entry)
                            }
                            Spacer()
                            if store.model(for: selectedVendor, catalog: client.modelCatalog) == entry.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(t.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    private var effortSection: some View {
        let modelId = store.model(for: selectedVendor, catalog: client.modelCatalog)
        let supports = ProviderModelPickerSupport.supportsEffort(
            vendor: selectedVendor,
            modelId: modelId,
            catalog: client.modelCatalog
        )
        return Section("Effort - \(selectedVendor.displayName)") {
            if supports {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                        Button {
                            selectEffort(effort)
                        } label: {
                            effortPill(
                                effort,
                                selected: (store.effort(for: selectedVendor, catalog: client.modelCatalog) ?? .medium) == effort
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack {
                    Text("Auto")
                    Spacer()
                    Text(selectedVendor == .cursor ? "Cursor account default" : "Unsupported by selected model")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func effortPill(_ effort: ReasoningEffort, selected: Bool) -> some View {
        Text(effortLabel(effort))
            .font(TahoeFont.body(12, weight: .semibold))
            .foregroundStyle(selected ? t.accent : t.fg3)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? t.accent.opacity(0.14) : Color.white.opacity(0.055), in: Capsule())
            .overlay(Capsule().stroke(selected ? t.accent.opacity(0.42) : t.hairline, lineWidth: 0.5))
    }

    private func badges(for entry: ModelCatalogEntry) -> some View {
        HStack(spacing: 5) {
            ForEach(ProviderModelPickerSupport.badges(for: entry), id: \.self) { badge in
                Text(badge)
                    .font(TahoeFont.body(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ContinuumTokens.surface2, in: Capsule())
            }
        }
    }

    private var canToggleSelectedVendor: Bool {
        if store.isVendorSelected(selectedVendor) {
            return store.selectedVendorCount > 1
        }
        return store.selectedVendorCount < 3 && isVendorAvailable(selectedVendor)
    }

    private func refreshCatalog() {
        Task {
            refreshing = true
            _ = await client.refreshChatProviders()
            await client.refreshModelCatalog()
            refreshing = false
        }
    }

    private func selectModel(_ entry: ModelCatalogEntry) {
        store.selectModel(entry.id, for: selectedVendor, catalog: client.modelCatalog)
        let effort = store.effort(for: selectedVendor, catalog: client.modelCatalog)
        Task {
            _ = await client.updateProviderDefault(
                vendor: selectedVendor,
                model: entry.id,
                effort: effort,
                clearEffort: effort == nil
            )
        }
    }

    private func selectEffort(_ effort: ReasoningEffort) {
        store.selectEffort(effort, for: selectedVendor, catalog: client.modelCatalog)
        let model = store.model(for: selectedVendor, catalog: client.modelCatalog)
        let resolvedEffort = store.effort(for: selectedVendor, catalog: client.modelCatalog)
        Task {
            _ = await client.updateProviderDefault(
                vendor: selectedVendor,
                model: model,
                effort: resolvedEffort,
                clearEffort: resolvedEffort == nil
            )
        }
    }

    private func isVendorAvailable(_ vendor: ChatVendor) -> Bool {
        let provider = vendor.backingProvider
        guard let entries = providerMatrix?.providers.filter({ $0.provider == provider }),
              !entries.isEmpty else {
            return true
        }
        return entries.contains { $0.capabilityProbePassed }
    }

    private func providerUnavailableReason(_ vendor: ChatVendor) -> String? {
        guard !isVendorAvailable(vendor) else { return nil }
        let provider = vendor.backingProvider
        return providerMatrix?.providers.first { $0.provider == provider && !$0.capabilityProbePassed }?.reason
    }

    private func effortLabel(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .minimal: return "Min"
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .xhigh: return "xHigh"
        case .max: return "Max"
        }
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
