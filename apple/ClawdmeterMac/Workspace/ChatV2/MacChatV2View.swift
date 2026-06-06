import SwiftUI
import AppKit
import Combine
import ClawdmeterShared

/// Per-conversation title derived from the first user message (like other chat
/// apps), persisted in UserDefaults keyed by the solo session id or broadcast
/// group id. Falls back to the generic label when unset. File-scope so both the
/// sidebar row builder and the composer send path can reach it.
fileprivate enum ChatTitleStore {
    private static func key(_ id: UUID) -> String { "clawdmeter.chat.title.\(id.uuidString)" }
    static func set(_ id: UUID, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        UserDefaults.standard.set(t, forKey: key(id))
    }
    static func get(_ id: UUID) -> String? {
        let t = UserDefaults.standard.string(forKey: key(id))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }
    /// First ~5 words of the prompt, single-lined, with an ellipsis if longer.
    static func firstWords(_ s: String, _ n: Int = 5) -> String {
        let words = s.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return "" }
        let head = words.prefix(n).joined(separator: " ")
        return words.count > n ? head + "…" : head
    }
}

/// A broadcast that's been requested but whose child sessions haven't spawned
/// yet. Rendered as skeleton columns the instant the user hits send, so the
/// comparison surface appears within ~200ms instead of after the multi-second
/// spawn. A column flips to an error banner if its provider fails to start.
fileprivate struct PendingBroadcast {
    let prompt: String
    var columns: [Column]
    struct Column: Identifiable {
        let id = UUID()
        let provider: AgentKind
        let model: String?
        var error: String? = nil   // nil = still provisioning
    }
}

