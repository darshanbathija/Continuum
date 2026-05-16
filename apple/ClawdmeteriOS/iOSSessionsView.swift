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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No sessions yet", systemImage: "tray")
        } description: {
            Text("Tap ＋ to start one. Repos appear after you run Claude or Codex in them on your Mac.")
        }
    }

    private var repoList: some View {
        List {
            ForEach(filteredRepos, id: \.key) { repo in
                repoSection(for: repo)
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
    @ViewBuilder
    private func repoSectionHeader(for repo: AgentRepo, isExpanded: Binding<Bool>) -> some View {
        let count = sessionsForRepo(repo).count + repo.recentSessions.count
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
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

    var body: some View {
        // Show the actual chat. The previous body showed only a "Read-only"
        // pill + JSONL path + last write — useless. The new body fetches
        // the parsed transcript from the Mac daemon's `/transcript`
        // endpoint and renders it the same way the Mac chat view does.
        iOSChatTranscriptView(
            jsonlPath: recent.path,
            banner: .readOnlyOutside,
            client: client
        )
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
                structuredView
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
        if let host = client.host, let token = client.token {
            iOSTerminalView(
                sessionId: session.id,
                host: host,
                wsPort: client.wsPort,
                token: token
            )
        } else {
            ContentUnavailableView("Not paired", systemImage: "wifi.exclamationmark")
        }
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
            .task {
                await client.refreshModelCatalog()
                if repoKey.isEmpty, let first = client.repos.first {
                    repoKey = first.key
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
}
