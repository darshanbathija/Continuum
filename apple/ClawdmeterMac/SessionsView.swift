import SwiftUI
import ClawdmeterShared

/// Sessions tab. Codex-desktop three-pane workspace: sidebar of repos +
/// sessions on the left, conversation thread in the center, review pane
/// (plan / diff / sources / artifacts) on the right.
///
/// G0 replaces the prior 2-pane push/pop layout. Pre-G0 we used a state-
/// driven push/pop with a back button; that worked but didn't surface
/// review surfaces (diff, plan tracker, sources) — the workspace view
/// lays them out side-by-side instead.
struct SessionsView: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        SessionWorkspaceView(model: model)
    }
}

// MARK: - New session sheet (Mac)

struct NewSessionMacSheet: View {
    @ObservedObject var model: SessionsModel
    @Environment(\.dismiss) private var dismiss

    @State private var repoPath: String = ""
    @State private var agent: AgentKind = .claude
    @State private var goal: String = ""
    @State private var planMode: Bool = true
    @State private var mode: SessionMode = .local
    @State private var isSpawning: Bool = false
    @State private var errorMessage: String?

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
                    Text("Claude").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                }
                .pickerStyle(.segmented)

                TextField("Goal", text: $goal,
                          prompt: Text("Optional. Used by done-detector + worktree slug."))

                Toggle("Plan mode (Claude only)", isOn: $planMode)
                    .disabled(agent != .claude)

                Picker("Mode", selection: $mode) {
                    Text("Local").tag(SessionMode.local)
                    Text("Worktree").tag(SessionMode.worktree)
                }
                .pickerStyle(.segmented)
                .help("Local: agent runs in the repo cwd. Worktree: agent runs in .claude/worktrees/<slug> so it can't stomp your edits.")
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
        }
    }

    private func startSession() async {
        isSpawning = true
        errorMessage = nil
        defer { isSpawning = false }
        guard let runtime = AppDelegate.runtime else {
            errorMessage = "Daemon not started — relaunch Clawdmeter."
            return
        }
        do {
            _ = try await model.spawnSession(
                repoPath: repoPath,
                agent: agent,
                planMode: agent == .claude && planMode,
                goal: goal.isEmpty ? nil : goal,
                mode: mode,
                tmux: runtime.tmuxClient
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
    /// Per-session PR mirrors (G16). Lazy-instantiated on first access; we
    /// attach the chat store automatically so PR detection picks up the
    /// agent's `gh pr create` output. Paired with `chatStores` — evicted
    /// together so we don't leak polling tasks.
    private var prMirrors: [UUID: PRMirror] = [:]

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
        if let existing = chatStores[session.id] {
            touchLRU(session.id)
            return existing
        }
        let url: URL? = forcedChatStoreURLs[session.id]
            ?? SessionChatStore.resolveSessionFileURL(repoCwd: session.repoKey)
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
    /// Never evicts the currently-open session (which would tear down the
    /// view's data source mid-render). Pairs eviction with `prMirrors` so
    /// the PR poller's Task is cancelled alongside the JSONLTail.
    private func evictExcessChatStores() {
        let protectedId = openSessionId
        while chatStoreLRU.count > Self.maxResidentChatStores {
            // Find the oldest entry that isn't protected.
            guard let evictIdx = chatStoreLRU.firstIndex(where: { $0 != protectedId })
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
        public var errorDescription: String? {
            switch self {
            case .missingBinary(let m): return m
            }
        }
    }

    public func spawnSession(
        repoPath: String,
        agent: AgentKind,
        planMode: Bool,
        goal: String?,
        mode: SessionMode,
        tmux: TmuxControlClient
    ) async throws -> AgentSession {
        // Fail fast on missing CLIs rather than spawning tmux + the
        // worktree only to error in the agent's pane (where the user
        // can't easily see it without opening the terminal view).
        if let reason = AgentSpawner.preflight() {
            throw SpawnError.missingBinary(reason)
        }
        try await tmux.start()
        var cwd = repoPath
        var worktreePath: String? = nil
        if mode == .worktree {
            let slug = WorktreeManager.slug(goal: goal, sessionId: UUID())
            worktreePath = try await WorktreeManager.shared.add(
                repoRoot: repoPath, slug: slug
            )
            cwd = worktreePath!
        }
        let argv = AgentSpawner.argv(for: NewSessionRequest(
            repoKey: repoPath,
            agent: agent,
            model: nil,
            planMode: planMode,
            goal: goal,
            useWorktree: mode == .worktree
        ))
        let windowId = try await tmux.newWindow(cwd: cwd, child: argv)
        let session = registry.create(
            repoKey: repoPath,
            repoDisplayName: (repoPath as NSString).lastPathComponent,
            agent: agent,
            model: nil,
            goal: goal,
            worktreePath: worktreePath,
            tmuxWindowId: windowId,
            tmuxPaneId: nil,
            planMode: planMode,
            mode: mode
        )
        expandedRepoKeys.insert(repoPath)
        openSessionId = session.id
        await self.refresh()
        return session
    }

    /// G2: switch a live session's mode (Local ↔ Worktree). Kills the
    /// running agent, optionally creates/destroys a worktree, then re-spawns
    /// the agent in the new cwd. Caller owns the D13 overlay around this.
    public func switchMode(sessionId: UUID, to newMode: SessionMode) async {
        guard let runtime = AppDelegate.runtime,
              let session = registry.session(id: sessionId)
        else { return }
        guard newMode != session.mode, newMode != .cloud else { return }
        // Tear down the existing agent.
        if let windowId = session.tmuxWindowId {
            try? await runtime.tmuxClient.killWindow(windowId)
        }
        // Pick the new cwd.
        var newCwd = session.repoKey
        var newWorktree: String? = nil
        switch newMode {
        case .worktree:
            let slug = WorktreeManager.slug(goal: session.goal, sessionId: session.id)
            do {
                newWorktree = try await WorktreeManager.shared.add(
                    repoRoot: session.repoKey, slug: slug
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
            repoKey: session.repoKey,
            agent: session.agent,
            model: session.model,
            planMode: session.status == .planning,
            goal: session.goal,
            useWorktree: newMode == .worktree
        ))
        do {
            let newWindowId = try await runtime.tmuxClient.newWindow(cwd: newCwd, child: argv)
            registry.updateRuntime(
                id: sessionId,
                worktreePath: newWorktree,
                tmuxWindowId: newWindowId,
                tmuxPaneId: nil,
                mode: newMode
            )
        } catch {
            // Spawn failed — surface via lastError once we plumb it; for now,
            // session status stays at degraded by the supervisor.
        }
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
        if let worktreePath = session.worktreePath {
            _ = try? await WorktreeManager.shared.delete(
                repoRoot: session.repoKey,
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
        try? await runtime.tmuxClient.start()
        let cwd = parent.worktreePath ?? parent.repoKey
        let argv = AgentSpawner.argv(for: NewSessionRequest(
            repoKey: parent.repoKey,
            agent: parent.agent,
            model: parent.model,
            planMode: false,
            goal: nil,
            useWorktree: parent.mode == .worktree
        ))
        do {
            let windowId = try await runtime.tmuxClient.newWindow(cwd: cwd, child: argv)
            let child = registry.create(
                repoKey: parent.repoKey,
                repoDisplayName: parent.repoDisplayName,
                agent: parent.agent,
                model: parent.model,
                goal: nil,
                worktreePath: parent.worktreePath,
                tmuxWindowId: windowId,
                tmuxPaneId: nil,
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
        let cwd = session.worktreePath ?? session.repoKey
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
              let windowId = session.tmuxWindowId
        else { return }
        do {
            try await runtime.tmuxClient.killWindow(windowId)
            let argv = [
                "/Users/darshanbathija_1/.local/bin/claude",
                "--permission-mode", "acceptEdits",
            ]
            let cwd = session.worktreePath ?? session.repoKey
            _ = try await runtime.tmuxClient.newWindow(cwd: cwd, child: argv)
            registry.updateStatus(id: id, status: .running)
        } catch {}
    }
}