/// A broadcast slot that failed to spawn — rendered as an error column next to
/// the live ones so each provider's failure stays visible in its own lane.
fileprivate struct FailedBroadcastColumn: Identifiable {
    let id = UUID()
    let provider: AgentKind
    let model: String?
    let reason: String
}

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
    @StateObject private var usageSource: ChatCursorUsageSource
    @State private var openTarget: ChatOpenTarget?
    @State private var providerMatrix: ChatProvidersResponse?
    /// Optimistic broadcast skeleton shown during the spawn gap (openTarget nil).
    @State private var pendingBroadcast: PendingBroadcast?
    /// Providers that failed to spawn — shown as error columns in the live group.
    @State private var failedBroadcastColumns: [FailedBroadcastColumn] = []

    init(client: AgentControlClient, runtime: AppRuntime?) {
        self.client = client
        self.runtime = runtime
        _sendCtl = StateObject(wrappedValue: ComposerSendController(client: client))
        _usageSource = StateObject(wrappedValue: ChatCursorUsageSource(cursorModel: runtime?.cursorModel))
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
                    pendingBroadcast = nil
                    failedBroadcastColumns = []
                }
            )
            .frame(width: 252)

            VStack(spacing: 10) {
                Header(store: store, openTarget: openTarget, children: frontierChildren)
                if openTarget == nil, let pending = pendingBroadcast {
                    PendingBroadcastView(pending: pending)
                } else if let openTarget {
                    switch openTarget {
                    case .solo(let id):
                        if let session = client.chatSessions.first(where: { $0.id == id }) {
                            // .solo(A)→.solo(B) stays in the same switch slot, so
                            // TranscriptScroll's @State (projectionCache keyed only on
                            // updateCounter, plus pinned + expandedTurns) survives the
                            // swap and leaks A's transcript/scroll state into B. Key on
                            // session.id to force a clean remount — mirrors the sibling
                            // BroadcastTranscript's .id(groupId) below.
                            SoloTranscript(session: session, runtime: runtime)
                                .id(session.id)
                        } else {
                            ChatEmptyState(title: "Conversation not loaded", subtitle: "Refresh chat history and try again.")
                        }
                    case .frontier(let groupId):
                        BroadcastTranscript(
                            groupId: groupId,
                            children: frontierChildren,
                            failedColumns: failedBroadcastColumns,
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
                    providerMatrix: providerMatrix,
                    cursorQuota: usageSource.cursorQuota,
                    pendingBroadcast: $pendingBroadcast,
                    failedBroadcastColumns: $failedBroadcastColumns
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        // A2 (v0.30.x): TahoeWallpaperView is already painted by MacRootView
        // (the parent). Painting it again here is a doubled SwiftUI Canvas
        // draw (radial-gradient orbs + base gradients) on every resize / tab
        // switch. Drop the local instance; the root wallpaper bleeds through.
        .task {
            await refreshProviderSurface()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderEnablement.changedNotification)) { _ in
            Task { await refreshProviderSurface() }
        }
        .onChange(of: client.providerDefaults) { _, defaults in
            store.applyProviderDefaults(defaults, catalog: client.modelCatalog)
        }
        .onReceive(client.$modelCatalog) { catalog in
            store.applyProviderDefaults(client.providerDefaults, catalog: catalog)
        }
    }

    private func refreshProviderSurface() async {
        await client.refreshSessions()
        await client.refreshModelCatalog()
        await client.refreshProviderDefaults()
        store.applyProviderDefaults(client.providerDefaults, catalog: client.modelCatalog)
        providerMatrix = await client.refreshChatProviders()
    }

    private var frontierChildren: [AgentSession] {
        guard case .frontier(let groupId) = openTarget else { return [] }
        return client.frontierChildren(groupId: groupId)
    }

}

@MainActor
private final class ChatCursorUsageSource: ObservableObject {
    @Published var cursorQuota: UsageData.CursorQuota?
    private var cancellables: Set<AnyCancellable> = []

    init(cursorModel: AppModel?) {
        self.cursorQuota = cursorModel?.usage?.cursorQuota
        cursorModel?.objectWillChange
            .sink { [weak self, weak cursorModel] _ in
                Task { @MainActor in
                    self?.cursorQuota = cursorModel?.usage?.cursorQuota
                }
            }
            .store(in: &cancellables)
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

    // A4 memoization (Phase 2). groupRows used to re-sort + re-group the
    // full session list on every Sidebar body invalidation. Now held in
    // a MemoizedDerivedStore keyed on `[AgentSession]` (Hashable struct
    // array; cheap Equatable). Cache hit when SidebarRow projection is
    // unchanged ⇒ no re-sort + no re-group.
    @StateObject private var groupRowsStore = MemoizedDerivedStore<[AgentSession], [SidebarRow]>(
        placeholder: [],
        mode: .sync,
        compute: { Sidebar.computeGroupRows($0) }
    )

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(spacing: 0) {
                HStack {
                    Text("Chat")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Spacer()
                    Button(action: onNew) {
                        TahoeIcon("plus", size: 13).foregroundStyle(t.fg2)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("New chat")
                }
                .padding(12)

                TahoeGlass(radius: 6, tone: .chip) {
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
                                HistoryRow(
                                    row: row,
                                    selected: openTarget == row.target,
                                    action: { openTarget = row.target },
                                    onArchive: { archive(row) }
                                )
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
                                .buttonStyle(PressableButtonStyle())
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        // A4: drive the groupRows memoized store from sessions changes.
        // task(id:) compares the [AgentSession] Equatable; identical
        // session lists ⇒ no compute. Identity changes ⇒ recompute.
        .task(id: sessions) {
            groupRowsStore.update(input: sessions)
        }
    }

    private var groupRows: [SidebarRow] {
        // A4: read from the memoized derived store. Inline-compute
        // fallback when `output == nil`: the store's `.task(id:)` driver
        // fires AFTER body returns, so reading the placeholder `[]` would
        // otherwise render an empty sidebar for one runloop tick on first
        // open even when sessions exist. Falling back to the static
        // compute keeps first-render semantics identical to pre-A4 (one
        // compute on first body); subsequent body invocations cache-hit
        // through the store.
        groupRowsStore.output ?? Sidebar.computeGroupRows(sessions)
    }

    /// Pure projection. Sortable + group-aware. Exposed `fileprivate
    /// static` so the MemoizedDerivedStore's compute closure can call it
    /// without capturing `self.sessions` (closure capture would stale).
    /// Archive the chat behind a sidebar row. Solo → archive the session;
    /// broadcast → archive every live child of the group. Refreshes after, and
    /// clears the open target if the archived chat was being viewed.
    private func archive(_ row: SidebarRow) {
        let wasOpen = (openTarget == row.target)
        Task {
            switch row.target {
            case .solo(let id):
                await client.archiveSession(id: id)
            case .frontier(let groupId):
                for child in sessions.filter({ $0.frontierGroupId == groupId }) {
                    await client.archiveSession(id: child.id)
                }
            case .transcript:
                break
            }
            await client.refreshSessions()
            if wasOpen { await MainActor.run { openTarget = nil } }
        }
    }

    nonisolated fileprivate static func computeGroupRows(_ sessions: [AgentSession]) -> [SidebarRow] {
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
                    title: ChatTitleStore.get(groupId) ?? "Broadcast comparison",
                    subtitle: children.map { $0.agent.brandedChatName }.joined(separator: " / "),
                    providers: children.map(\.agent),
                    lastEventAt: children.map(\.lastEventAt).max() ?? session.lastEventAt
                ))
            } else {
                rows.append(SidebarRow(
                    id: session.id,
                    target: .solo(session.id),
                    title: ChatTitleStore.get(session.id) ?? session.displayLabel,
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

    // Perf: one shared formatter instead of allocating a fresh
    // RelativeDateTimeFormatter per sidebar row / search row on every render.
    // fileprivate so HistoryRow (separate struct, same file) reuses it too.
    fileprivate static let relativeFormatter = RelativeDateTimeFormatter()

    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
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
    var onArchive: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    ForEach(Array(row.providers.prefix(3).enumerated()), id: \.offset) { _, provider in
                        TahoeProviderGlyph(provider: provider.tahoeProvider, size: 16)
                    }
                    Spacer()
                    Text(Sidebar.relativeFormatter.localizedString(for: row.lastEventAt, relativeTo: Date()))
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
            .background(selected ? Color.white.opacity(0.11) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? t.accent.opacity(0.45) : t.hairline, lineWidth: 0.6))
        }
        .buttonStyle(PressableButtonStyle())
        .overlay(alignment: .trailing) {
            if hovering, let onArchive {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(t.fg)
                        .padding(6)
                        .background(Circle().fill(t.fg.opacity(0.16)))
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.trailing, 10)
                .help("Archive chat")
            }
        }
        .onHover { hovering = $0 }
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
            if openTarget?.isFrontier == true {
                ForEach(children, id: \.id) { child in
                    ProviderSummary(session: child)
                }
            } else {
                ForEach(store.selectedVendors, id: \.self) { vendor in
                    ProviderDraftSummary(vendor: vendor, store: store)
                }
            }
        }
    }
}

@available(macOS 14, *)
private struct ProviderDraftSummary: View {
    @Environment(\.tahoe) private var t
    let vendor: ChatVendor
    @ObservedObject var store: ChatV2Store

