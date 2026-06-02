import SwiftUI
import ClawdmeterShared

/// Mac Code IDE — sidebar + thread/composer + review pane. Ports
/// `mac-sessions.jsx` + `mac-sessions-parts.jsx` + `mac-composer.jsx`.
/// Accepts a `TahoeCodeBindings` value (defaults to demo); the Mac app
/// injects real AgentRuntime-derived data via `MacRootView.body`.
///
/// Codex review P1 fix: every demo-content surface (thread, plan halo,
/// review pane tabs) is now gated on `data.isDemo`. In production
/// (`data.isDemo == false`) the IDE renders empty-state placeholders
/// rather than the JSX fixture data — so a user can't approve a fake
/// plan or read a hardcoded diff thinking it's their real session.
struct MacCodeView: View {
    @Environment(\.tahoe) private var t

    enum ComposerState: String { case idle, running, plan }
    enum ReviewTab: String, CaseIterable { case plan, diff, sources, pr, term }

    var data: TahoeCodeBindings
    /// Caller-provided callbacks. `onNewSession(key)` is fired by the
    /// per-repo `+` button (key = repo path) and the sidebar `+` icon
    /// (key = nil, sheet lets user pick). Defaults to `{ _ in }` so the
    /// view remains preview-friendly.
    var onNewSession: (String?) -> Void
    /// Open a PR in the system browser. Wired only when the PR review
    /// tab is visible (i.e. demo bindings today).
    var onOpenPRInBrowser: (() -> Void)?
    /// In-process daemon client for Mac IDE actions (PR #24a D2).
    /// Nil when the local agent server failed to bind ports — actions
    /// disable themselves rather than crash.
    var loopbackClient: AgentControlClient?
    /// Optional Mac runtime ref for the in-process ReviewPane tab embeds
    /// (PR #24b D9 + X1). Nil in Previews — ReviewPane falls back to the
    /// existing demo / placeholder content when no runtime is available.
    /// Mac-target only (`AppRuntime` is internal to ClawdmeterMac).
    var runtime: AppRuntime?

    @State private var openId: UUID? = nil
    @State private var composerState: ComposerState = .idle
    @State private var rightTab: ReviewTab = .plan
    @State private var showRight: Bool = true
    @State private var expanded: Set<String> = []
    @State private var didInitComposer: Bool = false

    /// v0.22.11: JSONL preview path. Set when the user clicks a
    /// RECENT sidebar row whose `sessionId` is nil (i.e. a disk-only
    /// transcript). The `.task(id: openJsonlPath)` below loads it
    /// asynchronously into `jsonlMessages`; the middle pane swaps to
    /// the read-only preview while this is non-nil. Selecting any
    /// real live session clears it.
    @State private var openJsonlPath: String? = nil
    @State private var jsonlMessages: [ChatMessage] = []

    /// Refine/Edit plan modal state — both share the same wire (A3:
    /// Edit plan = Refine via sendPrompt). The bool drives sheet
    /// presentation; the text holds the in-flight user input.
    @State private var refineSheetPresented: Bool = false
    @State private var refineText: String = ""
    @State private var actionAlertMessage: String?
    @State private var refineSubmitting: Bool = false

    /// Composer send controller for the idle-state composer Send button.
    /// Owned per-MacCodeView instance; reset when the open session
    /// changes so a half-typed draft doesn't flow into a different
    /// session.
    @StateObject private var composerController: ComposerSendController

    init(
        data: TahoeCodeBindings = .demo,
        onNewSession: @escaping (String?) -> Void = { _ in },
        onOpenPRInBrowser: (() -> Void)? = nil,
        loopbackClient: AgentControlClient? = nil,
        runtime: AppRuntime? = nil
    ) {
        self.data = data
        self.onNewSession = onNewSession
        self.onOpenPRInBrowser = onOpenPRInBrowser
        self.loopbackClient = loopbackClient
        self.runtime = runtime
        // Construct a controller bound to the loopback client when
        // available. In Previews / no-client mode, build a dummy
        // controller bound to a UserDefaults-backed client so the view
        // still renders — sends fail-fast on nil host.
        let clientForController = loopbackClient ?? AgentControlClient()
        _composerController = StateObject(wrappedValue: ComposerSendController(client: clientForController))
    }

