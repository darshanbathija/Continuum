import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ClawdmeterShared

fileprivate func chatProviderDisplayName(session: AgentSession, catalog: ModelCatalog) -> String {
    if let id = session.customProviderId,
       let summary = catalog.customProviders.first(where: { $0.id == id }) {
        return summary.label
    }
    return session.tahoeProvider.displayName
}

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
    @State private var providerInstances: ProviderInstanceListResponse?
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
                    providerMatrix: providerMatrix,
                    providerInstances: providerInstances
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
            let matrix = await client.fetchChatProviders()
            providerMatrix = matrix
            chatStore.applyProviderDefaults(client.providerDefaults, catalog: client.modelCatalog)
            chatStore.applyEnabledChoiceScope(enabledChoices(from: matrix))
            // Multi-account (wire v28): account list for the model
            // selector; also drops pins to accounts removed on the Mac
            // so a sticky pick can't 422 every create.
            providerInstances = await client.fetchProviderInstances()
            if let instances = providerInstances {
                for vendor in ChatVendor.allCases {
                    let available = instances.instances(for: vendor.backingProvider)
                    if let pinned = chatStore.selectedAccountByVendor[vendor],
                       !available.contains(where: { $0.wireId == pinned }) {
                        chatStore.selectAccount(nil, for: vendor)
                    }
                }
            }
        }
        .onChange(of: client.providerDefaults) { _, defaults in
            chatStore.applyProviderDefaults(defaults, catalog: client.modelCatalog)
        }
        .onChange(of: client.modelCatalog.updatedAt) { _, _ in
            chatStore.applyProviderDefaults(client.providerDefaults, catalog: client.modelCatalog)
            chatStore.applyEnabledChoiceScope(enabledChoices(from: providerMatrix))
        }
    }

    private func enabledChoices(from matrix: ChatProvidersResponse?) -> [ProviderChoice] {
        var choices = ChatV2Store.enabledChatChoices(
            from: matrix?.enabledProviderIDs,
            catalog: client.modelCatalog
        )
        if !client.supportsCustomProviders {
            choices = choices.filter { $0.chatVendor != nil }
        }
        return choices
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
                    Text(openTarget?.isReadOnlyTranscript == true ? "Archived transcript" : (openTarget?.isFrontier == true || chatStore.selectedChoiceCount > 1 ? "Broadcast to selected" : "One selected provider"))
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(openTarget?.isReadOnlyTranscript == true ? "Read-only history result" : (openTarget?.isFrontier == true || chatStore.selectedChoiceCount > 1 ? "Compare answers · tap a model to read its reply" : "\(chatStore.primaryChoice.displayName(in: client.modelCatalog)) answers this thread"))
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
                SoloTranscript(
                    session: session,
                    client: client,
                    sendCtl: sendCtl,
                    openTarget: $openTarget
                )
            } else {
                EmptyState(title: "Conversation not loaded", subtitle: "Open a recent chat or start a new one.")
            }
        case .frontier(let groupId):
            FrontierTranscript(
                groupId: groupId,
                client: client,
                sendCtl: sendCtl,
                openTarget: $openTarget,
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
            EmptyState(
                title: chatStore.selectedChoiceCount == 1
                    ? "Ask \(chatStore.primaryChoice.displayName(in: client.modelCatalog))"
                    : "Ask selected providers",
                subtitle: chatStore.selectedChoiceCount == 1
                    ? "One selected provider answers this thread."
                    : "Selected providers will answer together."
            )
        }
    }
}

