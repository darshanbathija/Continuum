import SwiftUI
import ClawdmeterShared

/// Sessions/Code data layer. Owns `SessionsModel` (the @MainActor
/// ObservableObject that bridges `RepoIndex` + `AgentSessionRegistry` +
/// `TmuxSupervisor` to SwiftUI) and `NewSessionMacSheet` (still hosted by
/// `SessionWorkspaceView`).
///
/// The top-level `SessionsView` SwiftUI struct that used to live here was
/// retired in v0.11 — the Tahoe `MacCodeView` is the only entry point
/// into the IDE surface now. File name kept as `SessionsView.swift` for
/// minimal diff noise; effectively a `SessionsModel.swift`.

// MARK: - New session sheet (Mac)

struct NewSessionMacSheet: View {
    @ObservedObject var model: SessionsModel
    @Environment(\.dismiss) private var dismiss

    /// Pre-selected repo path (when MacCodeView's per-repo `+` button opens
    /// the sheet, this is the repo's key so the picker lands on the right
    /// row without the user needing to choose). Nil opens the sheet with
    /// "(custom path)" selected, matching the previous behavior.
    var preselectedRepoKey: String?

    @State private var repoPath: String = ""
    @State private var agent: AgentKind = .claude
    @State private var goal: String = ""
    @State private var planMode: Bool = true
    @State private var opencodeReady: Bool = false
    @State private var cursorReady: Bool = false
    @State private var modelCatalog: ModelCatalog = .bundled
    @State private var selectedModelId: String?
    // v0.7.9: worktree by default. Local stays in the enum for
    // back-compat but the mode chip is no longer in the New Session UI.
    @State private var mode: SessionMode = .worktree
    @State private var isSpawning: Bool = false
    @State private var errorMessage: String?