    public var body: some View {
        // v0.22.11: JSONL preview wins over the live session pick. When
        // the user clicks a RECENT row that's JSONL-only (sessionId
        // nil), `openJsonlPath` flips and the middle pane swaps to the
        // read-only preview. Clearing the path or picking a real
        // session restores the normal flow.
        let previewingJsonl = openJsonlPath != nil
        let effectiveOpenId = previewingJsonl ? nil : (openId ?? data.openSessionId)
        let openRepo = data.repos.first { repo in
            repo.sessions.contains { $0.id == effectiveOpenId }
        } ?? data.repos.first
        let openSession = openRepo?.sessions.first { $0.id == effectiveOpenId }

        HStack(spacing: 10) {
            TahoeGlass(radius: 20, tone: .panel) {
                Sidebar(
                    repos: data.repos,
                    openId: Binding(get: { effectiveOpenId }, set: { openId = $0; openJsonlPath = nil }),
                    expanded: $expanded,
                    onNewSession: onNewSession,
                    loopbackClient: loopbackClient,
                    onOpenJsonl: { path in
                        openJsonlPath = path
                        openId = nil
                        jsonlMessages = []  // clear so spinner shows
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 260)

            TahoeGlass(radius: 20, tone: .panel) {
                VStack(spacing: 0) {
                    if let openSession {
                        ThreadHeader(session: openSession, isDemo: data.isDemo)
                        TahoeHair()
                    }
                    Thread(
                        session: openSession,
                        state: composerState,
                        isDemo: data.isDemo,
                        onApprovePlan: openSession != nil ? {
                            approvePlan(sessionId: openSession!.id)
                        } : {},
                        onRefinePlan: { refineSheetPresented = true },
                        canAct: loopbackClient != nil && openSession != nil,
                        previewTranscript: previewingJsonl ? jsonlMessages : nil,
                        previewJsonlPath: openJsonlPath
                    )
                    .frame(maxHeight: .infinity)
                    ComposerBar(
                        state: $composerState,
                        isDemo: data.isDemo,
                        hasRealPlan: openSession?.runtimePlanText?.isEmpty == false,
                        session: openSession,
                        client: loopbackClient,
                        onCycle: {
                            composerState = composerState == .idle ? .running
                                          : composerState == .running ? .plan
                                          : .idle
                        },
                        onSend: loopbackClient != nil && openSession != nil ? {
                            sendComposer(sessionId: openSession!.id)
                        } : nil,
                        onStop: loopbackClient != nil && openSession != nil ? {
                            interrupt(sessionId: openSession!.id)
                        } : nil,
                        composerText: loopbackClient != nil ? $composerController.text : nil,
                        sending: composerController.sending
                    )
                }
            }
            .frame(maxWidth: .infinity)

            if showRight {
                TahoeGlass(radius: 20, tone: .panel) {
                    ReviewPane(
                        tab: $rightTab,
                        session: openSession,
                        isDemo: data.isDemo,
                        runtime: runtime,
                        // v0.22.31: thread JSONL preview through so the
                        // right pane's tabs can derive Plan / Diff /
                        // Sources / PR from the transcript when no
                        // live AgentSession exists.
                        previewTranscript: previewingJsonl ? jsonlMessages : nil,
                        previewJsonlPath: openJsonlPath
                    )
                }
                .frame(width: 380)
            }
        }
        .onAppear {
            // Default-expand the first 2 repos so the user sees sessions
            // immediately — matches JSX `useState(['defx-frontend','ccwatch'])`.
            if expanded.isEmpty {
                expanded = Set(data.repos.prefix(2).map { $0.key })
            }
            // Demo bindings start in `.plan` so Xcode Previews show the
            // halo card; production starts in `.idle` so we don't dangle
            // a halo with no underlying plan text.
            if !didInitComposer {
                composerState = data.isDemo ? .plan : .idle
                didInitComposer = true
            }
        }
        .onChange(of: data.repos.flatMap { $0.sessions.map { $0.id } }) { _, ids in
            // Watch the FULL session id set, not just repo keys — sessions
            // can be archived while their repo persists. Keep the open-id
            // valid: if the previously open session vanished, pick the
            // first available one in the first repo with sessions.
            if let oid = openId, !ids.contains(oid) {
                openId = data.repos.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
            }
            // Auto-expand any repo with live sessions so users see new work
            // without manual clicking.
            for repo in data.repos where repo.liveSessionCount > 0 {
                expanded.insert(repo.key)
            }
        }
        // v0.22.11: load the JSONL transcript whenever the user picks
        // a different RECENT row. TranscriptLoader.load is synchronous
        // I/O (memory-mapped) but we hop off the main actor to avoid
        // blocking the UI on multi-MB files. Cap at 200 messages —
        // matches the AgentControlServer chat-history limit and keeps
        // the SwiftUI ForEach tractable.
        .task(id: openJsonlPath) {
            guard let path = openJsonlPath else { return }
            let url = URL(fileURLWithPath: path)
            let loaded = await Task.detached(priority: .userInitiated) {
                TranscriptLoader.load(from: url, maxMessages: 200)
            }.value
            // Guard against a tap-then-tap race: only commit if the
            // path we just finished loading is still the one the user
            // is looking at.
            if openJsonlPath == path {
                jsonlMessages = loaded
            }
        }
        .onChange(of: openSession?.id) { _, newId in
            // Switching to a session with a real plan auto-cycles the
            // composer into plan-mode; otherwise it stays idle so the
            // Refine/Approve actions don't dangle.
            if openSession?.runtimePlanText?.isEmpty == false {
                composerState = .plan
            } else if !data.isDemo {
                composerState = .idle
            }
            // Reset composer-controller state so a half-typed draft
            // doesn't bleed across session switches.
            if newId != nil { composerController.reset() }
        }
        // PR #24a Refine modal (A3: Edit plan reuses this too).
        .sheet(isPresented: $refineSheetPresented) {
            refineSheetView
        }
        // Action error surface.
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { actionAlertMessage != nil },
                set: { if !$0 { actionAlertMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { actionAlertMessage = nil } },
            message: { Text(actionAlertMessage ?? "") }
        )
    }

    // MARK: - Action helpers (PR #24a)

    /// Refine modal body. Pre-fills with the current planText so the user
    /// can edit-then-resend. Per A3 (Edit plan = Refine), submission is
    /// a plain `sendPrompt(asFollowUp:true)`.
    @ViewBuilder
    private var refineSheetView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Refine the plan")
                .font(.system(size: 16, weight: .semibold))
            Text("Your message is sent to the agent as a plan-mode follow-up. The agent revises the plan and you re-approve.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextEditor(text: $refineText)
                .font(.system(size: 13))
                .frame(minHeight: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    refineSheetPresented = false
                    refineText = ""
                }
                .keyboardShortcut(.cancelAction)
                Button(refineSubmitting ? "Sending…" : "Send") {
                    submitRefine()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(refineSubmitting || refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func approvePlan(sessionId: UUID) {
        guard let client = loopbackClient else {
            actionAlertMessage = "Agent server isn't running. Restart Clawdmeter to try again."
            return
        }
        Task { @MainActor in
            await client.approvePlan(sessionId: sessionId)
            if let err = client.lastError {
                actionAlertMessage = err
            }
        }
    }

    private func submitRefine() {
        guard let client = loopbackClient else {
            actionAlertMessage = "Agent server isn't running. Restart Clawdmeter to try again."
            return
        }
        guard let session = data.repos.first(where: { repo in
            repo.sessions.contains { $0.id == (openId ?? data.openSessionId) }
        })?.sessions.first(where: { $0.id == (openId ?? data.openSessionId) })
        else {
            actionAlertMessage = "No session selected."
            return
        }
        let text = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        refineSubmitting = true
        Task { @MainActor in
            defer {
                refineSubmitting = false
                refineSheetPresented = false
                refineText = ""
            }
            await client.sendPrompt(sessionId: session.id, text: text, asFollowUp: true)
            if let err = client.lastError {
                actionAlertMessage = err
            }
        }
    }

    private func sendComposer(sessionId: UUID) {
        Task { @MainActor in
            await composerController.send(via: .solo(sessionId: sessionId))
            if let err = composerController.lastError {
                actionAlertMessage = err
            }
        }
    }

    private func interrupt(sessionId: UUID) {
        guard let client = loopbackClient else {
            actionAlertMessage = "Agent server isn't running."
            return
        }
        Task { @MainActor in
            await client.interruptSession(sessionId: sessionId)
            composerState = .idle
            if let err = client.lastError {
                actionAlertMessage = err
            }
        }
    }
}

// MARK: - Titlebar pieces

private struct ThreadHeader: View {
    @Environment(\.tahoe) private var t
    var session: TahoeCodeSession
    var isDemo: Bool
    var body: some View {
        HStack(spacing: 12) {
            TahoeProviderGlyph(provider: session.agent, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("\(session.agent.displayName) · \(session.model) · \(session.mode) mode")
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
            // Branch pill renders real `commitBranch` (worktree sessions)
            // when present; demo bindings keep the JSX placeholder. Local
            // sessions in production omit it rather than display a
            // fake branch name.
            if let branch = session.commitBranch, !branch.isEmpty {
                TahoePill {
                    HStack(spacing: 5) {
                        TahoeIcon("branch", size: 11)
                        Text(branch).font(TahoeFont.mono(11))
                    }
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            } else if isDemo {
                TahoePill {
                    HStack(spacing: 5) {
                        TahoeIcon("branch", size: 11)
                        Text("fix/settlement-dedupe").font(TahoeFont.mono(11))
                    }
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
            // Autopilot status pill is a fixture today; hide outside demo
            // until a real autopilot signal exists for code sessions.
            if isDemo {
                TahoePill {
                    HStack(spacing: 5) {
                        TahoeIcon("bolt", size: 11)
                        Text("autopilot · trusted")
                            .font(TahoeFont.body(11))
                    }
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 10)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(\.tahoe) private var t
    var repos: [TahoeCodeRepo]
    @Binding var openId: UUID?
    @Binding var expanded: Set<String>
    var onNewSession: (String?) -> Void
    /// PR #35: passed through to RepoSection → RecentRow so the
    /// "re-open archived session" action can call the unarchive RPC.
    /// Nil in Previews; production injects the real loopback client.
    var loopbackClient: AgentControlClient? = nil
    /// v0.22.11: invoked when the user taps a RECENT row whose backing
    /// row is JSONL-only (no live AgentSession). The parent flips
    /// `openJsonlPath` and the middle pane renders the read-only
    /// transcript preview. Falls through to `nil` in Previews.
    var onOpenJsonl: ((String) -> Void)? = nil

    /// D8 sidebar filter (PR #24b). Persisted to UserDefaults so the
    /// user's view sticks across launches.
    @AppStorage("clawdmeter.codeIDE.filter.status") private var statusFilterRaw: String = StatusFilter.all.rawValue
    @AppStorage("clawdmeter.codeIDE.filter.sort") private var sortKeyRaw: String = SortKey.lastActive.rawValue
    @AppStorage("clawdmeter.codeIDE.filter.providerClaude") private var providerClaudeEnabled: Bool = true
    @AppStorage("clawdmeter.codeIDE.filter.providerCodex") private var providerCodexEnabled: Bool = true
    @AppStorage("clawdmeter.codeIDE.filter.providerGemini") private var providerGeminiEnabled: Bool = true
    @AppStorage("clawdmeter.codeIDE.filter.providerOpenCode") private var providerOpenCodeEnabled: Bool = true
    @AppStorage("clawdmeter.codeIDE.filter.providerCursor") private var providerCursorEnabled: Bool = true

    /// v0.22.19: free-text query the user types in the Search field at
    /// the top of the sidebar. ⌘K from anywhere flips to the Code tab
    /// and focuses this field (see `.clawdmeterFocusCodeSearch` in
    /// ClawdmeterMacApp). Filters projects + sessions case-insensitively
    /// — a repo stays in the list if its name OR any of its sessions'
    /// titles OR any of its recent-jsonl entries' titles match.
    @State private var searchQuery: String = ""
    @FocusState private var searchFocused: Bool

    private var statusFilter: StatusFilter {
        StatusFilter(rawValue: statusFilterRaw) ?? .all
    }
    private var sortKey: SortKey {
        SortKey(rawValue: sortKeyRaw) ?? .lastActive
    }

    enum StatusFilter: String, CaseIterable {
        case all = "all"
        case live = "live"
        case paused = "paused"
        case done = "done"

        var label: String {
            switch self {
            case .all: return "All sessions"
            case .live: return "Live only"
            case .paused: return "Paused only"
            case .done: return "Done only"
            }
        }
    }

    enum SortKey: String, CaseIterable {
        case lastActive = "lastActive"
        case name = "name"
        case liveCount = "liveCount"

        var label: String {
            switch self {
            case .lastActive: return "Sort: Last active"
            case .name: return "Sort: Name"
            case .liveCount: return "Sort: Live count"
            }
        }
    }

    /// Apply status + provider filters and sort the repos.
    private var filteredRepos: [TahoeCodeRepo] {
        let providerAllowed: (TahoeProvider) -> Bool = { p in
            switch p {
            case .claude: return providerClaudeEnabled
            case .codex: return providerCodexEnabled
            case .gemini: return providerGeminiEnabled
            case .opencode: return providerOpenCodeEnabled  // PR #31
            case .cursor: return providerCursorEnabled
            }
        }
        let statusAllowed: (TahoeCodeSession.Status) -> Bool = { s in
            switch self.statusFilter {
            case .all: return true
            case .live: return s == .running || s == .planning
            case .paused: return s == .paused
            case .done: return s == .done
            }
        }
        // v0.22.19: case-insensitive substring query applied to each
        // repo's name, its sessions' titles, and its recents' titles.
        // When the query is empty, every repo passes (back-compat).
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryActive = !trimmedQuery.isEmpty
        let needle = trimmedQuery.lowercased()
        func matchesQuery(_ repo: TahoeCodeRepo, sessions: [TahoeCodeSession]) -> Bool {
            if !queryActive { return true }
            if repo.name.lowercased().contains(needle) { return true }
            if sessions.contains(where: { $0.title.lowercased().contains(needle) }) { return true }
            if repo.recents.contains(where: { $0.title.lowercased().contains(needle) }) { return true }
            return false
        }
        let processed: [TahoeCodeRepo] = repos.map { repo in
            let kept = repo.sessions.filter { s in
                providerAllowed(s.agent) && statusAllowed(s.status)
            }
            return TahoeCodeRepo(
                key: repo.key,
                name: repo.name,
                tint: repo.tint,
                liveSessionCount: repo.liveSessionCount,
                sessions: kept,
                recents: repo.recents
            )
        }
        // Drop repos that now have neither sessions nor recents.
        let nonEmpty = processed.filter {
            (!$0.sessions.isEmpty || !$0.recents.isEmpty) && matchesQuery($0, sessions: $0.sessions)
        }
        let collapsed = TahoeCodeProjectList.collapseDuplicateVisibleNames(nonEmpty)
        switch sortKey {
        case .lastActive:
            // TahoeCodeSession doesn't carry lastEventAt yet; the
            // server's already-sorted order is "last active first".
            return collapsed
        case .name:
            return collapsed.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .liveCount:
            return collapsed.sorted { $0.liveSessionCount > $1.liveSessionCount }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // v0.22.19: real TextField (was a static `Text("Search…")`
            // label). Filters repo + session + recent titles. ⌘K
            // focuses it via the .clawdmeterFocusCodeSearch
            // notification fired from the View menu's "Search Code"
            // command (wired in ClawdmeterMacApp).
            HStack(spacing: 8) {
                TahoeIcon("search", size: 13).foregroundStyle(t.fg3)
                TextField("Search\u{2026}", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(TahoeFont.body(12.5))
                    .foregroundStyle(t.fg)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { /* filtering is live as the user types */ }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchFocused = true
                    } label: {
                        TahoeIcon("x", size: 11).foregroundStyle(t.fg3)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search (Esc)")
                }
                Text("\u{2318}K")
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg4)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                    }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(searchFocused ? t.accent : t.hairline, lineWidth: searchFocused ? 1 : 0.5)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            // ⌘K from anywhere → focus this field. Wrapping the post
            // in `Task { @MainActor in … }` ensures the FocusState
            // update happens on the run loop tick after the notification
            // fires, dodging "modifying state during view update" warnings.
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterFocusCodeSearch)) { _ in
                Task { @MainActor in
                    searchFocused = true
                }
            }

            // Projects header — `folderPlus` opens NewSessionMacSheet with no
            // repo pre-selected (the sheet's picker shows the full list).
            // `filter` opens a SwiftUI Menu with status/provider/sort
            // controls (D8, PR #24b).
            HStack(spacing: 4) {
                Text("PROJECTS")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                Spacer()
                filterMenu
                SidebarIconBtn(icon: "folderPlus", action: { onNewSession(nil) })
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if repos.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("No repositories yet")
                                .font(TahoeFont.body(13, weight: .semibold))
                                .foregroundStyle(t.fg2)
                            Text("Start a session in any git repo and it shows up here. Continuum also auto-discovers repos from your recent Claude Code and Codex activity; add more under Settings → Sessions.")
                                .font(TahoeFont.body(11.5))
                                .foregroundStyle(t.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(action: { onNewSession(nil) }) {
                                Text("Start a session…")
                                    .font(TahoeFont.body(12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(t.accent)
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 14)
                    } else if filteredRepos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No matches")
                                .font(TahoeFont.body(13, weight: .semibold))
                                .foregroundStyle(t.fg2)
                            Text("Adjust the filter in the funnel icon above to see more sessions.")
                                .font(TahoeFont.body(11.5))
                                .foregroundStyle(t.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 14)
                    } else {
                        ForEach(filteredRepos) { repo in
                            RepoSection(
                                repo: repo,
                                expanded: expanded.contains(repo.key),
                                onToggle: {
                                    if expanded.contains(repo.key) { expanded.remove(repo.key) }
                                    else { expanded.insert(repo.key) }
                                },
                                openId: openId,
                                onOpen: { openId = $0 },
                                onNewSession: { onNewSession(repo.key) },
                                loopbackClient: loopbackClient,
                                onOpenJsonl: onOpenJsonl
                            )
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 12)
            }
        }
    }

    /// D8: SwiftUI Menu with Status / Provider / Sort sections.
    /// `ModelPicker.swift` is the template pattern for chip-styled menus.
    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Section("Status") {
                ForEach(StatusFilter.allCases, id: \.rawValue) { opt in
                    Button {
                        statusFilterRaw = opt.rawValue
                    } label: {
                        HStack {
                            Text(opt.label)
                            if statusFilter == opt {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section("Provider") {
                Toggle("Claude", isOn: $providerClaudeEnabled)
                Toggle("Codex", isOn: $providerCodexEnabled)
                Toggle("Antigravity", isOn: $providerGeminiEnabled)
                Toggle("OpenCode", isOn: $providerOpenCodeEnabled)  // PR #31
                Toggle("Cursor", isOn: $providerCursorEnabled)
            }
            Section("Sort") {
                ForEach(SortKey.allCases, id: \.rawValue) { opt in
                    Button {
                        sortKeyRaw = opt.rawValue
                    } label: {
                        HStack {
                            Text(opt.label)
                            if sortKey == opt {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            TahoeIcon("filter", size: 13).foregroundStyle(t.fg3).frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter sessions")
    }
}

private struct SidebarIconBtn: View {
    @Environment(\.tahoe) private var t
    var icon: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            TahoeIcon(icon, size: 13).foregroundStyle(t.fg3).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }
}

private struct RepoSection: View {
    @Environment(\.tahoe) private var t
    var repo: TahoeCodeRepo
    var expanded: Bool
    var onToggle: () -> Void
    var openId: UUID?
    var onOpen: (UUID) -> Void
    var onNewSession: () -> Void
    /// PR #35: loopback client threaded down to RecentRow so the
    /// "re-open archived session" action has an RPC to call. Nil =
    /// recents render read-only (Preview path).
    var loopbackClient: AgentControlClient? = nil
    /// v0.22.11: invoked when a JSONL-only RecentRow is tapped. The
    /// parent flips MacCodeView's openJsonlPath; the middle pane
    /// swaps to the read-only transcript preview.
    var onOpenJsonl: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TahoeIcon(expanded ? "chevD" : "chevR", size: 11).foregroundStyle(t.fg3)
                TahoeProjectGlyph(name: repo.name, tint: repo.tint, size: 22)
                Text(repo.name)
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                if repo.liveSessionCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
                            .frame(width: 6, height: 6)
                            .shadow(color: Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), radius: 3, x: 0, y: 0)
                        Text("\(repo.liveSessionCount)")
                            .font(TahoeFont.body(10, weight: .bold))
                            .foregroundStyle(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
                    }
                }
                Spacer()
                if !repo.sessions.isEmpty {
                    Text("\(repo.sessions.count)")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background {
                            Capsule(style: .continuous).fill(t.hair2)
                        }
                }
                Button(action: onNewSession) {
                    TahoeIcon("plus", size: 13).foregroundStyle(t.fg3)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New session in \(repo.name)")
                .opacity(0.55)
            }
            .padding(.horizontal, 4).padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(repo.sessions) { s in
                        SessionRow(session: s, open: openId == s.id, onClick: { onOpen(s.id) })
                    }
                    if !repo.recents.isEmpty {
                        Text("RECENT")
                            .font(TahoeFont.body(10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(t.fg4)
                            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                        ForEach(repo.recents) { r in
                            RecentRow(
                                recent: r,
                                loopbackClient: loopbackClient,
                                onOpenRestored: { onOpen($0) },
                                onOpenJsonl: onOpenJsonl
                            )
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(\.tahoe) private var t
    var session: TahoeCodeSession
    var open: Bool
    var onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 8) {
                TahoeProviderGlyph(provider: session.agent, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        let color = statusColor(session.status)
                        Circle().fill(color).frame(width: 5, height: 5)
                            .shadow(color: session.status == .running ? color : .clear, radius: 3, x: 0, y: 0)
                        Text(session.subtitle)
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                if open {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(t.accentAlpha(t.dark ? 0.18 : 0.12))
                }
            }
            .overlay {
                if open {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(t.accentAlpha(0.35), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
    }

    private func statusColor(_ s: TahoeCodeSession.Status) -> Color {
        switch s {
        case .running:  return Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0)
        case .planning: return t.fg3
        case .paused:   return Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0)
        case .done:     return t.accent
        case .degraded: return Color(.sRGB, red: 1, green: 0x5F/255.0, blue: 0x57/255.0)
        }
    }
}

private struct RecentRow: View {
    @Environment(\.tahoe) private var t
    var recent: TahoeCodeRecent
    /// PR #35: loopback client for the unarchive RPC. Nil when the row
    /// represents a JSONL-only entry (no Clawdmeter session record);
    /// the action becomes a no-op + the row dims to signal that.
    var loopbackClient: AgentControlClient?
    /// PR #35: invoked when the unarchive succeeds; lets the parent
    /// focus the newly-restored session in the right column.
    var onOpenRestored: ((UUID) -> Void)?
    /// v0.22.11: invoked when this is a JSONL-only row (no live
    /// session). The parent flips `openJsonlPath`; the middle pane
    /// renders the read-only transcript preview inline.
    var onOpenJsonl: ((String) -> Void)?

    @State private var isRestoring: Bool = false

    private var canUnarchive: Bool {
        recent.sessionId != nil && loopbackClient != nil
    }

    /// v0.22.11: row tappable when either we can unarchive OR there's a
    /// JSONL path + an `onOpenJsonl` handler to receive it. Previously
    /// (v0.22.9) the fallback was reveal-in-Finder, which the user
    /// flagged as wrong — the desired UX is inline preview.
    private var tappable: Bool {
        canUnarchive || (recent.jsonlPath != nil && onOpenJsonl != nil)
    }

    var body: some View {
        Button(action: restore) {
            HStack(alignment: .top, spacing: 8) {
                // v0.22.14: lock the glyph cell to a fixed 22pt square
                // so the "live" green outline doesn't push the icon out
                // and offset the row's label. Previously the stroke
                // used `.padding(-2)` which extended the ZStack's
                // natural size to 22pt for live rows but left non-live
                // rows at 18pt — rows with different sizes broke the
                // vertical alignment in the sidebar.
                ZStack {
                    TahoeProviderGlyph(provider: recent.provider, size: 18)
                    if recent.live {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recent.title)
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg2)
                        .lineLimit(1)
                    Text("\(recent.provider.displayName) · \(recent.ago)")
                        .font(TahoeFont.body(10))
                        .foregroundStyle(t.fg4)
                }
                Spacer()
                if isRestoring {
                    ProgressView().controlSize(.mini)
                } else if tappable {
                    // chevron hints the row is tappable (its action
                    // restores the archived session or — for JSONL-only
                    // rows — reveals the file on disk).
                    TahoeIcon("chevR", size: 9).foregroundStyle(t.fg4)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .opacity(tappable ? 0.95 : 0.65)
        }
        .buttonStyle(.plain)
        .disabled(!tappable || isRestoring)
        .help(canUnarchive
            ? "Re-open this archived session"
            : (recent.jsonlPath != nil ? "Open this transcript inline" : "Read-only history entry"))
    }

    /// Restore: for a real archived session, calls the daemon's
    /// `POST /sessions/:id/unarchive`. For a JSONL-only row, hands the
    /// path to the parent's `onOpenJsonl` so MacCodeView can flip
    /// `openJsonlPath` and render a read-only transcript preview in
    /// the middle pane (v0.22.11 — previously revealed in Finder).
    private func restore() {
        if let client = loopbackClient,
           let sessionId = recent.sessionId {
            isRestoring = true
            Task { @MainActor in
                await client.unarchiveSession(id: sessionId)
                await client.refreshSessions()
                isRestoring = false
                onOpenRestored?(sessionId)
            }
            return
        }
        if let path = recent.jsonlPath, let handler = onOpenJsonl {
            handler(path)
        }
    }
}

// MARK: - Thread

private struct Thread: View {
    @Environment(\.tahoe) private var t
    var session: TahoeCodeSession?
    var state: MacCodeView.ComposerState
    var isDemo: Bool
    /// PR #24a wires propagated down to PlanHalo for real plan
    /// approve/refine actions.
    var onApprovePlan: () -> Void = {}
    var onRefinePlan: () -> Void = {}
    var canAct: Bool = false
    /// v0.22.11: read-only transcript preview rendered when the user
    /// clicks a JSONL-only "RECENT" row in the sidebar (no live
    /// AgentSession to drive the regular stream). When non-nil this
    /// takes precedence over the EmptyThreadState / demo / placeholder
    /// branches. Loaded by the parent MacCodeView via
    /// `TranscriptLoader.load(from:URL(fileURLWithPath:openJsonlPath))`.
    var previewTranscript: [ChatMessage]?
    /// Path being previewed — surfaced in the empty-state copy so the
    /// user knows which file is loading when `previewTranscript` is
    /// still empty (load is async).
    var previewJsonlPath: String?

    /// Whether the open session has a real plan from the agent. Drives
    /// whether the PlanHalo renders at all in production — empty plan +
    /// `state == .plan` would otherwise dangle a Refine/Approve card with
    /// no underlying plan content.
    private var hasRealPlan: Bool {
        guard let raw = session?.runtimePlanText else { return false }
        return !raw.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let transcript = previewTranscript {
                    JsonlPreviewHeader(path: previewJsonlPath)
                    if transcript.isEmpty {
                        // Async load in flight — show a tiny spinner row
                        // rather than an empty pane so the user knows the
                        // tap registered.
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading transcript…").font(TahoeFont.body(12)).foregroundStyle(t.fg3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(Array(transcript.enumerated()), id: \.offset) { _, msg in
                            JsonlPreviewMsg(msg: msg)
                        }
                    }
                } else if session == nil {
                    EmptyThreadState()
                } else if isDemo {
                    // Demo bindings keep the JSX fixture so Previews remain
                    // visually rich.
                    ForEach(Array(TahoeDemo.thread.enumerated()), id: \.offset) { _, msg in
                        ThreadMsg(msg: msg, providerOverride: session?.agent)
                    }
                } else {
                    // Production: the live message stream isn't piped to
                    // the IDE yet. Render a placeholder instead of
                    // pretending the JSX fixture is real activity.
                    LiveStreamPlaceholder()
                }
                if state == .running { RunningRow(providerOverride: session?.agent, isDemo: isDemo) }
                if state == .plan, (isDemo || hasRealPlan) {
                    PlanHalo(
                        session: session,
                        isDemo: isDemo,
                        onApprove: onApprovePlan,
                        onRefine: onRefinePlan,
                        canAct: canAct
                    )
                }
            }
            .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 18)
        }
    }
}

/// v0.22.11: header strip rendered above a JSONL preview transcript.
/// Mirrors `ThreadHeader` but communicates the read-only nature of the
/// view so the user doesn't expect the composer to send into the
/// preview (it won't — there's no live AgentSession to send to).
private struct JsonlPreviewHeader: View {
    @Environment(\.tahoe) private var t
    var path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TahoeIcon("folder", size: 12).foregroundStyle(t.fg4)
                Text("Read-only transcript preview")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                Spacer()
                if let path {
                    Button {
                        let url = URL(fileURLWithPath: path)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        HStack(spacing: 4) {
                            TahoeIcon("folder", size: 10)
                            Text("Reveal in Finder").font(TahoeFont.body(11))
                        }
                        .foregroundStyle(t.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let path {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(TahoeFont.mono(11))
                    .foregroundStyle(t.fg4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 8)
    }
}

/// v0.22.31: chat-like renderer for the JSONL preview transcript.
/// Was: verbose 2-line role-prefixed dump of every tool call/result
/// chunk including Chunk ID / Wall time / Process exited / Original
/// token count noise. Now: compact collapsed cards that match the
/// live MacChatView shape — tool calls fold into a one-line summary
/// with a disclosure for the full body, user/assistant turns become
/// bubble rows. User reported "render smoothly and be as performative
/// as a regular messaging chat session" — this is that.
private struct JsonlPreviewMsg: View {
    @Environment(\.tahoe) private var t
    let msg: ChatMessage
    @State private var expanded: Bool = false

    var body: some View {
        switch msg.kind {
        case .userText:      userBubble
        case .assistantText: assistantBubble
        case .toolCall:      toolCard(isResult: false)
        case .toolResult:    toolCard(isResult: true)
        case .meta:          metaRow
        }
    }

    // MARK: - User / Assistant bubbles

    private var userBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 60)
            Text(ClawdmeterMac_displaySkillInvocations(in: msg.body))
                .font(TahoeFont.body(13))
                .foregroundStyle(t.fg)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(t.accentAlpha(0.18))
                }
                .frame(maxWidth: 540, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.fg3)
                .frame(width: 18, height: 18)
                .padding(.top, 4)
            Text(msg.body)
                .font(TahoeFont.body(13))
                .foregroundStyle(t.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 30)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Tool call / result (compact card, expandable)

    @ViewBuilder
    private func toolCard(isResult: Bool) -> some View {
        let isError = msg.isError
        let summary = compactSummary(isResult: isResult)
        Button {
            withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: isResult
                          ? (isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                          : "wrench.and.screwdriver.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isError ? .red : (isResult ? .green : t.fg3))
                    Text(headerLabel(isResult: isResult))
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.3)
                        .foregroundStyle(t.fg3)
                    Spacer(minLength: 8)
                    Text(summary)
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(t.fg4)
                }
                if expanded {
                    Text(cleanedBody)
                        .font(TahoeFont.mono(11.5))
                        .foregroundStyle(isError ? .red : t.fg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(t.glassTintHi.opacity(0.5))
                        }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(t.hair2.opacity(0.6))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(t.fg4)
            Text(msg.body)
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg4)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Body cleanup

    /// Strip JSONL/transcript boilerplate ("Chunk ID:", "Wall time:",
    /// "Process exited", "Original token count:", "Output:") that the
    /// CLIs sometimes prepend to tool results. The user's screenshot
    /// flagged these as noise. Keeps the meaningful payload only.
    private var cleanedBody: String {
        let lines = msg.body.split(separator: "\n", omittingEmptySubsequences: false)
        let noise = [
            "Chunk ID:", "Wall time:", "Process exited", "Original token count:",
            "Output:", "Total output lines:"
        ]
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            for marker in noise where trimmed.hasPrefix(marker) {
                return false
            }
            return true
        }
        return kept.joined(separator: "\n")
    }

    /// One-line summary shown next to the header — the first
    /// meaningful line of detail (preferred) or body so the row is
    /// scannable without expansion.
    private func compactSummary(isResult: Bool) -> String {
        if let detail = msg.detail, !detail.isEmpty {
            return detail.split(separator: "\n").first.map(String.init) ?? detail
        }
        for line in cleanedBody.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private func headerLabel(isResult: Bool) -> String {
        // `title` carries the tool name when populated; fall back to a
        // generic label otherwise.
        let baseLabel = isResult ? "Result" : (msg.title.isEmpty ? "Tool call" : msg.title)
        return baseLabel.uppercased()
    }
}

private struct LiveStreamPlaceholder: View {
    @Environment(\.tahoe) private var t
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            TahoeIcon("chat", size: 22).foregroundStyle(t.fg4)
            Text("Live transcript coming soon")
                .font(TahoeFont.body(13, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Session metadata above is live. The streamed message thread will appear here once the daemon bridge ships.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

private struct EmptyThreadState: View {
    @Environment(\.tahoe) private var t
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            TahoeIcon("chat", size: 22).foregroundStyle(t.fg4)
            Text("No session selected")
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Pick a session from the sidebar, or start a new one in any repo.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct ThreadMsg: View {
    @Environment(\.tahoe) private var t
    var msg: TahoeDemo.DemoThreadMsg
    /// Optional real provider so the demo bubble at least matches the
    /// real session's agent in Previews where mixed-agent threads matter.
    var providerOverride: TahoeProvider?
    var body: some View {
        switch msg {
        case .user(let text):
            // JSX caps user bubble at maxWidth 78% of the parent column.
            // Use a GeometryReader so the cap scales with the actual thread
            // column width instead of the hard 580pt cap from v1.
            GeometryReader { geo in
                HStack {
                    Spacer()
                    TahoeGlass(radius: 20, tone: .raised) {
                        Text(text)
                            .font(TahoeFont.body(13))
                            .foregroundStyle(t.fg)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: geo.size.width * 0.78, alignment: .trailing)
                }
            }
            .frame(minHeight: 44)
            .fixedSize(horizontal: false, vertical: true)
        case .tool(let tool, let target, let detail):
            HStack(alignment: .top, spacing: 10) {
                Spacer().frame(width: 36)
                TahoePill {
                    HStack(spacing: 8) {
                        TahoeIcon(tool == "grep" ? "search" : "doc", size: 11).foregroundStyle(t.fg2)
                        Text(tool).font(TahoeFont.body(11.5, weight: .semibold)).foregroundStyle(t.fg2)
                        Text(target).font(TahoeFont.mono(11)).foregroundStyle(t.fg3)
                        Text("· \(detail)").font(TahoeFont.body(11)).foregroundStyle(t.fg4)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 5)
                }
                Spacer()
            }
        case .assistant(let text):
            HStack(alignment: .top, spacing: 12) {
                TahoeProviderGlyph(provider: providerOverride ?? .claude, size: 26)
                Text(text)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Spacer()
            }
        }
    }
}

private struct RunningRow: View {
    @Environment(\.tahoe) private var t
    var providerOverride: TahoeProvider?
    var isDemo: Bool
    var body: some View {
        HStack(spacing: 12) {
            TahoeProviderGlyph(provider: providerOverride ?? .claude, size: 26)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(t.accent)
                if isDemo {
                    Text("Editing ")
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg2)
                    + Text("settlement-store.ts")
                        .font(TahoeFont.mono(12.5))
                        .foregroundStyle(t.fg)
                } else {
                    Text("Working…")
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg2)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Plan Halo

private struct PlanHalo: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var auraGlow: Bool = false
    var session: TahoeCodeSession?
    var isDemo: Bool
    /// Wires set by MacCodeView. In production they call
    /// `loopbackClient.approvePlan(sessionId:)` / open the Refine modal.
    /// Default `{}` keeps SwiftUI Previews and demo bindings working.
    var onApprove: () -> Void = {}
    /// Both "Refine" and "Edit plan" buttons fire this (A3: Edit plan =
    /// Refine via the same `sendPrompt` wire).
    var onRefine: () -> Void = {}
    /// True when the action wires are reachable. False disables the
    /// Approve & run button so users don't tap into a no-op.
    var canAct: Bool = false

    /// Parse `session.planText` into discrete plan steps when available.
    /// In demo mode, falls back to the JSX fixture plan; in production,
    /// the parent Thread view already guards on `hasRealPlan` so this
    /// branch shouldn't reach an empty list — but keep the guard as a
    /// belt-and-braces empty array rather than fixture data.
    private var planSteps: [String] {
        if let session,
           let parsed = parsePlanText(for: session),
           !parsed.isEmpty {
            return parsed
        }
        return isDemo ? TahoeDemo.plan : []
    }

    private func parsePlanText(for session: TahoeCodeSession) -> [String]? {
        guard let raw = session.runtimePlanText, !raw.isEmpty else { return nil }
        let lines = TahoePlanParser.steps(from: raw, cap: 8)
        return lines.isEmpty ? nil : lines
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(RadialGradient(
                    colors: [t.accentGlow.color(opacity: t.muted ? 0.10 : 0.30), .clear],
                    center: .init(x: 0.5, y: 0.3),
                    startRadius: 0, endRadius: 600))
                .blur(radius: 8)
                .padding(-28)
                .allowsHitTesting(false)
                // Motion polish: subtle aura breath, held static for Reduce Motion.
                .opacity(reduceMotion ? 0.90 : (auraGlow ? 1.0 : 0.85))
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: auraGlow)
                .onAppear {
                    guard !reduceMotion else { return }
                    auraGlow = true
                }
                .onChange(of: reduceMotion) { _, newValue in
                    auraGlow = !newValue
                }

            TahoeGlass(radius: 20, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 28, height: 28)
                            .overlay {
                                TahoeIcon("sparkles", size: 14).foregroundStyle(.white)
                            }
                            .shadow(color: t.accentDeep.color(opacity: 0.35), radius: 6, x: 0, y: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("PLAN READY · REVIEW BEFORE RUN")
                                .font(TahoeFont.body(11.5, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(t.fg3)
                            Text("\(planSteps.count) step\(planSteps.count == 1 ? "" : "s")")
                                .font(TahoeFont.body(14, weight: .bold))
                                .foregroundStyle(t.fg)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(planSteps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.hair2)
                                    Text("\(i+1)")
                                        .font(TahoeFont.mono(11, weight: .bold))
                                        .foregroundStyle(t.fg2)
                                }
                                .frame(width: 20, height: 20)

                                Text(step)
                                    .font(TahoeFont.body(13))
                                    .foregroundStyle(t.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 14)

                    TahoeHair()

                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .m, action: onRefine) {
                            HStack(spacing: 5) {
                                TahoeIcon("chat", size: 11)
                                Text("Refine")
                            }
                        }
                        TahoeGhostButton(size: .m, action: onRefine) {
                            Text("Edit plan")
                        }
                        Spacer()
                        // Only show the "Will commit to <branch>" hint when
                        // there's a real commit branch (worktree session) or
                        // we're rendering the demo fixture. Local production
                        // sessions show no hint rather than the JSX literal.
                        if let branch = session?.commitBranch, !branch.isEmpty {
                            HStack(spacing: 4) {
                                TahoeIcon("branch", size: 10)
                                Text("Will commit to ")
                                + Text(branch).font(TahoeFont.mono(11)).foregroundColor(t.fg2)
                            }
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                        } else if isDemo {
                            HStack(spacing: 4) {
                                TahoeIcon("branch", size: 10)
                                Text("Will commit to ")
                                + Text("fix/settlement-dedupe").font(TahoeFont.mono(11)).foregroundColor(t.fg2)
                            }
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                        }
                        // PR #24a: Approve & run now reaches the daemon via
                        // loopback. Enabled when `canAct` is true (Mac has
                        // a live loopback client). Demo bindings stay
                        // enabled too so Previews render the button as
                        // interactive.
                        TahoeAccentButton(size: .m, action: onApprove) {
                            HStack(spacing: 8) {
                                Text("Approve & run")
                                Text("\u{21E7}\u{23CE}").opacity(0.7).fontWeight(.regular)
                            }
                        }
                        .opacity((isDemo || canAct) ? 1.0 : 0.5)
                        .disabled(!(isDemo || canAct))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
        }
        .padding(.top, 6)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Composer

private struct ComposerBar: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var state: MacCodeView.ComposerState
    /// Demo bindings keep the JSX literal placeholder text and the
    /// LiveTicker fixture. Production composer shows a neutral prompt and
    /// hides the fake cost-ticker until the real one is wired.
    var isDemo: Bool
    /// Whether the open session has a real plan from the agent. When false
    /// in production, the chip label stays "autopilot" rather than "plan"
    /// since there's nothing to refine.
    var hasRealPlan: Bool
    var session: TahoeCodeSession?
    var client: AgentControlClient?
    var onCycle: () -> Void
    /// PR #24a: real send/stop wires. When non-nil they override the
    /// demo `onCycle` state-cycler. Production passes both; demo bindings
    /// leave them nil to preserve the JSX cycle UX.
    var onSend: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    /// Composer text binding. Owned by `ComposerSendController` upstream;
    /// the TextField writes through here.
    var composerText: Binding<String>? = nil
    /// Disable the send button while a send is in flight.
    var sending: Bool = false
    @State private var pulse: Bool = false
    // Slash-command (skills) palette — typing `/` at the start of a line in
    // the Code chat box brings up the installed Claude Code skills, mirroring
    // the older ComposerInputCore composer. SkillCatalog.shared walks
    // ~/.claude/skills (+ Codex built-ins for Codex sessions).
    @ObservedObject private var skillCatalog = SkillCatalog.shared
    @State private var showSlashPalette = false
    @State private var slashQuery = ""

    var body: some View {
        let running = state == .running
        let planMode = state == .plan

        VStack(spacing: 0) {
            TahoeGlass(radius: 18, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let composerText {
                            // PR #24a: real TextField bound to
                            // ComposerSendController.text. Submit on
                            // Enter when not running.
                            TextField(
                                placeholder(running: running, plan: planMode),
                                text: composerText,
                                axis: .vertical
                            )
                            .textFieldStyle(.plain)
                            .font(TahoeFont.body(14))
                            .foregroundStyle(t.fg)
                            .lineLimit(1...6)
                            .disabled(running || sending)
                            .opacity(running ? 0.55 : 1)
                            .onSubmit { onSend?() }
                        } else {
                            Text(placeholder(running: running, plan: planMode))
                                .font(TahoeFont.body(14))
                                .foregroundStyle(t.fg3)
                                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                                .opacity(running ? 0.55 : 1)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)

                    HStack(spacing: 6) {
                        // v0.22.9: chips are now actually clickable.
                        // The model + autopilot chips host SwiftUI
                        // Menus; paperclip/code/mic open NSOpenPanel /
                        // insert a fenced-code snippet / start macOS
                        // dictation respectively. Previously every chip
                        // was a static label with no action — the user
                        // reported "all of them are broken".
                        modelMenu

                        planModeMenu

                        TahoeComposerChip(icon: "paperclip", action: { Self.attachFile(into: composerText) })
                        TahoeComposerChip(icon: "code", action: { Self.insertCodeBlock(into: composerText) })
                        TahoeComposerChip(icon: "mic", action: { Self.openDictation() })
                        Spacer()
                        if running {
                            // PR #24a: LiveTicker stop now calls real
                            // `interruptSession` when wired (onStop != nil);
                            // demo bindings keep the cycle fallback.
                            LiveTicker(onStop: { (onStop ?? onCycle)() }, isDemo: isDemo)
                        } else {
                            SendButton(planMode: planMode, action: { (onSend ?? onCycle)() })
                                .opacity(sending ? 0.6 : 1.0)
                                .disabled(sending)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 6)
                }
            }
            .overlay {
                if running {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(t.accentAlpha(0.45), lineWidth: 1)
                        .shadow(color: t.accentAlpha(0.30), radius: 11, x: 0, y: 0)
                        // Motion polish: running-state rim pulse, held static for Reduce Motion.
                        .opacity(reduceMotion ? 0.85 : (pulse ? 1.0 : 0.7))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                        .onAppear {
                            guard !reduceMotion else { return }
                            pulse = true
                        }
                        .onDisappear { pulse = false }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state)
            .onChange(of: reduceMotion) { _, newValue in
                if newValue { pulse = false }
            }
            .onChange(of: composerText?.wrappedValue ?? "") { _, newText in
                updateSlashTrigger(newText)
            }
            .onAppear { skillCatalog.refreshIfStale() }
            // Palette floats flush ABOVE the composer, attached HERE — outside
            // the inner TahoeGlass, whose `.clipShape` was clipping (hiding) it
            // when it sat inside. `alignmentGuide(.top){ $0[.bottom] }` shifts
            // it up by its own height so it opens right where the user types.
            .overlay(alignment: .topLeading) {
                if showSlashPalette, composerText != nil {
                    CommandPaletteView(
                        catalog: skillCatalog,
                        agent: paletteAgent,
                        query: $slashQuery,
                        onSelect: applyPaletteSelection,
                        onDismiss: { showSlashPalette = false }
                    )
                    .alignmentGuide(VerticalAlignment.top) { $0[.bottom] }
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
    }

    // MARK: - Slash-command (skills) palette

    /// The session's agent mapped to AgentKind so the palette filters to the
    /// right command set (Claude skills vs Codex built-ins). The idle/empty
    /// composer (no session yet) defaults to Claude so the skill list shows.
    private var paletteAgent: AgentKind {
        guard let prov = session?.agent else { return .claude }
        return AgentKind.allCases.first { $0.tahoeProvider == prov } ?? .claude
    }

    /// Show the palette while the composer's last line starts with `/`.
    private func updateSlashTrigger(_ text: String) {
        if let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last,
           lastLine.hasPrefix("/") {
            slashQuery = String(lastLine.dropFirst())
            showSlashPalette = true
        } else {
            showSlashPalette = false
        }
    }

    /// Replace the trailing `/query` line with `/<cmd.id> ` and keep focus so
    /// the user can add arguments before sending (Enter runs it). We do NOT
    /// auto-send — skills like `/code-review high` take arguments.
    private func applyPaletteSelection(_ cmd: PaletteCommand) {
        guard let composerText else { showSlashPalette = false; return }
        var lines = composerText.wrappedValue
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !lines.isEmpty { lines.removeLast() }
        lines.append("/\(cmd.id) ")
        composerText.wrappedValue = lines.joined(separator: "\n")
        showSlashPalette = false
        slashQuery = ""
    }

    // MARK: - v0.22.9: composer chip helpers

    /// Open NSOpenPanel and insert `@/absolute/path` into the composer
    /// text. Mirrors the iOS attach behavior + the existing `@path`
    /// token convention the agent's prompt parser handles.
    private static func attachFile(into composerText: Binding<String>?) {
        guard let composerText else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canResolveUbiquitousConflicts = true
        panel.title = "Attach files"
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            let mentions = panel.urls
                .map { "@\($0.path)" }
                .joined(separator: " ")
            if composerText.wrappedValue.isEmpty {
                composerText.wrappedValue = "\(mentions) "
            } else if composerText.wrappedValue.hasSuffix(" ") {
                composerText.wrappedValue += "\(mentions) "
            } else {
                composerText.wrappedValue += " \(mentions) "
            }
        }
    }

    /// Append a fenced code-block template to the composer so the user
    /// can paste a snippet without remembering the backtick fences.
    private static func insertCodeBlock(into composerText: Binding<String>?) {
        guard let composerText else { return }
        let stub = composerText.wrappedValue.isEmpty
            ? "```\n\n```\n"
            : "\n\n```\n\n```\n"
        composerText.wrappedValue += stub
    }

    /// macOS dictation isn't directly toggleable from a sandboxed-app
    /// API, but Keyboard preferences carries the user's enable +
    /// shortcut config. Open that pane so the user can verify dictation
    /// is on + see the trigger keystroke. (Future: integrate
    /// `SFSpeechRecognizer` for in-app dictation.)
    private static func openDictation() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var modelMenu: some View {
        Menu {
            if let agentSession {
                Section("Active model") {
                    Text(currentModelLabel).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(modelEntries) { entry in
                    Button {
                        Task { await changeModel(to: entry) }
                    } label: {
                        Label(entry.displayName, systemImage: isCurrentModel(entry) ? "checkmark" : "")
                    }
                }
            } else {
                Text("Open a live session")
                    .foregroundStyle(.secondary)
            }
        } label: {
            TahoeComposerChip(icon: "sparkles", label: currentModelLabel, caret: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(agentSession == nil || modelEntries.isEmpty || cursorSwapUnavailable)
    }

    @ViewBuilder
    private var planModeMenu: some View {
        Menu {
            Button(action: { Task { await setPlanMode(false) } }) {
                Label("Autopilot", systemImage: state == .plan ? "circle" : "checkmark.circle.fill")
            }
            Button(action: { Task { await setPlanMode(true) } }) {
                Label("Plan mode", systemImage: state == .plan ? "checkmark.circle.fill" : "circle")
            }
        } label: {
            TahoeComposerChip(icon: "bolt", label: state == .plan ? "plan" : "autopilot", caret: true, tinted: state != .plan)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(agentSession == nil || cursorSwapUnavailable)
    }

    private var agentSession: AgentSession? {
        guard let id = session?.id else { return nil }
        return client?.sessions.first { $0.id == id }
    }

    private var currentModelLabel: String {
        guard let session else { return "Model" }
        if let model = agentSession?.model,
           let entry = client?.modelCatalog.entry(forId: model) ?? ModelCatalog.bundled.entry(forId: model) {
            return entry.displayName
        }
        return session.model
    }

    private var modelEntries: [ModelCatalogEntry] {
        guard let agent = agentSession?.agent else { return [] }
        let catalog = client?.modelCatalog ?? .bundled
        switch agent {
        case .claude: return catalog.claude
        case .codex: return catalog.codex
        case .gemini: return catalog.gemini
        case .opencode: return catalog.opencode
        case .cursor: return catalog.cursor
        case .grok: return catalog.grok
        case .unknown: return []
        }
    }

    private func isCurrentModel(_ entry: ModelCatalogEntry) -> Bool {
        guard let raw = agentSession?.model else { return false }
        return raw == entry.id || raw == entry.cliAlias
    }

    @MainActor
    private func changeModel(to entry: ModelCatalogEntry) async {
        guard let agentSession, let client else { return }
        guard !cursorSwapUnavailable else { return }
        _ = await client.changeModel(
            sessionId: agentSession.id,
            request: ChangeModelRequest(model: entry.cliAlias ?? entry.id, effort: agentSession.effort)
        )
    }

    @MainActor
    private func setPlanMode(_ enabled: Bool) async {
        guard let agentSession, let client else {
            if (enabled && state != .plan) || (!enabled && state == .plan) {
                onCycle()
            }
            return
        }
        guard !cursorSwapUnavailable else { return }
        if await client.changeMode(sessionId: agentSession.id, mode: agentSession.mode, planMode: enabled) != nil {
            state = enabled ? .plan : .idle
        }
    }

    private var cursorSwapUnavailable: Bool {
        guard let agentSession, agentSession.agent == .cursor else { return false }
        let candidate = agentSession.runtimeBinding?.externalSessionId
            ?? agentSession.runtimeBinding?.externalThreadId
        return candidate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private func placeholder(running: Bool, plan: Bool) -> String {
        if plan {
            return isDemo
                ? "Refine the plan above… (e.g. \"skip the migration step, just add the test\")"
                : (hasRealPlan ? "Refine the plan above…" : "Ask anything. Use / for skills, @ for files.")
        }
        if running {
            return isDemo
                ? "Editing settlement-store.ts — send a follow-up…"
                : "Working — send a follow-up…"
        }
        return "Ask anything. Use / for skills, @ for files."
    }
}

private struct SendButton: View {
    @Environment(\.tahoe) private var t
    var planMode: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(planMode ? AnyShapeStyle(t.hair2)
                                       : AnyShapeStyle(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                                      startPoint: .top, endPoint: .bottom)))
                TahoeIcon("arrowU", size: 15, weight: .bold)
                    .foregroundStyle(planMode ? t.fg4 : .white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: planMode ? .clear : t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(planMode)
    }
}

private struct LiveTicker: View {
    @Environment(\.tahoe) private var t
    var onStop: () -> Void
    /// Demo bindings keep the JSX `$0.124 / 2.3k tok/s` fixture. Production
    /// shows a neutral "live" pill until the real cost/tok stream wire ships.
    var isDemo: Bool

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(t.dark ? Color.white.opacity(0.92) : Color(.sRGB, red: 21.0/255, green: 23.0/255, blue: 27.0/255))
                    TahoeIcon("stop", size: 9).foregroundStyle(t.dark ? Color(.sRGB, red: 21.0/255, green: 23.0/255, blue: 27.0/255) : .white)
                }
                .frame(width: 26, height: 26)
                .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if isDemo {
                            Text("$0.124")
                                .font(TahoeFont.mono(12.5, weight: .bold))
                                .foregroundStyle(t.fg)
                        } else {
                            Text("Stop")
                                .font(TahoeFont.body(12.5, weight: .bold))
                                .foregroundStyle(t.fg)
                        }
                        Text("● live")
                            .font(TahoeFont.body(10.5, weight: .semibold))
                            .foregroundStyle(t.accent)
                    }
                    if isDemo {
                        Text("2.3k tok/s · 14s elapsed")
                            .font(TahoeFont.body(10))
                            .monospacedDigit()
                            .foregroundStyle(t.fg3)
                    } else {
                        Text("session running")
                            .font(TahoeFont.body(10))
                            .foregroundStyle(t.fg3)
                    }
                }
            }
            .padding(.leading, 4).padding(.trailing, 10)
            .frame(height: 34)
            .background {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [t.accentAlpha(0.18), t.accentAlpha(0.10)],
                                         startPoint: .leading, endPoint: .trailing))
            }
            .overlay {
                Capsule(style: .continuous).stroke(t.accentAlpha(0.40), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Review pane

private struct ReviewPane: View {
    @Environment(\.tahoe) private var t
    @Binding var tab: MacCodeView.ReviewTab
    var session: TahoeCodeSession?
    /// Demo bindings still expose JSX fixture content for the Diff /
    /// Sources / PR / Term tabs (used by SwiftUI Previews). Production
    /// (`!isDemo`) shows all 5 tabs too — they embed the existing
    /// in-process Mac views (GitDiffPane, SourcesPane, PRReviewPane,
    /// MacTerminalView) per X1 / PR #24b.
    var isDemo: Bool
    /// Mac runtime — when present, ReviewPane embeds the real
    /// in-process views. Nil falls back to the demo placeholders so
    /// Previews keep working.
    var runtime: AppRuntime?
    /// v0.22.31: JSONL preview transcript — when non-nil, the user
    /// opened a rollout from disk rather than a live AgentSession.
    /// Right-pane tabs derive Plan / Diff / Sources / PR data from
    /// this transcript instead of looking up an AgentSession by id.
    var previewTranscript: [ChatMessage]?
    /// Path on disk for the JSONL preview — used to surface the file
    /// in the empty-state copy and to resolve the rollout's cwd for
    /// the Diff tab.
    var previewJsonlPath: String?

    /// All 5 tabs visible in both demo and production after PR #24b.
    private var visibleTabs: [(MacCodeView.ReviewTab, String, String)] {
        [
            (.plan, "Plan", "doc"),
            (.diff, "Diff", "diff"),
            (.sources, "Sources", "search"),
            (.pr, "PR", "pull"),
            (.term, "Term", "terminal"),
        ]
    }

    /// Resolve the open session's `AgentSession` (the registry shape
    /// the in-process Mac views expect) from the loopback client.
    /// Returns nil when the session was archived mid-view or runtime is
    /// nil. The fallback content surfaces "Session unavailable".
    @MainActor
    private func agentSession() -> AgentSession? {
        guard let runtime, let id = session?.id else { return nil }
        return runtime.loopbackClient?.sessions.first(where: { $0.id == id })
            ?? runtime.agentSessionRegistry.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(visibleTabs, id: \.0) { tb in
                    let active = tab == tb.0
                    Button {
                        // v0.22.14: animation-disabling transaction so
                        // the active-pill swap is instant. Without it
                        // SwiftUI's default animation on the @Binding
                        // change made the tab feel laggy.
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { tab = tb.0 }
                    } label: {
                        HStack(spacing: 5) {
                            TahoeIcon(tb.2, size: 12)
                            Text(tb.1)
                        }
                        .font(TahoeFont.body(11.5, weight: active ? .bold : .semibold))
                        .foregroundStyle(active ? t.fg : t.fg3)
                        .padding(.horizontal, 0)
                        // DESIGN.md Review Pane: each tab is exactly 30px high.
                        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                        // v0.22.14: explicit hit shape so the whole
                        // pill is tappable. Without this, taps fell
                        // through the spacing between the icon and
                        // label.
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .background {
                            if active {
                                // DESIGN.md: active tab fill white@10% (dark) / #fff
                                // (light) with `0 1px 2px black@10%, 0 0 0 0.5px black@8%`.
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                                    .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                                    )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)

            TahoeHair()

            if let provisioning = agentSession()?.provisioning {
                filesToCopyAudit(provisioning.filesToCopy)
                TahoeHair()
            }

            ScrollView {
                Group {
                    switch tab {
                    case .plan:    planTab
                    case .diff:    diffTab
                    case .sources: sourcesTab
                    case .pr:      prTab
                    case .term:    termTab
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filesToCopyAudit(_ summary: WorktreeFileCopySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TahoeIcon("folder", size: 11, weight: .semibold)
                    .foregroundStyle(t.accent)
                Text("Files to copy")
                    .font(TahoeFont.body(11, weight: .bold))
                    .foregroundStyle(t.fg)
                Text(summary.source.rawValue)
                    .font(TahoeFont.body(10, weight: .semibold))
                    .foregroundStyle(t.fg3)
                Spacer(minLength: 0)
                Text("\(summary.copiedFileCount) files · \(summary.copiedDirectoryCount) dirs · \(summary.skippedFileCount) skipped")
                    .font(TahoeFont.body(10))
                    .foregroundStyle(t.fg4)
            }
            Text(filesToCopyDescription(summary))
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg3)
                .lineLimit(2)
            if let failure = summary.failureSummary, !failure.isEmpty {
                Text(failure)
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let manifest = summary.manifestPath {
                Text("manifest: \(manifest)")
                    .font(TahoeFont.body(10))
                    .foregroundStyle(t.fg4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Real-view embeds (PR #24b D9 + X1, + v0.22.31 JSONL preview wires)

    /// v0.22.31: Plan tab — uses session.runtimePlanText for live
    /// sessions; for JSONL preview, falls back to TranscriptPlanExtract
    /// which scans the transcript for plan-shaped assistant turns.
    @ViewBuilder
    private var planTab: some View {
        if session?.runtimePlanText?.isEmpty == false || isDemo {
            ReviewPlan(session: session, isDemo: isDemo)
        } else if let transcript = previewTranscript {
            JsonlPlanTab(transcript: transcript)
        } else {
            ReviewPlan(session: session, isDemo: isDemo)
        }
    }

    private func filesToCopyDescription(_ summary: WorktreeFileCopySummary) -> String {
        if summary.source == .disabled { return "(disabled)" }
        if summary.mode == .allIgnored {
            return "all ignored files, directories, dependencies, build artifacts, and local databases"
        }
        return summary.patterns.isEmpty ? "(no patterns)" : summary.patterns.joined(separator: ", ")
    }

    @ViewBuilder
    private var diffTab: some View {
        if let agentSession = agentSession() {
            GitDiffPane(repoCwd: agentSession.effectiveCwd)
        } else if let cwd = previewCwd() {
            // v0.22.31: JSONL preview — embed GitDiffPane against the
            // rollout's cwd (parsed from the meta line).
            GitDiffPane(repoCwd: cwd.path)
        } else if isDemo {
            ReviewDiff()
        } else {
            placeholder(title: "Diff unavailable",
                        body: "Open a session with a worktree to see the live `git diff HEAD`.")
        }
    }

    @ViewBuilder
    private var sourcesTab: some View {
        if let runtime,
           let agentSession = agentSession(),
           let chatStore = runtime.agentControlServer.chatStore(for: agentSession) {
            SourcesPane(session: agentSession, chatStore: chatStore)
        } else if let transcript = previewTranscript {
            // v0.22.31: JSONL preview — list files referenced in tool
            // calls (Bash / Read / Write / Edit). No live store needed.
            JsonlSourcesTab(transcript: transcript, cwd: previewCwd())
        } else if isDemo {
            ReviewSources()
        } else {
            placeholder(title: "Sources unavailable",
                        body: "Waiting for the session's transcript to materialize.")
        }
    }

    @ViewBuilder
    private var prTab: some View {
        if let runtime, let agentSession = agentSession() {
            PRReviewPane(
                session: agentSession,
                coordinator: runtime.sessionsModel.prCoordinator(for: agentSession),
                onBeforeMerge: nil
            )
        } else if let transcript = previewTranscript {
            // v0.22.31: JSONL preview — scan transcript for github
            // pull-request URLs and surface them as taps to open.
            JsonlPRTab(transcript: transcript)
        } else if isDemo {
            ReviewPR()
        } else {
            placeholder(title: "No PR detected",
                        body: "The agent hasn't surfaced a GitHub PR URL in this session yet.")
        }
    }

    @ViewBuilder
    private var termTab: some View {
        if let runtime,
           let agentSession = agentSession(),
           let wsPort = runtime.agentControlServer.boundWsPort {
            MacTerminalView(
                sessionId: agentSession.id,
                host: "127.0.0.1",
                wsPort: Int(wsPort),
                token: runtime.agentControlServer.localLoopbackToken,
                paneId: nil
            )
            // SwiftTerm wraps an NSView and ignores .frame heights from
            // the wrapping VStack; force a minimum so it doesn't collapse
            // to zero height inside the ReviewPane scroll container.
            .frame(minHeight: 320)
            .id(agentSession.id) // recreate on session swap
        } else if isDemo {
            ReviewTerm()
        } else if let transcript = previewTranscript {
            // v0.22.33: JSONL preview — there's no live tmux to attach
            // to, but the rollout has every Bash/shell tool call + its
            // output stored. Replay them as a terminal-shaped scroll
            // so the user sees the agent's actual command history.
            JsonlTermTab(transcript: transcript)
        } else {
            placeholder(title: "Terminal unavailable",
                        body: "Open a session to see live agent output.")
        }
    }

    /// v0.22.31: extract the working directory from the JSONL preview's
    /// first meta line. Codex rollouts include `cwd` in the meta dict;
    /// Claude Code logs include `cwd` too. Returns nil when not present
    /// so the caller falls back to the unavailable placeholder.
    private func previewCwd() -> URL? {
        guard let path = previewJsonlPath else { return nil }
        // Heuristic: the parent directory of the rollout file is
        // usually `~/.codex/sessions/YYYY/MM/DD/` which is NOT the
        // session's working directory. But the meta line itself has
        // `cwd` populated. Scan the transcript's first meta msg.
        if let metaCwd = previewTranscript?.first(where: { $0.kind == .meta })?.detail,
           !metaCwd.isEmpty {
            return URL(fileURLWithPath: metaCwd, isDirectory: true)
        }
        // Fallback: nil. Don't fabricate a path.
        _ = path
        return nil
    }

    @ViewBuilder
    private func placeholder(title: String, body: String) -> some View {
        VStack(alignment: .center, spacing: 8) {
            TahoeIcon("chat", size: 22).foregroundStyle(t.fg4)
            Text(title)
                .font(TahoeFont.body(13, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text(body)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - JSONL preview tab content (v0.22.31)

/// Plan tab content derived from a JSONL transcript. Scans the
/// transcript for assistant messages that look like a plan (numbered
/// list, dash-prefixed steps, or "## Plan"/"Plan:" headers) and
/// surfaces them as a step list. Falls back to "No plan yet" copy when
/// nothing plan-shaped is found.
private struct JsonlPlanTab: View {
    @Environment(\.tahoe) private var t
    var transcript: [ChatMessage]

    private var planText: String? {
        // Prefer the most recent assistant turn that looks like a plan.
        let assistant = transcript.reversed().filter { $0.kind == .assistantText }
        for msg in assistant {
            let body = msg.body
            if body.range(of: #"(?im)^\s*(?:#+\s*plan|plan:|##\s)"#, options: .regularExpression) != nil {
                return body
            }
            if body.range(of: #"(?m)^\s*(?:\d+[.)]\s|[-*]\s)"#, options: .regularExpression) != nil {
                return body
            }
        }
        return nil
    }

    private var steps: [String] {
        guard let raw = planText else { return [] }
        return TahoePlanParser.steps(from: raw, cap: 12)
    }

    var body: some View {
        if steps.isEmpty {
            VStack(alignment: .center, spacing: 8) {
                TahoeIcon("doc", size: 22).foregroundStyle(t.fg4)
                Text("No plan in this transcript")
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text("The agent didn't post a plan-shaped step list in this rollout.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("PLAN · \(steps.count) STEPS")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                    .padding(.bottom, 10)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(t.hair2)
                            Text("\(i+1)")
                                .font(TahoeFont.mono(11, weight: .bold))
                                .foregroundStyle(t.fg2)
                        }
                        .frame(width: 22, height: 22)
                        Text(step)
                            .font(TahoeFont.body(12.5))
                            .foregroundStyle(t.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                    if i < steps.count - 1 { TahoeHair() }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }
}

/// Sources tab content derived from JSONL transcript. Scans tool calls
/// + results for file paths and surfaces unique entries grouped by
/// directory. Tapping a row reveals the file in Finder.
private struct JsonlSourcesTab: View {
    @Environment(\.tahoe) private var t
    var transcript: [ChatMessage]
    var cwd: URL?

    private var files: [String] {
        // Match relative repo paths in tool detail/body (e.g.
        // `apple/ClawdmeterMac/Foo.swift:42:`). Also catches absolute
        // paths under common roots. Returns sorted unique list.
        var seen = Set<String>()
        let pattern = #"(?<![\w/])([A-Za-z0-9_\-./]+\.[A-Za-z0-9]{1,8})(?=[:\s]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for msg in transcript where msg.kind == .toolCall || msg.kind == .toolResult {
            let text = (msg.detail ?? "") + "\n" + msg.body
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for m in matches where m.numberOfRanges > 1 {
                let path = nsText.substring(with: m.range(at: 1))
                // Heuristics to drop false positives.
                if path.hasPrefix(".") { continue }
                if path.count < 4 { continue }
                if path.contains("..") { continue }
                seen.insert(path)
            }
        }
        return seen.sorted()
    }

    var body: some View {
        if files.isEmpty {
            VStack(alignment: .center, spacing: 8) {
                TahoeIcon("search", size: 22).foregroundStyle(t.fg4)
                Text("No source files found")
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text("This transcript doesn't reference any file paths.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("SOURCES · \(files.count) FILES")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                ForEach(Array(files.enumerated()), id: \.offset) { _, path in
                    Button {
                        let absolute: URL
                        if path.hasPrefix("/") {
                            absolute = URL(fileURLWithPath: path)
                        } else if let cwd {
                            absolute = cwd.appendingPathComponent(path)
                        } else {
                            return
                        }
                        if FileManager.default.fileExists(atPath: absolute.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([absolute])
                        }
                    } label: {
                        HStack(spacing: 6) {
                            TahoeIcon("folder", size: 10).foregroundStyle(t.fg4)
                            Text(path)
                                .font(TahoeFont.mono(11.5))
                                .foregroundStyle(t.fg2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    TahoeHair()
                }
            }
        }
    }
}

/// PR tab content derived from JSONL transcript. Scans for GitHub
/// pull-request URLs (`https://github.com/{owner}/{repo}/pull/{n}`) in
/// any message body/detail and renders them as a list. Tap opens in
/// the default browser.
private struct JsonlPRTab: View {
    @Environment(\.tahoe) private var t
    var transcript: [ChatMessage]

    private var prURLs: [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        let pattern = #"https?://github\.com/[A-Za-z0-9_./-]+/(?:pull|issues)/\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for msg in transcript {
            let text = (msg.detail ?? "") + "\n" + msg.body
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for m in matches {
                let raw = nsText.substring(with: m.range)
                if seen.contains(raw) { continue }
                seen.insert(raw)
                if let u = URL(string: raw) { urls.append(u) }
            }
        }
        return urls
    }

    var body: some View {
        if prURLs.isEmpty {
            VStack(alignment: .center, spacing: 8) {
                TahoeIcon("pull", size: 22).foregroundStyle(t.fg4)
                Text("No PR detected")
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text("The agent didn't reference any github.com/.../pull/N URLs in this transcript.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("LINKED PRS · \(prURLs.count)")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                ForEach(Array(prURLs.enumerated()), id: \.offset) { _, url in
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 6) {
                            TahoeIcon("pull", size: 10).foregroundStyle(t.accent)
                            Text(url.absoluteString)
                                .font(TahoeFont.mono(11.5))
                                .foregroundStyle(t.accent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    TahoeHair()
                }
            }
        }
    }
}

/// v0.22.33: Term tab content for JSONL preview mode. There's no live
/// tmux to attach to in preview, but the transcript records every
/// shell command the agent ran (Bash / shell / exec tool calls) along
/// with the output. Render them as a terminal-shaped scroll: prompt
/// + command + output, monospaced, chronological. Better than the
/// previous "preview mode — open the live session" placeholder which
/// left users staring at an empty panel.
private struct JsonlTermTab: View {
    @Environment(\.tahoe) private var t
    var transcript: [ChatMessage]

    /// Pair each shell tool call with its result. Walks the
    /// chronological transcript and joins consecutive toolCall +
    /// toolResult entries where the call's title looks shell-shaped
    /// (Bash / shell / exec / pwsh / zsh / sh).
    private struct ShellEntry: Identifiable {
        let id: String
        let command: String
        let output: String
        let isError: Bool
    }

    private var entries: [ShellEntry] {
        let shellTools: Set<String> = ["bash", "shell", "exec", "sh", "zsh", "pwsh", "run", "execute"]
        var result: [ShellEntry] = []
        // Walk transcript pairing toolCall→next toolResult of any shell-ish tool.
        var lastCallIndex: Int? = nil
        for (idx, msg) in transcript.enumerated() {
            if msg.kind == .toolCall, shellTools.contains(msg.title.lowercased()) {
                lastCallIndex = idx
            } else if msg.kind == .toolResult, let i = lastCallIndex {
                let call = transcript[i]
                let cleaned = Self.stripNoise(msg.body)
                result.append(ShellEntry(
                    id: msg.id,
                    command: (call.detail?.isEmpty == false ? call.detail! : call.body)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    output: cleaned,
                    isError: msg.isError
                ))
                lastCallIndex = nil
            }
        }
        return result
    }

    /// Strip transcript boilerplate (Chunk ID / Wall time / Process
    /// exited / Original token count / Output:) so the terminal view
    /// shows only the actual stdout/stderr the command produced.
    /// Mirrors `JsonlPreviewMsg.cleanedBody` so the two views stay in
    /// sync.
    private static func stripNoise(_ raw: String) -> String {
        let prefixes = ["Chunk ID:", "Wall time:", "Process exited", "Original token count:", "Output:", "Total output lines:"]
        let kept = raw.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            for marker in prefixes where trimmed.hasPrefix(marker) { return false }
            return true
        }
        return kept.joined(separator: "\n")
    }

    var body: some View {
        let list = entries
        if list.isEmpty {
            VStack(alignment: .center, spacing: 8) {
                TahoeIcon("terminal", size: 22).foregroundStyle(t.fg4)
                Text("No shell activity")
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text("This transcript doesn't include any Bash / shell tool calls.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("REPLAY · \(list.count) COMMAND\(list.count == 1 ? "" : "S")")
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(t.fg3)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

                ForEach(list) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 6) {
                            Text("$")
                                .font(TahoeFont.mono(11.5, weight: .bold))
                                .foregroundStyle(t.accent)
                            Text(entry.command)
                                .font(TahoeFont.mono(11.5, weight: .semibold))
                                .foregroundStyle(t.fg)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !entry.output.isEmpty {
                            Text(entry.output)
                                .font(TahoeFont.mono(11))
                                .foregroundStyle(entry.isError ? .red : t.fg2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 12)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    TahoeHair()
                }
            }
            // Subtle terminal-y backdrop so the prompts read as a
            // shell session rather than a regular list.
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(t.dark
                          ? Color(.sRGB, white: 0, opacity: 0.18)
                          : Color(.sRGB, white: 0.96, opacity: 0.6))
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
    }
}

private struct ReviewPlan: View {
    @Environment(\.tahoe) private var t
    var session: TahoeCodeSession?
    var isDemo: Bool

    private var steps: [String] {
        if let raw = session?.runtimePlanText, !raw.isEmpty {
            let parsed = TahoePlanParser.steps(from: raw, cap: 12)
            if !parsed.isEmpty { return parsed }
        }
        // Production with no plan text shows an empty list and a helper
        // message; demo bindings keep the JSX fixture plan.
        return isDemo ? TahoeDemo.plan : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if steps.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    TahoeIcon("doc", size: 22).foregroundStyle(t.fg4)
                    Text("No plan yet")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg2)
                    Text("Run an agent in plan mode and the steps will appear here for review.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                Text("PLAN · \(steps.count) STEPS")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                    .padding(.bottom, 10)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(i == 0 ? t.accentAlpha(0.18) : t.hair2)
                            Text("\(i+1)")
                                .font(TahoeFont.mono(11, weight: .bold))
                                .foregroundStyle(i == 0 ? t.accent : t.fg2)
                        }
                        .frame(width: 22, height: 22)
                        Text(step)
                            .font(TahoeFont.body(12.5))
                            .foregroundStyle(t.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                    if i < steps.count - 1 { TahoeHair() }
                }
            }
        }
        .padding(16)
    }
}

private struct ReviewDiff: View {
    @Environment(\.tahoe) private var t

    private struct Line { var type: String; var text: String }
    private let lines: [Line] = [
        Line(type: "meta", text: "apps/web/src/lib/settlement-store.ts"),
        Line(type: "hunk", text: "@@ -47,12 +47,9 @@ export async function writeSettlement(fill: Fill) {"),
        Line(type: "ctx",  text: "  const ts = Date.now();"),
        Line(type: "del",  text: "  const existing = await db.get(`SELECT 1 FROM settlements WHERE fill_id = ?`, fill.id);"),
        Line(type: "del",  text: "  if (existing) return;"),
        Line(type: "del",  text: "  await db.run(`INSERT INTO settlements (fill_id, ts, ...) VALUES (?, ?, ...)`, fill.id, ts);"),
        Line(type: "add",  text: "  await db.run("),
        Line(type: "add",  text: "    `INSERT INTO settlements (fill_id, ts, ...) VALUES (?, ?, ...) ON CONFLICT (fill_id) DO NOTHING`,"),
        Line(type: "add",  text: "    fill.id, ts,"),
        Line(type: "add",  text: "  );"),
        Line(type: "ctx",  text: "}"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, ln in
                HStack(spacing: 0) {
                    let sign: String = {
                        switch ln.type { case "add": return "+"; case "del": return "-"; case "ctx": return " "; default: return "" }
                    }()
                    if ln.type != "meta" && ln.type != "hunk" {
                        Text(sign)
                            .frame(width: 14, alignment: .leading)
                            .opacity(0.7)
                    }
                    Text(ln.text)
                }
                .font(TahoeFont.mono(11.5))
                .foregroundStyle(color(for: ln.type))
                .padding(.horizontal, 16).padding(.vertical, 1)
                .background(bg(for: ln.type))
            }
        }
    }

    private func color(for type: String) -> Color {
        switch type {
        case "add":  return t.dark ? Color(.sRGB, red: 0x7E/255.0, green: 0xE2/255.0, blue: 0x9A/255.0) : Color(.sRGB, red: 0x1F/255.0, green: 0x7C/255.0, blue: 0x3A/255.0)
        case "del":  return t.dark ? Color(.sRGB, red: 1, green: 0x8E/255.0, blue: 0x88/255.0) : Color(.sRGB, red: 0xA4/255.0, green: 0x23/255.0, blue: 0x2A/255.0)
        case "ctx":  return t.fg2
        case "meta": return t.fg3
        case "hunk": return t.fg3
        default:     return t.fg
        }
    }

    private func bg(for type: String) -> Color {
        switch type {
        case "add":  return t.dark ? Color(.sRGB, red: 56.0/255, green: 180.0/255, blue: 113.0/255, opacity: 0.16) : Color(.sRGB, red: 46.0/255, green: 160.0/255, blue: 67.0/255, opacity: 0.10)
        case "del":  return t.dark ? Color(.sRGB, red: 255.0/255, green: 95.0/255, blue: 87.0/255, opacity: 0.16)  : Color(.sRGB, red: 244.0/255, green: 71.0/255, blue: 71.0/255, opacity: 0.10)
        case "hunk": return t.hair2
        default:     return .clear
        }
    }
}

private struct ReviewSources: View {
    @Environment(\.tahoe) private var t
    private let sources: [(String, String, String)] = [
        ("apps/web/src/lib/settlement-store.ts", "47-72",  "core writeSettlement function"),
        ("apps/web/src/lib/settlement-store.ts", "101-118","reconcileTick re-entry"),
        ("apps/web/src/db/schema.sql",            "34-39", "settlements table definition"),
        ("apps/daemon/src/dedupe-cache.ts",       "12-44", "in-memory dedupe cache used per-process"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 10) {
                    TahoeIcon("doc", size: 13).foregroundStyle(t.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.0).font(TahoeFont.mono(11.5)).foregroundStyle(t.fg)
                            Text(s.1).font(TahoeFont.body(11.5, weight: .medium)).foregroundStyle(t.fg3)
                        }
                        Text(s.2).font(TahoeFont.body(11)).foregroundStyle(t.fg3)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
        }
        .padding(12)
    }
}

private struct ReviewPR: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("fix(settlement): dedupe on insert with ON CONFLICT")
                .font(TahoeFont.body(13, weight: .bold))
                .foregroundStyle(t.fg)
                .padding(.bottom, 4)
            Text("defx-frontend · fix/settlement-dedupe → main")
                .font(TahoeFont.mono(11.5))
                .foregroundStyle(t.fg3)
                .padding(.bottom, 14)

            TahoeGlass(radius: 12, tone: .chip) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Checks").font(TahoeFont.body(11)).foregroundStyle(t.fg3).padding(.bottom, 6)
                    check("unit · settlement", "passed", "14.2s")
                    check("e2e · trading flows", "passed", "2m 18s")
                    check("lint · pnpm", "passed", "6s")
                    check("type-check", "in progress", "\u{2014}")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 10)

            TahoeAccentButton(size: .m) {
                HStack(spacing: 6) {
                    TahoeIcon("pull", size: 12)
                    Text("Open PR on GitHub")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }

    @ViewBuilder
    private func check(_ name: String, _ status: String, _ time: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(status == "passed" ? Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0)
                                                : Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0))
                    .frame(width: 14, height: 14)
                if status == "passed" {
                    TahoeIcon("check", size: 9, weight: .bold).foregroundStyle(.white)
                }
            }
            .shadow(color: status == "in progress" ? Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0) : .clear, radius: 4, x: 0, y: 0)
            Text(name).font(TahoeFont.body(12)).foregroundStyle(t.fg)
            Spacer()
            Text(time).font(TahoeFont.mono(11)).foregroundStyle(t.fg3)
        }
        .padding(.vertical, 4)
    }
}

private struct ReviewTerm: View {
    @Environment(\.tahoe) private var t

    private struct Line { var color: Color; var text: String }
    private var lines: [Line] {
        [
            Line(color: t.fg3, text: "$ pnpm test --filter @defx/settlement"),
            Line(color: t.fg2, text: " PASS  src/settlement-store.test.ts"),
            Line(color: t.fg2, text: "   ✓ writes once when called concurrently (212ms)"),
            Line(color: t.fg2, text: "   ✓ skips on duplicate fill_id (3ms)"),
            Line(color: Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), text: "Tests: 14 passed, 14 total"),
            Line(color: t.fg2, text: "Time:  4.182s"),
            Line(color: t.fg3, text: "$ _"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.text)
                    .font(TahoeFont.mono(11.5))
                    .foregroundStyle(l.color)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.dark ? Color.black.opacity(0.3) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
    }
}
