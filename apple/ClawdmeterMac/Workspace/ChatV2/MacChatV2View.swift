import SwiftUI
import AppKit
import ClawdmeterShared

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
            ChatEmptyState(title: "Chat unavailable", subtitle: "The local agent daemon is not running.")
        }
    }
}

@available(macOS 14, *)
private struct ChatRoot: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    weak var runtime: AppRuntime?

    @StateObject private var store = ChatV2Store()
    @StateObject private var sendCtl: ComposerSendController
    @State private var openTarget: ChatOpenTarget?
    @State private var providerMatrix: ChatProvidersResponse?

    init(client: AgentControlClient, runtime: AppRuntime?) {
        self.client = client
        self.runtime = runtime
        _sendCtl = StateObject(wrappedValue: ComposerSendController(client: client))
    }

    var body: some View {
        HStack(spacing: 10) {
            Sidebar(
                sessions: client.chatSessions,
                openTarget: $openTarget,
                client: client,
                onNew: {
                    openTarget = nil
                    sendCtl.reset()
                    store.clearAttachments()
                }
            )
            .frame(width: 252)

            VStack(spacing: 10) {
                Header(store: store, openTarget: openTarget, children: frontierChildren)
                if let openTarget {
                    switch openTarget {
                    case .solo(let id):
                        if let session = client.chatSessions.first(where: { $0.id == id }) {
                            SoloTranscript(session: session, runtime: runtime)
                        } else {
                            ChatEmptyState(title: "Conversation not loaded", subtitle: "Refresh chat history and try again.")
                        }
                    case .frontier(let groupId):
                        BroadcastTranscript(
                            groupId: groupId,
                            children: frontierChildren,
                            runtime: runtime,
                            client: client,
                            onContinueWinner: { winner in
                                // P1 fix (v0.23.9): server promoted the
                                // winner out of the broadcast group;
                                // flip the UI to Solo so follow-ups go
                                // through /sessions/:id/send (not the
                                // Frontier fan-out hitting archived
                                // losers).
                                self.openTarget = .solo(winner.id)
                                Task { await client.refreshSessions() }
                            }
                        )
                        .id(groupId)
                    case .transcript(_, let path):
                        ReadOnlyTranscript(path: path, client: client)
                    }
                } else {
                    StartPanel(store: store)
                }
                ComposerBar(
                    store: store,
                    sendCtl: sendCtl,
                    openTarget: $openTarget,
                    client: client,
                    providerMatrix: providerMatrix
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .background(TahoeWallpaperView())
        .task {
            await client.refreshSessions()
            providerMatrix = await client.fetchChatProviders()
        }
    }

    private var frontierChildren: [AgentSession] {
        guard case .frontier(let groupId) = openTarget else { return [] }
        return client.frontierChildren(groupId: groupId)
    }

}

@available(macOS 14, *)
private struct Sidebar: View {
    @Environment(\.tahoe) private var t
    let sessions: [AgentSession]
    @Binding var openTarget: ChatOpenTarget?
    @ObservedObject var client: AgentControlClient
    let onNew: () -> Void

    @State private var query = ""
    @State private var results: [ChatSessionSearchMatch] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        TahoeGlass(radius: 18, tone: .panel) {
            VStack(spacing: 0) {
                HStack {
                    Text("Chat")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Spacer()
                    Button(action: onNew) {
                        TahoeIcon("plus", size: 13).foregroundStyle(t.fg2)
                    }
                    .buttonStyle(.plain)
                    .help("New chat")
                }
                .padding(12)

                TahoeGlass(radius: 10, tone: .chip) {
                    HStack(spacing: 7) {
                        TahoeIcon("search", size: 11).foregroundStyle(t.fg3)
                        TextField("Search chats", text: $query)
                            .textFieldStyle(.plain)
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .onChange(of: query) { _, value in
                    searchTask?.cancel()
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        results = []
                        return
                    }
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 220_000_000)
                        guard !Task.isCancelled,
                              let response = await client.searchChatHistory(query: trimmed) else { return }
                        await MainActor.run { results = response.matches }
                    }
                }

                TahoeHair()

                ScrollView {
                    LazyVStack(spacing: 7) {
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ForEach(groupRows) { row in
                                HistoryRow(row: row, selected: openTarget == row.target) {
                                    openTarget = row.target
                                }
                            }
                        } else {
                            ForEach(results) { match in
                                Button {
                                    Task { await open(match: match) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(match.snippet)
                                            .font(TahoeFont.body(11.5))
                                            .foregroundStyle(t.fg)
                                            .lineLimit(3)
                                        Text(Self.relative(match.lastEventAt))
                                            .font(TahoeFont.body(10))
                                            .foregroundStyle(t.fg4)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(t.dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private var groupRows: [SidebarRow] {
        var seenGroups = Set<UUID>()
        var rows: [SidebarRow] = []
        for session in sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt }) {
            if let groupId = session.frontierGroupId {
                guard !seenGroups.contains(groupId) else { continue }
                seenGroups.insert(groupId)
                let children = sessions.filter { $0.frontierGroupId == groupId }
                rows.append(SidebarRow(
                    id: groupId,
                    target: .frontier(groupId),
                    title: "Broadcast comparison",
                    subtitle: children.map { $0.agent.tahoeProvider.displayName }.joined(separator: " / "),
                    providers: children.map(\.agent),
                    lastEventAt: children.map(\.lastEventAt).max() ?? session.lastEventAt
                ))
            } else {
                rows.append(SidebarRow(
                    id: session.id,
                    target: .solo(session.id),
                    title: session.displayLabel,
                    subtitle: session.model ?? "default",
                    providers: [session.agent],
                    lastEventAt: session.lastEventAt
                ))
            }
        }
        return rows
    }

    @MainActor
    private func open(match: ChatSessionSearchMatch) async {
        await client.refreshSessions()
        if let groupId = match.frontierGroupId {
            let liveChildren = client.frontierChildren(groupId: groupId)
            if liveChildren.count >= 2 {
                // Still a real broadcast group.
                openTarget = .frontier(groupId)
                return
            }
            // P1 fix (v0.23.9): if the group collapsed (e.g. after
            // pick-winner promoted one child out of the group + archived
            // the others), prefer reopening the matched child as a
            // regular Solo chat over the read-only transcript fallback.
            if let session = client.chatSessions.first(where: { $0.id == match.sessionId }) {
                openTarget = session.frontierGroupId.map(ChatOpenTarget.frontier) ?? .solo(session.id)
                return
            }
            if let promoted = liveChildren.first {
                openTarget = .solo(promoted.id)
                return
            }
            _ = await client.fetchTranscript(path: match.jsonlPath, limit: 1)
            openTarget = .transcript(sessionId: match.sessionId, jsonlPath: match.jsonlPath)
            return
        }
        if let session = client.chatSessions.first(where: { $0.id == match.sessionId }) {
            openTarget = session.frontierGroupId.map(ChatOpenTarget.frontier) ?? .solo(session.id)
            return
        }
        _ = await client.fetchTranscript(path: match.jsonlPath, limit: 1)
        openTarget = .transcript(sessionId: match.sessionId, jsonlPath: match.jsonlPath)
    }

    private static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

private struct SidebarRow: Identifiable {
    let id: UUID
    let target: ChatOpenTarget
    let title: String
    let subtitle: String
    let providers: [AgentKind]
    let lastEventAt: Date
}

@available(macOS 14, *)
private struct HistoryRow: View {
    @Environment(\.tahoe) private var t
    let row: SidebarRow
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    ForEach(Array(row.providers.prefix(3).enumerated()), id: \.offset) { _, provider in
                        TahoeProviderGlyph(provider: provider.tahoeProvider, size: 16)
                    }
                    Spacer()
                    Text(RelativeDateTimeFormatter().localizedString(for: row.lastEventAt, relativeTo: Date()))
                        .font(TahoeFont.body(10))
                        .foregroundStyle(t.fg4)
                }
                Text(row.title)
                    .font(TahoeFont.body(12.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg3)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.white.opacity(0.11) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? t.accent.opacity(0.45) : t.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 14, *)
private struct Header: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var store: ChatV2Store
    let openTarget: ChatOpenTarget?
    let children: [AgentSession]

    var body: some View {
        HStack(spacing: 10) {
            modeToggle
            if openTarget?.isFrontier == true {
                ForEach(children, id: \.id) { child in
                    ProviderSummary(session: child)
                }
            } else {
                ForEach(store.mode == .broadcast ? store.broadcastProviderOrder : [store.selectedProvider], id: \.self) { provider in
                    ProviderDraftSummary(provider: provider, store: store)
                }
            }
        }
    }

    private var modeToggle: some View {
        TahoeGlass(radius: 14, tone: .chip) {
            HStack(spacing: 4) {
                modeButton(.broadcast, "Broadcast")
                modeButton(.solo, "Solo")
            }
            .padding(4)
        }
        .frame(width: 190)
    }

    private func modeButton(_ mode: ChatV2Mode, _ title: String) -> some View {
        Button {
            store.mode = mode
            store.persist()
        } label: {
            Text(title)
                .font(TahoeFont.body(11.5, weight: .semibold))
                .foregroundStyle(store.mode == mode ? t.fg : t.fg3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(store.mode == mode ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(openTarget != nil)
    }
}

@available(macOS 14, *)
private struct ProviderDraftSummary: View {
    @Environment(\.tahoe) private var t
    let provider: AgentKind
    @ObservedObject var store: ChatV2Store

    var body: some View {
        TahoeGlass(radius: 14, tone: .panel) {
            HStack(spacing: 9) {
                TahoeProviderGlyph(provider: provider.tahoeProvider, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.tahoeProvider.displayName)
                        .font(TahoeFont.body(12.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(store.model(for: provider) ?? "default")
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                }
                Spacer()
                Text(store.deepResearch ? "research" : "ready")
                    .font(TahoeFont.body(10, weight: .semibold))
                    .foregroundStyle(store.deepResearch ? provider.tahoeProvider.halo.color : t.fg4)
            }
            .padding(10)
        }
    }
}

@available(macOS 14, *)
private struct ProviderSummary: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession

    var body: some View {
        TahoeGlass(radius: 14, tone: .panel) {
            HStack(spacing: 9) {
                TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.agent.tahoeProvider.displayName)
                        .font(TahoeFont.body(12.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(session.model ?? "default")
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                }
                Spacer()
                Text(session.deepResearch ? "research" : "live")
                    .font(TahoeFont.body(10, weight: .semibold))
                    .foregroundStyle(session.deepResearch ? session.agent.tahoeProvider.halo.color : t.fg4)
            }
            .padding(10)
        }
    }
}

@available(macOS 14, *)
private struct StartPanel: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var store: ChatV2Store

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ForEach(store.mode == .broadcast ? store.broadcastProviderOrder : [store.selectedProvider], id: \.self) { provider in
                        TahoeProviderGlyph(provider: provider.tahoeProvider, size: 42)
                    }
                }
                Text(store.mode == .broadcast ? "Broadcast to all selected agents" : "Start a solo chat")
                    .font(TahoeFont.body(18, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text(store.mode == .broadcast ? "Send one prompt and compare live replies side by side." : "Use one provider when you already know who should answer.")
                    .font(TahoeFont.body(12.5))
                    .foregroundStyle(t.fg3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@available(macOS 14, *)
private struct SoloTranscript: View {
    let session: AgentSession
    weak var runtime: AppRuntime?

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            if let runtime, let store = runtime.agentControlServer.chatStore(for: session) {
                TranscriptScroll(items: store.snapshot.items, updateCounter: store.snapshot.updateCounter)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

@available(macOS 14, *)
private struct ReadOnlyTranscript: View {
    let path: String
    @ObservedObject var client: AgentControlClient
    @State private var envelope: TranscriptEnvelope?
    @State private var failed = false

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            if let envelope {
                TranscriptScroll(
                    items: envelope.messages.map(ChatItem.message),
                    updateCounter: UInt64(envelope.messages.count)
                )
            } else if failed {
                ChatEmptyState(title: "Transcript unavailable", subtitle: "The archived JSONL could not be loaded.")
            } else {
                ProgressView().controlSize(.small)
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

@available(macOS 14, *)
private struct BroadcastTranscript: View {
    @Environment(\.tahoe) private var t
    let groupId: UUID
    let children: [AgentSession]
    weak var runtime: AppRuntime?
    @ObservedObject var client: AgentControlClient
    let onContinueWinner: (AgentSession) -> Void
    @StateObject private var frontierStore: FrontierSnapshotStore

    init(
        groupId: UUID,
        children: [AgentSession],
        runtime: AppRuntime?,
        client: AgentControlClient,
        onContinueWinner: @escaping (AgentSession) -> Void
    ) {
        self.groupId = groupId
        self.children = children
        self.runtime = runtime
        self.client = client
        self.onContinueWinner = onContinueWinner
        _frontierStore = StateObject(wrappedValue: FrontierSnapshotStore(groupId: groupId, client: client))
    }

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            if children.isEmpty {
                ChatEmptyState(title: "Broadcast group is empty", subtitle: "No live child sessions are attached to this comparison.")
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(children, id: \.id) { child in
                            let frontierChild = frontierStore.snapshot.children.first { $0.sessionId == child.id }
                            ProviderColumn(
                                groupId: groupId,
                                turnId: frontierStore.snapshot.latestTurnId,
                                session: child,
                                frontierChild: frontierChild,
                                winner: winner(for: child),
                                runtime: runtime,
                                client: client,
                                onContinueWinner: onContinueWinner
                            )
                                .frame(width: max(280, min(420, columnWidth)))
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear { frontierStore.start() }
        .onDisappear { frontierStore.stop() }
    }

    private var columnWidth: CGFloat {
        NSScreen.main?.visibleFrame.width ?? 1180 / CGFloat(max(children.count, 1))
    }

    private func winner(for child: AgentSession) -> FrontierTurnWinner? {
        frontierStore.snapshot.turnWinners.last {
            $0.childIndex == (child.frontierChildIndex ?? 0)
                && $0.turnId == frontierStore.snapshot.latestTurnId
        }
    }
}

@available(macOS 14, *)
private struct ProviderColumn: View {
    @Environment(\.tahoe) private var t
    let groupId: UUID
    let turnId: String
    let session: AgentSession
    let frontierChild: FrontierChild?
    let winner: FrontierTurnWinner?
    weak var runtime: AppRuntime?
    @ObservedObject var client: AgentControlClient
    let onContinueWinner: (AgentSession) -> Void
    // v0.23.9 adversarial-review fix: double-tap on the continue
    // button used to fire two /pick-winner POSTs (the second hits
    // 404 because the winner has already been promoted out of the
    // group). Gate the button while one request is in flight.
    @State private var continuing = false

    var body: some View {
        TahoeGlass(radius: 16, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.agent.tahoeProvider.displayName)
                            .font(TahoeFont.body(12, weight: .semibold))
                            .foregroundStyle(t.fg)
                        Text(session.model ?? "default")
                            .font(TahoeFont.mono(10))
                            .foregroundStyle(t.fg4)
                    }
                    Spacer()
                    Button {
                        Task { _ = await client.setFrontierTurnWinner(groupId: groupId, turnId: turnId, childIndex: session.frontierChildIndex ?? 0) }
                    } label: {
                        TahoeIcon("bookmark", size: 13).foregroundStyle(winner == nil ? t.fg3 : session.agent.tahoeProvider.halo.color)
                    }
                    .buttonStyle(.plain)
                    .disabled(turnId == "turn-0")
                    .help("Mark this answer as winner")
                    Button {
                        guard !continuing else { return }
                        continuing = true
                        Task {
                            defer { Task { @MainActor in continuing = false } }
                            if let promoted = await client.continueFrontierFromWinner(
                                groupId: groupId,
                                childIndex: session.frontierChildIndex ?? 0
                            ) {
                                await MainActor.run { onContinueWinner(promoted) }
                            }
                        }
                    } label: {
                        TahoeIcon("arrowR", size: 13).foregroundStyle(continuing ? t.fg4 : t.fg3)
                    }
                    .buttonStyle(.plain)
                    .disabled(continuing)
                    .help("Continue from this answer")
                }
                .padding(12)
                TahoeHair()
                if let snapshot = frontierChild?.snapshot {
                    TranscriptScroll(items: snapshot.items, updateCounter: snapshot.updateCounter)
                } else if let runtime, let store = runtime.agentControlServer.chatStore(for: session) {
                    TranscriptScroll(items: store.snapshot.items, updateCounter: store.snapshot.updateCounter)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

@available(macOS 14, *)
private struct TranscriptScroll: View {
    let items: [ChatItem]
    let updateCounter: UInt64
    @State private var pinned = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        MessageRow(item: item).id(item.id)
                    }
                    Color.clear.frame(height: 12).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: updateCounter) { _, _ in
                guard pinned else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

@available(macOS 14, *)
private struct MessageRow: View {
    @Environment(\.tahoe) private var t
    let item: ChatItem

    var body: some View {
        switch item {
        case .message(let message):
            switch message.kind {
            case .userText:
                HStack {
                    Spacer(minLength: 40)
                    Text(message.body)
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(t.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
                        .textSelection(.enabled)
                }
            case .assistantText:
                VStack(alignment: .leading, spacing: 7) {
                    if !message.title.isEmpty {
                        Text(message.title.uppercased())
                            .font(TahoeFont.body(9.5, weight: .bold))
                            .foregroundStyle(t.fg4)
                    }
                    Text(message.body)
                        .font(TahoeFont.body(13))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.hairline, lineWidth: 0.5))
            case .toolCall, .toolResult:
                HStack(alignment: .top, spacing: 7) {
                    TahoeIcon("terminal", size: 10).foregroundStyle(t.fg3)
                    Text(message.body)
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(5)
                }
                .padding(9)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            case .meta:
                Text(message.body)
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg4)
            }
        case .toolRun(_, let pairs):
            Text(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg3)
        }
    }
}

@available(macOS 14, *)
private struct ComposerBar: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var store: ChatV2Store
    @ObservedObject var sendCtl: ComposerSendController
    @Binding var openTarget: ChatOpenTarget?
    @ObservedObject var client: AgentControlClient
    let providerMatrix: ChatProvidersResponse?
    @FocusState private var focused: Bool

    var body: some View {
        TahoeGlass(radius: 20, tone: .raised) {
            VStack(alignment: .leading, spacing: 8) {
                if !store.attachments.isEmpty {
                    attachmentStrip
                }
                TextField(placeholder, text: $sendCtl.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(TahoeFont.body(13.5))
                    .foregroundStyle(t.fg)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .onSubmit { Task { await dispatchSend() } }

                if let err = sendCtl.lastError {
                    Text(err)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                }

                HStack(spacing: 7) {
                    if openTarget == nil {
                        providerControls
                        deepResearchChip
                    } else {
                        lockedModeChip
                    }
                    attachmentButton
                    Spacer()
                    Text(estimatedCost)
                        .font(TahoeFont.body(10.5))
                        .foregroundStyle(t.fg4)
                    sendButton
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var providerControls: some View {
        if store.mode == .broadcast {
            ForEach(ChatV2Store.defaultBroadcastProviderOrder, id: \.self) { provider in
                Button { store.toggleBroadcastProvider(provider) } label: {
                    HStack(spacing: 5) {
                        TahoeProviderGlyph(provider: provider.tahoeProvider, size: 14)
                        Text(provider.tahoeProvider.displayName)
                            .font(TahoeFont.body(11, weight: .semibold))
                    }
                    .foregroundStyle(isProviderAvailable(provider) && store.broadcastProviders.contains(provider) ? t.fg : t.fg4)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(isProviderAvailable(provider) && store.broadcastProviders.contains(provider) ? Color.white.opacity(0.10) : Color.white.opacity(0.045), in: Capsule())
                    .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(!isProviderAvailable(provider))
                .help(providerUnavailableReason(provider) ?? provider.tahoeProvider.displayName)
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
                HStack(spacing: 5) {
                    TahoeProviderGlyph(provider: store.selectedProvider.tahoeProvider, size: 14)
                    Text(store.selectedProvider.tahoeProvider.displayName)
                        .font(TahoeFont.body(11, weight: .semibold))
                    TahoeIcon("chevD", size: 8)
                }
                .foregroundStyle(t.fg)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
        }
    }

    private var deepResearchChip: some View {
        Button {
            store.deepResearch.toggle()
            store.persist()
        } label: {
            HStack(spacing: 5) {
                TahoeIcon("search", size: 11)
                Text("Deep Research")
                    .font(TahoeFont.body(11, weight: .semibold))
            }
            .foregroundStyle(store.deepResearch ? t.accent : t.fg3)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(store.deepResearch ? t.accent.opacity(0.15) : Color.white.opacity(0.045), in: Capsule())
            .overlay(Capsule().stroke(store.deepResearch ? t.accent.opacity(0.4) : t.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var lockedModeChip: some View {
        HStack(spacing: 5) {
            TahoeIcon(openTarget?.isReadOnlyTranscript == true ? "doc" : (openTarget?.isFrontier == true ? "branch" : "chat"), size: 11)
            Text(openTarget?.isReadOnlyTranscript == true ? "Read-only transcript" : (openTarget?.isFrontier == true ? "Broadcast thread" : "Solo thread"))
                .font(TahoeFont.body(11, weight: .semibold))
        }
        .foregroundStyle(t.fg3)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.045), in: Capsule())
        .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
    }

    private var attachmentButton: some View {
        Button(action: pickAttachments) {
            TahoeIcon("paperclip", size: 12)
                .foregroundStyle(t.fg3)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.045), in: Capsule())
                .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var attachmentStrip: some View {
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
                .background(Color.white.opacity(0.05), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var sendButton: some View {
        Button { Task { await dispatchSend() } } label: {
            ZStack {
                Circle().fill(sendCtl.canSend ? t.accent : Color.white.opacity(0.08))
                if sendCtl.sending {
                    ProgressView().controlSize(.mini)
                } else {
                    TahoeIcon("arrowU", size: 14).foregroundStyle(sendCtl.canSend ? .white : t.fg4)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .disabled(!sendCtl.canSend || sendCtl.sending || openTarget?.isReadOnlyTranscript == true)
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private var placeholder: String {
        if openTarget?.isReadOnlyTranscript == true { return "Archived transcript is read-only" }
        if openTarget?.isFrontier == true { return "Follow up with all agents…" }
        if openTarget != nil { return "Reply to this chat…" }
        if store.mode == .broadcast { return "Ask Claude, Codex, and Antigravity…" }
        return "Ask \(store.selectedProvider.tahoeProvider.displayName)…"
    }

    private var estimatedCost: String {
        if openTarget?.isReadOnlyTranscript == true { return "read-only" }
        return store.mode == .broadcast || openTarget?.isFrontier == true ? "est. 3x tokens" : "est. 1x tokens"
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
                let perChild = await uploadAndBuildPerChildPrompts(base: trimmed, sessionIds: children.map(\.id))
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
                    // degradation — surface the per-slot failure
                    // reasons so the user can fix the underlying
                    // provider problem (Antigravity not running, Codex
                    // missing creds, etc.).
                    guard created.hasMinimumBroadcast else {
                        let reasons = created.failedSlots.compactMap(\.reason)
                        let detail = reasons.isEmpty ? "" : "\n" + reasons.joined(separator: "\n")
                        return "Broadcast needs at least two providers; only \(created.successfulSlots.count) spawned.\(detail)"
                    }
                    openTarget = .frontier(created.groupId)
                    let sessionIds = created.successfulSlots.compactMap(\.sessionId)
                    let perChild = await uploadAndBuildPerChildPrompts(base: trimmed, sessionIds: sessionIds)
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
        return entries.contains { $0.available }
    }

    private func providerUnavailableReason(_ provider: AgentKind) -> String? {
        guard !isProviderAvailable(provider) else { return nil }
        return providerMatrix?.providers.first { $0.provider == provider && !$0.available }?.reason
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
            guard let url = attachment.localFileURL,
                  let data = try? Data(contentsOf: url),
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
    /// Returns nil if there are no attachments to upload — caller
    /// falls back to the shared `text` in `sendFrontierPrompt`.
    private func uploadAndBuildPerChildPrompts(
        base: String,
        sessionIds: [UUID]
    ) async -> [UUID: String]? {
        guard !store.attachments.isEmpty, !sessionIds.isEmpty else { return nil }
        // Pre-read the bytes from disk once per attachment so a
        // multi-child upload doesn't re-open the same local URL N×.
        struct Stagable { let url: URL; let data: Data; let ext: String }
        var stagables: [Stagable] = []
        for attachment in store.attachments {
            // pathOnDaemon entries are session-scoped (the daemon staged
            // them under a specific session). They are NOT valid for
            // other Frontier children, so we still need the local bytes
            // to re-upload per child. If the local URL is gone, skip.
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

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach to chat"
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            store.addAttachment(ChatV2Attachment(
                displayName: url.lastPathComponent,
                pathOnDaemon: url.path,
                localFileURL: url
            ))
        }
    }
}

@available(macOS 14, *)
private struct ChatEmptyState: View {
    @Environment(\.tahoe) private var t
    let title: String
    let subtitle: String

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            VStack(spacing: 8) {
                Text(title)
                    .font(TahoeFont.body(16, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text(subtitle)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }
}
