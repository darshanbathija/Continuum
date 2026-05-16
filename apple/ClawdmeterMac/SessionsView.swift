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
                        let suffix = repo.liveSessionCount > 0 ? "  • live" : ""
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

    /// When the user opens a repo's outside-Clawdmeter latest session, we
    /// synthesize a read-only AgentSession instance. Stored here so it
    /// survives the workspace's render cycle.
    @Published public var openOutsideRepoKey: String?
    private var syntheticOutsideSessions: [String: AgentSession] = [:]

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
        if let key = openOutsideRepoKey,
           let s = syntheticOutsideSessions[key] {
            return s
        }
        return nil
    }

    /// True when the currently-open session is the synthetic outside-
    /// Clawdmeter one. The center pane disables composer + actions.
    public var openSessionIsReadOnly: Bool {
        openOutsideRepoKey != nil && openSessionId == nil
    }

    /// Open a read-only chat view for a repo whose live activity is from
    /// outside Clawdmeter (Conductor / Cursor / Terminal-launched agent).
    public func openOutsideSession(repoKey: String) {
        let displayName = repos.first { $0.key == repoKey }?.displayName
            ?? (repoKey as NSString).lastPathComponent
        let synth = AgentSession(
            id: UUID(),
            repoKey: repoKey,
            repoDisplayName: displayName,
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0
        )
        syntheticOutsideSessions[repoKey] = synth
        openOutsideRepoKey = repoKey
        openSessionId = nil
    }

    public func closeChatView() {
        openSessionId = nil
        openOutsideRepoKey = nil
    }

    public let repoIndex: RepoIndex
    public let registry: AgentSessionRegistry
    public let supervisor: TmuxSupervisor
    private var refreshTask: Task<Void, Never>?

    /// Per-session chat stores. Shared between the chat-thread view and
    /// review pane (plan tracker, sources, artifacts) so they observe the
    /// same parsed JSONL. Stored across re-renders to avoid re-parsing.
    private var chatStores: [UUID: SessionChatStore] = [:]

    public init(
        repoIndex: RepoIndex,
        registry: AgentSessionRegistry,
        supervisor: TmuxSupervisor
    ) {
        self.repoIndex = repoIndex
        self.registry = registry
        self.supervisor = supervisor
    }

    /// Get or create the chat store for a session.
    public func chatStore(for session: AgentSession) -> SessionChatStore? {
        if let existing = chatStores[session.id] { return existing }
        guard let url = SessionChatStore.resolveSessionFileURL(repoCwd: session.repoKey) else {
            return nil
        }
        let store = SessionChatStore(sessionId: session.id, sessionFileURL: url)
        store.start()
        chatStores[session.id] = store
        return store
    }

    public func closeChatStore(for sessionId: UUID) {
        chatStores[sessionId]?.stop()
        chatStores.removeValue(forKey: sessionId)
    }

    public func sessions(for repoKey: String, includeArchived: Bool = false) -> [AgentSession] {
        registry.sessions.filter { s in
            guard s.repoKey == repoKey else { return false }
            if !includeArchived, s.archivedAt != nil { return false }
            return true
        }
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

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await repoIndex.refresh()
        self.repos = snapshot
        for repo in snapshot {
            if !sessions(for: repo.key).isEmpty || repo.liveSessionCount > 0 {
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
    public func spawnSession(
        repoPath: String,
        agent: AgentKind,
        planMode: Bool,
        goal: String?,
        mode: SessionMode,
        tmux: TmuxControlClient
    ) async throws -> AgentSession {
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
