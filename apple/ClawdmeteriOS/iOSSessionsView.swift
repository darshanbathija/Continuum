import SwiftUI
import ClawdmeterShared

/// Third TabView tab on iOS. Mobile defaults to structured-card view per
/// D1; user can toggle to the terminal pane via the segmented control.
struct iOSSessionsView: View {
    @ObservedObject var client: AgentControlClient
    @State private var showingPairing: Bool = false
    @State private var showingNewSession: Bool = false
    @State private var searchQuery: String = ""
    @State private var showArchived: Bool = false
    /// Phase 5 sidebar grouping. `byRepo` (default) keeps the v2.0
    /// repo-section UX; `byStatus` swaps in Conductor-style Backlog /
    /// In Progress / Review / Done buckets across all repos.
    @State private var grouping: SidebarGrouping = .byRepo
    /// Repos the user has manually toggled. Wins over the default
    /// "expanded if live/active, collapsed otherwise" heuristic — once
    /// the user makes a choice for a repo, it sticks for the session.
    @State private var manuallyExpanded: Set<String> = []
    @State private var manuallyCollapsed: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if !client.isConfigured {
                    pairingPrompt
                } else if client.repos.isEmpty {
                    emptyState
                } else {
                    repoList
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingNewSession = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(!client.isConfigured || client.repos.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Refresh") {
                            Task { await client.refreshAll() }
                        }
                        Toggle("Show archived", isOn: $showArchived)
                        Divider()
                        Button("Pair to Mac…") {
                            showingPairing = true
                        }
                        if client.isConfigured {
                            Button("Unpair", role: .destructive) {
                                client.clearPairing()
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable {
                await client.refreshAll()
            }
            .sheet(isPresented: $showingPairing) {
                PairingFlow(client: client, isPresented: $showingPairing)
            }
            .sheet(isPresented: $showingNewSession) {
                NewSessionSheet(client: client, isPresented: $showingNewSession)
            }
            .task {
                await client.refreshAll()
            }
        }
    }

    // MARK: - States

    private var pairingPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 42))
                .foregroundStyle(terraCotta)
            Text("Pair to Mac")
                .font(.title2.bold())
            Text("Open Clawdmeter on your Mac and tap **Sync with iPhone** in the header — either scan the QR, or paste the copied URL.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            PairingCTAButtons(client: client)
                .padding(.horizontal, 28)
                .padding(.top, 4)
        }
        .padding(28)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isMacLikelyUnreachable {
            ContentUnavailableView {
                Label("Mac unreachable", systemImage: "wifi.exclamationmark")
            } description: {
                VStack(spacing: 6) {
                    Text("Couldn't reach the paired Mac at \(client.host ?? "—"). Open the Clawdmeter Mac app and confirm you're on the same Tailnet.")
                    if let host = client.host, host == "127.0.0.1" {
                        Text("Stored host is `127.0.0.1` — re-pair from the Mac so the iPhone gets a routable Tailscale address.")
                            .font(.caption)
                            .foregroundStyle(SessionsV2Theme.accent)
                    } else if let err = client.lastError, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            } actions: {
                VStack(spacing: 8) {
                    Button("Retry") {
                        Task { await client.refreshAll() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SessionsV2Theme.accent)
                    Button("Re-pair…") { showingPairing = true }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No sessions yet", systemImage: "tray")
            } description: {
                Text("Tap ＋ to start one. Repos appear after you run Claude or Codex in them on your Mac.")
            }
        }
    }

    /// Heuristic: if the client is configured but the last successful
    /// poll is more than 60 seconds old (or never happened), the daemon
    /// is probably unreachable. Surface as a distinct error state so
    /// "no sessions" doesn't disguise a connectivity bug.
    private var isMacLikelyUnreachable: Bool {
        guard client.isConfigured else { return false }
        guard let last = client.lastPolledAt else { return true }
        return Date().timeIntervalSince(last) > 60
    }

    private var repoList: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $grouping) {
                ForEach(SidebarGrouping.allCases) { g in
                    Text(g.label).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityLabel("Sidebar grouping")
            switch grouping {
            case .byRepo:
                List {
                    ForEach(filteredRepos, id: \.key) { repo in
                        repoSection(for: repo)
                    }
                }
            case .byStatus:
                statusGroupedList
            }
        }
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search sessions")
    }

    /// One collapsible section per repo. Tapping the header (or its
    /// chevron) toggles expand/collapse. Default state matches the Mac
    /// dashboard convention: a repo is expanded when it has a live or
    /// active session, otherwise collapsed — so the user's hot repos
    /// stay visible while stale ones don't push everything off-screen.
    @ViewBuilder
    private func repoSection(for repo: AgentRepo) -> some View {
        let isExpanded = Binding<Bool>(
            get: { isRepoExpanded(repo) },
            set: { newValue in
                if newValue {
                    manuallyExpanded.insert(repo.key)
                    manuallyCollapsed.remove(repo.key)
                } else {
                    manuallyCollapsed.insert(repo.key)
                    manuallyExpanded.remove(repo.key)
                }
            }
        )
        Section(isExpanded: isExpanded) {
            repoSectionRows(for: repo)
        } header: {
            repoSectionHeader(for: repo, isExpanded: isExpanded)
        }
    }

    @ViewBuilder
    private func repoSectionRows(for repo: AgentRepo) -> some View {
        let sessions = sessionsForRepo(repo)
        if sessions.isEmpty && repo.recentSessions.isEmpty {
            Text("No sessions yet — tap ＋ to start one")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(sessions) { session in
                NavigationLink {
                    SessionDetailView(session: session, client: client)
                } label: {
                    SessionRow(session: session)
                }
                // Phase 5 swipe-leading: positive-intent quick actions.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if session.planText != nil && session.status == .planning {
                        Button {
                            Task { await client.approvePlan(sessionId: session.id) }
                        } label: {
                            Label("Approve", systemImage: "checkmark.seal.fill")
                        }
                        .tint(SessionsV2Theme.accent)
                    }
                    if session.status == .running {
                        Button {
                            Task { await client.interruptSession(sessionId: session.id) }
                        } label: {
                            Label("Interrupt", systemImage: "stop.fill")
                        }
                        .tint(SessionsV2Theme.warn)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if session.archivedAt == nil {
                        Button {
                            Task { await client.archiveSession(id: session.id) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.orange)
                    } else {
                        Button {
                            Task { await client.unarchiveSession(id: session.id) }
                        } label: {
                            Label("Unarchive", systemImage: "archivebox.fill")
                        }
                        .tint(.blue)
                    }
                    Button(role: .destructive) {
                        Task { await client.deleteSession(id: session.id) }
                    } label: {
                        Label("End", systemImage: "stop.circle")
                    }
                }
            }
            if !repo.recentSessions.isEmpty {
                recentSessionsHeader
                ForEach(repo.recentSessions) { recent in
                    NavigationLink {
                        OutsideSessionDetailView(
                            recent: recent, repo: repo, client: client
                        )
                    } label: {
                        RecentSessionRow(recent: recent)
                    }
                }
            }
        }
    }

    /// Whole-row tap target. `Section(isExpanded:)` already animates
    /// the disclosure on header tap, but adding a `Button` over the
    /// chevron gives an explicit affordance + a row-count badge.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    private func repoSectionHeader(for repo: AgentRepo, isExpanded: Binding<Bool>) -> some View {
        let count = sessionsForRepo(repo).count + repo.recentSessions.count
        Button {
            withAnimation(SessionsV2Theme.disclosureToggle(reduceMotion: reduceMotion)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                Text(repo.displayName)
                    .textCase(nil)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                }
                Spacer()
                if repo.liveSessionCount > 0 {
                    Circle().fill(.green).frame(width: 6, height: 6)
                } else if repo.hasActiveSessions {
                    Circle().fill(terraCotta).frame(width: 6, height: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Default-expanded if the repo has a live session, an active
    /// Clawdmeter-owned session, OR the user has manually expanded it.
    /// Manual collapse always wins for the rest of the session.
    private func isRepoExpanded(_ repo: AgentRepo) -> Bool {
        if manuallyCollapsed.contains(repo.key) { return false }
        if manuallyExpanded.contains(repo.key) { return true }
        return repo.liveSessionCount > 0 || repo.hasActiveSessions
    }

    private var recentSessionsHeader: some View {
        Text("Recent (last 30 days)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .listRowBackground(Color.clear)
    }

    /// Repos filtered by search query + archive toggle. When the user has
    /// typed a query we keep repos whose name matches OR which have at
    /// least one matching session/goal.
    private var filteredRepos: [AgentRepo] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return client.repos }
        return client.repos.filter { repo in
            if repo.displayName.lowercased().contains(q) { return true }
            let matches = sessionsForRepo(repo).contains { s in
                (s.goal ?? "").lowercased().contains(q)
            }
            return matches
        }
    }

    private func sessionsForRepo(_ repo: AgentRepo) -> [AgentSession] {
        client.sessions.filter { s in
            guard s.repoKey == repo.key else { return false }
            if !showArchived, s.archivedAt != nil { return false }
            return true
        }
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

    // MARK: - Phase 5 status-grouped list

    enum SidebarGrouping: String, CaseIterable, Identifiable {
        case byRepo
        case byStatus
        var id: String { rawValue }
        var label: String {
            switch self {
            case .byRepo:   return "By repo"
            case .byStatus: return "By status"
            }
        }
    }

    /// Buckets adopted from Conductor's Backlog / In Progress / Review /
    /// Done / Archived split. iOS skips Backlog (we don't have a queued
    /// state pre-spawn). "Needs attention" wraps sessions waiting on a
    /// plan approval — the highest-priority bucket on a phone where the
    /// user is glancing not scrolling.
    enum StatusBucket: String, CaseIterable, Identifiable {
        case needsAttention
        case inProgress
        case idle
        case done
        case archived
        var id: String { rawValue }
        var label: String {
            switch self {
            case .needsAttention: return "Needs attention"
            case .inProgress:     return "In progress"
            case .idle:           return "Idle / paused"
            case .done:           return "Done"
            case .archived:       return "Archived"
            }
        }
    }

    private func bucket(for session: AgentSession) -> StatusBucket {
        if session.archivedAt != nil { return .archived }
        if session.planText != nil && session.status == .planning { return .needsAttention }
        switch session.status {
        case .running:        return .inProgress
        case .planning:       return .inProgress
        case .paused:         return .idle
        case .done:           return .done
        case .degraded:       return .needsAttention
        }
    }

    private var statusGroupedList: some View {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = client.sessions.filter { s in
            // Archived bucket is gated by showArchived toggle.
            if s.archivedAt != nil && !showArchived { return false }
            // Search across goal + repo display name.
            if !q.isEmpty {
                let inGoal = (s.goal ?? "").lowercased().contains(q)
                let inRepo = s.repoDisplayName.lowercased().contains(q)
                if !inGoal && !inRepo { return false }
            }
            return true
        }
        let bucketed = Dictionary(grouping: visible, by: { bucket(for: $0) })
        return List {
            ForEach(StatusBucket.allCases) { b in
                if let sessions = bucketed[b], !sessions.isEmpty {
                    Section(b.label) {
                        ForEach(sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session, client: client)
                            } label: {
                                SessionRow(session: session)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if session.planText != nil && session.status == .planning {
                                    Button {
                                        Task { await client.approvePlan(sessionId: session.id) }
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.seal.fill")
                                    }
                                    .tint(SessionsV2Theme.accent)
                                }
                                if session.status == .running {
                                    Button {
                                        Task { await client.interruptSession(sessionId: session.id) }
                                    } label: {
                                        Label("Interrupt", systemImage: "stop.fill")
                                    }
                                    .tint(SessionsV2Theme.warn)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if session.archivedAt == nil {
                                    Button {
                                        Task { await client.archiveSession(id: session.id) }
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.orange)
                                } else {
                                    Button {
                                        Task { await client.unarchiveSession(id: session.id) }
                                    } label: {
                                        Label("Unarchive", systemImage: "archivebox.fill")
                                    }
                                    .tint(.blue)
                                }
                                Button(role: .destructive) {
                                    Task { await client.deleteSession(id: session.id) }
                                } label: {
                                    Label("End", systemImage: "stop.circle")
                                }
                            }
                        }
                    }
                }
            }
            if bucketed.allSatisfy({ $0.value.isEmpty }) {
                Text("No sessions match the current filter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.agent.rawValue.capitalized)
                        .font(.subheadline.weight(.medium))
                    Text(session.status.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let goal = session.goal {
                    Text(goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if session.planText != nil {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
            }
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .degraded: return .secondary
        }
    }
}

/// One row in the iOS sidebar for a JSONL outside-Clawdmeter session
/// (Conductor / Cursor / Terminal-launched) found within the last 30
/// days. Tap opens a read-only chat — composer hidden, swipe actions
/// stripped, "Read-only" badge in the detail header.
private struct RecentSessionRow: View {
    let recent: RecentSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isLive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var isLive: Bool {
        Date().timeIntervalSince(recent.lastModified) < 5 * 60
    }

    private var title: String {
        if let prompt = recent.firstPrompt, !prompt.isEmpty {
            return prompt
        }
        let provider = recent.provider == .claude ? "Claude" : "Codex"
        return isLive ? "\(provider) · live now" : "\(provider) session"
    }

    private var subtitle: String {
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        let provider = recent.provider == .claude ? "Claude" : "Codex"
        let when = rel.localizedString(for: recent.lastModified, relativeTo: Date())
        if recent.firstPrompt != nil {
            let live = isLive ? " · live now" : ""
            return "\(provider) · \(when)\(live) · read-only"
        }
        return "\(when) · read-only"
    }
}

/// Detail view for an outside-Clawdmeter recent JSONL. Mirrors
/// `SessionDetailView` but with composer / delete actions hidden and a
/// "Read-only" badge prominent in the header. The structured view shows
/// the goal + recent-session metadata; the terminal view is not offered
/// (the JSONL is historical, not a live tmux pane).
private struct OutsideSessionDetailView: View {
    let recent: RecentSession
    let repo: AgentRepo
    @ObservedObject var client: AgentControlClient
    @State private var showingPathInfo: Bool = false
    /// When non-nil, the read-only row has been promoted into a live
    /// session and we want to navigate into its detail view instead of
    /// staying on the outside view. The promote happens server-side via
    /// `POST /sessions/continue-readonly`.
    @State private var promotedSession: AgentSession?

    var body: some View {
        VStack(spacing: 0) {
            // Show the actual chat. Renders the parsed transcript from
            // the Mac daemon's `/transcript` endpoint. The composer
            // below promotes the session on send (continue-readonly).
            iOSChatTranscriptView(
                jsonlPath: recent.path,
                banner: .readOnlyOutside,
                client: client
            )
            iOSComposerBar(
                mode: .outside(recent: recent, repo: repo),
                client: client,
                onPromoted: { newId in
                    // Resolve the new live session from the refreshed list.
                    if let live = client.sessions.first(where: { $0.id == newId }) {
                        promotedSession = live
                    }
                }
            )
        }
        .navigationDestination(item: $promotedSession) { session in
            SessionDetailView(session: session, client: client)
        }
        .navigationTitle(repo.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingPathInfo = true } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showingPathInfo) {
            NavigationStack {
                Form {
                    Section("Session") {
                        LabeledContent("Repo") { Text(repo.displayName) }
                        LabeledContent("Provider") {
                            Text(recent.provider == .claude ? "Claude" : "Codex")
                        }
                        LabeledContent("Last write") {
                            Text(recent.lastModified, style: .relative)
                        }
                    }
                    Section {
                        Text(recent.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } header: {
                        Text("JSONL path on Mac")
                    } footer: {
                        Text("Tap-and-hold to copy. Clawdmeter reads this file from your Mac over Tailscale; it's not transferred to the iPhone.")
                    }
                }
                .navigationTitle("Session info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingPathInfo = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

private struct SessionDetailView: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient
    @State private var viewMode: ViewMode = .chat
    /// Sessions v2 T40: chat store mirrors the daemon's chat snapshot.
    @StateObject private var chatStore: iOSChatStore
    /// Tracks whether the chat scroll is at the tail so we know when to
    /// auto-scroll on new items vs. surface a "Jump to latest" CTA.
    @State private var liveChatPinnedToBottom: Bool = true

    init(session: AgentSession, client: AgentControlClient) {
        self.session = session
        self.client = client
        _chatStore = StateObject(
            wrappedValue: iOSChatStoreCache.shared.store(for: session.id, client: client)
        )
    }

    /// Phase 4: 5-tab view structure (Chat / Plan / Diff / PR / Terminal).
    /// Chat is the default; Plan auto-promotes when planText is non-nil.
    enum ViewMode: String, CaseIterable {
        case chat     = "Chat"
        case plan     = "Plan"
        case diff     = "Diff"
        case pr       = "PR"
        case terminal = "Terminal"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sessions v2 T39: activity strip (per-agent indicator, duration, tokens, cost).
            iOSSessionActivityStrip(session: session, chatStore: chatStore)
            Divider()

            // Sessions v2 Phase 3: control strip (model/effort/plan-code/interrupt).
            iOSSessionControlsStrip(session: session, client: client)
            Divider()

            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            switch viewMode {
            case .chat:
                VStack(spacing: 0) {
                    liveChatList
                    iOSComposerBar(
                        mode: .live(sessionId: session.id),
                        client: client
                    )
                }
            case .plan:
                iOSPlanTrackerView(session: session)
            case .diff:
                iOSDiffView(session: session, client: client)
            case .pr:
                iOSPRPane(session: session, client: client)
            case .terminal:
                terminalView
            }
        }
        .navigationTitle(session.repoDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { iOSChatStoreCache.shared.protectSession(session.id) }
        .onDisappear { iOSChatStoreCache.shared.unprotectSession(session.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        iOSArtifactsPane(client: client, session: session, chatStore: chatStore)
                            .navigationTitle("Artifacts")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Artifacts (\(chatStore.snapshot.artifactEntries.count))", systemImage: "paperclip")
                    }
                    Divider()
                    if session.archivedAt == nil {
                        Button("Archive session") {
                            Task { await client.archiveSession(id: session.id) }
                        }
                    } else {
                        Button("Unarchive session") {
                            Task { await client.unarchiveSession(id: session.id) }
                        }
                    }
                    Button("Toggle autopilot") {
                        Task { await client.setAutopilot(sessionId: session.id, enabled: true) }
                    }
                    Divider()
                    Button("Delete session", role: .destructive) {
                        Task { await client.deleteSession(id: session.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    /// Live chat for an in-session SessionDetailView. Renders the items
    /// already polled by `iOSChatStore` from the daemon's chat-snapshot
    /// endpoint. Auto-scrolls to the latest item; floating "Jump to
    /// latest" CTA mirrors the Mac chat thread.
    @ViewBuilder
    private var liveChatList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let planText = session.planText, !planText.isEmpty {
                            PlanCardView(
                                goal: session.goal,
                                planSummary: planText,
                                files: [],
                                onApprove: {
                                    Task { await client.approvePlan(sessionId: session.id) }
                                }
                            )
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                        }
                        if chatStore.snapshot.items.isEmpty {
                            emptyChatPlaceholder
                        } else {
                            ForEach(chatStore.snapshot.items) { item in
                                liveChatItemRow(item)
                                    .id(item.id)
                                    .padding(.horizontal, 12)
                                    .onAppear {
                                        if item.id == chatStore.snapshot.items.last?.id {
                                            liveChatPinnedToBottom = true
                                        }
                                    }
                                    .onDisappear {
                                        if item.id == chatStore.snapshot.items.last?.id {
                                            liveChatPinnedToBottom = false
                                        }
                                    }
                            }
                        }
                        Color.clear.frame(height: 12).id("bottom-anchor")
                    }
                    .padding(.vertical, 12)
                }
                .background(Color(.systemGroupedBackground))
                .onAppear {
                    jumpLiveChatToLatest(proxy, animated: false)
                }
                .onChange(of: chatStore.snapshot.updateCounter) { _, _ in
                    guard liveChatPinnedToBottom else { return }
                    jumpLiveChatToLatest(proxy, animated: true)
                }
                if !liveChatPinnedToBottom, !chatStore.snapshot.items.isEmpty {
                    Button(action: {
                        liveChatPinnedToBottom = true
                        jumpLiveChatToLatest(proxy, animated: true)
                    }) {
                        Label("Latest", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: liveChatPinnedToBottom)
        }
    }

    @ViewBuilder
    private var emptyChatPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Waiting for the agent's first turn…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    @ViewBuilder
    private func liveChatItemRow(_ item: ChatItem) -> some View {
        switch item {
        case .message(let msg):
            liveMessageBubble(msg)
        case .toolRun(_, let pairs):
            liveToolRunCard(pairs: pairs)
        }
    }

    @ViewBuilder
    private func liveMessageBubble(_ msg: ChatMessage) -> some View {
        switch msg.kind {
        case .userText:
            HStack {
                Spacer(minLength: 40)
                Text(msg.body)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
        case .assistantText:
            HStack {
                Text(msg.body)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                Spacer(minLength: 40)
            }
        case .meta:
            Text(msg.body)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolCall, .toolResult:
            // Folded into .toolRun groups by ChatItemBuilder — never seen here.
            EmptyView()
        }
    }

    @ViewBuilder
    private func liveToolRunCard(pairs: [ToolPair]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pairs) { pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.call.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if !pair.call.body.isEmpty {
                            Text(pair.call.body)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(8)
                        }
                    }
                    .padding(8)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Ran \(pairs.count) command\(pairs.count == 1 ? "" : "s")",
                  systemImage: "terminal")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func jumpLiveChatToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        let target: AnyHashable = chatStore.snapshot.items.last?.id ?? "bottom-anchor"
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var structuredView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let planText = session.planText, !planText.isEmpty {
                    PlanCardView(
                        goal: session.goal,
                        planSummary: planText,
                        files: [],
                        onApprove: {
                            Task { await client.approvePlan(sessionId: session.id) }
                        }
                    )
                }
                StructuredEventList(items: [
                    // Placeholder: the WS event stream feeds this in v1.1.
                ])
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var terminalView: some View {
        iOSTerminalTabsView(client: client, session: session)
    }
}

struct PairingFlow: View {
    @ObservedObject var client: AgentControlClient
    @Binding var isPresented: Bool

    /// Allows callers to open the sheet pre-targeted to "Paste URL" so a
    /// dedicated Paste-URL CTA in an empty state can skip the segmented
    /// control. Defaults to `.scan` to preserve the original behavior.
    var initialMode: PairingMode = .scan

    @State private var mode: PairingMode = .scan
    @State private var pastedURL: String = ""
    @State private var pasteError: String?

    enum PairingMode: String, CaseIterable {
        case scan = "Scan QR"
        case paste = "Paste URL"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(PairingMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(16)

                Divider()

                switch mode {
                case .scan:
                    PairingScannerView { challenge in
                        applyChallenge(challenge)
                    }
                case .paste:
                    pasteForm
                }
            }
            .navigationTitle("Pair to Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .onAppear { mode = initialMode }
        }
    }

    private var pasteForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Clawdmeter on your Mac → Settings → Sessions → Copy pairing URL. Then paste it below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("clawdmeter://host:21731?token=...&ws=21732", text: $pastedURL, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            if let error = pasteError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Button("Pair") {
                guard let challenge = PairingScannerView.parse(urlString: pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    pasteError = "Not a valid clawdmeter:// URL"
                    return
                }
                applyChallenge(challenge)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
            .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }
        .padding(20)
    }

    private func applyChallenge(_ challenge: PairingChallenge) {
        client.setPairing(
            host: challenge.host,
            httpPort: challenge.port,
            wsPort: challenge.wsPort,
            token: challenge.token
        )
        Task { @MainActor in
            await client.refreshAll()
        }
        isPresented = false
    }
}

/// Sessions v2 Phase 2 — full new-session sheet matching the design spec:
/// Repo → Goal → Agent → Model picker → Effort dial → Mode chip → Plan
/// toggle → Start (sticky bottom). Sends a complete `NewSessionRequest`
/// with effort + optional A/B pair config.
private struct NewSessionSheet: View {
    @ObservedObject var client: AgentControlClient
    @Binding var isPresented: Bool

    @State private var repoKey: String = ""
    @State private var baseBranch: String = "main"
    @State private var goal: String = ""
    @State private var agent: AgentKind = .claude
    @State private var modelId: String?
    @State private var effort: ReasoningEffort = .medium
    @State private var mode: SessionMode = .worktree
    @State private var planMode: Bool = true
    @State private var runAsABPair: Bool = false
    @State private var isStarting: Bool = false
    @State private var openOnMacUnsupportedAlert: String?
    /// Phase 8: pre-flight cost + weekly-cap estimate. Refreshes when
    /// any input the daemon would care about changes (repo, agent,
    /// model, effort, goal length). Debounced via the .task(id:) below.
    @State private var preflight: PreflightResponse?
    @State private var preflightLoading: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    Picker("Repo", selection: $repoKey) {
                        ForEach(client.repos, id: \.key) { repo in
                            Text(repo.displayName).tag(repo.key)
                        }
                    }
                    TextField("Base branch", text: $baseBranch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Goal") {
                    TextField("What should the agent do?", text: $goal, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(3...6)
                }

                Section("Agent") {
                    Picker("Agent", selection: $agent) {
                        Text("Claude").tag(AgentKind.claude)
                        Text("Codex").tag(AgentKind.codex)
                    }
                    .pickerStyle(.segmented)

                    iOSModelPicker(selectedModelId: $modelId, catalog: client.modelCatalog, agent: agent)

                    iOSEffortDial(selected: $effort, supportsEffort: currentModelSupportsEffort)
                }

                Section("Run mode") {
                    Picker("Mode", selection: $mode) {
                        Text("Local").tag(SessionMode.local)
                        Text("Worktree").tag(SessionMode.worktree)
                    }
                    .pickerStyle(.segmented)

                    // Plan mode applies to both agents. Claude maps it
                    // to `--permission-mode plan`; Codex maps it to
                    // `--sandbox read-only`. Approve & run flips the
                    // sandbox afterwards.
                    Toggle("Plan mode", isOn: $planMode)

                    Toggle("Run as A/B pair (Claude + Codex)", isOn: $runAsABPair)
                        .toggleStyle(.switch)
                        .tint(SessionsV2Theme.accent)
                }

                preflightSection

                if client.hasWireVersionMismatch {
                    Section {
                        Label("Mac is running a different version. Update the Mac app.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SessionsV2Theme.warn)
                    }
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 8) {
                        Button(action: openOnMac) {
                            Label("Open on Mac", systemImage: "desktopcomputer")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.isConfigured)
                        .help("Send the prompt to the paired Mac's empty-state composer instead of starting a session here.")
                        .accessibilityLabel("Send draft to Mac")
                        Button(action: startSession) {
                            if isStarting {
                                ProgressView()
                            } else {
                                Label("Start", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SessionsV2Theme.accent)
                        .disabled(repoKey.isEmpty || isStarting)
                        .accessibilityLabel("Start new session")
                    }
                }
            }
            .task {
                await client.refreshModelCatalog()
                if repoKey.isEmpty, let first = client.repos.first {
                    repoKey = first.key
                }
            }
            .task(id: preflightInputs) {
                await refreshPreflight()
            }
            .alert("Couldn't open on Mac",
                   isPresented: Binding(
                    get: { openOnMacUnsupportedAlert != nil },
                    set: { if !$0 { openOnMacUnsupportedAlert = nil } }
                   ),
                   actions: { Button("OK", role: .cancel) { openOnMacUnsupportedAlert = nil } },
                   message: { Text(openOnMacUnsupportedAlert ?? "") })
        }
    }

    /// Tuple of every input the preflight estimate depends on. Used as
    /// the `.task(id:)` key so SwiftUI re-runs the refresh whenever any
    /// input changes (Form binding edits invalidate the task naturally).
    private var preflightInputs: String {
        "\(repoKey)|\(agent.rawValue)|\(modelId ?? "")|\(effort.rawValue)|\(goal.count)"
    }

    @MainActor
    private func refreshPreflight() async {
        // Need all three keys before the daemon can answer.
        guard !repoKey.isEmpty,
              let modelId, !modelId.isEmpty,
              client.isConfigured else {
            preflight = nil
            return
        }
        preflightLoading = true
        defer { preflightLoading = false }
        let query = PreflightQuery(
            repoKey: repoKey,
            agent: agent,
            model: modelId,
            effort: currentModelSupportsEffort ? effort : nil,
            goalLength: goal.count
        )
        preflight = await client.fetchPreflight(query: query)
    }

    @ViewBuilder
    private var preflightSection: some View {
        if let preflight {
            Section {
                CostBannerView(
                    response: preflight,
                    currentModel: modelId ?? "",
                    onSwap: { newModel in
                        modelId = newModel
                    }
                )
            } header: {
                Text("Estimated cost")
            } footer: {
                if preflight.staleData {
                    Text("Estimate based on cached usage; may be off until the next analytics refresh.")
                }
            }
        } else if preflightLoading {
            Section {
                HStack {
                    ProgressView()
                    Text("Calculating estimate…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var currentModelSupportsEffort: Bool {
        guard let id = modelId,
              let entry = client.modelCatalog.entry(forId: id)
        else { return true }
        return entry.supportsEffort
    }

    private func startSession() {
        guard !repoKey.isEmpty else { return }
        isStarting = true
        Task {
            _ = await client.createSession(NewSessionRequest(
                repoKey: repoKey,
                agent: agent,
                model: modelId,
                planMode: planMode,
                goal: goal.isEmpty ? nil : goal,
                useWorktree: mode == .worktree,
                baseBranch: baseBranch.isEmpty ? nil : baseBranch,
                effort: currentModelSupportsEffort ? effort : nil,
                abPair: runAsABPair ? (agent == .claude ? .codex : .claude) : nil
            ))
            await MainActor.run {
                isStarting = false
                isPresented = false
            }
        }
    }

    /// X1 cross-Apple handoff: post the current composer state as a
    /// `compose-draft` WS envelope to the paired Mac. The Mac's empty-state
    /// composer pre-fills with this text + chip suggestions. No session is
    /// spawned here — the user finishes on the Mac.
    private func openOnMac() {
        let draft = ComposeDraft(
            text: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            repoKey: repoKey.isEmpty ? nil : repoKey,
            suggestedAgent: agent,
            suggestedModel: modelId,
            suggestedEffort: currentModelSupportsEffort ? effort : nil
        )
        Task {
            // Refresh /health first so the wire-version gate inside
            // postComposeDraft has fresh data to consult.
            await client.refreshHealth()
            let result = await client.postComposeDraft(draft)
            await MainActor.run {
                switch result {
                case .delivered:
                    isPresented = false
                case .macUnsupported(let v):
                    openOnMacUnsupportedAlert = "Your Mac is on wire version \(v); Open on Mac needs ≥\(AgentControlWireVersion.composeDraftMinimum). Update Clawdmeter on the Mac."
                case .failed(let msg):
                    openOnMacUnsupportedAlert = msg
                }
            }
        }
    }
}