    var body: some View {
        TahoeGlass(radius: 6, tone: .panel) {
            HStack(spacing: 9) {
                TahoeProviderGlyph(provider: vendor.backingProvider.tahoeProvider, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vendor.displayName)
                        .font(TahoeFont.body(12.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(store.model(for: vendor) ?? "default")
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                }
                Spacer()
                Text(store.deepResearch ? "research" : "ready")
                    .font(TahoeFont.body(10, weight: .semibold))
                    .foregroundStyle(store.deepResearch ? vendor.backingProvider.tahoeProvider.dot : t.fg4)
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
        TahoeGlass(radius: 6, tone: .panel) {
            HStack(spacing: 9) {
                TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.agent.brandedChatName)
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
                    .foregroundStyle(session.deepResearch ? session.agent.tahoeProvider.dot : t.fg4)
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
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ForEach(store.selectedVendors, id: \.self) { vendor in
                        TahoeProviderGlyph(provider: vendor.backingProvider.tahoeProvider, size: 30)
                    }
                }
                Text(store.selectedVendorCount == 1 ? "Ask \(store.primaryVendor.displayName)" : "Broadcast to all selected agents")
                    .font(TahoeFont.body(18, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text(store.selectedVendorCount == 1 ? "One selected vendor answers this thread." : "Send one prompt and compare live replies side by side.")
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
        TahoeGlass(radius: 8, tone: .panel) {
            if let runtime, let store = runtime.agentControlServer.chatStore(for: session) {
                TranscriptScroll(
                    items: store.snapshot.items,
                    updateCounter: store.snapshot.updateCounter,
                    pathRoot: Self.transcriptPathRoot(for: session),
                    turnState: store.snapshot.currentTurnState
                )
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private static func transcriptPathRoot(for session: AgentSession) -> URL? {
        for raw in [session.runtimeCwd, session.worktreePath, session.repoKey] {
            guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            if path.hasPrefix("/") || path.hasPrefix("~") {
                return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            }
        }
        return nil
    }
}

@available(macOS 14, *)
private struct ReadOnlyTranscript: View {
    let path: String
    @ObservedObject var client: AgentControlClient
    @State private var envelope: TranscriptEnvelope?
    @State private var failed = false
    @State private var isLoadingOlder = false

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            if let envelope {
                TranscriptScroll(
                    items: envelope.messages.map(ChatItem.message),
                    updateCounter: UInt64(envelope.messages.count),
                    pathRoot: nil,
                    hasOlderHistory: envelope.truncated,
                    isLoadingOlder: isLoadingOlder,
                    onLoadOlder: loadOlder
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

@available(macOS 14, *)
private struct BroadcastTranscript: View {
    @Environment(\.tahoe) private var t
    let groupId: UUID
    let children: [AgentSession]
    let failedColumns: [FailedBroadcastColumn]
    weak var runtime: AppRuntime?
    @ObservedObject var client: AgentControlClient
    let onContinueWinner: (AgentSession) -> Void
    @StateObject private var frontierStore: FrontierSnapshotStore

    init(
        groupId: UUID,
        children: [AgentSession],
        failedColumns: [FailedBroadcastColumn] = [],
        runtime: AppRuntime?,
        client: AgentControlClient,
        onContinueWinner: @escaping (AgentSession) -> Void
    ) {
        self.groupId = groupId
        self.children = children
        self.failedColumns = failedColumns
        self.runtime = runtime
        self.client = client
        self.onContinueWinner = onContinueWinner
        _frontierStore = StateObject(wrappedValue: FrontierSnapshotStore(groupId: groupId, client: client))
    }

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            if children.isEmpty && failedColumns.isEmpty {
                ChatEmptyState(title: "Broadcast group is empty", subtitle: "No live child sessions are attached to this comparison.")
            } else {
                // Divide + FILL the full width so two providers don't leave half
                // the page empty; fall back to a horizontal scroll when columns
                // would get too narrow to read (now uncapped — N providers).
                GeometryReader { geo in
                    let count = max(children.count + failedColumns.count, 1)
                    let spacing: CGFloat = 10
                    let pad: CGFloat = 12
                    let avail = geo.size.width - pad * 2 - spacing * CGFloat(count - 1)
                    let per = avail / CGFloat(count)
                    if per >= 300 {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(children, id: \.id) { child in
                                columnView(child).frame(maxWidth: .infinity)
                            }
                            ForEach(failedColumns) { col in
                                BroadcastStatusColumn(provider: col.provider, model: col.model, state: .error(col.reason))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(pad)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: spacing) {
                                ForEach(children, id: \.id) { child in
                                    columnView(child).frame(width: max(300, per))
                                }
                                ForEach(failedColumns) { col in
                                    BroadcastStatusColumn(provider: col.provider, model: col.model, state: .error(col.reason))
                                        .frame(width: max(300, per))
                                }
                            }
                            .padding(pad)
                        }
                    }
                }
            }
        }
        .onAppear { frontierStore.start() }
        .onDisappear { frontierStore.stop() }
    }

    @ViewBuilder
    private func columnView(_ child: AgentSession) -> some View {
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
        TahoeGlass(radius: 6, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                // Provider identity = a 3px column-top edge (DESIGN.md broadcast),
                // never a colored panel.
                ProviderEdge(session.agent.tahoeProvider, axis: .horizontal, thickness: 3)
                HStack(spacing: 8) {
                    ProviderDot(session.agent.tahoeProvider, size: 6)
                    TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.agent.brandedChatName)
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
                        TahoeIcon("bookmark", size: 13).foregroundStyle(winner == nil ? t.fg3 : session.agent.tahoeProvider.dot)
                    }
                    .buttonStyle(PressableButtonStyle())
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
                    .buttonStyle(PressableButtonStyle())
                    .disabled(continuing)
                    .help("Continue from this answer")
                }
                .padding(12)
                TahoeHair()
                if let snapshot = frontierChild?.snapshot {
                    TranscriptScroll(
                        items: snapshot.items,
                        updateCounter: snapshot.updateCounter,
                        pathRoot: Self.transcriptPathRoot(for: session),
                        turnState: frontierChild?.currentTurnState ?? .idle
                    )
                } else if let runtime, let store = runtime.agentControlServer.chatStore(for: session) {
                    TranscriptScroll(
                        items: store.snapshot.items,
                        updateCounter: store.snapshot.updateCounter,
                        pathRoot: Self.transcriptPathRoot(for: session),
                        turnState: store.snapshot.currentTurnState
                    )
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private static func transcriptPathRoot(for session: AgentSession) -> URL? {
        for raw in [session.runtimeCwd, session.worktreePath, session.repoKey] {
            guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            if path.hasPrefix("/") || path.hasPrefix("~") {
                return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            }
        }
        return nil
    }
}

/// A single broadcast column in a non-live state: either provisioning (a spawn
/// is in flight → skeleton spinner) or failed (the provider couldn't start →
/// error banner). Reused by the optimistic pending overlay and by the live
/// group's per-provider error lanes.
@available(macOS 14, *)
private struct BroadcastStatusColumn: View {
    @Environment(\.tahoe) private var t
    let provider: AgentKind
    let model: String?
    var prompt: String? = nil
    enum ColState { case loading, error(String) }
    let state: ColState

    private let errColor = Color(red: 0.90, green: 0.42, blue: 0.36)

    var body: some View {
        TahoeGlass(radius: 6, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    TahoeProviderGlyph(provider: provider.tahoeProvider, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.brandedChatName)
                            .font(TahoeFont.body(12, weight: .semibold))
                            .foregroundStyle(t.fg)
                        Text(model ?? "default")
                            .font(TahoeFont.mono(10))
                            .foregroundStyle(t.fg4)
                    }
                    Spacer()
                }
                .padding(12)
                TahoeHair()
                VStack(alignment: .leading, spacing: 10) {
                    if let prompt, !prompt.isEmpty {
                        Text(prompt)
                            .font(TahoeFont.body(12.5))
                            .foregroundStyle(t.fg2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(t.fg.opacity(0.06)))
                    }
                    switch state {
                    case .loading:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting…").font(TahoeFont.body(11)).foregroundStyle(t.fg4)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                    case .error(let reason):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11)).foregroundStyle(errColor)
                                Text("Couldn't start").font(TahoeFont.body(11, weight: .semibold)).foregroundStyle(errColor)
                            }
                            Text(reason)
                                .font(TahoeFont.body(11)).foregroundStyle(t.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(errColor.opacity(0.08)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Optimistic broadcast surface shown the instant the user hits send, before the
/// child sessions finish spawning — one skeleton (or error) column per selected
/// provider, mirroring BroadcastTranscript's fill/scroll layout.
@available(macOS 14, *)
private struct PendingBroadcastView: View {
    @Environment(\.tahoe) private var t
    let pending: PendingBroadcast

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            GeometryReader { geo in
                let count = max(pending.columns.count, 1)
                let spacing: CGFloat = 10
                let pad: CGFloat = 12
                let per = (geo.size.width - pad * 2 - spacing * CGFloat(count - 1)) / CGFloat(count)
                if per >= 300 {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(pending.columns) { col in
                            BroadcastStatusColumn(
                                provider: col.provider, model: col.model, prompt: pending.prompt,
                                state: col.error.map { BroadcastStatusColumn.ColState.error($0) } ?? .loading
                            ).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(pad)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(pending.columns) { col in
                                BroadcastStatusColumn(
                                    provider: col.provider, model: col.model, prompt: pending.prompt,
                                    state: col.error.map { BroadcastStatusColumn.ColState.error($0) } ?? .loading
                                ).frame(width: max(300, per))
                            }
                        }
                        .padding(pad)
                    }
                }
            }
        }
    }
}

@available(macOS 14, *)
private struct TranscriptScroll: View {
    let items: [ChatItem]
    let updateCounter: UInt64
    var pathRoot: URL? = nil
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
    private static let bottomSentinelId = "chat-v2-bottom-sentinel"
    private static let thinkingRowId = "chat-v2-thinking"

    /// Show the thinking dots only while a turn is streaming AND no assistant
    /// *text* has appeared yet — the growing text is its own feedback, so the
    /// indicator covers the send→first-token gap (and tool work before any
    /// answer text). Find the most-recent item: assistant text → hide; anything
    /// else (the user's prompt, a tool run) → still waiting.
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
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.up.circle")
                                }
                                Text(isLoadingOlder ? "Loading earlier…" : "Load earlier messages")
                            }
                            .font(TahoeFont.body(11, weight: .semibold))
                        }
                        .buttonStyle(PressableButtonStyle())
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
                    Color.clear.frame(height: 12).id(Self.bottomSentinelId)
                }
                .padding(14)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                return visibleBottom >= geometry.contentSize.height - 36
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
                // When a send flips the turn to streaming the thinking row
                // appears with no updateCounter bump — scroll so it's visible.
                guard pinned else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                }
            }
        }
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
            .buttonStyle(PressableButtonStyle())
        } else {
            disclosureLabel(turn, icon: "clock")
        }
    }

    private func disclosureLabel(_ turn: TranscriptTurn, icon: String) -> some View {
        Label(turn.summary.disclosureLabel, systemImage: icon)
            .font(TahoeFont.body(10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.045), in: Capsule())
    }

    @ViewBuilder
    private func compactChipStrip(_ turn: TranscriptTurn) -> some View {
        if !turn.outputArtifacts.isEmpty || !turn.editedFiles.isEmpty {
            HStack(spacing: 7) {
                ForEach(turn.outputArtifacts.prefix(4)) { artifact in
                    Button {
                        openArtifact(artifact)
                    } label: {
                        compactChip(icon: iconName(for: artifact.kind), title: artifact.filename)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                ForEach(turn.editedFiles.prefix(4)) { file in
                    compactChip(icon: "pencil.and.scribble", title: file.basename)
                }
            }
            .padding(.leading, 38)
        }
    }

    private func compactChip(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(TahoeFont.body(10.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.045), in: Capsule())
    }

    private func openArtifact(_ artifact: TranscriptOutputArtifact) {
        guard let url = resolvedArtifactURL(artifact.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func resolvedArtifactURL(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return pathRoot?.appendingPathComponent(trimmed)
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
@available(macOS 14, *)
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
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.hairline, lineWidth: 0.5))
        .onAppear { animating = true }
        .accessibilityLabel("Waiting for a response")
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
                    Text(ClawdmeterMac_displaySkillInvocations(in: message.body))
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(t.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
            case .assistantText:
                VStack(alignment: .leading, spacing: 7) {
                    if !message.title.isEmpty {
                        Text(message.title.uppercased())
                            .font(TahoeFont.body(9.5, weight: .bold))
                            .foregroundStyle(t.fg4)
                    }
                    // Assistant bodies are Markdown; plain Text rendered the raw
                    // source (## headings, **bold**, fenced code as literal text).
                    // Reuse the same renderer the Code tab uses for parity.
                    MarkdownRenderer(source: message.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.hairline, lineWidth: 0.5))
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
            VStack(alignment: .leading, spacing: 6) {
                Text(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg3)
                ForEach(pairs) { pair in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TahoeIcon("terminal", size: 10).foregroundStyle(t.fg3)
                            Text(pair.call.title)
                                .font(TahoeFont.mono(10.5, weight: .semibold))
                                .foregroundStyle(t.fg2)
                            Text(pair.call.body)
                                .font(TahoeFont.mono(10.5))
                                .foregroundStyle(t.fg3)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        if let result = pair.result, !result.body.isEmpty {
                            Text(result.body)
                                .font(TahoeFont.mono(10.5))
                                .foregroundStyle(result.isError ? .red : t.fg3)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .id("pair:\(pair.id)")
                }
            }
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
    let cursorQuota: UsageData.CursorQuota?
    @Binding var pendingBroadcast: PendingBroadcast?
    @Binding var failedBroadcastColumns: [FailedBroadcastColumn]
    @FocusState private var focused: Bool
    // v0.29.x — multi-provider selector (Option A): one compact bar that opens a
    // single popover (flat per-provider checklist + model/effort + Solo/Compare).
    @State private var providerPopoverPresented = false
    // v0.29.8 — backing store for the new ComposerModelPicker. Each
    // ProviderDefaultsStore instance reads/writes the same UserDefaults
    // keys, so writes from the picker persist and other instances pick
    // them up on their next `refresh()` / init. Live in-memory snapshots
    // on sibling stores will lag until they re-read. This is consistent
    // with how MacSettingsView, SessionLauncherModel, and AgentControlServer
    // already instantiate their own stores — the picker does not
    // introduce a new divergence pattern.
    @StateObject private var providerDefaultsStore = ProviderDefaultsStore()

    var body: some View {
        TahoeGlass(radius: 8, tone: .raised) {
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if !store.attachments.isEmpty {
                        attachmentStrip
                    }
                    TextField(placeholder, text: $sendCtl.text)
                        .textFieldStyle(.plain)
                        .font(TahoeFont.body(13.5))
                        .foregroundStyle(t.fg)
                        .frame(height: 28, alignment: .topLeading)
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 7) {
                    if openTarget == nil {
                        providerControls
                            .layoutPriority(1)
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
                .frame(minHeight: 34, alignment: .center)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(height: maxComposerHeight)
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: maxComposerHeight, alignment: .topLeading)
        .onAppear { focused = true }
    }

    private var maxComposerHeight: CGFloat {
        (store.attachments.isEmpty && sendCtl.lastError == nil) ? 102 : 168
    }

    // Multi-provider selector — Option A (compact bar + popover). One small
    // control in the composer opens a single popover: a flat per-provider
    // checklist, each row with its own model + effort, plus a Solo/Compare
    // toggle. Selecting 1 provider = solo; 2–3 = broadcast (compare).
    @ViewBuilder
    private var providerControls: some View {
        if providerEnabledVendors.isEmpty {
            Text("No providers enabled")
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg4)
                .padding(.horizontal, 9).padding(.vertical, 7).frame(height: 32)
                .background(Color.white.opacity(0.045), in: Capsule())
                .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
                .help("Enable a provider in Settings → Providers.")
        } else {
            Button { providerPopoverPresented = true } label: { providerBarLabel }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .popover(isPresented: $providerPopoverPresented, arrowEdge: .bottom) {
                    providerSelectorPopover
                }
                .help("Choose a provider, or pick 2–3 to compare side by side")
        }
    }

    /// Compact composer control: stacked glyphs of the selected providers + a
    /// label (solo → name·model; multi → "N providers"). Opens the selector.
    private var providerBarLabel: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(store.selectedVendors, id: \.self) { v in
                    TahoeProviderGlyph(provider: v.backingProvider.tahoeProvider, size: 16)
                }
            }
            if store.selectedVendorCount == 1 {
                let v = store.primaryVendor
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.displayName)
                        .font(TahoeFont.body(11.5, weight: .semibold))
                        .foregroundStyle(t.fg).lineLimit(1)
                    if let model = compactModelLabel(for: v) {
                        Text(model)
                            .font(TahoeFont.mono(8.5))
                            .foregroundStyle(t.fg4).lineLimit(1).truncationMode(.middle)
                    }
                }
            } else {
                Text("\(store.selectedVendorCount) providers")
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(t.fg4)
        }
        .padding(.horizontal, 10).padding(.vertical, 6).frame(height: 32)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
        .contentShape(Capsule())
    }

    /// Solo/Compare toggle + a flat per-provider checklist, each row with its own
    /// model + effort. 1 selected = solo; 2–3 = broadcast.
    private var providerSelectorPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ask or compare")
                    .font(TahoeFont.body(12.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer()
                soloCompareToggle
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            Rectangle().fill(t.hairline).frame(height: 0.5)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(providerPickerVendors, id: \.self) { vendor in
                        providerSelectorRow(vendor)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(maxHeight: 320)

            Rectangle().fill(t.hairline).frame(height: 0.5)
            Text(store.selectedVendorCount <= 1
                 ? "Solo · \(store.primaryVendor.displayName)"
                 : "Comparing \(store.selectedVendorCount) — answers shown side by side")
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg4)
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .frame(width: 384)
        .background(t.surfaceSolid)
    }

    private var soloCompareToggle: some View {
        HStack(spacing: 2) {
            soloCompareSegment(title: "Solo", active: store.selectedVendorCount <= 1) {
                store.selectedVendors = [store.primaryVendor]
                store.persist()
            }
            soloCompareSegment(title: "Compare", active: store.selectedVendorCount > 1) {
                if store.selectedVendorCount <= 1 { store.toggleVendor(firstConfigurableVendor) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func soloCompareSegment(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(active ? t.fg : t.fg4)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.white.opacity(0.12) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func providerSelectorRow(_ vendor: ChatVendor) -> some View {
        let selected = store.isVendorSelected(vendor)
        let enabled = ProviderEnablement.isEnabled(vendor)
        let available = isVendorAvailable(vendor)
        let canSelect = enabled && (selected || available)
        // A not-yet-enabled provider stays tappable so the row can opt it in
        // inline (toggleProviderRow enables + selects it); once enabled, normal
        // availability gating applies.
        let canInteract = canSelect || !enabled
        HStack(spacing: 10) {
            Button { toggleProviderRow(vendor) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? t.accent : t.fg4)
            }
            .buttonStyle(.plain)
            .disabled(!canInteract)

            TahoeProviderGlyph(provider: vendor.backingProvider.tahoeProvider, size: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(vendor.displayName)
                    .font(TahoeFont.body(12.5, weight: .semibold))
                    .foregroundStyle(enabled ? t.fg : t.fg4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let reason = providerUnavailableReason(vendor) {
                    Text(reason)
                        .font(TahoeFont.body(9.5))
                        .foregroundStyle(t.fg4).lineLimit(1).truncationMode(.tail)
                } else if vendor == .cursor, let cursorQuota {
                    Text(cursorQuotaSummary(cursorQuota))
                        .font(TahoeFont.mono(9.5))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            providerRowModelMenu(vendor)
            if modelSupportsEffort(vendor) { providerRowEffortMenu(vendor) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.white.opacity(0.06) : Color.clear))
        .opacity(canSelect ? 1 : 0.55)
        .contentShape(Rectangle())
    }

    private func toggleProviderRow(_ vendor: ChatVendor) {
        // Inline-enable: checking a not-yet-enabled provider (e.g. Antigravity/
        // Gemini or OpenRouter) opts it in right here instead of forcing a detour
        // to Settings → Providers, then selects it. The provider probe + model
        // catalog refresh off the changed-notification setEnabled posts; the
        // ChatV2Store selection change re-renders the row to its enabled state.
        if !ProviderEnablement.isEnabled(vendor) {
            // setEnabled posts ProviderEnablement.changedNotification, which
            // ChatRoot observes to re-run the probe + model-catalog refresh — so
            // the row un-greys and its model dropdown populates on the next render.
            ProviderEnablement.setEnabled(vendor.backingProvider.rawValue, true)
            if !store.isVendorSelected(vendor) { store.toggleVendor(vendor) }
            return
        }
        if !store.isVendorSelected(vendor), !isVendorAvailable(vendor) { return }
        store.toggleVendor(vendor)
    }

    private func providerRowModelMenu(_ vendor: ChatVendor) -> some View {
        let models = vendor.models(in: client.modelCatalog)
        let currentId = store.model(for: vendor, catalog: client.modelCatalog)
        return Menu {
            if models.isEmpty { Text("No models") }
            ForEach(models, id: \.id) { m in
                Button {
                    store.selectModel(m.id, for: vendor, catalog: client.modelCatalog)
                } label: {
                    if m.id == currentId { Label(m.displayName, systemImage: "checkmark") }
                    else { Text(m.displayName) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(t.fg4)
                Text(rowModelLabel(for: vendor))
                    .font(TahoeFont.body(11)).foregroundStyle(t.fg2)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(width: 116, alignment: .leading)
        }
        // Deterministic fixed width so the model dropdown never collapses (when
        // flexible) nor balloons (under .fixedSize with a long OpenRouter label).
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 116)
    }

    /// Model name for a row, stripping a redundant "<Provider> · " prefix
    /// (e.g. "OpenRouter · OpenAI: GPT-5.5" → "OpenAI: GPT-5.5") since the row
    /// already shows the provider name.
    private func rowModelLabel(for vendor: ChatVendor) -> String {
        let label = compactModelLabel(for: vendor) ?? "Model"
        let prefix = "\(vendor.displayName) · "
        return label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
    }

    private func cursorQuotaSummary(_ quota: UsageData.CursorQuota) -> String {
        var parts = ["Total \(quota.totalPct)%"]
        if let auto = quota.autoPct { parts.append("Auto \(auto)%") }
        if let api = quota.apiPct { parts.append("API \(api)%") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func providerRowEffortMenu(_ vendor: ChatVendor) -> some View {
        let current = store.effort(for: vendor, catalog: client.modelCatalog)
        Menu {
            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                Button {
                    store.selectEffort(effort, for: vendor, catalog: client.modelCatalog)
                } label: {
                    if current == effort { Label(effort.rawValue.capitalized, systemImage: "checkmark") }
                    else { Text(effort.rawValue.capitalized) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(t.fg4)
                Text(current?.rawValue.capitalized ?? "Auto")
                    .font(TahoeFont.body(11)).foregroundStyle(t.fg3)
                    .lineLimit(1)
            }
            .frame(width: 58, alignment: .leading)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 58)
        .help("Reasoning effort")
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
        .buttonStyle(PressableButtonStyle())
    }

    private var lockedModeChip: some View {
        HStack(spacing: 5) {
            TahoeIcon(openTarget?.isReadOnlyTranscript == true ? "doc" : (openTarget?.isFrontier == true ? "branch" : "chat"), size: 11)
            Text(openTarget?.isReadOnlyTranscript == true ? "Read-only transcript" : (openTarget?.isFrontier == true ? "Broadcast thread" : "Single-vendor thread"))
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
        .buttonStyle(PressableButtonStyle())
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
                    .buttonStyle(PressableButtonStyle())
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
        .buttonStyle(PressableButtonStyle())
        .disabled(!sendCtl.canSend || sendCtl.sending || openTarget?.isReadOnlyTranscript == true)
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private var placeholder: String {
        if openTarget?.isReadOnlyTranscript == true { return "Archived transcript is read-only" }
        if openTarget?.isFrontier == true { return "Follow up with all agents…" }
        if openTarget != nil { return "Reply to this chat…" }
        // DESIGN.md Composer: the idle placeholder copy is fixed. Provider
        // selection is conveyed by the provider chips, not the placeholder.
        return "Ask anything. Use / for skills, @ for files."
    }

    private var estimatedCost: String {
        if openTarget?.isReadOnlyTranscript == true { return "read-only" }
        if case .frontier(let groupId) = openTarget {
            return "est. \(max(2, client.frontierChildren(groupId: groupId).count))x tokens"
        }
        if openTarget != nil { return "est. 1x tokens" }
        return "est. \(store.selectedVendorCount)x tokens"
    }

    private func dispatchSend() async {
        await sendCtl.sendCustomOptimistic { trimmed in
            switch openTarget {
            case .solo(let sessionId):
                let prompt = await uploadAndBuildPrompt(base: trimmed, sessionId: sessionId)
                let ok = await client.sendPrompt(sessionId: sessionId, text: prompt, asFollowUp: true)
                if ok { store.clearAttachments() }
                return ok ? nil : (client.lastError ?? "Couldn't send prompt.")
            case .frontier(let groupId):
                let children = client.frontierChildren(groupId: groupId)
                guard children.count >= 2 else {
                    return "Broadcast compares two or more providers, but only one is still live here. Star its answer to keep it as a single chat, or start a new broadcast."
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
                    // Optimistic: paint skeleton columns immediately so the
                    // comparison surface appears within ~200ms instead of after
                    // the multi-second spawn. (openTarget stays nil until the
                    // group exists, so this renders via PendingBroadcastView.)
                    pendingBroadcast = PendingBroadcast(
                        prompt: trimmed,
                        columns: slots.map { PendingBroadcast.Column(provider: $0.provider, model: $0.model) }
                    )
                    failedBroadcastColumns = []
                    guard let created = await client.createBroadcastChat(slots: slots) else {
                        pendingBroadcast = nil
                        return client.lastError ?? "Couldn't create broadcast chat."
                    }
                    // Map each failed slot back to its provider (by request index)
                    // for a per-provider error banner instead of one blanket error.
                    let failedByProvider: [AgentKind: String] = Dictionary(
                        created.failedSlots.compactMap { r -> (AgentKind, String)? in
                            guard r.index >= 0, r.index < slots.count else { return nil }
                            return (slots[r.index].provider, r.reason ?? "Couldn't start this provider.")
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    // P1 fix (v0.23.9): broadcast needs ≥2 live providers. Rather
                    // than a blanket failure, keep the columns up with a per-
                    // provider status so the user sees exactly what broke.
                    guard created.hasMinimumBroadcast else {
                        pendingBroadcast = PendingBroadcast(
                            prompt: trimmed,
                            columns: slots.map { s in
                                PendingBroadcast.Column(
                                    provider: s.provider, model: s.model,
                                    error: failedByProvider[s.provider] ?? "Broadcast needs at least two providers to start."
                                )
                            }
                        )
                        return nil
                    }
                    failedBroadcastColumns = created.failedSlots.compactMap { r in
                        guard r.index >= 0, r.index < slots.count else { return nil }
                        let s = slots[r.index]
                        return FailedBroadcastColumn(provider: s.provider, model: s.model, reason: r.reason ?? "Couldn't start this provider.")
                    }
                    pendingBroadcast = nil
                    openTarget = .frontier(created.groupId)
                    ChatTitleStore.set(created.groupId, ChatTitleStore.firstWords(trimmed))
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
                    let vendor = selectedVendors.first ?? store.primaryVendor
                    // Optimistic single-column skeleton so the loading animation
                    // shows during the ~9-10s tmux spawn (Claude cold start) —
                    // not a blank center. Reuses the broadcast pending overlay.
                    pendingBroadcast = PendingBroadcast(
                        prompt: trimmed,
                        columns: [PendingBroadcast.Column(
                            provider: vendor.backingProvider,
                            model: store.model(for: vendor, catalog: client.modelCatalog)
                        )]
                    )
                    failedBroadcastColumns = []
                    guard let session = await client.createChatSession(
                        provider: vendor.backingProvider,
                        model: store.model(for: vendor, catalog: client.modelCatalog),
                        codexBackend: vendor == .chatgpt ? store.codexBackendPreference : nil,
                        effort: store.effort(for: vendor, catalog: client.modelCatalog),
                        chatVendor: vendor,
                        billingProvider: vendor.billingProvider,
                        deepResearch: store.deepResearch
                    ) else {
                        pendingBroadcast = nil
                        return client.lastError ?? "Couldn't create chat."
                    }
                    pendingBroadcast = nil
                    openTarget = .solo(session.id)
                    ChatTitleStore.set(session.id, ChatTitleStore.firstWords(trimmed))
                    let prompt = await uploadAndBuildPrompt(base: trimmed, sessionId: session.id)
                    let ok = await client.sendPrompt(sessionId: session.id, text: prompt, asFollowUp: false)
                    if ok { store.clearAttachments() }
                    return ok ? nil : (client.lastError ?? "Couldn't send prompt.")
                }
            }
        }
    }

    private func isProviderAvailable(_ provider: AgentKind) -> Bool {
        guard ProviderEnablement.isEnabled(provider) else {
            return false
        }
        guard let entries = providerMatrix?.providers.filter({ $0.provider == provider }),
              !entries.isEmpty else {
            return true
        }
        return entries.contains { $0.capabilityProbePassed }
    }

    private func isVendorAvailable(_ vendor: ChatVendor) -> Bool {
        guard ProviderEnablement.isEnabled(vendor) else {
            return false
        }
        let provider = vendor.backingProvider
        guard let entries = providerMatrix?.providers.filter({ $0.provider == provider }),
              !entries.isEmpty else {
            return true
        }
        if vendor == .chatgpt {
            return entries.contains { $0.codexBackend == .sdk && $0.capabilityProbePassed }
        }
        return entries.contains { $0.capabilityProbePassed }
    }

    private func providerUnavailableReason(_ vendor: ChatVendor) -> String? {
        guard ProviderEnablement.isEnabled(vendor) else {
            return "Enable \(vendor.displayName) in Settings → Providers."
        }
        guard !isVendorAvailable(vendor) else { return nil }
        let provider = vendor.backingProvider
        if vendor == .chatgpt {
            return providerMatrix?.providers.first {
                $0.provider == provider && $0.codexBackend == .sdk && !$0.capabilityProbePassed
            }?.reason
        }
        return providerMatrix?.providers.first { $0.provider == provider && !$0.capabilityProbePassed }?.reason
    }

    private var providerEnabledVendors: [ChatVendor] {
        ProviderEnablement.enabledChatVendors()
    }

    private var providerPickerVendors: [ChatVendor] {
        // Show EVERY chat-capable vendor (incl. Antigravity/Gemini + OpenRouter) so
        // they're discoverable in chat even before they're enabled. Disabled rows
        // render greyed with an "Enable … in Settings → Providers" reason and a
        // tap enables them inline (see toggleProviderRow). Selected vendors are
        // always present even if reordered.
        var vendors = ChatV2Store.defaultChatVendorOrder
        for vendor in store.selectedVendors where !vendors.contains(vendor) {
            vendors.append(vendor)
        }
        return vendors
    }

    private func compactModelLabel(for vendor: ChatVendor) -> String? {
        guard let id = store.model(for: vendor, catalog: client.modelCatalog) else { return nil }
        if let entry = vendor.models(in: client.modelCatalog).first(where: { $0.id == id }) {
            return entry.displayName
        }
        return id
    }

    private func modelSupportsEffort(_ vendor: ChatVendor) -> Bool {
        guard let id = store.model(for: vendor, catalog: client.modelCatalog),
              let entry = vendor.models(in: client.modelCatalog).first(where: { $0.id == id }) else {
            return vendor.defaultEffort != nil
        }
        return entry.supportsEffort
    }

    private var firstConfigurableVendor: ChatVendor {
        providerEnabledVendors.first { vendor in
            !store.isVendorSelected(vendor) && isVendorAvailable(vendor)
        } ?? store.primaryVendor
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
        TahoeGlass(radius: 8, tone: .panel) {
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