@available(iOS 17, *)
private struct SoloTranscript: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient
    @ObservedObject var sendCtl: ComposerSendController
    @Binding var openTarget: ChatOpenTarget?

    var body: some View {
        let store = iOSChatStoreCache.shared.store(for: session.id, client: client)
        TranscriptScroll(
            items: store.snapshot.items,
            updateCounter: store.snapshot.updateCounter,
            turnState: store.snapshot.currentTurnState,
            recoveryActions: ChatV2TranscriptRecoveryActions(
                onRetryFailedTurn: { promptBody in
                    Task {
                        await ChatV2TurnRecovery.retryInSession(
                            sendCtl: sendCtl,
                            sessionId: session.id,
                            promptBody: promptBody
                        )
                    }
                },
                onRetryFailedTurnInNewChat: { promptBody in
                    Task {
                        await ChatV2TurnRecovery.retryInNewChat(
                            sendCtl: sendCtl,
                            client: client,
                            from: session,
                            promptBody: promptBody,
                            openTarget: $openTarget
                        )
                    }
                }
            )
        )
    }
}

@available(iOS 17, *)
private struct FrontierTranscript: View {
    @Environment(\.tahoe) private var t
    let groupId: UUID
    @ObservedObject var client: AgentControlClient
    @ObservedObject var sendCtl: ComposerSendController
    @Binding var openTarget: ChatOpenTarget?
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
        sendCtl: ComposerSendController,
        openTarget: Binding<ChatOpenTarget?>,
        selectedProvider: Binding<AgentKind>,
        onContinueWinner: @escaping (AgentSession) -> Void
    ) {
        self.groupId = groupId
        self.client = client
        self.sendCtl = sendCtl
        _openTarget = openTarget
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
                                if let customProviderId = child.customProviderId {
                                    CustomProviderGlyph(
                                        label: chatProviderDisplayName(session: child, catalog: client.modelCatalog),
                                        size: 16
                                    )
                                } else {
                                    TahoeProviderGlyph(provider: child.agent.tahoeProvider, size: 16)
                                }
                                Text(chatProviderDisplayName(session: child, catalog: client.modelCatalog))
                                    .font(TahoeFont.body(12, weight: .semibold))
                            }
                            .foregroundStyle(selectedChild?.id == child.id ? t.fg : t.fg3)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(selectedChild?.id == child.id ? Color.white.opacity(0.12) : Color.white.opacity(0.05), in: Capsule())
                            .overlay(Capsule().stroke(
                                selectedChild?.id == child.id
                                    ? (child.customProviderId.map { CustomProviderAccent.dot(for: $0).opacity(0.45) }
                                        ?? child.agent.tahoeProvider.dot.opacity(0.45))
                                    : t.hairline,
                                lineWidth: 0.5
                            ))
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
                    turnState: frontierChild?.currentTurnState ?? store.snapshot.currentTurnState,
                    recoveryActions: recoveryActions(for: child)
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

    private func recoveryActions(for session: AgentSession) -> ChatV2TranscriptRecoveryActions {
        ChatV2TranscriptRecoveryActions(
            onRetryFailedTurn: { promptBody in
                Task {
                    await ChatV2TurnRecovery.retryInSession(
                        sendCtl: sendCtl,
                        sessionId: session.id,
                        promptBody: promptBody
                    )
                }
            },
            onRetryFailedTurnInNewChat: { promptBody in
                Task {
                    await ChatV2TurnRecovery.retryInNewChat(
                        sendCtl: sendCtl,
                        client: client,
                        from: session,
                        promptBody: promptBody,
                        openTarget: $openTarget
                    )
                }
            }
        )
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
                    onLoadOlder: loadOlder,
                    recoveryActions: ChatV2TranscriptRecoveryActions(isReadOnly: true)
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
private struct ChatV2TranscriptRecoveryActions {
    var isReadOnly: Bool = false
    var onRetryFailedTurn: ((String) -> Void)?
    var onRetryFailedTurnInNewChat: ((String) -> Void)?
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
    var recoveryActions: ChatV2TranscriptRecoveryActions = ChatV2TranscriptRecoveryActions()
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
                messageRow(for: item).id(item.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(promptItems(turn)) { item in
                    messageRow(for: item).id(item.id)
                }
                disclosureButton(turn)
                if turn.hasCollapsedContent, expandedTurns.contains(turn.id) {
                    ForEach(turn.hiddenItems) { item in
                        messageRow(for: item).id(item.id)
                    }
                }
                ForEach(finalItems(turn)) { item in
                    messageRow(for: item).id(item.id)
                }
                compactChipStrip(turn)
            }
        }
    }

    private func messageRow(for item: ChatItem) -> some View {
        MessageRow(
            item: item,
            modelFailureRetryPrompt: modelFailureRetryPrompt(for: item),
            onRetryFailedTurn: recoveryActions.onRetryFailedTurn,
            onRetryFailedTurnInNewChat: recoveryActions.onRetryFailedTurnInNewChat
        )
    }

    private func modelFailureRetryPrompt(for item: ChatItem) -> String? {
        guard case .message(let message) = item else { return nil }
        let retryPrompt = ModelFailureRecovery.retryPrompt(
            forErrorMessageId: message.id,
            in: items
        )
        guard ModelFailureRecovery.shouldOfferRetryActions(
            message: message,
            isStreamingTail: false,
            turnState: turnState,
            isReadOnly: recoveryActions.isReadOnly,
            retryPrompt: retryPrompt
        ) else { return nil }
        return retryPrompt
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
            VStack(alignment: .leading, spacing: 8) {
                if !turn.outputArtifacts.isEmpty {
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
                    }
                }
                if !turn.editedFiles.isEmpty {
                    TranscriptEditedFileChipStripView(turn: turn)
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
    var modelFailureRetryPrompt: String? = nil
    var onRetryFailedTurn: ((String) -> Void)? = nil
    var onRetryFailedTurnInNewChat: ((String) -> Void)? = nil

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
                .contextMenu { messageCopyMenu(message) }
            case .assistantText:
                if message.isError {
                    errorAssistantRow(message)
                } else {
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
                    .contextMenu { messageCopyMenu(message) }
                }
            case .toolCall, .toolResult:
                AgentToolActionRow(
                    toolName: message.title,
                    callBody: message.body,
                    detail: message.detail,
                    isError: message.isError
                )
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            case .meta:
                if message.title == "Thinking" {
                    ThinkingActionRow(summary: message.body)
                } else {
                    Text(message.body)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg4)
                }
            }
        case .toolRun(_, let pairs):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pairs) { pair in
                    AgentToolActionRow(pair: pair)
                        .id("pair:\(pair.id)")
                }
            }
        }
    }

    private func errorAssistantRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SessionsV2Theme.danger)
                    Text("Model failed")
                        .font(TahoeFont.body(11, weight: .semibold))
                        .foregroundStyle(SessionsV2Theme.danger)
                }
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
            .background(SessionsV2Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SessionsV2Theme.danger.opacity(0.55), lineWidth: 1.25)
            )
            .accessibilityLabel("Model failed: \(message.body)")
            .contextMenu { messageCopyMenu(message) }

            if let retryPrompt = modelFailureRetryPrompt {
                modelFailureActionRow(retryPrompt: retryPrompt)
            }
        }
    }

    @ViewBuilder
    private func modelFailureActionRow(retryPrompt: String) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(ModelFailureRecovery.actionDescriptors().enumerated()), id: \.offset) { _, descriptor in
                switch descriptor.kind {
                case .retry:
                    Button(descriptor.visibleTitle) {
                        onRetryFailedTurn?(retryPrompt)
                    }
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.accent)
                    .accessibilityIdentifier(descriptor.accessibilityIdentifier)
                case .retryInNewChat:
                    Button(descriptor.visibleTitle) {
                        onRetryFailedTurnInNewChat?(retryPrompt)
                    }
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.accent)
                    .accessibilityIdentifier(descriptor.accessibilityIdentifier)
                }
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func messageCopyMenu(_ message: ChatMessage) -> some View {
        Button("Copy Message", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.body
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
    /// Multi-account (wire v28): nil on older Macs — account picker hidden.
    let providerInstances: ProviderInstanceListResponse?
    @State private var fileImporterPresented = false
    @State private var modelPickerPresented = false
    @State private var modelPickerChoice: ProviderChoice = .builtin(.chatgpt)
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
                    composerActionsMenu
                    if openTarget == nil {
                        providerControls
                    } else {
                        threadBadge
                    }
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
                initialChoice: modelPickerChoice,
                store: store,
                client: client,
                providerMatrix: providerMatrix,
                providerInstances: providerInstances
            )
        }
    }

    @ViewBuilder
    private var providerControls: some View {
        HStack(spacing: 6) {
            if enabledChoices.isEmpty {
                Text("Enable on Mac")
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.06), in: Capsule())
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(visibleSelectedChoices, id: \.self) { choice in
                            Button {
                                modelPickerChoice = choice
                                modelPickerPresented = true
                            } label: {
                                HStack(spacing: 5) {
                                    AnyProviderGlyph(choice: choice, catalog: client.modelCatalog, size: 12)
                                    Text(compactModelLabel(for: choice) ?? choice.displayName(in: client.modelCatalog))
                                        .font(TahoeFont.body(11.5, weight: .semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 104, alignment: .leading)
                                }
                                .foregroundStyle(isChoiceAvailable(choice) ? t.fg : t.fg4)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .frame(maxWidth: 138, alignment: .leading)
                                .background(Color.white.opacity(0.08), in: Capsule())
                                .overlay(Capsule().stroke(choiceAccent(choice).opacity(0.35), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: 168, alignment: .leading)
            }

            Button {
                if let choice = firstConfigurableChoice {
                    modelPickerChoice = choice
                    modelPickerPresented = true
                }
            } label: {
                TahoeIcon(store.selectedChoiceCount < 3 ? "plus" : "sliders", size: 12)
                    .foregroundStyle(t.fg3)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(firstConfigurableChoice == nil)
        }
        .frame(maxWidth: 176, alignment: .leading)
    }

    /// Bottom-left "+" overflow: Deep Research + Attach. Mirrors the Mac
    /// chat composer's `composerActionsMenu`.
    private var composerActionsMenu: some View {
        Menu {
            if openTarget == nil {
                Button {
                    store.deepResearch.toggle()
                    store.persist()
                } label: {
                    if store.deepResearch {
                        Label("Deep Research", systemImage: "checkmark")
                    } else {
                        Label("Deep Research", systemImage: "magnifyingglass")
                    }
                }
            }
            Button { fileImporterPresented = true } label: {
                Label("Attach", systemImage: "paperclip")
            }
        } label: {
            TahoeIcon("plus", size: 13)
                .foregroundStyle(store.deepResearch ? t.accent : t.fg3)
                .frame(width: 30, height: 30)
                .background(
                    store.deepResearch ? t.accent.opacity(0.16) : Color.white.opacity(0.06),
                    in: Circle()
                )
        }
        .accessibilityLabel("Composer actions")
        .accessibilityIdentifier("chat.composer.actions")
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
        if enabledChoices.isEmpty { return "Enable a provider on your Mac…" }
        return store.selectedChoiceCount == 1
            ? "Ask \(store.primaryChoice.displayName(in: client.modelCatalog))…"
            : "Ask selected providers…"
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
                let selectedChoices = visibleSelectedChoices
                guard !selectedChoices.isEmpty else {
                    return "Enable a provider in Continuum → Providers on your Mac."
                }
                let unavailableReasons = selectedChoices.compactMap { choiceUnavailableReason($0) }
                guard unavailableReasons.isEmpty else {
                    return unavailableReasons.joined(separator: "\n")
                }
                if selectedChoices.count >= 2 {
                    let slots = store.frontierSlots(catalog: client.modelCatalog).filter { slot in
                        if let customProviderId = slot.customProviderId {
                            return isChoiceAvailable(.custom(customProviderId))
                        }
                        if let chatVendor = slot.chatVendor {
                            return isVendorAvailable(chatVendor)
                        }
                        return isProviderAvailable(slot.provider)
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
                    let choice = store.primaryChoice
                    guard let agent = choice.backingAgent(in: client.modelCatalog) else {
                        return "Selected provider is unavailable."
                    }
                    guard let session = await client.createChatSession(
                        provider: agent,
                        model: store.model(forChoice: choice, catalog: client.modelCatalog),
                        effort: store.effort(forChoice: choice, catalog: client.modelCatalog),
                        chatVendor: choice.chatVendor,
                        billingProvider: choice.customProviderId ?? choice.chatVendor?.billingProvider,
                        deepResearch: store.deepResearch,
                        // Account pins only exist on the stock-vendor axis;
                        // custom-provider choices carry their own credentials.
                        providerInstanceId: choice.chatVendor.flatMap { vendor in
                            store.accountWireId(
                                for: vendor,
                                available: providerInstances?.instances(for: vendor.backingProvider)
                            )
                        },
                        customProviderId: choice.customProviderId
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

    private func isChoiceAvailable(_ choice: ProviderChoice) -> Bool {
        switch choice {
        case .builtin(let vendor):
            return isVendorAvailable(vendor)
        case .custom(let providerId):
            guard client.modelCatalog.customProviders.contains(where: { $0.id == providerId && $0.enabled }) else {
                return false
            }
            guard let entry = providerMatrix?.customProviders.first(where: { $0.id == providerId }) else {
                return true
            }
            return entry.available
        }
    }

    private func choiceUnavailableReason(_ choice: ProviderChoice) -> String? {
        switch choice {
        case .builtin(let vendor):
            return providerUnavailableReason(vendor)
        case .custom(let providerId):
            let label = choice.displayName(in: client.modelCatalog)
            guard client.modelCatalog.customProviders.contains(where: { $0.id == providerId && $0.enabled }) else {
                return "Enable \(label) in Continuum → Custom providers on your Mac."
            }
            guard isChoiceAvailable(choice) else {
                return providerMatrix?.customProviders.first(where: { $0.id == providerId && !$0.available })?.reason
                    ?? "\(label) is unavailable."
            }
            return nil
        }
    }

    private func choiceAccent(_ choice: ProviderChoice) -> Color {
        if let customProviderId = choice.customProviderId {
            return CustomProviderAccent.dot(for: customProviderId)
        }
        return choice.chatVendor?.tahoeProvider.dot ?? t.fg4
    }

    private func isProviderAvailable(_ provider: AgentKind) -> Bool {
        guard enabledChoices.contains(where: { $0.backingAgent(in: client.modelCatalog) == provider }) else {
            return false
        }
        guard let entries = providerMatrix?.providers.filter({ $0.provider == provider }),
              !entries.isEmpty else {
            return true
        }
        return entries.contains { $0.capabilityProbePassed }
    }

    private func isVendorAvailable(_ vendor: ChatVendor) -> Bool {
        guard enabledChoices.contains(.builtin(vendor)) else { return false }
        let provider = vendor.backingProvider
        guard let entries = providerMatrix?.providers.filter({ $0.provider == provider }),
              !entries.isEmpty else {
            return true
        }
        return entries.contains { $0.capabilityProbePassed }
    }

    private func providerUnavailableReason(_ vendor: ChatVendor) -> String? {
        guard enabledChoices.contains(.builtin(vendor)) else {
            return "Enable \(vendor.displayName) in Continuum → Providers on your Mac."
        }
        guard !isVendorAvailable(vendor) else { return nil }
        let provider = vendor.backingProvider
        return providerMatrix?.providers.first { $0.provider == provider && !$0.capabilityProbePassed }?.reason
    }

    private var firstConfigurableChoice: ProviderChoice? {
        enabledChoices.first { choice in
            !store.isChoiceSelected(choice) && isChoiceAvailable(choice)
        } ?? visibleSelectedChoices.first
    }

    private var enabledChoices: [ProviderChoice] {
        var choices = ChatV2Store.enabledChatChoices(
            from: providerMatrix?.enabledProviderIDs,
            catalog: client.modelCatalog
        )
        if !client.supportsCustomProviders {
            choices = choices.filter { $0.chatVendor != nil }
        }
        return choices
    }

    private var visibleSelectedChoices: [ProviderChoice] {
        ChatV2Store.normalizedChoices(
            store.selectedChoices.filter { enabledChoices.contains($0) },
            enabledChoices: enabledChoices
        )
    }

    private func compactModelLabel(for choice: ProviderChoice) -> String? {
        guard let id = store.model(forChoice: choice, catalog: client.modelCatalog) else { return nil }
        if let entry = choice.models(in: client.modelCatalog).first(where: { $0.id == id }) {
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
    @State private var selectedChoice: ProviderChoice
    @State private var query = ""
    @State private var refreshing = false
    @ObservedObject var store: ChatV2Store
    @ObservedObject var client: AgentControlClient
    @State private var providerMatrix: ChatProvidersResponse?
    private let providerInstances: ProviderInstanceListResponse?

    init(
        initialChoice: ProviderChoice,
        store: ChatV2Store,
        client: AgentControlClient,
        providerMatrix: ChatProvidersResponse?,
        providerInstances: ProviderInstanceListResponse? = nil
    ) {
        self._selectedChoice = State(initialValue: initialChoice)
        self.store = store
        self.client = client
        self._providerMatrix = State(initialValue: providerMatrix)
        self.providerInstances = providerInstances
    }

    var body: some View {
        NavigationStack {
            List {
                choiceSection
                selectionSection
                modelSection
                effortSection
                accountSection
            }
            .navigationTitle("Model selector")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search model name or raw id")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if case .builtin(let vendor) = selectedChoice,
                       vendor == .cursor || vendor == .openrouter {
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
            .onAppear {
                if !enabledChoices.contains(selectedChoice),
                   let first = enabledChoices.first {
                    selectedChoice = first
                }
                store.applyEnabledChoiceScope(enabledChoices)
            }
        }
    }

    private var choiceSection: some View {
        Section("Providers") {
            if enabledChoices.isEmpty {
                Text("Enable a provider in Continuum → Providers on your Mac.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(enabledChoices, id: \.self) { choice in
                    Button {
                        selectedChoice = choice
                    } label: {
                        HStack(spacing: 10) {
                            AnyProviderGlyph(choice: choice, catalog: client.modelCatalog, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.displayName(in: client.modelCatalog))
                                    .font(TahoeFont.body(14, weight: .semibold))
                                    .foregroundStyle(t.fg)
                                Text(isChoiceAvailable(choice) ? "Available" : (choiceUnavailableReason(choice) ?? "Unavailable"))
                                    .font(TahoeFont.body(11))
                                    .foregroundStyle(isChoiceAvailable(choice) ? t.fg3 : Color.orange)
                            }
                            Spacer()
                            if selectedChoice == choice {
                                Text("Editing")
                                    .font(TahoeFont.body(10.5, weight: .semibold))
                                    .foregroundStyle(t.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(t.accent.opacity(0.12), in: Capsule())
                            }
                            if store.isChoiceSelected(choice) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(t.accent)
                            }
                        }
                    }
                    .listRowBackground(selectedChoice == choice ? t.accent.opacity(0.08) : Color.clear)
                    .disabled(!store.isChoiceSelected(choice) && !isChoiceAvailable(choice))
                }
            }
        }
    }

    private var selectionSection: some View {
        Section {
            Button(selectionActionLabel) {
                store.toggleChoice(selectedChoice)
            }
            .disabled(!canToggleSelectedChoice)
        } footer: {
            Text(store.selectedChoiceCount == 1 ? "One provider creates a solo chat." : "Two or three providers create a broadcast.")
        }
    }

    private var selectionActionLabel: String {
        let name = selectedChoice.displayName(in: client.modelCatalog)
        if store.isChoiceSelected(selectedChoice) {
            return canToggleSelectedChoice ? "Remove \(name)" : "\(name) required"
        }
        return "Add \(name)"
    }

    @ViewBuilder
    private var modelSection: some View {
        if !enabledChoices.contains(selectedChoice) {
            Section("Model") {
                Text("Enable a provider on your Mac to choose models.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let sections = ProviderModelPickerSupport.sections(
                for: selectedChoice,
                catalog: client.modelCatalog,
                query: query
            )
            Section("Model - \(selectedChoice.displayName(in: client.modelCatalog))") {
                if sections.isEmpty {
                    Text("No models match the search.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sections) { section in
                    if case .builtin(.openrouter) = selectedChoice {
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
                                if store.model(forChoice: selectedChoice, catalog: client.modelCatalog) == entry.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(t.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Multi-account: which configured account runs the chat. Rendered
    /// only for stock-vendor choices (custom providers carry their own
    /// credentials) whose backing kind has ≥2 accounts on the paired Mac
    /// (wire ≥ 28).
    @ViewBuilder
    private var accountSection: some View {
        if let vendor = selectedChoice.chatVendor,
           let accounts = providerInstances?.instances(for: vendor.backingProvider),
           accounts.count >= 2 {
            let currentWireId = store.accountWireId(for: vendor, available: accounts)
            Section("Account - \(vendor.displayName)") {
                ForEach(accounts) { account in
                    Button {
                        store.selectAccount(account.isPrimary ? nil : account.wireId, for: vendor)
                    } label: {
                        HStack {
                            Text(account.displayName)
                                .font(account.isPrimary ? TahoeFont.body(13) : TahoeFont.mono(12.5))
                                .foregroundStyle(t.fg)
                            Spacer()
                            let isCurrent = account.isPrimary
                                ? currentWireId == nil
                                : account.wireId == currentWireId
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(t.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var effortSection: some View {
        if !enabledChoices.contains(selectedChoice) {
            Section("Effort") {
                Text("Enable a provider on your Mac to choose effort.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let modelId = store.model(forChoice: selectedChoice, catalog: client.modelCatalog)
            let supports = ProviderModelPickerSupport.supportsEffort(
                choice: selectedChoice,
                modelId: modelId,
                catalog: client.modelCatalog
            )
            Section("Effort - \(selectedChoice.displayName(in: client.modelCatalog))") {
                if supports {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                        ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                            Button {
                                selectEffort(effort)
                            } label: {
                                effortPill(
                                    effort,
                                    selected: (store.effort(forChoice: selectedChoice, catalog: client.modelCatalog) ?? .medium) == effort
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    HStack {
                        Text("Auto")
                        Spacer()
                        Text(selectedChoice.chatVendor == .cursor ? "Cursor account default" : "Unsupported by selected model")
                            .font(TahoeFont.body(12))
                            .foregroundStyle(.secondary)
                    }
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

    private var canToggleSelectedChoice: Bool {
        guard enabledChoices.contains(selectedChoice) else { return false }
        if store.isChoiceSelected(selectedChoice) {
            return store.selectedChoiceCount > 1
        }
        return store.selectedChoiceCount < 3 && isChoiceAvailable(selectedChoice)
    }

    private func refreshCatalog() {
        Task {
            refreshing = true
            if let matrix = await client.refreshChatProviders() {
                providerMatrix = matrix
                store.applyEnabledChoiceScope(enabledChoices)
                if !enabledChoices.contains(selectedChoice),
                   let first = enabledChoices.first {
                    selectedChoice = first
                }
            }
            await client.refreshModelCatalog()
            refreshing = false
        }
    }

    private func selectModel(_ entry: ModelCatalogEntry) {
        store.selectModel(entry.id, forChoice: selectedChoice, catalog: client.modelCatalog)
        guard let vendor = selectedChoice.chatVendor else { return }
        let effort = store.effort(forChoice: selectedChoice, catalog: client.modelCatalog)
        Task {
            _ = await client.updateProviderDefault(
                vendor: vendor,
                model: entry.id,
                effort: effort,
                clearEffort: effort == nil
            )
        }
    }

    private func selectEffort(_ effort: ReasoningEffort) {
        store.selectEffort(effort, forChoice: selectedChoice, catalog: client.modelCatalog)
        guard let vendor = selectedChoice.chatVendor else { return }
        let model = store.model(forChoice: selectedChoice, catalog: client.modelCatalog)
        let resolvedEffort = store.effort(forChoice: selectedChoice, catalog: client.modelCatalog)
        Task {
            _ = await client.updateProviderDefault(
                vendor: vendor,
                model: model,
                effort: resolvedEffort,
                clearEffort: resolvedEffort == nil
            )
        }
    }

    private func isChoiceAvailable(_ choice: ProviderChoice) -> Bool {
        switch choice {
        case .builtin(let vendor):
            return isVendorAvailable(vendor)
        case .custom(let providerId):
            guard client.modelCatalog.customProviders.contains(where: { $0.id == providerId && $0.enabled }) else {
                return false
            }
            guard let entry = providerMatrix?.customProviders.first(where: { $0.id == providerId }) else {
                return true
            }
            return entry.available
        }
    }

    private func choiceUnavailableReason(_ choice: ProviderChoice) -> String? {
        switch choice {
        case .builtin(let vendor):
            return providerUnavailableReason(vendor)
        case .custom(let providerId):
            let label = choice.displayName(in: client.modelCatalog)
            guard client.modelCatalog.customProviders.contains(where: { $0.id == providerId && $0.enabled }) else {
                return "Enable in Continuum → Custom providers"
            }
            guard isChoiceAvailable(choice) else {
                return providerMatrix?.customProviders.first(where: { $0.id == providerId && !$0.available })?.reason
                    ?? "\(label) is unavailable"
            }
            return nil
        }
    }

    private func isVendorAvailable(_ vendor: ChatVendor) -> Bool {
        guard enabledChoices.contains(.builtin(vendor)) else { return false }
        let provider = vendor.backingProvider
        guard let entries = providerMatrix?.providers.filter({ $0.provider == provider }),
              !entries.isEmpty else {
            return true
        }
        return entries.contains { $0.capabilityProbePassed }
    }

    private func providerUnavailableReason(_ vendor: ChatVendor) -> String? {
        guard enabledChoices.contains(.builtin(vendor)) else {
            return "Enable in Continuum → Providers"
        }
        guard !isVendorAvailable(vendor) else { return nil }
        let provider = vendor.backingProvider
        return providerMatrix?.providers.first { $0.provider == provider && !$0.capabilityProbePassed }?.reason
    }

    private var enabledChoices: [ProviderChoice] {
        var choices = ChatV2Store.enabledChatChoices(
            from: providerMatrix?.enabledProviderIDs,
            catalog: client.modelCatalog
        )
        if !client.supportsCustomProviders {
            choices = choices.filter { $0.chatVendor != nil }
        }
        return choices
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

@available(iOS 17, *)
@MainActor
private enum ChatV2TurnRecovery {
    static func retryInSession(
        sendCtl: ComposerSendController,
        sessionId: UUID,
        promptBody: String
    ) async {
        let liveDraft = sendCtl.text
        sendCtl.text = promptBody
        await sendCtl.send(via: .solo(sessionId: sessionId))
        if !liveDraft.isEmpty && liveDraft != promptBody {
            sendCtl.text = liveDraft
        }
    }

    static func retryInNewChat(
        sendCtl: ComposerSendController,
        client: AgentControlClient,
        from session: AgentSession,
        promptBody: String,
        openTarget: Binding<ChatOpenTarget?>
    ) async {
        let liveDraft = sendCtl.text
        sendCtl.text = promptBody
        await sendCtl.sendCustomOptimistic { trimmed in
            guard let newSession = await client.createChatSession(
                provider: session.agent,
                model: session.model,
                codexBackend: session.codexChatBackend,
                effort: session.effort,
                deepResearch: session.deepResearch,
                providerInstanceId: session.providerInstanceId,
                customProviderId: session.customProviderId
            ) else {
                return client.lastError ?? "Couldn't create chat."
            }
            openTarget.wrappedValue = .solo(newSession.id)
            let ok = await client.sendPrompt(
                sessionId: newSession.id,
                text: trimmed,
                asFollowUp: false
            )
            return ok ? nil : (client.lastError ?? "Couldn't send prompt.")
        }
        if !liveDraft.isEmpty && liveDraft != promptBody {
            sendCtl.text = liveDraft
        }
    }
}