    init(model: SessionsModel, preselectedRepoKey: String? = nil) {
        self.model = model
        self.preselectedRepoKey = preselectedRepoKey
        if let key = preselectedRepoKey {
            self._repoPath = State(initialValue: key)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New session")
                .font(.system(size: 18, weight: .semibold))

            Form {
                Picker("Pick a repo", selection: $repoPath) {
                    Text("(custom path)").tag("")
                    ForEach(model.repos, id: \.key) { repo in
                        let suffix: String = {
                            if repo.liveSessionCount > 0 { return "  • live" }
                            if !repo.recentSessions.isEmpty { return "  • \(repo.recentSessions.count) recent" }
                            return ""
                        }()
                        Text("\(repo.displayName)\(suffix)").tag(repo.key)
                    }
                }
                .pickerStyle(.menu)

                TextField("Or enter a path", text: $repoPath,
                          prompt: Text("/Users/.../my-repo"))

                Picker("Agent", selection: $agent) {
                    ForEach(selectableAgents, id: \.self) { kind in
                        Text(kind.tahoeProvider.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Model")
                    Spacer()
                    ModelPicker(
                        selectedModelId: selectedModelId,
                        catalog: modelCatalog,
                        agent: agent
                    ) { entry in
                        selectedModelId = entry.id
                    }
                }

                TextField("Goal", text: $goal,
                          prompt: Text("Optional. Used by done-detector + worktree slug."))

                // Plan mode applies to both agents. Claude maps it to
                // `--permission-mode plan`; Codex maps it to
                // `--sandbox read-only` (E&S verified against
                // `codex --help` 2026-05). Approve & run swaps the
                // sandbox/permission afterwards.
                Toggle("Plan mode", isOn: $planMode)
                    .disabled(agent == .cursor)
                    .help({
                        switch agent {
                        case .claude: return "Claude runs in --permission-mode plan: reads + proposes, doesn't write until approved."
                        case .codex:  return "Codex runs in --sandbox read-only: reads + proposes, doesn't write until approved."
                        case .gemini: return "Gemini runs in --approval-mode plan: reads + proposes, doesn't write until approved."
                        case .opencode: return "OpenCode handles tool-call approval inside `opencode serve` — plan mode here is a UI hint only."
                        case .cursor: return "Cursor Agent starts in code mode until Cursor resume ids are available."
                        case .unknown: return "Plan mode: reads + proposes, doesn't write until approved."
                        }
                    }())

                // v0.7.9: Mode picker removed. Worktree is the only
                // mode new sessions land in — the agent always runs
                // in `.claude/worktrees/<city>/` on a branch named
                // after the city (assigned via CityNamer). Local mode
                // is still in the enum for back-compat with persisted
                // sessions and is still reachable through the
                // Session detail mode-swap action.
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSpawning ? "Starting…" : "Start") {
                    Task { await startSession() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
                .disabled(repoPath.isEmpty || isSpawning)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if let selected = model.selectedRepoKey { repoPath = selected }
            ensureSelectedModelIsAvailable()
        }
        .task { await refreshProviderAvailability() }
        .onChange(of: agent) { _, _ in
            selectedModelId = defaultModelId(for: agent)
            if agent == .cursor { planMode = false }
        }
        .onChange(of: modelCatalog.updatedAt) { _, _ in
            ensureSelectedModelIsAvailable()
        }
    }

    private var selectableAgents: [AgentKind] {
        var agents: [AgentKind] = [.claude, .codex, .gemini]
        if opencodeReady {
            agents.append(.opencode)
        }
        if cursorReady {
            agents.append(.cursor)
        }
        return agents
    }

    private func refreshProviderAvailability() async {
        await OpencodeProcessManager.shared.refreshAuthStatus()
        let hasBinary = OpencodeProcessManager.shared.binaryPath != nil
        let hasProvider = !(OpencodeProcessManager.shared.authStatus ?? [:]).isEmpty
        opencodeReady = hasBinary && hasProvider
        let cursorState = await CursorModelProbe.shared.currentState()
        modelCatalog = ModelCatalog.bundled.replacingCursor(cursorState.models)
        cursorReady = cursorState.binaryPath != nil && cursorState.authenticated
        if !opencodeReady, agent == .opencode {
            agent = .claude
        }
        if !cursorReady, agent == .cursor {
            agent = .claude
        }
        ensureSelectedModelIsAvailable()
    }

    private func defaultModelId(for agent: AgentKind) -> String? {
        modelCatalog.entries(for: agent).first?.id
    }

    private func ensureSelectedModelIsAvailable() {
        let models = modelCatalog.entries(for: agent)
        guard !models.isEmpty else {
            selectedModelId = nil
            return
        }
        if let selectedModelId,
           models.contains(where: { $0.id == selectedModelId || $0.cliAlias == selectedModelId }) {
            return
        }
        selectedModelId = models.first?.id
    }

    private func supportsEffort(modelId: String?) -> Bool {
        guard let modelId,
              let entry = modelCatalog.entry(forId: modelId) else {
            return true
        }
        return entry.supportsEffort
    }

    private func startSession() async {
        isSpawning = true
        errorMessage = nil
        defer { isSpawning = false }
        guard let runtime = AppDelegate.runtime else {
            errorMessage = "Daemon not started — relaunch Clawdmeter."
            return
        }
        // Seed effort from ComposerStore.ChipDefaults while model comes from
        // this sheet's picker. Cursor models are the live account-visible
        // probe result with Cursor default / Auto as the fallback.
        let defaults = ComposerStore.ChipDefaults.default
        let selectedModel = selectedModelId ?? defaultModelId(for: agent)
        switch agent {
        case .unknown:
            // X3: unreachable from the picker (allCases excludes .unknown)
            errorMessage = "Unknown agent kind — relaunch to refresh."
            return
        default:
            break
        }
        do {
            _ = try await model.spawnSession(
                repoPath: repoPath,
                agent: agent,
                planMode: agent == .cursor ? false : planMode,
                goal: goal.isEmpty ? nil : goal,
                mode: mode,
                tmux: runtime.tmuxClient,
                model: selectedModel,
                effort: supportsEffort(modelId: selectedModel) ? defaults.effort : nil
            )
            dismiss()
        } catch {
            errorMessage = (error as? TmuxControlClient.TmuxError).map(humanize)
                ?? error.localizedDescription
        }
    }

    private func humanize(_ err: TmuxControlClient.TmuxError) -> String {
        switch err {
        case .notStarted: return "tmux not started — try again in a moment"
        case .commandFailed(let s): return "tmux: \(s)"
        case .serverExited: return "tmux server exited"
        case .ptyClosed: return "PTY closed unexpectedly"
        case .invalidArgument(let s): return "tmux: invalid argument (\(s))"
        }
    }
}

// MARK: - Model

@MainActor
public final class SessionsModel: ObservableObject {

    @Published public var repos: [AgentRepo] = []
    @Published public var selectedRepoKey: String?
    @Published public var isRefreshing: Bool = false
    @Published public var showingNewSessionSheet: Bool = false
    @Published public var expandedRepoKeys: Set<String> = []

    /// Currently-open session in the workspace center pane. nil = empty
    /// center pane (workspace still renders sidebar + review).
    @Published public var openSessionId: UUID?

    /// When the user opens an outside-Clawdmeter session (any JSONL in the
    /// recent-activity window), we synthesize a read-only AgentSession.
    /// Keyed by the JSONL absolute path so each recent row is its own
    /// distinct synthetic session.
    @Published public var openOutsideJSONLPath: String?
    private var syntheticOutsideSessions: [String: AgentSession] = [:]
    /// Per-synthetic-session URL pin. Drives `chatStore(for:)` to tail this
    /// exact JSONL instead of falling back to `resolveSessionFileURL`'s
    /// newest-wins logic.
    private var forcedChatStoreURLs: [UUID: URL] = [:]

    /// Sidebar search query (G6). Filters repos + sessions by displayName,
    /// goal, and message body substring. Empty = no filter.
    @Published public var searchQuery: String = ""

    /// When true, archived sessions are visible in the sidebar (G7).
    @Published public var showArchived: Bool = false

    /// Currently surfaced as a session in the workspace's center pane.
    /// Resolves the registry first, then synthetic outside-Clawdmeter
    /// sessions as a fallback.
    public var openSession: AgentSession? {
        if let id = openSessionId,
           let s = registry.sessions.first(where: { $0.id == id }) {
            return s
        }
        if let path = openOutsideJSONLPath,
           let s = syntheticOutsideSessions[path] {
            return s
        }
        return nil
    }

    /// True when the currently-open session is a synthetic outside-
    /// Clawdmeter one. The center pane disables composer + actions.
    public var openSessionIsReadOnly: Bool {
        openOutsideJSONLPath != nil && openSessionId == nil
    }

    /// Open a specific outside-Clawdmeter JSONL as a read-only chat. Each
    /// JSONL gets its own synthetic AgentSession, so flipping between
    /// recent rows in the sidebar doesn't share state.
    public func openOutsideSession(recent: RecentSession, repoKey: String, repoDisplayName: String) {
        let url = URL(fileURLWithPath: recent.path)
        let path = recent.path
        if let existing = syntheticOutsideSessions[path] {
            openOutsideJSONLPath = path
            openSessionId = nil
            forcedChatStoreURLs[existing.id] = url
            return
        }
        let synth = AgentSession(
            id: UUID(),
            repoKey: repoKey,
            repoDisplayName: repoDisplayName,
            agent: recent.provider,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: recent.lastModified,
            lastEventAt: recent.lastModified,
            lastEventSeq: 0
        )
        syntheticOutsideSessions[path] = synth
        forcedChatStoreURLs[synth.id] = url
        openOutsideJSONLPath = path
        openSessionId = nil
    }

    public func closeChatView() {
        openSessionId = nil
        openOutsideJSONLPath = nil
    }

    public let repoIndex: RepoIndex
    public let registry: AgentSessionRegistry
    public let supervisor: TmuxSupervisor
    private var refreshTask: Task<Void, Never>?

    /// Per-session chat stores, LRU-bound to `maxResidentChatStores`. Each
    /// store holds a JSONLTail dispatch source, a parsed messages array,
    /// and (post-perf) a markdown cache; without this bound, navigating
    /// through five large recent sessions would keep five tails + five
    /// parsed arrays + five caches alive, which surfaced in the codex
    /// outside-voice review as the plausible root cause of the
    /// repeated-navigation beachball.
    /// `chatStoreLRU` holds UUIDs oldest-first; accessing a store moves
    /// its id to the tail of the array.
    private var chatStores: [UUID: SessionChatStore] = [:]
    private var chatStoreLRU: [UUID] = []
    private static let maxResidentChatStores = 3
    /// Sessions explicitly protected from LRU eviction. The main
    /// workspace's currently-open session is always protected; popped-out
    /// session windows register themselves on mount (and unregister on
    /// dismount). Without this, navigating through three other sessions
    /// while a pop-out window is up would evict and `stop()` the pop-out's
    /// store while it's still on screen — surfaced by Codex M1.
    @Published public private(set) var protectedSessionIds: Set<UUID> = []
    /// Per-session PR mirrors (G16). Lazy-instantiated on first access; we
    /// attach the chat store automatically so PR detection picks up the
    /// agent's `gh pr create` output. Paired with `chatStores` — evicted
    /// together so we don't leak polling tasks.
    private var prMirrors: [UUID: PRMirror] = [:]

    /// Register a session as protected from LRU eviction. Called by
    /// PoppedOutSessionView.onAppear so the pop-out's chat store survives
    /// even if the main workspace navigates to three other sessions.
    public func protectSession(_ id: UUID) {
        protectedSessionIds.insert(id)
    }

    /// Unregister a session from protection. Called by
    /// PoppedOutSessionView.onDisappear; subsequent LRU sweeps may
    /// evict the store on the next chatStore(for:) call.
    public func unprotectSession(_ id: UUID) {
        protectedSessionIds.remove(id)
    }

    public init(
        repoIndex: RepoIndex,
        registry: AgentSessionRegistry,
        supervisor: TmuxSupervisor
    ) {
        self.repoIndex = repoIndex
        self.registry = registry
        self.supervisor = supervisor
    }

    /// Get or create the chat store for a session. If the session is one of
    /// our synthetic outside-Clawdmeter ones, route through the pinned URL
    /// the caller registered via `openOutsideSession(...)`; otherwise fall
    /// back to "newest JSONL under the repo's project dir".
    /// On cache hit, the id is bumped to the tail of the LRU. On miss, the
    /// new store is created, started, and any over-cap entries are evicted
    /// via `evictExcessChatStores()` (which calls `stop()` to cancel each
    /// evicted store's JSONLTail + parse task).
    public func chatStore(for session: AgentSession) -> SessionChatStore? {
        // v0.8 QA: for chat-kind sessions, route to the DAEMON's
        // SessionChatStore (single source of truth). The Mac UI and daemon
        // are in the same process; CodexSDKEventIngestor writes events into
        // the daemon's store, and we want the UI to read from that same
        // instance — not create its own empty parallel store. iOS achieves
        // the same effect via chat-subscribe WS; Mac just reaches across
        // the process boundary directly. We cache the result in chatStores
        // so the LRU/eviction machinery still applies.
        if session.kind == .chat {
            if let existing = chatStores[session.id] {
                touchLRU(session.id)
                return existing
            }
            guard let daemonStore = AppDelegate.runtime?.agentControlServer.chatStore(for: session) else {
                return nil
            }
            chatStores[session.id] = daemonStore
            chatStoreLRU.append(session.id)
            evictExcessChatStores()
            return daemonStore
        }
        if let existing = chatStores[session.id] {
            touchLRU(session.id)
            // Audit P1 fix: when the daemon spawns a fresh post-approve
            // rollout (Codex `approve-plan` writes a new JSONL), the
            // cached store keeps tailing the dead plan-mode file unless
            // we swap it in place. Compare the cached URL against the
            // currently-resolved one and call switchTailedFile when
            // they diverge — without this the Mac chat freezes on the
            // plan and the user has to relaunch the app to see live
            // execution turns.
            let resolved = forcedChatStoreURLs[session.id]
                ?? SessionChatStore.resolveSessionFileURL(repoCwd: session.effectiveCwd)
            if let resolved, existing.currentFileURL != resolved {
                existing.switchTailedFile(to: resolved)
            }
            return existing
        }
        let url: URL? = forcedChatStoreURLs[session.id]
            ?? SessionChatStore.resolveSessionFileURL(repoCwd: session.effectiveCwd)
        guard let url else { return nil }
        let store = SessionChatStore(sessionId: session.id, sessionFileURL: url)
        store.start()
        chatStores[session.id] = store
        chatStoreLRU.append(session.id)
        evictExcessChatStores()
        return store
    }

    /// LRU bump: move `id` to the tail (most-recently-used position).
    private func touchLRU(_ id: UUID) {
        if let idx = chatStoreLRU.firstIndex(of: id) {
            chatStoreLRU.remove(at: idx)
        }
        chatStoreLRU.append(id)
    }

    /// Drop oldest stores until we're at or below `maxResidentChatStores`.
    /// Never evicts a protected session — the currently-open one in the
    /// main workspace plus any popped-out windows that have registered
    /// themselves via `protectSession(_:)`. Pairs eviction with
    /// `prMirrors` so the PR poller's Task is cancelled alongside the
    /// JSONLTail.
    private func evictExcessChatStores() {
        var protected = protectedSessionIds
        if let open = openSession?.id { protected.insert(open) }
        while chatStoreLRU.count > Self.maxResidentChatStores {
            // Find the oldest entry that isn't protected.
            guard let evictIdx = chatStoreLRU.firstIndex(where: { !protected.contains($0) })
            else { break }
            let evictId = chatStoreLRU.remove(at: evictIdx)
            chatStores[evictId]?.stop()
            chatStores.removeValue(forKey: evictId)
            prMirrors[evictId]?.detach()
            prMirrors.removeValue(forKey: evictId)
        }
    }

    public func closeChatStore(for sessionId: UUID) {
        chatStores[sessionId]?.stop()
        chatStores.removeValue(forKey: sessionId)
        chatStoreLRU.removeAll { $0 == sessionId }
        prMirrors[sessionId]?.detach()
        prMirrors.removeValue(forKey: sessionId)
    }

    /// G16: lazy PR mirror, attached to this session's chat store on first
    /// access so it can auto-detect a `gh pr create` URL.
    public func prMirror(for session: AgentSession) -> PRMirror {
        if let existing = prMirrors[session.id] { return existing }
        let mirror = PRMirror(sessionId: session.id)
        if let store = chatStore(for: session) {
            mirror.attach(chatStore: store)
        }
        prMirrors[session.id] = mirror
        return mirror
    }

    public func sessions(for repoKey: String, includeArchived: Bool = false) -> [AgentSession] {
        registry.sessions.filter { s in
            guard s.repoKey == repoKey else { return false }
            if !includeArchived, s.archivedAt != nil { return false }
            return true
        }
    }

    /// Children of a parent session (G17). Used by the sidebar to nest
    /// sub-chats under their parent row.
    public func children(of parentId: UUID) -> [AgentSession] {
        registry.sessions
            .filter { $0.parentSessionId == parentId && $0.archivedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// G6 sidebar search. Filters a session list by search query against
    /// goal text and (lightweight) message body. Empty query = no filter.
    public func filter(sessions: [AgentSession]) -> [AgentSession] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { s in
            if (s.goal ?? "").lowercased().contains(q) { return true }
            if s.repoDisplayName.lowercased().contains(q) { return true }
            if let store = chatStores[s.id] {
                for msg in store.messages.suffix(50) {
                    if msg.body.lowercased().contains(q) { return true }
                }
            }
            return false
        }
    }

    /// G6 sidebar search applied at the repo level. Filters out repos that
    /// have no matching sessions (when a query is set) so the sidebar is
    /// scoped to the search.
    public var filteredRepos: [AgentRepo] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return repos }
        return repos.filter { repo in
            if repo.displayName.lowercased().contains(q) { return true }
            let matches = filter(sessions: sessions(for: repo.key, includeArchived: showArchived))
            return !matches.isEmpty
        }
    }

    /// G8 keyboard nav: flat list of sessions visible in the sidebar, in
    /// the order they're rendered (parents first, children nested under).
    /// Used by Cmd+1..9 jump shortcuts and Cmd+; sub-chat detection.
    public var visibleSessions: [AgentSession] {
        var out: [AgentSession] = []
        for repo in filteredRepos {
            guard expandedRepoKeys.contains(repo.key) else { continue }
            let all = filter(sessions: sessions(for: repo.key, includeArchived: showArchived))
            let roots = all.filter { $0.parentSessionId == nil }
            for root in roots {
                out.append(root)
                appendChildren(of: root, into: &out, allowed: Set(all.map { $0.id }))
            }
        }
        return out
    }

    /// Recursively append children of `parent` (subject to `allowed`) in
    /// depth-first order. Loops are impossible in a healthy tree but the
    /// `seen` guard keeps a cycle (corrupt registry) from spinning forever.
    private func appendChildren(
        of parent: AgentSession,
        into out: inout [AgentSession],
        allowed: Set<UUID>,
        seen: Set<UUID> = []
    ) {
        var seen = seen
        seen.insert(parent.id)
        for child in children(of: parent.id) where allowed.contains(child.id) && !seen.contains(child.id) {
            out.append(child)
            appendChildren(of: child, into: &out, allowed: allowed, seen: seen)
        }
    }

    /// Jump to the Nth visible session (1-indexed for the Cmd+1..9 shortcut).
    public func openVisibleSession(at index: Int) {
        guard index >= 1, index <= visibleSessions.count else { return }
        let session = visibleSessions[index - 1]
        openOutsideJSONLPath = nil
        openSessionId = session.id
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await repoIndex.refresh()
        self.repos = snapshot
        for repo in snapshot {
            if !sessions(for: repo.key).isEmpty
                || repo.liveSessionCount > 0
                || !repo.recentSessions.isEmpty {
                expandedRepoKeys.insert(repo.key)
            }
        }
    }

    public func startPeriodicRefresh() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    /// Spawn a new Clawdmeter-owned session. The caller picks Local vs
    /// Worktree via the mode picker; for Worktree we create the directory
    /// via WorktreeManager and spawn the agent there.
    public enum SpawnError: LocalizedError {
        case missingBinary(String)
        case unsupportedMode(String)
        /// v0.8.0 agy-migration — Antigravity 2 isn't installed / running /
        /// signed in / has-no-project-for-this-repo. Carries the
        /// user-facing CTA string the composer surfaces inline.
        case antigravityNotReady(String)
        public var errorDescription: String? {
            switch self {
            case .missingBinary(let m): return m
            case .unsupportedMode(let m): return m
            case .antigravityNotReady(let m): return m
            }
        }
    }

    public func spawnSession(
        repoPath: String,
        agent: AgentKind,
        planMode: Bool,
        goal: String?,
        mode: SessionMode,
        tmux: TmuxControlClient,
        resumeSessionId: String? = nil,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        acceptEdits: Bool = false,
        // v0.7.15: empty-state composer can now pick Bypass and have it
        // actually reach the spawned CLI. Caller is responsible for the
        // trust-gate UX (AutopilotState.trustRepo) before passing true.
        autopilot: Bool = false,
        pinnedJSONLURL: URL? = nil,
        // v0.8.1 agy-migration — full first-prompt text for agentapi
        // spawn. tmux-based spawn ignores this (the CLI's stdin gets the
        // prompt via the post-spawn /send call), but Antigravity 2's
        // `agentapi new-conversation` requires the actual first turn at
        // spawn-time. Callers (EmptyStateCenteredComposer) pass the
        // composer's rendered body; nil falls back to `goal` for paths
        // that don't have a composer (resume flows, daemon-side spawns).
        initialMessage: String? = nil
    ) async throws -> AgentSession {
        // v0.8.0 agy-migration — Gemini sessions fork off here BEFORE the
        // tmux pipeline runs. Antigravity 2's agentapi is HTTP-RPC, not a
        // terminal CLI; there's no pane to spawn. Tier-2 v0.42 chat is
        // gone (D4 hard-stop). Returns the new session or throws
        // `.antigravityNotReady` with the CTA the composer surfaces.
        if agent == .gemini, resumeSessionId == nil {
            return try await spawnAntigravitySession(
                repoPath: repoPath,
                goal: goal,
                mode: mode,
                model: model,
                effort: effort,
                planMode: planMode,
                initialMessage: initialMessage
            )
        }
        if agent == .cursor, planMode, (resumeSessionId?.isEmpty ?? true) {
            throw SpawnError.unsupportedMode("Cursor plan mode requires a resumable Cursor session. Start Cursor in another permission mode.")
        }
        // Fail fast on missing CLIs rather than spawning tmux + the
        // worktree only to error in the agent's pane (where the user
        // can't easily see it without opening the terminal view).
        if let reason = AgentSpawner.preflight(agent: agent) {
            throw SpawnError.missingBinary(reason)
        }
        if agent == .cursor {
            let cursorState = await CursorModelProbe.shared.currentState()
            guard cursorState.binaryPath != nil else {
                throw SpawnError.missingBinary("Cursor Agent CLI not found or failed identity check: cursor-agent or agent. Configure in Settings -> Diagnostics.")
            }
            guard cursorState.authenticated else {
                throw SpawnError.missingBinary("Run cursor-agent login, then try again.")
            }
            if let model,
               !CursorModelCatalog.isAutoModel(model),
               !cursorState.models.contains(where: { $0.id == model || $0.cliAlias == model }) {
                throw SpawnError.missingBinary("Cursor model is not available for the authenticated account.")
            }
        }
        let effectivePlanMode = planMode
        try await tmux.start()
        var cwd = repoPath
        var worktreePath: String? = nil
        var provisionalSessionId: UUID?
        // Skip worktree creation for resumes — the CLI handles cwd from JSONL.
        if mode == .worktree, resumeSessionId == nil {
            // v0.7.9: city-named worktree + matching branch. Mint up
            // front so the path slug + branch use the same name.
            let sessionId = UUID()
            provisionalSessionId = sessionId
            let city = CityNamer.shared.cityName(for: sessionId)
            let slug = WorktreeManager.slug(city: city)
            do {
                worktreePath = try await WorktreeManager.shared.add(
                    repoRoot: repoPath,
                    slug: slug,
                    branchName: slug
                )
            } catch {
                CityNamer.shared.release(sessionId)
                throw error
            }
            cwd = worktreePath!
        }
        // Build argv per agent. Use direct argv-builders for the resume
        // path so we can pass the CLI session id (the JSONL `sessionId`
        // / payload `id`, NOT the Clawdmeter UUID — Codex P0 fix).
        let argv: [String]
        switch agent {
        case .claude:
            argv = AgentSpawner.claudeArgv(
                model: model,
                planMode: effectivePlanMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: resumeSessionId
            ) ?? []
        case .codex:
            argv = AgentSpawner.codexArgv(
                model: model,
                planMode: effectivePlanMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: resumeSessionId
            ) ?? []
        case .gemini:
            // v0.8.0 dead branch — the .gemini case is short-circuited
            // by `spawnAntigravitySession` above. This argv assignment
            // is unreachable but the compiler requires it for
            // exhaustiveness; if execution gets here (resumeSessionId
            // path for Gemini), the missingBinary error below catches.
            argv = []
        case .opencode:
            // PR #29: OpenCode spawns don't go through this tmux argv
            // path — OpencodeProcessManager + SSEAdapter handle them
            // out-of-band. The missingBinary throw below surfaces a
            // clean error if execution reaches here unexpectedly.
            argv = []
        case .cursor:
            argv = AgentSpawner.cursorArgv(
                model: model,
                planMode: effectivePlanMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: resumeSessionId,
                workspacePath: cwd
            ) ?? []
        case .unknown:
            // X3: forward-compat unknown kind — no spawn argv path. The
            // missingBinary throw below surfaces a clean error.
            argv = []
        }
        guard !argv.isEmpty else {
            await cleanupUnregisteredWorktree(
                repoPath: repoPath,
                worktreePath: worktreePath,
                provisionalSessionId: provisionalSessionId
            )
            throw SpawnError.missingBinary("Agent CLI not found on PATH: \(agent.rawValue). Configure in Settings -> Diagnostics.")
        }
        let window: TmuxControlClient.WindowRef
        do {
            window = try await tmux.newWindow(cwd: cwd, child: argv)
        } catch {
            await cleanupUnregisteredWorktree(
                repoPath: repoPath,
                worktreePath: worktreePath,
                provisionalSessionId: provisionalSessionId
            )
            throw error
        }
        let session = registry.create(
            repoKey: repoPath,
            repoDisplayName: (repoPath as NSString).lastPathComponent,
            agent: agent,
            model: model,
            goal: goal,
            worktreePath: worktreePath,
            tmuxWindowId: window.windowId,
            tmuxPaneId: window.paneId,
            planMode: effectivePlanMode,
            mode: mode,
            effort: effort
        )
        if let pinned = pinnedJSONLURL {
            forcedChatStoreURLs[session.id] = pinned
        }
        expandedRepoKeys.insert(repoPath)
        openSessionId = session.id
        await self.refresh()
        return session
    }

    // MARK: - v0.8.0 Antigravity agentapi spawn (D4 hard-stop)

    /// Spawn a Gemini session via Antigravity 2's HTTP-RPC agentapi.
    /// No tmux pane is created — the language_server holds the session
    /// state in `~/.gemini/antigravity/conversations/<id>.db` and T6's
    /// `AntigravityConversationDB` feeds chat into SessionChatStore.
    ///
    /// Errors:
    ///   - `.absent`:                "Install Antigravity 2 …"
    ///   - `.installedNotSignedIn`:  "Sign into Antigravity 2 first"
    ///   - `.appOnlyNotRunning`:     "Open Antigravity 2 to start a Gemini session"
    ///   - `.noProjectForRepo`:      "Open this repo in Antigravity 2 first"
    /// All surface as `.antigravityNotReady(message)` in the composer.
    private func spawnAntigravitySession(
        repoPath: String,
        goal: String?,
        mode: SessionMode,
        model: String?,
        effort: ReasoningEffort?,
        planMode: Bool,
        initialMessage: String? = nil
    ) async throws -> AgentSession {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appBundle = URL(fileURLWithPath: "/Applications/Antigravity.app", isDirectory: true)
        let lsClient = LanguageServerClient()
        let projectResolver = AntigravityProjectResolver(
            projectsDir: home.appendingPathComponent(".gemini/config/projects", isDirectory: true)
        )

        // Preflight via the install enum (T3). The closures hand off to
        // LanguageServerClient + AntigravityProjectResolver so the test
        // surface in AntigravityInstallTests stays injectable.
        let install = await AntigravityInstall.preflight(
            forRepoKey: repoPath,
            isLanguageServerLive: {
                if case .live = lsClient.discoverLive() { return true }
                return false
            },
            resolveProject: { repoKey in
                await projectResolver.resolve(forRepoKey: repoKey)?.id
            },
            homeDirectory: home,
            applicationsRoot: appBundle.deletingLastPathComponent()
        )

        switch install {
        case .absent:
            throw SpawnError.antigravityNotReady(
                "Install Antigravity 2 from antigravity.google to start a Gemini session."
            )
        case .installedNotSignedIn:
            throw SpawnError.antigravityNotReady(
                "Sign into Antigravity 2 first, then try again."
            )
        case .appOnlyNotRunning:
            throw SpawnError.antigravityNotReady(
                "Open Antigravity 2 to start a Gemini session."
            )
        case .noProjectForRepo:
            throw SpawnError.antigravityNotReady(
                "Open this repo in Antigravity 2 first, then come back."
            )
        case .ready(_, let projectId):
            // The first turn of the conversation gets locked in here —
            // agentapi has no separate "send first user message" call.
            // Codex P1.2: original draft passed `goal` (truncated to 80
            // chars) which made the chat thread start with a chopped
            // version of the user's prompt. Prefer the composer's
            // initialMessage (full rendered body) when provided.
            let firstPrompt: String = {
                if let initial = initialMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !initial.isEmpty {
                    return initial
                }
                if let goalText = goal?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !goalText.isEmpty {
                    return goalText
                }
                return "Start a new Gemini session in \(repoPath)."
            }()
            let modelTier = AgentapiModelTier.from(modelCatalogId: model)
            let conversationIdString = try await lsClient.newConversation(
                modelTier: modelTier,
                prompt: firstPrompt,
                projectId: projectId
            )
            guard let conversationId = UUID(uuidString: conversationIdString) else {
                throw SpawnError.antigravityNotReady(
                    "Antigravity returned an unrecognized conversation id (\(conversationIdString)). Try reopening the app."
                )
            }
            let session = registry.create(
                repoKey: repoPath,
                repoDisplayName: (repoPath as NSString).lastPathComponent,
                agent: .gemini,
                model: model,
                goal: goal,
                worktreePath: nil,  // no worktree for agentapi sessions in v0.8.0
                tmuxWindowId: nil,  // no tmux pane
                tmuxPaneId: nil,
                planMode: planMode,
                mode: mode,
                effort: effort,
                geminiBackend: .agentapi,
                antigravityConversationId: conversationId
            )
            expandedRepoKeys.insert(repoPath)
            openSessionId = session.id
            await self.refresh()
            return session
        }
    }

    /// Promote the currently-open read-only synthetic session into a live
    /// Clawdmeter-owned session by spawning a fresh tmux pane with the
    /// CLI's `--resume`/`resume` flag. Returns the new live AgentSession,
    /// or nil if the JSONL can't be resumed (caller surfaces the failure
    /// in the composer's inline error banner).
    ///
    /// Used by the send-triggers-continue flow: in read-only mode the
    /// composer is always visible; sending invokes this helper, then
    /// posts the user's prompt to the now-live session. Avoids needing
    /// the user to find the right-click context menu (which had silent
    /// failure modes when the JSONL parser couldn't pull out the CLI id).
    @discardableResult
    public func continueCurrentReadOnly() async -> AgentSession? {
        guard let path = openOutsideJSONLPath,
              let synthetic = syntheticOutsideSessions[path]
        else { return nil }
        let jsonlURL = URL(fileURLWithPath: path)
        let provider: JSONLSessionId.Provider = (synthetic.agent == .codex) ? .codex : .claude
        guard let cliSessionId = JSONLSessionId.extract(from: jsonlURL, provider: provider) else {
            return nil
        }
        guard let runtime = AppDelegate.runtime else { return nil }
        // Continued sessions inherit the same Opus 4.7 1M + Max defaults
        // as freshly-created ones (per Claude Code's standard).
        let defaults = ComposerStore.ChipDefaults.default
        let modelDefault: String?
        switch synthetic.agent {
        case .claude: modelDefault = defaults.modelId
        case .codex:  modelDefault = ModelCatalog.bundled.codex.first?.id
        case .gemini: modelDefault = ModelCatalog.bundled.gemini.first?.id
        case .opencode:
            // PR #29: no JSONL outside-source for OpenCode (state lives
            // inside `opencode serve` shared process memory).
            return nil
        case .cursor:
            // Cursor imported-session resume requires a real Cursor chat id.
            // The JSONL importer cannot prove that yet, so leave imported
            // Cursor rows read-only until the Cursor importer lands.
            return nil
        case .unknown:
            // X3: forward-compat unknown kind — no JSONL parser plumbed.
            return nil
        }
        // Outside-JSONL continuation is a code-session-only path; chat
        // sessions never reach here (no JSONL outside-source). Skip if
        // somehow the synthetic has no repoKey to keep types honest.
        guard let syntheticRepoKey = synthetic.repoKey else { return nil }
        do {
            let session = try await spawnSession(
                repoPath: syntheticRepoKey,
                agent: synthetic.agent,
                planMode: false,
                goal: synthetic.goal,
                mode: .local,
                tmux: runtime.tmuxClient,
                resumeSessionId: cliSessionId,
                model: modelDefault,
                effort: defaults.effort,
                pinnedJSONLURL: jsonlURL
            )
            // Migrate open-state away from the synthetic; clean up the
            // synthetic entry so the chat-store cache doesn't keep two
            // entries pointing at the same JSONL.
            openOutsideJSONLPath = nil
            openSessionId = session.id
            syntheticOutsideSessions.removeValue(forKey: path)
            return session
        } catch {
            return nil
        }
    }

    /// v0.5.10: set or clear a custom display name for a Recent JSONL row.
    /// Writes directly to the in-process alias store (no HTTP loopback
    /// needed on the Mac side), then asks `RepoIndex` to rebuild so the
    /// sidebar reflects the new name without waiting for the 60s tick.
    public func renameJSONLAlias(path: String, name: String?) {
        JSONLAliasStore.shared.setAlias(path: path, name: name)
        Task { [repoIndex] in await repoIndex.refresh() }
    }

    /// Wave A: turn a read-only Recent JSONL row into a live continuable
    /// session. Parses the CLI session id from the JSONL header and spawns
    /// a fresh tmux pane with `--resume <cli-id>` (Claude) or
    /// `resume <cli-id>` (Codex). Falls back to the read-only view if the
    /// JSONL has no usable id.
    @discardableResult
    public func continueOutsideSession(
        recent: RecentSession,
        repoKey: String,
        repoDisplayName: String
    ) async -> AgentSession? {
        let jsonlURL = URL(fileURLWithPath: recent.path)
        guard recent.provider == .claude || recent.provider == .codex else {
            openOutsideSession(recent: recent, repoKey: repoKey, repoDisplayName: repoDisplayName)
            return nil
        }
        let provider: JSONLSessionId.Provider = (recent.provider == .codex) ? .codex : .claude
        guard let cliSessionId = JSONLSessionId.extract(from: jsonlURL, provider: provider) else {
            // No id → keep the read-only synthetic session open.
            openOutsideSession(recent: recent, repoKey: repoKey, repoDisplayName: repoDisplayName)
            return nil
        }
        guard let runtime = AppDelegate.runtime else { return nil }
        do {
            let session = try await spawnSession(
                repoPath: repoKey,
                agent: recent.provider,
                planMode: false,
                goal: recent.firstPrompt,
                mode: .local,
                tmux: runtime.tmuxClient,
                resumeSessionId: cliSessionId,
                pinnedJSONLURL: jsonlURL
            )
            // Migrate open-state away from the synthetic read-only row.
            openOutsideJSONLPath = nil
            openSessionId = session.id
            return session
        } catch {
            openOutsideSession(recent: recent, repoKey: repoKey, repoDisplayName: repoDisplayName)
            return nil
        }
    }

    /// G2: switch a live session's mode (Local ↔ Worktree). Kills the
    /// running agent, optionally creates/destroys a worktree, then re-spawns
    /// the agent in the new cwd. Caller owns the D13 overlay around this.
    public func switchMode(sessionId: UUID, to newMode: SessionMode) async {
        guard let runtime = AppDelegate.runtime,
              let session = registry.session(id: sessionId)
        else { return }
        guard newMode != session.mode, newMode != .cloud else { return }
        // v0.8: mode-switch is a code-session concept (Local ↔ Worktree
        // both require a git repo). Chat sessions don't expose the
        // chip, so this is unreachable for them — guard for type safety.
        guard session.kind == .code, let sessionRepoKey = session.repoKey else { return }
        // Tear down the existing agent.
        if let windowId = session.tmuxWindowId {
            try? await runtime.tmuxClient.killWindow(windowId)
        }
        // Pick the new cwd.
        var newCwd = sessionRepoKey
        var newWorktree: String? = nil
        switch newMode {
        case .worktree:
            // v0.7.9: reuse the session's already-assigned city for
            // its worktree branch. Mid-session swap → same city as
            // the sidebar label so user mental model stays consistent.
            let city = CityNamer.shared.cityName(for: session.id)
            let slug = WorktreeManager.slug(city: city)
            do {
                newWorktree = try await WorktreeManager.shared.add(
                    repoRoot: sessionRepoKey,
                    slug: slug,
                    branchName: slug
                )
                newCwd = newWorktree!
            } catch {
                // Couldn't create worktree — bail without changing state.
                return
            }
        case .local:
            // Leaving worktree: keep the existing worktree on disk; the
            // multi-gate GC handles cleanup when the session is deleted.
            newWorktree = nil
        case .cloud:
            return
        }
        // Re-spawn.
        let argv = AgentSpawner.argv(for: NewSessionRequest(
            repoKey: sessionRepoKey,
            agent: session.agent,
            model: session.model,
            planMode: session.status == .planning,
            goal: session.goal,
            useWorktree: newMode == .worktree
        ), workspacePath: newCwd)
        do {
            guard !argv.isEmpty else { return }
            let newWindow = try await runtime.tmuxClient.newWindow(cwd: newCwd, child: argv)
            registry.updateRuntime(
                id: sessionId,
                worktreePath: newWorktree,
                tmuxWindowId: newWindow.windowId,
                tmuxPaneId: newWindow.paneId,
                mode: newMode
            )
        } catch {
            // Spawn failed — surface via lastError once we plumb it; for now,
            // session status stays at degraded by the supervisor.
        }
    }

    /// Sessions v2 Phase 1: swap the model on a live session. Wraps
    /// `SessionConfigChanger` so the kill+respawn lives in one place.
    /// The chip picker calls this with the new entry's id; if `entry.cliAlias`
    /// is set, we pass the alias (e.g. "opus") since claude --model accepts
    /// both aliases and full ids.
    public func switchModel(sessionId: UUID, to entry: ModelCatalogEntry, effort: ReasoningEffort? = nil) async {
        guard let runtime = AppDelegate.runtime else { return }
        let changer = SessionConfigChanger(registry: registry, tmux: runtime.tmuxClient)
        let modelToUse = entry.cliAlias ?? entry.id
        _ = await changer.swap(sessionId: sessionId, newModel: modelToUse, newEffort: .some(effort))
    }

    /// Sessions v2 Phase 1: swap the effort dial mid-session.
    public func switchEffort(sessionId: UUID, to effort: ReasoningEffort) async {
        guard let runtime = AppDelegate.runtime else { return }
        let changer = SessionConfigChanger(registry: registry, tmux: runtime.tmuxClient)
        _ = await changer.swap(sessionId: sessionId, newEffort: .some(effort))
    }

    /// Sessions v2 Phase 1: toggle plan/code mid-session (Claude only).
    public func switchPlanMode(sessionId: UUID, planMode: Bool) async {
        guard let runtime = AppDelegate.runtime else { return }
        let changer = SessionConfigChanger(registry: registry, tmux: runtime.tmuxClient)
        _ = await changer.swap(sessionId: sessionId, newPlanMode: planMode)
    }

    /// Apply a new `PermissionMode` to a live session. Resolves to the
    /// (planMode, autopilot, acceptEdits) tuple and triggers a respawn.
    /// Caller is responsible for trust-gating `.bypass` BEFORE calling
    /// this — by the time we reach here, AutopilotState.trustRepo has
    /// already been recorded for that path.
    public func setPermissionMode(sessionId: UUID, to newMode: PermissionMode) async {
        guard let runtime = AppDelegate.runtime else { return }
        // Update the Mac-side stores so the next respawn picks up the
        // right argv. Order matters: write state first, then respawn —
        // SessionConfigChanger reads the stores when building newArgv.
        let store = PermissionModeStore.shared
        switch newMode {
        case .ask:
            store.setAcceptEdits(false, sessionId: sessionId)
            store.setBypass(false, sessionId: sessionId)
        case .acceptEdits:
            store.setAcceptEdits(true, sessionId: sessionId)
            store.setBypass(false, sessionId: sessionId)
        case .plan:
            store.setAcceptEdits(false, sessionId: sessionId)
            store.setBypass(false, sessionId: sessionId)
        case .bypass:
            store.setAcceptEdits(false, sessionId: sessionId)
            store.setBypass(true, sessionId: sessionId)
        }
        let changer = SessionConfigChanger(registry: registry, tmux: runtime.tmuxClient)
        _ = await changer.swap(sessionId: sessionId, newPlanMode: newMode == .plan)
    }

    public func endSession(id: UUID) async {
        guard let session = registry.session(id: id),
              let runtime = AppDelegate.runtime,
              let windowId = session.tmuxWindowId
        else {
            registry.delete(id: id)
            return
        }
        do { try await runtime.tmuxClient.killWindow(windowId) } catch {}
        // v0.8 REV-DELETE: code sessions go through WorktreeManager; chat
        // sessions get ChatCwdCleaner in Phase 4. Guard here so Phase 2
        // doesn't crash on a chat session reaching this path.
        if session.kind == .code, let worktreePath = session.worktreePath, let repoRoot = session.repoKey {
            _ = try? await WorktreeManager.shared.delete(
                repoRoot: repoRoot,
                worktreePath: worktreePath,
                registryOwned: true,
                attachedPanePaths: []
            )
        }
        if openSessionId == id { openSessionId = nil }
        closeChatStore(for: id)
        registry.delete(id: id)
    }

    // MARK: - G17 threaded sub-chats

    /// Spawn a child session linked to the parent via `parentSessionId`.
    /// The child runs in the same cwd as the parent (worktree-aware) but
    /// uses a fresh tmux window + JSONL. The sidebar nests it under the
    /// parent row.
    @discardableResult
    public func spawnSubchat(parentId: UUID) async -> AgentSession? {
        guard let runtime = AppDelegate.runtime,
              let parent = registry.session(id: parentId)
        else { return nil }
        // v0.8: sub-chats are a code-session-only feature (G17 nested
        // threaded rows). Chat-tab sessions don't carry sub-chats.
        guard parent.kind == .code, let parentRepoKey = parent.repoKey else { return nil }
        try? await runtime.tmuxClient.start()
        let cwd = parent.effectiveCwd
        let argv = AgentSpawner.argv(for: NewSessionRequest(
            repoKey: parentRepoKey,
            agent: parent.agent,
            model: parent.model,
            planMode: false,
            goal: nil,
            useWorktree: parent.mode == .worktree
        ), workspacePath: cwd)
        do {
            guard !argv.isEmpty else { return nil }
            let window = try await runtime.tmuxClient.newWindow(cwd: cwd, child: argv)
            let child = registry.create(
                repoKey: parentRepoKey,
                repoDisplayName: parent.repoDisplayName,
                agent: parent.agent,
                model: parent.model,
                goal: nil,
                worktreePath: parent.worktreePath,
                tmuxWindowId: window.windowId,
                tmuxPaneId: window.paneId,
                planMode: false,
                mode: parent.mode,
                parentSessionId: parentId
            )
            openSessionId = child.id
            await refresh()
            return child
        } catch {
            return nil
        }
    }

    // MARK: - G12 multi-terminal

    /// Spawn a new shell pane in the session's tmux window and add a
    /// TerminalPaneRef to the registry. Returns the new pane id.
    @discardableResult
    public func addTerminalPane(sessionId: UUID) async -> String? {
        guard let runtime = AppDelegate.runtime,
              let session = registry.session(id: sessionId),
              let windowId = session.tmuxWindowId
        else { return nil }
        let cwd = session.effectiveCwd
        do {
            let paneId = try await runtime.tmuxClient.splitWindow(
                windowId: windowId, cwd: cwd, horizontal: false
            )
            let ref = TerminalPaneRef(
                paneId: paneId,
                title: "Pane \(session.terminalPanes.count + 2)",
                isPrimary: false
            )
            registry.addTerminalPane(sessionId: sessionId, pane: ref)
            return paneId
        } catch {
            return nil
        }
    }

    /// Close one terminal pane (non-primary). Sends `kill-pane` to tmux
    /// and removes the registry entry.
    public func closeTerminalPane(sessionId: UUID, paneRef: TerminalPaneRef) async {
        guard !paneRef.isPrimary,
              let runtime = AppDelegate.runtime
        else { return }
        try? await runtime.tmuxClient.killPane(paneRef.paneId)
        registry.removeTerminalPane(sessionId: sessionId, paneRefId: paneRef.id)
    }

    public func approvePlan(id: UUID) async {
        guard let runtime = AppDelegate.runtime,
              let session = registry.session(id: id),
              let windowId = session.tmuxWindowId,
              session.status == .planning,
              (session.planText?.isEmpty == false || session.agent == .codex || session.agent == .cursor)
        else { return }
        do {
            let providerResumeId: String
            if session.agent == .cursor {
                guard let cursorResumeId = Self.cursorResumeId(for: session) else {
                    registry.setPlanText(
                        id: id,
                        planText: "Cursor approval needs a real Cursor chat id. Start Cursor in code mode or import a Cursor session with a proven id."
                    )
                    registry.updateStatus(id: id, status: .degraded)
                    return
                }
                providerResumeId = cursorResumeId
            } else {
                providerResumeId = session.id.uuidString
            }
            let argv = AgentSpawner.respawnArgv(
                agent: session.agent,
                resumeSessionId: providerResumeId,
                model: session.model,
                planMode: false,
                effort: session.effort,
                autopilot: false,
                workspacePath: session.effectiveCwd
            )
            guard !argv.isEmpty else { return }
            try await runtime.tmuxClient.killWindow(windowId)
            let cwd = session.effectiveCwd
            let window = try await runtime.tmuxClient.newWindow(cwd: cwd, child: argv)
            registry.updateRuntime(
                id: id,
                worktreePath: session.worktreePath,
                tmuxWindowId: window.windowId,
                tmuxPaneId: window.paneId,
                mode: session.mode
            )
            registry.setPlanText(id: id, planText: "")
            registry.updateStatus(id: id, status: .running)
        } catch {}
    }

    private func cleanupUnregisteredWorktree(
        repoPath: String,
        worktreePath: String?,
        provisionalSessionId: UUID?
    ) async {
        if let worktreePath {
            _ = try? await WorktreeManager.shared.delete(
                repoRoot: repoPath,
                worktreePath: worktreePath,
                registryOwned: true
            )
        }
        if let provisionalSessionId {
            CityNamer.shared.release(provisionalSessionId)
        }
    }

    private static func cursorResumeId(for session: AgentSession) -> String? {
        let candidate = session.runtimeBinding?.externalSessionId
            ?? session.runtimeBinding?.externalThreadId
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
