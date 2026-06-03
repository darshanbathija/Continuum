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
    @StateObject private var launcher = SessionLauncherModel()
    @State private var selectedModelId: String?
    @State private var selectedModelWasUserChosen = false
    // v0.7.9: worktree by default. Local stays in the enum for
    // back-compat but the mode chip is no longer in the New Session UI.
    @State private var mode: SessionMode = .worktree
    @State private var isSpawning: Bool = false
    @State private var errorMessage: String?
    // Conductor parity: per-repo setup script run in each new worktree.
    @State private var setupScript: String = ""

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

                if launcher.selectableAgents.isEmpty {
                    Text("Enable a provider in Settings → Providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Agent", selection: $agent) {
                        ForEach(launcher.selectableAgents, id: \.self) { kind in
                            Text(kind.tahoeProvider.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                HStack {
                    Text("Model")
                    Spacer()
                    ModelPicker(
                        selectedModelId: selectedModelId,
                        catalog: launcher.modelCatalog,
                        agent: agent
                    ) { entry in
                        selectedModelId = entry.id
                        selectedModelWasUserChosen = true
                    }
                    .disabled(launcher.selectableAgents.isEmpty)
                }

                TextField("Goal", text: $goal,
                          prompt: Text("Optional. Used by done-detector + worktree slug."))

                TextField("Setup script", text: $setupScript,
                          prompt: Text("Optional. e.g. npm install — runs in the new worktree"),
                          axis: .vertical)
                    .lineLimit(2...6)
                    .font(.system(.caption, design: .monospaced))
                    .help("Per-repo. Runs once in each new worktree before the agent, under a login shell with the repo's PATH. $CONTINUUM_WORKTREE and $CONTINUUM_REPO_ROOT are exported (e.g. ln -s \"$CONTINUUM_REPO_ROOT/node_modules\" node_modules).")

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
                        case .grok: return "Grok runs its own approval flow; plan mode here is a UI hint."
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
                .tint(SessionsV2Theme.accent)
                .disabled(repoPath.isEmpty || isSpawning || launcher.selectableAgents.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            if let selected = model.selectedRepoKey { repoPath = selected }
            setupScript = RepoSetupScriptStore.script(forRepoRoot: repoPath) ?? ""
            ensureSelectedModelIsAvailable()
        }
        .onChange(of: repoPath) { _, newValue in
            setupScript = RepoSetupScriptStore.script(forRepoRoot: newValue) ?? ""
        }
        .task {
            await launcher.refreshProviderAvailability()
            normalizeAgentAvailability()
            ensureSelectedModelIsAvailable()
        }
        .onChange(of: agent) { _, _ in
            selectedModelWasUserChosen = false
            selectedModelId = launcher.chipDefaults(for: agent).modelId
            if agent == .cursor { planMode = false }
        }
        .onChange(of: launcher.availability) { _, _ in
            normalizeAgentAvailability()
            ensureSelectedModelIsAvailable()
        }
        .onChange(of: launcher.modelCatalog.updatedAt) { _, _ in
            ensureSelectedModelIsAvailable()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderEnablement.changedNotification)) { _ in
            Task {
                await launcher.refreshProviderAvailability()
                normalizeAgentAvailability()
                ensureSelectedModelIsAvailable()
            }
        }
    }

    private func ensureSelectedModelIsAvailable() {
        guard !launcher.selectableAgents.isEmpty else {
            selectedModelId = nil
            return
        }
        selectedModelId = launcher.resolvedModelId(
            for: agent,
            selectedModelId: selectedModelWasUserChosen ? selectedModelId : nil
        )
    }

    private func normalizeAgentAvailability() {
        guard let normalized = launcher.availableAgentOrDefault(agent) else {
            selectedModelId = nil
            return
        }
        if normalized != agent {
            agent = normalized
            selectedModelWasUserChosen = false
        }
        if agent == .cursor {
            planMode = false
        }
    }

    private func supportsEffort(modelId: String?) -> Bool {
        launcher.supportsEffort(modelId: modelId)
    }

    private func startSession() async {
        isSpawning = true
        errorMessage = nil
        defer { isSpawning = false }
        // Persist the per-repo setup script BEFORE spawning so this session
        // (and future quick "+" spawns in this repo) pick it up via
        // RepoSetupScriptStore inside WorktreeManager.provision.
        RepoSetupScriptStore.setScript(setupScript, forRepoRoot: repoPath)
        guard let runtime = AppDelegate.runtime else {
            errorMessage = "Daemon not started — relaunch Clawdmeter."
            return
        }
        guard launcher.selectableAgents.contains(agent) else {
            errorMessage = "Enable a provider in Settings → Providers."
            return
        }
        // Seed effort from ComposerStore.ChipDefaults while model comes from
        // this sheet's picker. Cursor models are the live account-visible
        // probe result with Cursor default / Auto as the fallback.
        let defaults = launcher.chipDefaults(for: agent)
        let selectedModel = selectedModelId ?? launcher.defaultModelId(for: agent)
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
            errorMessage = SessionsModel.humanize(spawnError: error)
        }
    }

    // (former TmuxError-only humanizer removed — startSession() now routes
    // every failure through SessionsModel.humanize(spawnError:) so worktree
    // and access errors are humanized too, not just tmux ones.)
}

struct PendingFirstSendRecovery: Equatable {
    let text: String
    let attachments: [ComposerStore.Attachment]
    let error: ComposerStore.SendError
    /// When true, the queued draft auto-sends the moment the session is ready
    /// (used for sends made while a "+" session is still provisioning) instead
    /// of being restored to the composer for a manual retry.
    var autoSendWhenReady: Bool = false
}

struct WorkspaceDraftTab: Identifiable, Equatable {
    let id: UUID
    let workspaceKey: WorkspaceKey
    let mode: SessionMode
    let agent: AgentKind
    let modelId: String?
    let effort: ReasoningEffort?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        workspaceKey: WorkspaceKey,
        mode: SessionMode,
        agent: AgentKind,
        modelId: String?,
        effort: ReasoningEffort?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceKey = workspaceKey
        self.mode = mode
        self.agent = agent
        self.modelId = modelId
        self.effort = effort
        self.createdAt = createdAt
    }
}

struct WorkspaceTerminalTab: Identifiable, Equatable {
    let id: UUID
    let sessionId: UUID
    let workspaceKey: WorkspaceKey
    let paneRefId: UUID?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        workspaceKey: WorkspaceKey,
        paneRefId: UUID?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.workspaceKey = workspaceKey
        self.paneRefId = paneRefId
        self.createdAt = createdAt
    }
}

struct WorkspaceDocumentTab: Identifiable, Equatable {
    let id: UUID
    let sessionId: UUID
    let workspaceKey: WorkspaceKey
    let path: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        workspaceKey: WorkspaceKey,
        path: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.workspaceKey = workspaceKey
        self.path = path
        self.createdAt = createdAt
    }

    var title: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Markdown" : name
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

    /// Sessions whose worktree + agent are still being provisioned in the
    /// background (created optimistically by "+" so the composer is usable in
    /// <250ms). While in this set, the session has no worktree/pane yet; sends
    /// queue and auto-flush the moment provisioning completes.
    @Published public var provisioningSessionIds: Set<UUID> = []
    public func isProvisioning(_ id: UUID) -> Bool { provisioningSessionIds.contains(id) }

    /// Live "Setup Trail" state per provisioning session — drives the animated
    /// step ribbon (worktree → files → setup → agent) shown above the composer.
    @Published var provisioningProgress: [UUID: ProvisioningProgress] = [:]

    /// Apply a real provisioning milestone (from WorktreeManager) to the trail.
    private func applyProvisionPhase(_ phase: WorktreeManager.ProvisionPhase, sessionId: UUID) {
        guard var p = provisioningProgress[sessionId] else { return }
        withAnimation(.snappy(duration: 0.28)) {
            switch phase {
            case .worktreeReady(let branch):
                p.branch = branch
                p.set(.worktree, .done); p.set(.files, .active)
            case .copyingFiles:
                p.set(.worktree, .done); p.set(.files, .active)
            case .filesCopied(let count, let noop):
                p.filesCopied = count; p.filesNoop = noop
                p.set(.files, .done); p.set(.setup, .active)
            case .runningSetup:
                p.set(.files, .done); p.set(.setup, .active)
            case .setupFinished:
                p.setupRan = true; p.set(.setup, .done); p.set(.agent, .active)
            case .setupSkipped:
                p.setupRan = false; p.set(.setup, .skipped); p.set(.agent, .active)
            }
            provisioningProgress[sessionId] = p
        }
    }

    /// Currently-open session in the workspace center pane. nil = empty
    /// center pane (workspace still renders sidebar + review).
    @Published public var openSessionId: UUID?
    @Published var draftWorkspaceTab: WorkspaceDraftTab?
    @Published var workspaceTerminalTabs: [WorkspaceTerminalTab] = []
    @Published var selectedWorkspaceTerminalTabId: UUID?
    @Published var workspaceDocumentTabs: [WorkspaceDocumentTab] = []
    @Published var selectedWorkspaceDocumentTabId: UUID?

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
    /// JSONL paths opened as read-only external sessions. These use the
    /// same forced tailing path as first-party pinned stores, but must not
    /// count as Clawdmeter-owned for sidebar dedupe.
    private var externalForcedJSONLPaths: Set<String> = []

    /// Sidebar search query (G6). Filters repos + sessions by displayName,
    /// goal, and message body substring. Empty = no filter.
    @Published public var searchQuery: String = ""

    /// When true, archived sessions are visible in the sidebar (G7).
    @Published public var showArchived: Bool = false

    @Published var pendingFirstSendRecoveryVersion: Int = 0
    private var pendingFirstSendRecoveries: [UUID: PendingFirstSendRecovery] = [:]

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

    var selectedWorkspaceTerminalTab: WorkspaceTerminalTab? {
        guard let id = selectedWorkspaceTerminalTabId,
              let tab = workspaceTerminalTabs.first(where: { $0.id == id }),
              let session = registry.session(id: tab.sessionId),
              canOpenWorkspaceTerminalTab(from: session),
              let sessionKey = WorkspaceKey.of(session),
              sessionKey == tab.workspaceKey
        else { return nil }
        if let paneRefId = tab.paneRefId,
           !session.terminalPanes.contains(where: { $0.id == paneRefId }) {
            return nil
        }
        return tab
    }

    var selectedWorkspaceDocumentTab: WorkspaceDocumentTab? {
        guard let id = selectedWorkspaceDocumentTabId,
              let tab = workspaceDocumentTabs.first(where: { $0.id == id }),
              let session = registry.session(id: tab.sessionId),
              session.archivedAt == nil,
              let sessionKey = WorkspaceKey.of(session),
              sessionKey == tab.workspaceKey
        else { return nil }
        return tab
    }

    /// Open a specific outside-Clawdmeter JSONL as a read-only chat. Each
    /// JSONL gets its own synthetic AgentSession, so flipping between
    /// recent rows in the sidebar doesn't share state.
    public func openOutsideSession(recent: RecentSession, repoKey: String, repoDisplayName: String) {
        let url = URL(fileURLWithPath: recent.path)
        let path = recent.path
        if let existing = syntheticOutsideSessions[path] {
            draftWorkspaceTab = nil
            selectedWorkspaceTerminalTabId = nil
            selectedWorkspaceDocumentTabId = nil
            openOutsideJSONLPath = path
            openSessionId = nil
            forcedChatStoreURLs[existing.id] = url
            needsURLRevalidation.insert(existing.id)
            externalForcedJSONLPaths.insert(Self.canonicalJSONLPath(path))
            return
        }
        let synth = AgentSession(
            id: UUID(),
            repoKey: nil,
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
            lastEventSeq: 0,
            runtimeCwd: repoKey
        )
        syntheticOutsideSessions[path] = synth
        forcedChatStoreURLs[synth.id] = url
        needsURLRevalidation.insert(synth.id)
        externalForcedJSONLPaths.insert(Self.canonicalJSONLPath(path))
        draftWorkspaceTab = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = path
        openSessionId = nil
    }

    public func closeChatView() {
        openSessionId = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
    }

    public func prepareNewSession(in repoKey: String?) {
        selectedRepoKey = repoKey
        showingNewSessionSheet = true
    }

    /// One-click "+ New workspace" for a known repo. Bypasses the New
    /// Session sheet entirely — defaults are Codex / GPT-5.5 / max
    /// effort / plan mode / worktree, worktree branch auto-named by the
    /// existing city-namer. The user jumps straight into the composer.
    ///
    /// **No silent fall-back to the sheet.** The whole point of this
    /// button is to NOT see the sheet; routing back to it on error is
    /// the bug the user keeps re-reporting. Failures surface as a
    /// `.clawdmeterShowTransientToast` with the underlying error and a
    /// hint that Option-click opens the full sheet when the user
    /// actually wants to customize.
    public func quickSpawnInRepo(_ repoKey: String) {
        // `.other` and any non-resolvable bucket genuinely have no path
        // to spawn into. Route through the sheet ONLY in this terminal
        // case — there's no quick-spawn that makes sense without a
        // real repo path.
        guard repos.contains(where: { $0.key == repoKey }),
              repoKey != RepoKey.other else {
            prepareNewSession(in: repoKey)
            return
        }
        guard let runtime = AppDelegate.runtime else {
            Self.postQuickSpawnFailureToast(
                title: "Daemon offline",
                detail: "Restart Clawdmeter to spawn sessions."
            )
            return
        }
        let agent: AgentKind = .codex
        let modelId = "gpt-5.5"
        let effort: ReasoningEffort = .max
        let sessionId = UUID()
        // INSTANT (<250ms): expand the repo + create an optimistic provisional
        // session (no worktree/pane yet) and open it, so the composer is usable
        // immediately. The worktree (new branch + Conductor-style file copy +
        // setup script) and the codex agent are provisioned in the BACKGROUND;
        // a prompt typed/sent meanwhile is queued and auto-flushes on ready.
        expandedRepoKeys.insert(repoKey)
        selectedRepoKey = repoKey
        provisioningSessionIds.insert(sessionId)
        provisioningProgress[sessionId] = ProvisioningProgress()
        Task { @MainActor in
            do {
                let provisional = try await registry.create(
                    repoKey: repoKey,
                    repoDisplayName: (repoKey as NSString).lastPathComponent,
                    agent: agent,
                    model: modelId,
                    goal: nil,
                    worktreePath: nil,
                    tmuxWindowId: nil,
                    tmuxPaneId: nil,
                    planMode: true,
                    mode: .worktree,
                    effort: effort,
                    ownsWorktree: false,
                    id: sessionId
                )
                openSessionId = provisional.id
                provisionAndAttachWorktree(
                    sessionId: sessionId, repoKey: repoKey,
                    agent: agent, model: modelId, effort: effort, tmux: runtime.tmuxClient
                )
            } catch {
                // registry.create failed → no session was persisted; just undo
                // the optimistic UI state (trail + city reservation) + toast.
                provisioningSessionIds.remove(sessionId)
                provisioningProgress[sessionId] = nil
                CityNamer.shared.release(sessionId)
                if openSessionId == sessionId { openSessionId = nil }
                NSLog("[Clawdmeter] quickSpawn provisional create failed repo=%@: %@", repoKey, "\(error)")
                Self.postQuickSpawnFailureToast(
                    title: "Couldn’t start a session in \((repoKey as NSString).lastPathComponent)",
                    detail: Self.humanize(spawnError: error)
                )
            }
        }
    }

    /// Background half of the optimistic "+" spawn: provisions the worktree
    /// (new branch + Conductor-style file copy + setup script), spawns the codex
    /// agent in a tmux pane, attaches both to the already-open provisional
    /// session, then flushes any prompt the user queued while it was setting up.
    /// All errors are non-blocking: the provisional session is torn down and a
    /// toast surfaces, never the sheet.
    private func provisionAndAttachWorktree(
        sessionId: UUID,
        repoKey: String,
        agent: AgentKind,
        model: String,
        effort: ReasoningEffort,
        tmux: TmuxControlClient
    ) {
        Task { @MainActor in
            do {
                let city = CityNamer.shared.cityName(for: sessionId)
                let slug = WorktreeManager.slug(city: city)
                let provisioned = try await WorktreeManager.shared.provision(
                    repoRoot: repoKey,
                    slug: slug,
                    branchName: slug,
                    filesToCopy: filesToCopySettings(forRepoRoot: repoKey),
                    setupScript: RepoSetupScriptStore.script(forRepoRoot: repoKey),
                    onPhase: { [weak self] phase in
                        Task { @MainActor in self?.applyProvisionPhase(phase, sessionId: sessionId) }
                    }
                )
                let cwd = provisioned.path
                let argv = AgentSpawner.codexArgv(
                    model: model, planMode: true, effort: effort, workspacePath: cwd
                ) ?? []
                guard !argv.isEmpty else {
                    throw SpawnError.missingBinary("Codex CLI not found on PATH. Configure in Settings → Diagnostics.")
                }
                let resolvedEnv = try resolveRepoEnv(repoRoot: repoKey, cwd: cwd)
                let env = resolvedEnv?.environment ?? [:]
                // Guard the pane spawn with a deadline — a wedged tmux control
                // connection would otherwise leave the trail spinning on
                // "Starting Codex" forever (the symptom just hit).
                let window = try await Self.withSpawnTimeout(20) {
                    try await tmux.newWindow(cwd: cwd, child: argv, environment: env)
                }
                try await registry.updateRuntime(
                    id: sessionId,
                    worktreePath: cwd,
                    provisioning: provisioned.metadata,
                    runtimeCwd: cwd,
                    tmuxWindowId: window.windowId,
                    tmuxPaneId: window.paneId,
                    mode: .worktree,
                    ownsWorktree: true
                )
                recordWorkspaceSession(repoRoot: repoKey, sessionId: sessionId)
                provisioningSessionIds.remove(sessionId)
                await refresh()
                // Final step: mark the agent ready (final spring checkmark), then
                // let the "Codex ready" state linger briefly and dismiss the trail.
                if var p = provisioningProgress[sessionId] {
                    withAnimation(.snappy(duration: 0.28)) {
                        p.set(.worktree, .done)
                        if p.state(.files) != .done { p.set(.files, .done) }
                        if p.state(.setup) != .done && p.state(.setup) != .skipped { p.set(.setup, .skipped) }
                        p.set(.agent, .done)
                        provisioningProgress[sessionId] = p
                    }
                }
                // Ready — flush any prompt the user queued while provisioning.
                signalPendingFirstSendReady()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self?.provisioningProgress[sessionId] = nil
                    }
                }
            } catch {
                provisioningSessionIds.remove(sessionId)
                provisioningProgress[sessionId] = nil
                CityNamer.shared.release(sessionId)
                try? await registry.delete(id: sessionId)
                if openSessionId == sessionId { openSessionId = nil }
                NSLog("[Clawdmeter] quickSpawn provision failed sid=%@ repo=%@: %@",
                      sessionId.uuidString, repoKey, "\(error)")
                Self.postQuickSpawnFailureToast(
                    title: "Couldn’t set up the worktree in \((repoKey as NSString).lastPathComponent)",
                    detail: Self.humanize(spawnError: error)
                )
            }
        }
    }

    /// Bottom-anchored transient toast wired to MacRootView's existing
    /// `.clawdmeterShowTransientToast` observer. Six-second visible
    /// window is enough to read a multi-line error without blocking.
    private static func postQuickSpawnFailureToast(title: String, detail: String) {
        let toast = TransientToast(title: title, detail: detail, duration: 6)
        NotificationCenter.default.post(
            name: .clawdmeterShowTransientToast,
            object: nil,
            userInfo: ["toast": toast]
        )
    }

    /// Collapse the spawn / worktree / tmux / shell error zoo into ONE human,
    /// actionable line. Raw git/tmux/shell stderr — e.g. "fatal: Unable to
    /// read current working directory: Operation not permitted" or the
    /// "(…ShellError error 2.)" NSError fallback — must never reach the UI
    /// verbatim. Match the known low-level failures and say what to do next.
    /// Internal (not private) so `NewSessionMacSheet` can route its sheet
    /// errors through the same humanizer the quick-spawn toast uses.
    static func humanize(spawnError error: Error) -> String {
        // Failures that look identical across git, tmux, and the agent CLIs
        // are matched on the underlying stderr/text, regardless of the Swift
        // error type that wrapped them.
        func classify(_ raw: String) -> String? {
            let s = raw.lowercased()
            if s.contains("operation not permitted")
                || s.contains("permission denied")
                || s.contains("unable to read current working directory") {
                return "Continuum couldn’t access that folder. If you just updated the app, fully quit it (⌘Q) and reopen so the new permissions take effect — then try again."
            }
            if s.contains("not a git repository") {
                return "That folder isn’t a git repository. Pick a folder that contains a “.git”, or use Clone or Quick Start to set one up."
            }
            if s.contains("no such file") || s.contains("does not exist") {
                return "That path no longer exists. Pick the repo again from the list."
            }
            return nil
        }
        switch error {
        case let spawn as SpawnError:
            return spawn.errorDescription ?? "Couldn’t start the agent."
        case let wt as WorktreeManager.WorktreeError:
            if case .gitFailed(_, let stderr) = wt, let friendly = classify(stderr) { return friendly }
            if case .gitNotFound = wt {
                return "git wasn’t found. Install the Xcode command-line tools (run “xcode-select --install”) or Homebrew git, then try again."
            }
            return wt.errorDescription ?? "Couldn’t create the worktree."
        case let tmux as TmuxControlClient.TmuxError:
            switch tmux {
            case .notStarted:           return "The terminal backend isn’t ready yet — try again in a moment."
            case .serverExited:         return "The terminal backend stopped unexpectedly. Try again; if it persists, fully quit and reopen Continuum."
            case .ptyClosed:            return "The terminal session closed unexpectedly. Try again."
            case .commandFailed(let s): return classify(s) ?? "The terminal backend reported: \(s)"
            case .invalidArgument(let s): return "Internal error talking to the terminal backend (\(s))."
            }
        default:
            let desc = (error as NSError).localizedDescription
            return classify(desc) ?? "Couldn’t start the session. \(desc)"
        }
    }

    /// Persist a user-facing code-session label through the registry-backed
    /// session record. The sidebar, header, command palette, iOS mirror, and
    /// daemon `/rename` route all read `AgentSession.customName`, so local
    /// presentation-only title overrides are not enough for session rename.
    @discardableResult
    public func renameSession(id: UUID, name: String?) async -> Bool {
        guard registry.session(id: id) != nil else { return false }
        do {
            try await registry.rename(id: id, name: name)
            return true
        } catch {
            return false
        }
    }

    func queueFirstSendRecovery(
        sessionId: UUID,
        text: String,
        attachments: [ComposerStore.Attachment],
        error: ComposerStore.SendError,
        autoSendWhenReady: Bool = false
    ) {
        pendingFirstSendRecoveries[sessionId] = PendingFirstSendRecovery(
            text: text,
            attachments: attachments,
            error: error,
            autoSendWhenReady: autoSendWhenReady
        )
        pendingFirstSendRecoveryVersion += 1
    }

    /// Re-triggers `applyPendingFirstSendRecovery` in the open session view —
    /// used by the background provisioner to flush a queued auto-send once the
    /// worktree + agent are ready.
    func signalPendingFirstSendReady() {
        pendingFirstSendRecoveryVersion += 1
    }

    func takeFirstSendRecovery(sessionId: UUID) -> PendingFirstSendRecovery? {
        pendingFirstSendRecoveries.removeValue(forKey: sessionId)
    }

    public let repoIndex: RepoIndex
    public let registry: AgentSessionRegistry
    public let supervisor: TmuxSupervisor
    public let workspaceStore: WorkspaceStore
    public let repoEnvResolver: RepoEnvRuntimeResolver?
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
    /// Per-session cached `ComposerStore` (tab-switch perf). Built once on
    /// first open and reused, so switching Code tabs no longer rebuilds the
    /// composer (and discards the in-progress draft + model/effort/mode chip
    /// selections) on every flip. Evicted alongside `chatStores` under the
    /// same LRU window so it stays bounded.
    private var composerStores: [UUID: ComposerStore] = [:]
    /// The tmux pane id a session's chat store was last resolved against,
    /// keyed by session id ("" = resolved against no live pane). Every respawn
    /// (config swap, approve-plan, revive) assigns a NEW pane, so a changed
    /// pane id is the cheap, can't-miss signal that the Codex rollout JSONL may
    /// have rotated and the tailed file must be re-resolved. When the pane is
    /// unchanged — the common tab-toggle case — we skip the synchronous
    /// parent-walk + per-file stat scan `resolveSessionFileURL` runs, which on
    /// every warm hit was the dominant main-thread stall when toggling tabs.
    private var lastResolvedPaneId: [UUID: String] = [:]
    /// Sessions whose tailed JSONL must be re-resolved on the next `chatStore`
    /// access regardless of pane id — set when a forced JSONL pin is applied
    /// (continue-here / resume / synthetic-read-only) so the override takes
    /// effect immediately even though the pane id may be unchanged.
    private var needsURLRevalidation: Set<UUID> = []
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
    private var prCoordinators: [UUID: PRCoordinator] = [:]

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
        supervisor: TmuxSupervisor,
        workspaceStore: WorkspaceStore,
        repoEnvResolver: RepoEnvRuntimeResolver? = nil
    ) {
        self.repoIndex = repoIndex
        self.registry = registry
        self.supervisor = supervisor
        self.workspaceStore = workspaceStore
        self.repoEnvResolver = repoEnvResolver
    }

    /// Lazy `RepoOnboarding` service. Wired with self-referential closures
    /// for refresh + selection; `[weak self]` avoids retain cycles in case
    /// the service outlives the model (unlikely in practice — both live
    /// for the app's lifetime).
    public lazy var repoOnboarding: RepoOnboarding = {
        RepoOnboarding(
            workspaceStore: workspaceStore,
            repoIndex: repoIndex,
            refresh: { [weak self] in await self?.refresh() },
            onWorkspaceRegistered: { [weak self] record in
                self?.selectedRepoKey = record.repoRoot
            }
        )
    }()

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
        // Optimistic "+" session still provisioning: its effectiveCwd is the
        // REPO ROOT (worktree not created yet), so resolving a JSONL here would
        // tail the repo's newest codex rollout — surfacing an UNRELATED old
        // session's transcript AND title (latestAssistantSummary). Stay empty
        // until the real worktree is attached; effectiveCwd then points at the
        // new worktree and resolution is correct.
        if isProvisioning(session.id) { return nil }
        if let existing = chatStores[session.id] {
            touchLRU(session.id)
            // Audit P1 fix: when the daemon spawns a fresh post-approve
            // rollout (Codex `approve-plan` writes a new JSONL), the cached
            // store keeps tailing the dead plan-mode file unless we swap it
            // in place. But resolving on EVERY warm hit means a synchronous
            // parent-walk + per-file stat scan of ~/.claude/projects/<repo>/
            // on every Code-tab flip — the dominant main-thread stall when
            // toggling tabs. Every respawn (approve-plan, config swap,
            // revive) assigns a new tmux pane, so a changed pane id (or an
            // explicit pin via needsURLRevalidation) is the cheap can't-miss
            // signal that the rollout may have rotated; an unchanged pane —
            // the common toggle case — skips the scan entirely.
            let paneToken = session.tmuxPaneId ?? ""
            let forcedRevalidation = needsURLRevalidation.remove(session.id) != nil
            if lastResolvedPaneId[session.id] != paneToken || forcedRevalidation {
                lastResolvedPaneId[session.id] = paneToken
                let resolved = forcedChatStoreURLs[session.id]
                    ?? SessionChatStore.resolveSessionFileURL(repoCwd: session.effectiveCwd)
                if let resolved, existing.currentFileURL != resolved {
                    existing.switchTailedFile(to: resolved)
                }
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
        // Record the pane the store was just resolved against so the next warm
        // hit doesn't redundantly re-scan (see lastResolvedPaneId).
        needsURLRevalidation.remove(session.id)
        lastResolvedPaneId[session.id] = session.tmuxPaneId ?? ""
        evictExcessChatStores()
        return store
    }

    public var knownOwnedJSONLPaths: Set<String> {
        var paths = Set<String>()
        for url in forcedChatStoreURLs.values {
            let path = Self.canonicalJSONLPath(url.path)
            if !externalForcedJSONLPaths.contains(path) {
                paths.insert(path)
            }
        }
        for store in chatStores.values where !store.isSDKOnly {
            let path = Self.canonicalJSONLPath(store.currentFileURL.path)
            if !externalForcedJSONLPaths.contains(path) {
                paths.insert(path)
            }
        }
        if let daemonPaths = AppDelegate.runtime?.agentControlServer.ownedSessionJSONLPaths {
            for daemonPath in daemonPaths {
                let path = Self.canonicalJSONLPath(daemonPath)
                if !externalForcedJSONLPaths.contains(path) {
                    paths.insert(path)
                }
            }
        }
        return paths
    }

    private nonisolated static func canonicalJSONLPath(_ path: String) -> String {
        (path as NSString).standardizingPath
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
            composerStores.removeValue(forKey: evictId)
            lastResolvedPaneId.removeValue(forKey: evictId)
            needsURLRevalidation.remove(evictId)
            prMirrors[evictId]?.detach()
            prMirrors.removeValue(forKey: evictId)
            prCoordinators[evictId]?.stopWatching()
            prCoordinators.removeValue(forKey: evictId)
        }
    }

    public func closeChatStore(for sessionId: UUID) {
        chatStores[sessionId]?.stop()
        chatStores.removeValue(forKey: sessionId)
        chatStoreLRU.removeAll { $0 == sessionId }
        composerStores.removeValue(forKey: sessionId)
        lastResolvedPaneId.removeValue(forKey: sessionId)
        needsURLRevalidation.remove(sessionId)
        prMirrors[sessionId]?.detach()
        prMirrors.removeValue(forKey: sessionId)
        prCoordinators[sessionId]?.stopWatching()
        prCoordinators.removeValue(forKey: sessionId)
    }

    /// Tab-switch perf: lazy per-session composer store. Built once with the
    /// session's effective model/effort/mode + autopilot state and reused, so
    /// reopening a Code tab restores the in-progress draft + chip selections
    /// instead of rebuilding (and discarding them) on every flip. `CenterThread`
    /// observes this cached instance rather than constructing its own
    /// `@StateObject`, which is what let us drop the `.id(session.id)` view-
    /// identity teardown that made switching tabs feel heavy.
    public func composerStore(for session: AgentSession, catalog: ModelCatalog) -> ComposerStore {
        if let existing = composerStores[session.id] { return existing }
        let store = ComposerStore(mode: .bound(sessionId: session.id))
        let resolvedModel = CenterThread.effectiveModelId(for: session, catalog: catalog)
        store.modelId = resolvedModel
        store.effort = CenterThread.effectiveEffort(for: session, modelId: resolvedModel, catalog: catalog)
        store.mode = session.mode
        store.agent = session.agent
        store.planMode = session.status == .planning
        store.repoKey = session.repoKey
        store.autopilotEnabled = AutopilotState.shared.isEnabled(sessionId: session.id)
        composerStores[session.id] = store
        return store
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

    func prCoordinator(for session: AgentSession) -> PRCoordinator {
        if let existing = prCoordinators[session.id] { return existing }
        let mirror = prMirror(for: session)
        let coordinator = PRCoordinator(
            sessionId: session.id,
            client: AppDelegate.runtime?.loopbackClient,
            fallback: mirror
        )
        coordinator.attach(chatStore: chatStore(for: session))
        prCoordinators[session.id] = coordinator
        return coordinator
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
            if repo.recentSessions.contains(where: { Self.recentMatchesSearch($0, repo: repo, query: q) }) {
                return true
            }
            let matches = filter(sessions: sessions(for: repo.key, includeArchived: showArchived))
            return !matches.isEmpty
        }
    }

    private nonisolated static func recentMatchesSearch(_ recent: RecentSession, repo: AgentRepo, query: String) -> Bool {
        if repo.displayName.lowercased().contains(query) { return true }
        if recent.path.lowercased().contains(query) { return true }
        if let title = recent.firstPrompt?.lowercased(), title.contains(query) { return true }
        if let alias = recent.customName?.lowercased(), alias.contains(query) { return true }
        if AgentKindUI.displayName(for: recent.provider).lowercased().contains(query) { return true }
        return false
    }

    /// G8 keyboard nav: flat list of sessions visible in the sidebar, in
    /// the order they're rendered (parents first, children nested under).
    /// Used by Cmd+1..9 jump shortcuts and Cmd+; sub-chat detection.
    public var visibleSessions: [AgentSession] {
        var out: [AgentSession] = []
        let canonical = SessionSidebarGrouper.canonicalizeRepos(filteredRepos)
        for repo in canonical.repos {
            guard expandedRepoKeys.contains(repo.key) else { continue }
            let all = filter(sessions: sessions(for: repo.key, aliases: canonical.keyAliases, includeArchived: showArchived))
            let roots = all.filter { $0.parentSessionId == nil }
            for root in roots {
                out.append(root)
                appendChildren(of: root, into: &out, allowed: Set(all.map { $0.id }))
            }
        }
        return out
    }

    private func sessions(
        for canonicalRepoKey: String,
        aliases: [String: String],
        includeArchived: Bool
    ) -> [AgentSession] {
        registry.sessions.filter { session in
            guard let key = session.repoKey else { return false }
            guard (aliases[key] ?? key) == canonicalRepoKey else { return false }
            if !includeArchived, session.archivedAt != nil { return false }
            return true
        }
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
        draftWorkspaceTab = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = session.id
    }

    public func openSession(_ session: AgentSession) {
        // Do NOT clear draftWorkspaceTab here: switching to another tab must not
        // discard an in-progress "Untitled" draft. The draft persists in the tab
        // strip until the user closes it (X) or it's consumed by a spawn.
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = session.id
    }

    /// Re-select the in-progress draft tab (show its composer) without losing it.
    public func selectDraftWorkspaceTab() {
        guard draftWorkspaceTab != nil else { return }
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = nil
    }

    public func openDraftWorkspaceTab(
        from session: AgentSession,
        defaults: ComposerStore.ChipDefaults
    ) {
        guard let key = WorkspaceKey.of(session) else { return }
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        draftWorkspaceTab = WorkspaceDraftTab(
            workspaceKey: key,
            mode: session.mode,
            agent: defaults.agent,
            modelId: defaults.modelId,
            effort: defaults.effort
        )
        openOutsideJSONLPath = nil
        openSessionId = nil
    }

    public func clearDraftWorkspaceTab() {
        draftWorkspaceTab = nil
    }

    /// #185-named convenience over `openDraftWorkspaceTab(from:defaults:)`.
    ///
    /// The #185 chip + shortcut-registry surface refers to "spawning a
    /// same-workspace chat tab" by parent session id. Resolves the parent
    /// `AgentSession`, copies its chip defaults, and delegates to the same
    /// underlying `openDraftWorkspaceTab` so the two API names cannot drift.
    /// Returns the resulting `WorkspaceDraftTab.id` so call sites that want
    /// to immediately focus the new tab can do so without re-querying.
    @discardableResult
    public func spawnSameWorkspaceChatTab(parentId: UUID) -> UUID? {
        guard let session = registry.sessions.first(where: { $0.id == parentId }),
              let key = WorkspaceKey.of(session) else { return nil }
        let defaults = ComposerStore.ChipDefaults(
            agent: session.agent,
            modelId: session.model,
            effort: session.effort,
            mode: session.mode,
            planMode: false
        )
        openDraftWorkspaceTab(from: session, defaults: defaults)
        // `openDraftWorkspaceTab` minted a fresh `draftWorkspaceTab` with the
        // session's workspace key. Return its id when it's the one we just
        // created (a re-entrant call elsewhere could in principle have raced,
        // so guard on the workspaceKey match).
        if let draft = draftWorkspaceTab, draft.workspaceKey == key {
            return draft.id
        }
        return nil
    }

    /// #185-named convenience around `openOrCreateWorkspaceTerminalTab(from:)`.
    /// Resolves the parent session by id, validates the terminal-spawn gate,
    /// and forwards. Returns true iff the spawn was actually issued.
    @discardableResult
    public func spawnSameWorkspaceTerminalTab(parentId: UUID) async -> Bool {
        guard let session = registry.sessions.first(where: { $0.id == parentId }),
              canOpenWorkspaceTerminalTab(from: session) else { return false }
        await openOrCreateWorkspaceTerminalTab(from: session)
        return true
    }

    func workspaceTerminalTabs(in workspaceKey: WorkspaceKey) -> [WorkspaceTerminalTab] {
        workspaceTerminalTabs
            .compactMap { tab -> WorkspaceTerminalTab? in
                guard tab.workspaceKey == workspaceKey,
                      let session = registry.session(id: tab.sessionId),
                      canOpenWorkspaceTerminalTab(from: session),
                      let sessionKey = WorkspaceKey.of(session),
                      sessionKey == workspaceKey
                else { return nil }
                if let paneRefId = tab.paneRefId,
                   !session.terminalPanes.contains(where: { $0.id == paneRefId }) {
                    return nil
                }
                return tab
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func workspaceDocumentTabs(in workspaceKey: WorkspaceKey) -> [WorkspaceDocumentTab] {
        workspaceDocumentTabs
            .compactMap { tab -> WorkspaceDocumentTab? in
                guard tab.workspaceKey == workspaceKey,
                      let session = registry.session(id: tab.sessionId),
                      session.archivedAt == nil,
                      let sessionKey = WorkspaceKey.of(session),
                      sessionKey == workspaceKey
                else { return nil }
                return tab
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func canOpenWorkspaceTerminalTab(from session: AgentSession) -> Bool {
        guard session.archivedAt == nil,
              WorkspaceKey.of(session) != nil,
              let paneId = session.tmuxPaneId,
              !paneId.isEmpty
        else { return false }
        return true
    }

    func selectWorkspaceTerminalTab(_ tab: WorkspaceTerminalTab) {
        guard let session = registry.session(id: tab.sessionId),
              canOpenWorkspaceTerminalTab(from: session),
              let sessionKey = WorkspaceKey.of(session),
              sessionKey == tab.workspaceKey
        else { return }
        draftWorkspaceTab = nil
        openOutsideJSONLPath = nil
        openSessionId = tab.sessionId
        selectedWorkspaceDocumentTabId = nil
        selectedWorkspaceTerminalTabId = tab.id
    }

    func openWorkspaceTerminalTab(
        from session: AgentSession,
        paneRefId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        guard canOpenWorkspaceTerminalTab(from: session),
              let workspaceKey = WorkspaceKey.of(session)
        else { return }
        if let existing = workspaceTerminalTabs.first(where: {
            $0.sessionId == session.id && $0.paneRefId == paneRefId && $0.workspaceKey == workspaceKey
        }) {
            selectWorkspaceTerminalTab(existing)
            return
        }
        let tab = WorkspaceTerminalTab(
            sessionId: session.id,
            workspaceKey: workspaceKey,
            paneRefId: paneRefId,
            createdAt: createdAt
        )
        workspaceTerminalTabs.append(tab)
        selectWorkspaceTerminalTab(tab)
    }

    func openOrCreateWorkspaceTerminalTab(from session: AgentSession) async {
        guard canOpenWorkspaceTerminalTab(from: session) else { return }
        let primary = workspaceTerminalTabs.first {
            $0.sessionId == session.id && $0.paneRefId == nil
        }
        if primary == nil {
            openWorkspaceTerminalTab(from: session)
            return
        }
        if let _ = await addTerminalPane(sessionId: session.id),
           let paneRef = registry.session(id: session.id)?.terminalPanes.last {
            openWorkspaceTerminalTab(from: session, paneRefId: paneRef.id)
        } else if let primary {
            selectWorkspaceTerminalTab(primary)
        }
    }

    func closeWorkspaceTerminalTab(_ tab: WorkspaceTerminalTab) async {
        if let paneRefId = tab.paneRefId,
           let session = registry.session(id: tab.sessionId),
           let pane = session.terminalPanes.first(where: { $0.id == paneRefId }) {
            await closeTerminalPane(sessionId: tab.sessionId, paneRef: pane)
        }
        workspaceTerminalTabs.removeAll { $0.id == tab.id }
        if selectedWorkspaceTerminalTabId == tab.id {
            selectedWorkspaceTerminalTabId = nil
            if registry.session(id: tab.sessionId) != nil {
                openSessionId = tab.sessionId
            }
        }
    }

    func selectWorkspaceDocumentTab(_ tab: WorkspaceDocumentTab) {
        guard let session = registry.session(id: tab.sessionId),
              session.archivedAt == nil,
              let sessionKey = WorkspaceKey.of(session),
              sessionKey == tab.workspaceKey
        else { return }
        draftWorkspaceTab = nil
        openOutsideJSONLPath = nil
        openSessionId = tab.sessionId
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = tab.id
    }

    func openWorkspaceDocumentTab(
        from session: AgentSession,
        path rawPath: String,
        createdAt: Date = Date()
    ) {
        guard let workspaceKey = WorkspaceKey.of(session),
              let path = Self.standardizedDocumentPath(rawPath, relativeTo: session)
        else { return }
        if let existing = workspaceDocumentTabs.first(where: {
            $0.workspaceKey == workspaceKey && $0.path == path
        }) {
            selectWorkspaceDocumentTab(existing)
            return
        }
        let tab = WorkspaceDocumentTab(
            sessionId: session.id,
            workspaceKey: workspaceKey,
            path: path,
            createdAt: createdAt
        )
        workspaceDocumentTabs.append(tab)
        selectWorkspaceDocumentTab(tab)
    }

    func closeWorkspaceDocumentTab(_ tab: WorkspaceDocumentTab) {
        workspaceDocumentTabs.removeAll { $0.id == tab.id }
        if selectedWorkspaceDocumentTabId == tab.id {
            selectedWorkspaceDocumentTabId = nil
            selectedWorkspaceTerminalTabId = nil
            if registry.session(id: tab.sessionId) != nil {
                openSessionId = tab.sessionId
            }
        }
    }

    private static func standardizedDocumentPath(_ rawPath: String, relativeTo session: AgentSession) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded, isDirectory: false)
        } else {
            url = URL(fileURLWithPath: session.effectiveCwd, isDirectory: true)
                .appendingPathComponent(expanded, isDirectory: false)
        }
        return url.standardizedFileURL.path
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await repoIndex.refresh()
        self.repos = snapshot
        let canonical = SessionSidebarGrouper.canonicalizeRepos(snapshot)
        for repo in canonical.repos {
            if !sessions(for: repo.key, aliases: canonical.keyAliases, includeArchived: false).isEmpty
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
        /// tmux didn't create the pane in time — the control connection is
        /// wedged. Surfaced (not hung) so the user can relaunch + retry.
        case spawnTimedOut
        public var errorDescription: String? {
            switch self {
            case .missingBinary(let m): return m
            case .unsupportedMode(let m): return m
            case .antigravityNotReady(let m): return m
            case .spawnTimedOut:
                return "Timed out starting the agent (tmux unresponsive). Quit and relaunch Clawdmeter, then try again."
            }
        }
    }

    /// Race an async op against a deadline. A wedged `tmux.newWindow` never
    /// resumes its continuation (cooperative cancellation can't unstick a dead
    /// PTY), so we abandon it and surface a timeout instead of hanging forever.
    private static func withSpawnTimeout<T: Sendable>(
        _ seconds: Double, _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SpawnError.spawnTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func assertProviderEnabled(_ agent: AgentKind) throws {
        guard ProviderEnablement.isEnabled(agent) else {
            throw SpawnError.unsupportedMode("Enable \(providerDisplayName(agent)) in Settings → Providers.")
        }
    }

    private func providerDisplayName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        case .gemini: return "Antigravity"
        case .cursor: return "Cursor"
        case .opencode: return "OpenRouter"
        case .grok: return "Grok"
        case .unknown: return "this provider"
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
        try assertProviderEnabled(agent)
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
        var provisioning: WorktreeProvisioningMetadata? = nil
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
                let provisioned = try await WorktreeManager.shared.provision(
                    repoRoot: repoPath,
                    slug: slug,
                    branchName: slug,
                    filesToCopy: filesToCopySettings(forRepoRoot: repoPath),
                    setupScript: RepoSetupScriptStore.script(forRepoRoot: repoPath)
                )
                worktreePath = provisioned.path
                provisioning = provisioned.metadata
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
                resumeSessionId: resumeSessionId,
                workspacePath: cwd
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
        case .grok, .unknown:
            // grok is ACP (no tmux argv); unknown is X3 forward-compat. Both
            // fall through to the missingBinary throw below.
            argv = []
        }
        guard !argv.isEmpty else {
            await cleanupUnregisteredWorktree(
                repoPath: repoPath,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
            throw SpawnError.missingBinary("Agent CLI not found on PATH: \(agent.rawValue). Configure in Settings -> Diagnostics.")
        }
        let window: TmuxControlClient.WindowRef
        let resolvedEnv: RepoEnvResolvedEnvironment?
        do {
            resolvedEnv = try resolveRepoEnv(repoRoot: repoPath, cwd: cwd)
            window = try await tmux.newWindow(cwd: cwd, child: argv, environment: resolvedEnv?.environment ?? [:])
        } catch {
            await cleanupUnregisteredWorktree(
                repoPath: repoPath,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
            throw error
        }
        let session = try await registry.create(
            repoKey: repoPath,
            repoDisplayName: (repoPath as NSString).lastPathComponent,
            agent: agent,
            model: model,
            goal: goal,
            worktreePath: worktreePath,
            provisioning: provisioning,
            tmuxWindowId: window.windowId,
            tmuxPaneId: window.paneId,
            planMode: effectivePlanMode,
            mode: mode,
            effort: effort,
            ownsWorktree: worktreePath != nil,
            envSetId: resolvedEnv?.set?.id,
            envSetName: resolvedEnv?.set?.name,
            id: provisionalSessionId ?? UUID()
        )
        if let pinned = pinnedJSONLURL {
            forcedChatStoreURLs[session.id] = pinned
            needsURLRevalidation.insert(session.id)
        }
        recordWorkspaceSession(repoRoot: repoPath, sessionId: session.id)
        expandedRepoKeys.insert(repoPath)
        draftWorkspaceTab = nil
        openSessionId = session.id
        await self.refresh()
        return session
    }

    /// Spawn a sibling code session inside an existing workspace/worktree.
    /// Unlike `spawnSession(... mode: .worktree ...)`, this never calls
    /// `WorktreeManager.add`; the caller supplies the already-existing
    /// workspace path that should become the runtime cwd.
    public func spawnSessionInExistingWorkspace(
        repoPath: String,
        workspacePath: String,
        agent: AgentKind,
        planMode: Bool,
        goal: String?,
        mode: SessionMode,
        tmux: TmuxControlClient,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        acceptEdits: Bool = false,
        autopilot: Bool = false,
        initialMessage: String? = nil,
        inheritedContextSourceIds: [UUID] = []
    ) async throws -> AgentSession {
        try assertProviderEnabled(agent)
        let paths = Self.existingWorkspaceRecordPaths(
            repoPath: repoPath,
            workspacePath: workspacePath,
            mode: mode
        )
        if agent == .gemini {
            let session = try await spawnAntigravitySession(
                repoPath: repoPath,
                workspacePath: workspacePath,
                goal: goal,
                mode: mode,
                model: model,
                effort: effort,
                planMode: planMode,
                initialMessage: initialMessage
            )
            try await registry.setInheritedContextSources(sessionId: session.id, sourceIds: inheritedContextSourceIds)
            return registry.session(id: session.id) ?? session
        }
        if agent == .opencode {
            return try await spawnOpencodeSessionInExistingWorkspace(
                repoPath: repoPath,
                workspacePath: workspacePath,
                goal: goal,
                mode: mode,
                model: model,
                effort: effort,
                inheritedContextSourceIds: inheritedContextSourceIds
            )
        }
        if agent == .cursor, planMode {
            throw SpawnError.unsupportedMode("Cursor plan mode requires a resumable Cursor session. Start Cursor in another permission mode.")
        }
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

        try await tmux.start()
        let cwd = paths.cwd
        let argv: [String]
        switch agent {
        case .claude:
            argv = AgentSpawner.claudeArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: nil
            ) ?? []
        case .codex:
            argv = AgentSpawner.codexArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: nil
            ) ?? []
        case .cursor:
            argv = AgentSpawner.cursorArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: nil,
                workspacePath: cwd
            ) ?? []
        case .gemini, .opencode, .grok, .unknown:
            argv = []
        }
        guard !argv.isEmpty else {
            throw SpawnError.missingBinary("Agent CLI not found on PATH: \(agent.rawValue). Configure in Settings -> Diagnostics.")
        }
        let resolvedEnv = try resolveRepoEnv(repoRoot: repoPath, cwd: cwd)
        let window = try await tmux.newWindow(cwd: cwd, child: argv, environment: resolvedEnv?.environment ?? [:])
        let session = try await registry.create(
            repoKey: repoPath,
            repoDisplayName: (repoPath as NSString).lastPathComponent,
            agent: agent,
            model: model,
            goal: goal,
            worktreePath: paths.worktreePath,
            tmuxWindowId: window.windowId,
            tmuxPaneId: window.paneId,
            planMode: planMode,
            mode: mode,
            effort: effort,
            inheritedContextSourceIds: inheritedContextSourceIds,
            ownsWorktree: false,
            envSetId: resolvedEnv?.set?.id,
            envSetName: resolvedEnv?.set?.name
        )
        expandedRepoKeys.insert(repoPath)
        draftWorkspaceTab = nil
        openOutsideJSONLPath = nil
        openSessionId = session.id
        await self.refresh()
        return session
    }

    static func existingWorkspaceRecordPaths(
        repoPath: String,
        workspacePath: String,
        mode: SessionMode
    ) -> (cwd: String, worktreePath: String?) {
        let fallback = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? repoPath
            : workspacePath
        let cwd = WorkspaceKey.canonicalPath(fallback)
        return (cwd: cwd, worktreePath: mode == .worktree ? cwd : nil)
    }

    private func spawnOpencodeSessionInExistingWorkspace(
        repoPath: String,
        workspacePath: String,
        goal: String?,
        mode: SessionMode,
        model: String?,
        effort: ReasoningEffort?,
        inheritedContextSourceIds: [UUID]
    ) async throws -> AgentSession {
        let paths = Self.existingWorkspaceRecordPaths(
            repoPath: repoPath,
            workspacePath: workspacePath,
            mode: mode
        )
        guard let _ = await OpencodeProcessManager.shared.ensureRunning() else {
            switch OpencodeProcessManager.shared.state {
            case .notInstalled:
                throw SpawnError.missingBinary("OpenCode is not installed. Install OpenCode, then add an OpenRouter key in Settings.")
            case .failed(let detail):
                throw SpawnError.missingBinary("OpenCode serve failed: \(detail)")
            default:
                throw SpawnError.missingBinary("OpenCode serve is not running.")
            }
        }

        OpencodeSSEAdapter.shared.start()
        guard var request = OpencodeProcessManager.shared.makeAuthorizedRequest(path: "/session") else {
            throw SpawnError.missingBinary("OpenCode serve is not reachable.")
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let titleSource = goal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? goal!
            : (repoPath as NSString).lastPathComponent
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": String(titleSource.prefix(60))
        ])
        let resolvedEnv = try resolveRepoEnv(repoRoot: repoPath, cwd: paths.cwd)

        let opencodeID: String
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                throw SpawnError.missingBinary("OpenCode session creation failed.")
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  !id.isEmpty else {
                throw SpawnError.missingBinary("OpenCode returned an invalid session response.")
            }
            opencodeID = id
        } catch let error as SpawnError {
            throw error
        } catch {
            throw SpawnError.missingBinary("OpenCode session creation failed: \(error.localizedDescription)")
        }

        let session = try await registry.create(
            repoKey: repoPath,
            repoDisplayName: (repoPath as NSString).lastPathComponent,
            agent: .opencode,
            model: model,
            goal: goal,
            worktreePath: paths.worktreePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: mode,
            effort: effort,
            inheritedContextSourceIds: inheritedContextSourceIds,
            ownsWorktree: false,
            envSetId: resolvedEnv?.set?.id,
            envSetName: resolvedEnv?.set?.name
        )
        OpencodeSSEAdapter.shared.register(
            clawdmeterID: session.id,
            opencodeID: opencodeID,
            repo: paths.cwd
        )
        AgentEventStream.recordEvent(
            sessionId: session.id,
            kind: .sessionCreated,
            payload: ["repo": paths.cwd, "agent": "opencode", "opencodeID": opencodeID]
        )
        expandedRepoKeys.insert(repoPath)
        draftWorkspaceTab = nil
        openOutsideJSONLPath = nil
        openSessionId = session.id
        await self.refresh()
        return registry.session(id: session.id) ?? session
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
        workspacePath: String? = nil,
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

        func cleanupPreparedWorktree(
            worktreePath: String?,
            provisioning: WorktreeProvisioningMetadata?,
            provisionalSessionId: UUID?
        ) async {
            await cleanupUnregisteredWorktree(
                repoPath: repoPath,
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
        }

        // Preflight the provider before creating a worktree. For worktree
        // sessions we run a second project-resolution preflight against the
        // prepared cwd after branch creation, so Antigravity never silently
        // edits the original checkout when the worktree project is unknown.
        let baseInstall = await AntigravityInstall.preflight(
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

        switch baseInstall {
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
        case .ready:
            break
        }

        var cwd = workspacePath ?? repoPath
        var worktreePath: String? = mode == .worktree ? workspacePath : nil
        var provisioning: WorktreeProvisioningMetadata?
        var provisionalSessionId: UUID?
        if mode == .worktree, workspacePath == nil {
            let sessionId = UUID()
            provisionalSessionId = sessionId
            let city = CityNamer.shared.cityName(for: sessionId)
            let slug = WorktreeManager.slug(city: city)
            do {
                let provisioned = try await WorktreeManager.shared.provision(
                    repoRoot: repoPath,
                    slug: slug,
                    branchName: slug,
                    filesToCopy: filesToCopySettings(forRepoRoot: repoPath),
                    setupScript: RepoSetupScriptStore.script(forRepoRoot: repoPath)
                )
                cwd = provisioned.path
                worktreePath = provisioned.path
                provisioning = provisioned.metadata
            } catch {
                CityNamer.shared.release(sessionId)
                throw error
            }
        }
        let resolvedEnv: RepoEnvResolvedEnvironment?
        do {
            resolvedEnv = try resolveRepoEnv(repoRoot: repoPath, cwd: cwd)
        } catch {
            await cleanupPreparedWorktree(
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
            throw error
        }

        let install = await AntigravityInstall.preflight(
            forRepoKey: cwd,
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
            await cleanupPreparedWorktree(
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
            throw SpawnError.antigravityNotReady(
                "Install Antigravity 2 from antigravity.google to start a Gemini session."
            )
        case .installedNotSignedIn:
            await cleanupPreparedWorktree(
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
            throw SpawnError.antigravityNotReady(
                "Sign into Antigravity 2 first, then try again."
            )
        case .appOnlyNotRunning:
            await cleanupPreparedWorktree(
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
            throw SpawnError.antigravityNotReady(
                "Open Antigravity 2 to start a Gemini session."
            )
        case .noProjectForRepo:
            await cleanupPreparedWorktree(
                worktreePath: worktreePath,
                provisioning: provisioning,
                provisionalSessionId: provisionalSessionId
            )
            throw SpawnError.antigravityNotReady(
                "Open this prepared worktree in Antigravity 2 first, then try again."
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
                return "Start a new Gemini session in \(cwd)."
            }()
            let modelTier = AgentapiModelTier.from(modelCatalogId: model)
            let conversationIdString: String
            do {
                conversationIdString = try await lsClient.newConversation(
                    modelTier: modelTier,
                    prompt: firstPrompt,
                    projectId: projectId
                )
            } catch {
                await cleanupPreparedWorktree(
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    provisionalSessionId: provisionalSessionId
                )
                throw error
            }
            guard let conversationId = UUID(uuidString: conversationIdString) else {
                await cleanupPreparedWorktree(
                    worktreePath: worktreePath,
                    provisioning: provisioning,
                    provisionalSessionId: provisionalSessionId
                )
                throw SpawnError.antigravityNotReady(
                    "Antigravity returned an unrecognized conversation id (\(conversationIdString)). Try reopening the app."
                )
            }
            let session = try await registry.create(
                repoKey: repoPath,
                repoDisplayName: (repoPath as NSString).lastPathComponent,
                agent: .gemini,
                model: model,
                goal: goal,
                worktreePath: worktreePath,
                provisioning: provisioning,
                tmuxWindowId: nil,  // no tmux pane
                tmuxPaneId: nil,
                planMode: planMode,
                mode: mode,
                effort: effort,
                geminiBackend: .agentapi,
                antigravityConversationId: conversationId,
                antigravityProjectId: projectId,
                ownsWorktree: provisioning != nil && worktreePath != nil,
                envSetId: resolvedEnv?.set?.id,
                envSetName: resolvedEnv?.set?.name,
                id: provisionalSessionId ?? UUID()
            )
            recordWorkspaceSession(repoRoot: repoPath, sessionId: session.id)
            expandedRepoKeys.insert(repoPath)
            draftWorkspaceTab = nil
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
        case .grok, .unknown:
            // grok (ACP) has no JSONL outside-source; unknown is X3.
            return nil
        }
        // Synthetic outside sessions keep repoKey nil so WorkspaceKey never
        // treats them as first-party, but runtimeCwd still carries the repo
        // path needed to resume the CLI.
        let syntheticRepoKey = synthetic.effectiveCwd
        guard !syntheticRepoKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
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
        // Pick the new cwd.
        var newCwd = sessionRepoKey
        var newWorktree: String? = nil
        var newProvisioning: WorktreeProvisioningMetadata? = nil
        switch newMode {
        case .worktree:
            // v0.7.9: reuse the session's already-assigned city for
            // its worktree branch. Mid-session swap → same city as
            // the sidebar label so user mental model stays consistent.
            let city = CityNamer.shared.cityName(for: session.id)
            let slug = WorktreeManager.slug(city: city)
            do {
                let provisioned = try await WorktreeManager.shared.provision(
                    repoRoot: sessionRepoKey,
                    slug: slug,
                    branchName: slug,
                    filesToCopy: filesToCopySettings(forRepoRoot: sessionRepoKey),
                    setupScript: RepoSetupScriptStore.script(forRepoRoot: sessionRepoKey)
                )
                newWorktree = provisioned.path
                newProvisioning = provisioned.metadata
                newCwd = provisioned.path
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
            guard !argv.isEmpty else {
                await cleanupUnregisteredWorktree(
                    repoPath: sessionRepoKey,
                    worktreePath: newWorktree,
                    provisioning: newProvisioning,
                    provisionalSessionId: nil
                )
                return
            }
            let resolvedEnv = try resolveRepoEnv(session: session, cwd: newCwd)
            if let windowId = session.tmuxWindowId {
                try? await runtime.tmuxClient.killWindow(windowId)
            }
            let newWindow = try await runtime.tmuxClient.newWindow(
                cwd: newCwd,
                child: argv,
                environment: resolvedEnv?.environment ?? [:]
            )
            try await registry.updateRuntime(
                id: sessionId,
                worktreePath: newWorktree,
                provisioning: .some(newProvisioning),
                runtimeCwd: .some(newCwd),
                tmuxWindowId: newWindow.windowId,
                tmuxPaneId: newWindow.paneId,
                mode: newMode,
                ownsWorktree: newMode == .worktree && newWorktree != nil
            )
        } catch {
            await cleanupUnregisteredWorktree(
                repoPath: sessionRepoKey,
                worktreePath: newWorktree,
                provisioning: newProvisioning,
                provisionalSessionId: nil
            )
            // Spawn failed — surface via lastError once we plumb it; for now,
            // session status stays at degraded by the supervisor.
        }
    }

    /// Sessions v2 Phase 1: swap the model on a live session. Wraps
    /// `SessionConfigChanger` so the kill+respawn lives in one place.
    /// The chip picker calls this with the new entry's id; if `entry.cliAlias`
    /// is set, we pass the alias (e.g. "opus") since claude --model accepts
    /// both aliases and full ids.
    /// Surface the outcome of a mid-session config swap so it never fails
    /// silently. Failure always toasts with the daemon's reason; success is a
    /// brief confirmation (the chip itself already reflects the new value).
    private func surfaceSwap(
        _ result: SessionConfigChanger.SwapResult,
        succeeded: String,
        failed: String,
        successToast: Bool = true
    ) {
        switch result {
        case .swapped:
            // Some chips (EffortDial) confirm success with an inline pulse, so
            // they pass successToast:false to avoid a redundant toast.
            if successToast { WorkspaceFeedback.success(succeeded) }
        case .resumeFailed(let restoredOriginal):
            WorkspaceFeedback.failure(failed, detail: restoredOriginal
                ? "Couldn't resume — restored the previous session."
                : "Couldn't resume the session.")
        case .spawnError(let message):
            WorkspaceFeedback.failure(failed, detail: message)
        }
    }

    public func switchModel(sessionId: UUID, to entry: ModelCatalogEntry, effort: ReasoningEffort? = nil) async {
        guard let runtime = AppDelegate.runtime else { return }
        let changer = SessionConfigChanger(
            registry: registry,
            tmux: runtime.tmuxClient,
            repoEnvResolver: repoEnvResolver
        )
        let modelToUse = entry.cliAlias ?? entry.id
        let result = await changer.swap(sessionId: sessionId, newModel: modelToUse, newEffort: .some(effort))
        surfaceSwap(result, succeeded: "Model → \(entry.displayName)", failed: "Couldn't switch model")
    }

    /// Sessions v2 Phase 1: swap the effort dial mid-session.
    public func switchEffort(sessionId: UUID, to effort: ReasoningEffort) async {
        guard let runtime = AppDelegate.runtime else { return }
        let changer = SessionConfigChanger(
            registry: registry,
            tmux: runtime.tmuxClient,
            repoEnvResolver: repoEnvResolver
        )
        let result = await changer.swap(sessionId: sessionId, newEffort: .some(effort))
        surfaceSwap(result, succeeded: "Reasoning effort updated", failed: "Couldn't change effort", successToast: false)
    }

    /// Sessions v2 Phase 1: toggle plan/code mid-session (Claude only).
    public func switchPlanMode(sessionId: UUID, planMode: Bool) async {
        guard let runtime = AppDelegate.runtime else { return }
        let changer = SessionConfigChanger(
            registry: registry,
            tmux: runtime.tmuxClient,
            repoEnvResolver: repoEnvResolver
        )
        let result = await changer.swap(sessionId: sessionId, newPlanMode: planMode)
        surfaceSwap(result,
                    succeeded: planMode ? "Switched to Plan mode" : "Switched to Code mode",
                    failed: "Couldn't change mode")
    }

    /// Revive a degraded session: respawn its agent into a fresh tmux pane
    /// (same config + resume) when the recorded pane died (server restart).
    /// The terminal reconnects automatically once the registry's tmuxPaneId
    /// updates.
    @discardableResult
    public func revive(sessionId: UUID) async -> Bool {
        guard let runtime = AppDelegate.runtime else { return false }
        let changer = SessionConfigChanger(
            registry: registry,
            tmux: runtime.tmuxClient,
            repoEnvResolver: repoEnvResolver
        )
        if case .swapped = await changer.revive(sessionId: sessionId) { return true }
        return false
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
        // Snapshot the prior flags so we can roll the optimistic store write
        // back if the respawn fails — otherwise the permission chip would
        // claim a mode the restored CLI isn't actually running.
        let priorAcceptEdits = store.acceptEdits(sessionId: sessionId)
        let priorBypass = AutopilotState.shared.isEnabled(sessionId: sessionId)
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
        let changer = SessionConfigChanger(
            registry: registry,
            tmux: runtime.tmuxClient,
            repoEnvResolver: repoEnvResolver
        )
        let result = await changer.swap(sessionId: sessionId, newPlanMode: newMode == .plan)
        if case .swapped = result {} else {
            // Respawn didn't take — restore the flags so the chip reflects the
            // CLI that's actually running, not the mode the user attempted.
            store.setAcceptEdits(priorAcceptEdits, sessionId: sessionId)
            store.setBypass(priorBypass, sessionId: sessionId)
        }
        surfaceSwap(result, succeeded: "Permission mode updated", failed: "Couldn't change permission mode")
    }

    public func endSession(id: UUID) async {
        guard let session = registry.session(id: id) else {
            try? await registry.delete(id: id)
            return
        }
        if let runtime = AppDelegate.runtime, let windowId = session.tmuxWindowId {
            do { try await runtime.tmuxClient.killWindow(windowId) } catch {}
        }
        // v0.8 REV-DELETE: code sessions go through WorktreeManager; chat
        // sessions get ChatCwdCleaner in Phase 4. Guard here so Phase 2
        // doesn't crash on a chat session reaching this path.
        if session.kind == .code, session.ownsWorktree, let worktreePath = session.worktreePath, let repoRoot = session.repoKey {
            _ = try? await WorktreeManager.shared.delete(
                repoRoot: repoRoot,
                worktreePath: worktreePath,
                registryOwned: true,
                attachedPanePaths: []
            )
        }
        if openSessionId == id { openSessionId = nil }
        closeChatStore(for: id)
        try? await registry.delete(id: id)
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
            let resolvedEnv = try resolveRepoEnv(session: parent, cwd: cwd)
            let window = try await runtime.tmuxClient.newWindow(
                cwd: cwd,
                child: argv,
                environment: resolvedEnv?.environment ?? [:]
            )
            let child = try await registry.create(
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
                parentSessionId: parentId,
                ownsWorktree: false,
                envSetId: parent.envSetId,
                envSetName: parent.envSetName
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
            try await registry.addTerminalPane(sessionId: sessionId, pane: ref)
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
        try? await registry.removeTerminalPane(sessionId: sessionId, paneRefId: paneRef.id)
    }

    public func approvePlan(id: UUID) async {
        guard let runtime = AppDelegate.runtime,
              let session = registry.session(id: id),
              let windowId = session.tmuxWindowId,
              session.status == .planning,
              (session.planText?.isEmpty == false || session.agent == .codex || session.agent == .cursor)
        else { return }
        var windowKilled = false
        do {
            let providerResumeId: String
            if session.agent == .cursor {
                guard let cursorResumeId = Self.cursorResumeId(for: session) else {
                    try? await registry.setPlanText(
                        id: id,
                        planText: "Cursor approval needs a real Cursor chat id. Start Cursor in code mode or import a Cursor session with a proven id."
                    )
                    try? await registry.updateStatus(id: id, status: .degraded)
                    WorkspaceFeedback.failure(
                        "Can't approve plan",
                        detail: "Cursor needs a real chat id — start Cursor in code mode or import a session with a proven id."
                    )
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
            guard !argv.isEmpty else {
                WorkspaceFeedback.failure("Can't approve plan", detail: "Couldn't build the relaunch command for this agent.")
                return
            }
            let cwd = session.effectiveCwd
            let resolvedEnv = try resolveRepoEnv(session: session, cwd: cwd)
            try await runtime.tmuxClient.killWindow(windowId)
            windowKilled = true
            let window = try await runtime.tmuxClient.newWindow(
                cwd: cwd,
                child: argv,
                environment: resolvedEnv?.environment ?? [:]
            )
            try await registry.updateRuntime(
                id: id,
                worktreePath: session.worktreePath,
                tmuxWindowId: window.windowId,
                tmuxPaneId: window.paneId,
                mode: session.mode,
                ownsWorktree: session.ownsWorktree
            )
            try await registry.markPlanApproved(id: id)
            try await registry.updateStatus(id: id, status: .running)
            WorkspaceFeedback.success("Plan approved — running")
        } catch {
            if windowKilled {
                // The plan-mode pane is already dead; flag degraded so the user
                // gets the Revive affordance instead of a session pointed at a
                // killed window.
                try? await registry.updateStatus(id: id, status: .degraded)
            }
            WorkspaceFeedback.failure("Couldn't approve the plan", detail: error.localizedDescription)
        }
    }

    private func cleanupUnregisteredWorktree(
        repoPath: String,
        worktreePath: String?,
        provisioning: WorktreeProvisioningMetadata? = nil,
        provisionalSessionId: UUID?
    ) async {
        if let worktreePath {
            _ = try? await WorktreeManager.shared.cleanupProvisionedWorktree(
                repoRoot: repoPath,
                worktreePath: worktreePath,
                expectedMarkerId: provisioning?.ownershipMarkerId
            )
        }
        if let provisionalSessionId {
            CityNamer.shared.release(provisionalSessionId)
        }
    }

    private func filesToCopySettings(forRepoRoot repoRoot: String) -> WorkspaceFilesToCopySettings {
        workspaceStore.workspace(forRepoRoot: repoRoot)?.filesToCopy ?? WorkspaceFilesToCopySettings()
    }

    private func resolveRepoEnv(repoRoot: String, cwd: String) throws -> RepoEnvResolvedEnvironment? {
        try repoEnvResolver?.resolveForLaunch(repoRoot: repoRoot, cwd: cwd)
    }

    private func resolveRepoEnv(session: AgentSession, cwd: String? = nil) throws -> RepoEnvResolvedEnvironment? {
        try repoEnvResolver?.resolveForLaunch(session: session, cwd: cwd)
    }

    private func recordWorkspaceSession(repoRoot: String, sessionId: UUID) {
        let existing = workspaceStore.workspace(forRepoRoot: repoRoot)?.activeSessionIds ?? []
        var ids = existing.filter { $0 != sessionId }
        ids.append(sessionId)
        workspaceStore.syncActiveSessions(repoRoot: repoRoot, sessionIds: ids)
    }

    private static func cursorResumeId(for session: AgentSession) -> String? {
        let candidate = session.runtimeBinding?.externalSessionId
            ?? session.runtimeBinding?.externalThreadId
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
