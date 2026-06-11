import SwiftUI
import Combine
import ClawdmeterShared

/// Sessions/Code data layer. Owns `SessionsModel` (the @MainActor
/// ObservableObject that bridges `RepoIndex` + `AgentSessionRegistry` to
/// SwiftUI) and `NewSessionMacSheet` (still hosted by
/// `SessionWorkspaceView`).
///
/// The top-level `SessionsView` SwiftUI struct that used to live here was
/// retired in v0.11. File name kept as `SessionsView.swift` for minimal diff
/// noise; effectively a `SessionsModel.swift`.

// MARK: - New session sheet (Mac)

struct NewSessionMacSheet: View {
    @ObservedObject var model: SessionsModel
    @Environment(\.dismiss) private var dismiss

    /// Pre-selected repo path so the picker lands on the right row without the
    /// user needing to choose. Nil opens the sheet with "(custom path)"
    /// selected, matching the previous behavior.
    var preselectedRepoKey: String?

    @State private var repoPath: String = ""
    @State private var agent: AgentKind = .claude
    @State private var goal: String = ""
    @State private var planMode: Bool = true
    @StateObject private var launcher = SessionLauncherModel()
    @State private var selectedModelId: String?
    @State private var selectedModelWasUserChosen = false
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
        guard AppDelegate.runtime != nil else {
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
                mode: .worktree,
                model: selectedModel,
                effort: supportsEffort(modelId: selectedModel) ? defaults.effort : nil
            )
            dismiss()
        } catch {
            errorMessage = SessionsModel.humanize(spawnError: error)
        }
    }

    // (former spawn-error-only humanizer removed — startSession() now routes
    // every failure through SessionsModel.humanize(spawnError:) so worktree
    // and access errors are humanized too.)
}

struct PendingFirstSendRecovery: Equatable {
    let text: String
    let attachments: [ComposerStore.Attachment]
    let browserComments: [BrowserCommentContext]
    let error: ComposerStore.SendError
    let createdAt: Date
    let clientIntentId: String
    /// When true, the queued draft auto-sends the moment the session is ready
    /// (used for sends made while a "+" session is still provisioning) instead
    /// of being restored to the composer for a manual retry.
    var autoSendWhenReady: Bool = false
}

private struct ProvisionalLaunchConfiguration: Equatable {
    let agent: AgentKind
    let modelId: String
    let effort: ReasoningEffort?
    let customProviderId: String?
}

struct QuickSpawnProvisionalSession: Equatable {
    let session: AgentSession
    let slug: String
    let worktreePath: String
}

struct WorkspaceDraftTab: Identifiable, Equatable {
    let id: UUID
    let workspaceKey: WorkspaceKey
    var mode: SessionMode
    var agent: AgentKind
    var modelId: String?
    var effort: ReasoningEffort?
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
    let isPendingDirectShell: Bool
    let pendingTitle: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        workspaceKey: WorkspaceKey,
        paneRefId: UUID?,
        isPendingDirectShell: Bool = false,
        pendingTitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.workspaceKey = workspaceKey
        self.paneRefId = paneRefId
        self.isPendingDirectShell = isPendingDirectShell
        self.pendingTitle = pendingTitle
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
    private var provisionalLaunchConfigurations: [UUID: ProvisionalLaunchConfiguration] = [:]

    @discardableResult
    public func configureProvisionalLaunch(
        sessionId: UUID,
        agent: AgentKind,
        modelId: String,
        effort: ReasoningEffort?,
        customProviderId: String? = nil
    ) -> Bool {
        guard provisioningSessionIds.contains(sessionId),
              registry.session(id: sessionId) != nil
        else { return false }
        let next = ProvisionalLaunchConfiguration(
            agent: agent,
            modelId: modelId,
            effort: effort,
            customProviderId: customProviderId
        )
        if provisionalLaunchConfigurations[sessionId] != next {
            provisionalLaunchConfigurations[sessionId] = next
            registry.previewLaunchConfiguration(
                id: sessionId,
                agent: agent,
                model: modelId,
                effort: effort
            )
        }
        if let store = composerStores[sessionId] {
            store.agent = agent
            store.customProviderId = customProviderId
            store.modelId = modelId
            store.effort = effort
        }
        openOutsideJSONLPath = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openSessionId = sessionId
        return true
    }

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
    @Published var workspaceDraftTabs: [WorkspaceDraftTab] = []
    @Published var selectedWorkspaceDraftTabId: UUID?
    @Published var workspaceTerminalTabs: [WorkspaceTerminalTab] = []
    @Published var selectedWorkspaceTerminalTabId: UUID?
    @Published var workspaceDocumentTabs: [WorkspaceDocumentTab] = []
    @Published var selectedWorkspaceDocumentTabId: UUID?
    private var terminalPanePromotionTasks: [UUID: Task<Void, Never>] = [:]
    private var terminalPanePromotionTickets: [UUID: UUID] = [:]

    /// Per-session URL pin. Drives `chatStore(for:)` to tail the exact JSONL
    /// created for a Continuum-owned session instead of falling back to
    /// `resolveSessionFileURL`'s newest-wins logic.
    @Published public var openOutsideJSONLPath: String?
    private var syntheticOutsideSessions: [String: AgentSession] = [:]
    private var forcedChatStoreURLs: [UUID: URL] = [:]
    private var externalForcedJSONLPaths: Set<String> = []

    /// Sidebar search query (G6). Filters repos + sessions by displayName,
    /// goal, and message body substring. Empty = no filter.
    @Published public var searchQuery: String = ""

    /// When true, archived sessions are visible in the sidebar (G7).
    @Published public var showArchived: Bool = false

    @Published var pendingFirstSendRecoveryVersion: Int = 0
    private var pendingFirstSendRecoveries: [UUID: PendingFirstSendRecovery] = [:]

    /// Currently surfaced as a session in the workspace's center pane.
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

    public var openSessionIsReadOnly: Bool {
        openOutsideJSONLPath != nil && openSessionId == nil
    }

    var draftWorkspaceTab: WorkspaceDraftTab? {
        guard let id = selectedWorkspaceDraftTabId,
              let tab = workspaceDraftTabs.first(where: { $0.id == id })
        else { return nil }
        return tab
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

    var activeWorkspaceKey: WorkspaceKey? {
        if let tab = selectedWorkspaceDocumentTab {
            return tab.workspaceKey
        }
        if let tab = selectedWorkspaceTerminalTab {
            return tab.workspaceKey
        }
        if let session = openSession,
           let key = WorkspaceKey.of(session) {
            return key
        }
        if let draft = draftWorkspaceTab {
            return draft.workspaceKey
        }
        return nil
    }

    public func openOutsideSession(recent: RecentSession, repoKey: String, repoDisplayName: String) {
        let url = URL(fileURLWithPath: recent.path)
        let path = recent.path
        if let existing = syntheticOutsideSessions[path] {
            selectedWorkspaceDraftTabId = nil
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
            goal: recent.firstPrompt,
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
        selectedWorkspaceDraftTabId = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = path
        openSessionId = nil
    }

    public func closeChatView() {
        openSessionId = nil
        selectedWorkspaceDraftTabId = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
    }

    public func prepareNewSession(in repoKey: String?) {
        selectedWorkspaceDraftTabId = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = nil
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
        guard AppDelegate.runtime != nil else {
            Self.postQuickSpawnFailureToast(
                title: "Daemon offline",
                detail: "Restart Clawdmeter to spawn sessions."
            )
            return
        }
        let catalog = ModelCatalog.bundled.filteredToEnabledProviders(for: .code)
        // The per-repo "+" opens a FIXED config: Codex · GPT-5.5 · Extra High ·
        // Plan mode (plan + worktree are set in createQuickSpawnProvisionalSession).
        // Option-click opens the full sheet to customize. Fall back to the sheet
        // only when Codex / GPT-5.5 isn't enabled so we never silently spawn a
        // different provider.
        let agent: AgentKind = .codex
        let modelId = "gpt-5.5"
        guard catalog.entries(for: .codex).contains(where: { $0.id == modelId }) else {
            // Honor the quick-spawn contract: a known repo must NEVER open the
            // New Session sheet — surface the unavailable-provider case as a
            // toast instead (⌥-click still opens the full sheet to customize).
            Self.postQuickSpawnFailureToast(
                title: "Codex isn’t enabled",
                detail: "Turn on Codex (GPT-5.5) in Settings → Providers to use “+”, or ⌥-click “+” to pick another provider."
            )
            return
        }
        let effort: ReasoningEffort? = .xhigh
        let sessionId = UUID()
        expandedRepoKeys.insert(repoKey)
        selectedRepoKey = repoKey
        selectedWorkspaceDraftTabId = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = nil
        provisioningSessionIds.insert(sessionId)
        provisioningProgress[sessionId] = ProvisioningProgress()
        Task { @MainActor in
            do {
                let provisional = try await createQuickSpawnProvisionalSession(
                    repoKey: repoKey,
                    agent: agent,
                    modelId: modelId,
                    effort: effort,
                    sessionId: sessionId
                )
                provisionAndAttachWorktree(
                    sessionId: provisional.session.id,
                    repoKey: repoKey,
                    agent: agent,
                    model: modelId,
                    effort: effort,
                    slug: provisional.slug
                )
            } catch {
                NSLog("[Clawdmeter] quickSpawn provisional create failed repo=%@: %@", repoKey, "\(error)")
                Self.postQuickSpawnFailureToast(
                    title: "Couldn’t start a session in \((repoKey as NSString).lastPathComponent)",
                    detail: Self.humanize(spawnError: error)
                )
            }
        }
    }

    /// Create the visible optimistic row for the Code-tab repo "+" action.
    ///
    /// This is intentionally daemon-free and fast: it reserves the eventual
    /// city/worktree slug, inserts one provisional session keyed to that exact
    /// worktree, and makes that row the sole active workspace selection. The
    /// slower worktree provisioning and provider attach happen later.
    @discardableResult
    func createQuickSpawnProvisionalSession(
        repoKey: String,
        agent: AgentKind,
        modelId: String,
        effort: ReasoningEffort?,
        sessionId: UUID = UUID()
    ) async throws -> QuickSpawnProvisionalSession {
        let city = CityNamer.shared.cityName(for: sessionId)
        let slug = WorktreeManager.slug(city: city)
        let provisionalWorktreePath = WorktreeManager.worktreePath(repoRoot: repoKey, slug: slug)

        expandedRepoKeys.insert(repoKey)
        selectedRepoKey = repoKey
        selectedWorkspaceDraftTabId = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = nil
        provisioningSessionIds.insert(sessionId)
        provisioningProgress[sessionId] = ProvisioningProgress()

        do {
            let provisional = try await registry.create(
                repoKey: repoKey,
                repoDisplayName: (repoKey as NSString).lastPathComponent,
                agent: agent,
                model: modelId,
                goal: nil,
                worktreePath: provisionalWorktreePath,
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                planMode: true,
                mode: .worktree,
                effort: effort,
                ownsWorktree: false,
                id: sessionId
            )
            openOutsideJSONLPath = nil
            openSessionId = provisional.id
            return QuickSpawnProvisionalSession(
                session: provisional,
                slug: slug,
                worktreePath: provisionalWorktreePath
            )
        } catch {
            provisioningSessionIds.remove(sessionId)
            provisionalLaunchConfigurations.removeValue(forKey: sessionId)
            provisioningProgress[sessionId] = nil
            CityNamer.shared.release(sessionId)
            if openSessionId == sessionId { openSessionId = nil }
            throw error
        }
    }

    /// Background half of the optimistic "+" spawn: provisions the worktree
    /// (new branch + Conductor-style file copy + setup script), asks the daemon
    /// to attach the agent runtime to the already-open provisional session, then
    /// flushes any prompt the user queued while it was setting up.
    /// All errors are non-blocking: the provisional session is torn down and a
    /// toast surfaces, never the sheet.
    private func provisionAndAttachWorktree(
        sessionId: UUID,
        repoKey: String,
        agent: AgentKind,
        model: String,
        effort: ReasoningEffort?,
        slug: String
    ) {
        Task { @MainActor in
            var provisionedWorktree: WorktreeManager.ProvisionedWorktree?
            do {
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
                provisionedWorktree = provisioned
                let cwd = provisioned.path
                // v27: drive codex via the daemon ACP/app-server harness. The
                // daemon adopts the optimistic row (same sessionId) and reuses
                // this Mac-provisioned worktree (existingWorkspacePath). Guard
                // with a deadline so a wedged daemon/spawn doesn't leave the
                // trail spinning forever.
                guard let runtime = AppDelegate.runtime,
                      let port = runtime.agentControlServer.boundPort else {
                    throw SpawnError.missingBinary("Daemon not started — relaunch Clawdmeter.")
                }
                let sender = MacComposerSender(
                    port: Int(port),
                    token: runtime.agentControlServer.localLoopbackToken
                )
                let createReq = makeProvisionedLaunchRequest(
                    sessionId: sessionId,
                    repoKey: repoKey,
                    cwd: cwd,
                    fallbackAgent: agent,
                    fallbackModel: model,
                    fallbackEffort: effort
                )
                _ = try await Self.withSpawnTimeout(30) {
                    try await sender.createSession(createReq)
                }
                provisionalLaunchConfigurations.removeValue(forKey: sessionId)
                // Record the worktree provisioning metadata on the (adopted) row
                // so end-of-session cleanup removes the worktree — the daemon
                // adopt set worktree/owns but not the metadata (the Mac owns it).
                try await registry.updateRuntime(
                    id: sessionId,
                    worktreePath: cwd,
                    provisioning: provisioned.metadata,
                    runtimeCwd: cwd,
                    tmuxWindowId: nil,
                    tmuxPaneId: nil,
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
                provisionalLaunchConfigurations.removeValue(forKey: sessionId)
                provisioningProgress[sessionId] = nil
                CityNamer.shared.release(sessionId)
                // v27 timeout-race safety: createSession may have timed out on
                // the Mac while the daemon actually succeeded (adopted the row +
                // started the bridge). Tear down any harness bridge the daemon
                // registered for this id before deleting the row, so we don't
                // leak the driver child. No-op if no bridge exists.
                await AppDelegate.runtime?.agentControlServer.teardownHarnessSession(sessionId)
                if let provisionedWorktree {
                    try? await registry.updateRuntime(
                        id: sessionId,
                        worktreePath: provisionedWorktree.path,
                        provisioning: provisionedWorktree.metadata,
                        runtimeCwd: provisionedWorktree.path,
                        tmuxWindowId: nil,
                        tmuxPaneId: nil,
                        mode: .worktree,
                        ownsWorktree: true
                    )
                    try? await registry.updateStatus(id: sessionId, status: .degraded)
                    recordWorkspaceSession(repoRoot: repoKey, sessionId: sessionId)
                    await refresh()
                } else {
                    try? await registry.delete(id: sessionId)
                    if openSessionId == sessionId { openSessionId = nil }
                }
                NSLog("[Clawdmeter] quickSpawn provision failed sid=%@ repo=%@: %@",
                      sessionId.uuidString, repoKey, "\(error)")
                Self.postQuickSpawnFailureToast(
                    title: provisionedWorktree == nil
                        ? "Couldn’t set up the worktree in \((repoKey as NSString).lastPathComponent)"
                        : "Worktree created, but Codex didn’t attach",
                    detail: Self.humanize(spawnError: error)
                )
            }
        }
    }

    func makeProvisionedLaunchRequest(
        sessionId: UUID,
        repoKey: String,
        cwd: String,
        fallbackAgent: AgentKind,
        fallbackModel: String,
        fallbackEffort: ReasoningEffort?
    ) -> NewSessionRequest {
        let launchSession = registry.session(id: sessionId)
        let launchAgent: AgentKind
        let launchModel: String?
        let launchEffort: ReasoningEffort?
        let launchCustomProviderId: String?
        if let launchConfig = provisionalLaunchConfigurations[sessionId] {
            launchAgent = launchConfig.agent
            launchModel = launchConfig.modelId
            launchEffort = launchConfig.effort
            launchCustomProviderId = launchConfig.customProviderId
        } else {
            launchAgent = launchSession?.agent ?? fallbackAgent
            launchModel = launchSession?.model ?? fallbackModel
            launchEffort = launchSession?.effort ?? fallbackEffort
            launchCustomProviderId = launchSession?.customProviderId
        }
        return NewSessionRequest(
            repoKey: repoKey,
            agent: launchAgent,
            model: launchModel,
            planMode: false,
            goal: nil,
            useWorktree: true,
            effort: launchEffort,
            existingWorkspacePath: cwd,
            sessionId: sessionId,
            customProviderId: launchCustomProviderId
        )
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

    /// Collapse the spawn / worktree / shell error zoo into one human,
    /// actionable line. Raw git/shell stderr — e.g. "fatal: Unable to
    /// read current working directory: Operation not permitted" or the
    /// "(…ShellError error 2.)" NSError fallback — must never reach the UI
    /// verbatim. Match the known low-level failures and say what to do next.
    /// Internal (not private) so `NewSessionMacSheet` can route its sheet
    /// errors through the same humanizer the quick-spawn toast uses.
    static func humanize(spawnError error: Error) -> String {
        // Failures that look identical across git and the agent CLIs
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
        browserComments: [BrowserCommentContext] = [],
        error: ComposerStore.SendError,
        autoSendWhenReady: Bool = false
    ) {
        pendingFirstSendRecoveries[sessionId] = PendingFirstSendRecovery(
            text: text,
            attachments: attachments,
            browserComments: browserComments,
            error: error,
            createdAt: Date(),
            clientIntentId: UUID().uuidString,
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
    public let workspaceStore: WorkspaceStore
    public let repoEnvResolver: RepoEnvRuntimeResolver?
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

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
    private var daemonOwnedChatStoreIds: Set<UUID> = []
    private static let maxResidentChatStores = 3
    /// Per-session cached `ComposerStore` (tab-switch perf). Built once on
    /// first open and reused, so switching Code tabs no longer rebuilds the
    /// composer (and discards the in-progress draft + model/effort/mode chip
    /// selections) on every flip. Evicted alongside `chatStores` under the
    /// same LRU window so it stays bounded.
    private var composerStores: [UUID: ComposerStore] = [:]
    /// Per-draft composer stores. Workspace drafts are not registry sessions yet,
    /// so they need their own cache keyed by draft tab id; otherwise selecting
    /// another draft can resurrect another tab's model/text state.
    private var draftComposerStores: [UUID: ComposerStore] = [:]
    /// The legacy pane token a session's chat store was last resolved against,
    /// keyed by session id ("" = no legacy pane metadata). Forced revalidation
    /// handles runtime changes that can rotate JSONLs; otherwise we avoid the
    /// synchronous parent-walk + per-file stat scan on warm tab toggles.
    private var lastResolvedPaneId: [UUID: String] = [:]
    /// Sessions whose tailed JSONL must be re-resolved on the next `chatStore`
    /// access regardless of pane id. This is set when a Continuum-owned
    /// forced JSONL pin is applied so the override takes effect immediately
    /// even though the pane id may be unchanged.
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
        workspaceStore: WorkspaceStore,
        repoEnvResolver: RepoEnvRuntimeResolver? = nil
    ) {
        self.repoIndex = repoIndex
        self.registry = registry
        self.workspaceStore = workspaceStore
        self.repoEnvResolver = repoEnvResolver
        registry.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
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

    /// Get or create the chat store for a session. Continuum-owned sessions
    /// may pin the exact JSONL they spawned; otherwise this falls back to
    /// "newest JSONL under the repo's project dir".
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
                daemonOwnedChatStoreIds.insert(session.id)
                touchLRU(session.id)
                return existing
            }
            guard let daemonStore = AppDelegate.runtime?.agentControlServer.chatStore(for: session) else {
                return nil
            }
            chatStores[session.id] = daemonStore
            daemonOwnedChatStoreIds.insert(session.id)
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
        // v27 Code-tab harness migration: a paneless harness Code session
        // (codex/cursor/gemini driven by a live bridge) reads the daemon-owned
        // store the bridge writes into — exactly like a chat session — instead
        // of resolving + tailing a JSONL. Mirror the `.chat` branch above.
        if AppDelegate.runtime?.agentControlServer.isHarnessLive(session.id) == true {
            if let existing = chatStores[session.id] {
                daemonOwnedChatStoreIds.insert(session.id)
                touchLRU(session.id)
                return existing
            }
            guard let daemonStore = AppDelegate.runtime?.agentControlServer.chatStore(for: session) else {
                return nil
            }
            chatStores[session.id] = daemonStore
            daemonOwnedChatStoreIds.insert(session.id)
            chatStoreLRU.append(session.id)
            lastResolvedPaneId[session.id] = session.tmuxPaneId ?? ""
            evictExcessChatStores()
            return daemonStore
        }
        if let existing = chatStores[session.id] {
            touchLRU(session.id)
            // Audit P1 fix: when a runtime changes the tailed JSONL, the cached
            // store can keep tailing the dead plan-mode file unless we swap it
            // in place. Resolving on EVERY warm hit means a synchronous
            // parent-walk + per-file stat scan of ~/.claude/projects/<repo>/
            // on every Code-tab flip. Use forced revalidation, plus the legacy
            // pane token for old persisted rows, to skip the common toggle scan.
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
        daemonOwnedChatStoreIds.remove(session.id)
        chatStoreLRU.append(session.id)
        // Record the token the store was just resolved against so the next warm
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

    public func renameJSONLAlias(path: String, name: String?) {
        JSONLAliasStore.shared.setAlias(path: path, name: name)
        Task { [repoIndex] in await repoIndex.refresh() }
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
            if !daemonOwnedChatStoreIds.contains(evictId) {
                chatStores[evictId]?.stop()
            }
            chatStores.removeValue(forKey: evictId)
            daemonOwnedChatStoreIds.remove(evictId)
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
        if !daemonOwnedChatStoreIds.contains(sessionId) {
            chatStores[sessionId]?.stop()
        }
        chatStores.removeValue(forKey: sessionId)
        daemonOwnedChatStoreIds.remove(sessionId)
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

    func composerStore(for draft: WorkspaceDraftTab) -> ComposerStore {
        if let existing = draftComposerStores[draft.id] { return existing }
        let store = ComposerStore(mode: .emptyState(repoKey: draft.workspaceKey.repoKey, agent: draft.agent))
        store.resetChipsForRepo(
            draft.workspaceKey.repoKey,
            defaults: ComposerStore.ChipDefaults(
                agent: draft.agent,
                modelId: draft.modelId,
                effort: draft.effort,
                mode: draft.mode,
                planMode: false
            )
        )
        draftComposerStores[draft.id] = store
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
            let matches = filter(sessions: sessions(for: repo.key, includeArchived: showArchived))
            return !matches.isEmpty
        }
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
        selectedWorkspaceDraftTabId = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = session.id
    }

    public func openSession(_ session: AgentSession) {
        // Do not remove draft tabs here: switching to another tab must not
        // discard in-progress "Untitled" drafts. Drafts persist in the tab strip
        // until the user closes them or they are consumed by a spawn.
        selectedWorkspaceDraftTabId = nil
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = session.id
    }

    /// Re-select the in-progress draft tab (show its composer) without losing it.
    func selectDraftWorkspaceTab(_ tab: WorkspaceDraftTab? = nil) {
        let target = tab ?? draftWorkspaceTab
        guard let target,
              workspaceDraftTabs.contains(where: { $0.id == target.id })
        else { return }
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        selectedWorkspaceDraftTabId = target.id
        openSessionId = nil
    }

    func updateDraftWorkspaceTabConfiguration(
        id: UUID,
        agent: AgentKind,
        modelId: String?,
        effort: ReasoningEffort?
    ) {
        guard let index = workspaceDraftTabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = workspaceDraftTabs[index]
        guard tab.agent != agent || tab.modelId != modelId || tab.effort != effort else { return }
        tab.agent = agent
        tab.modelId = modelId
        tab.effort = effort
        workspaceDraftTabs[index] = tab
    }

    func workspaceDraftTabs(in workspaceKey: WorkspaceKey) -> [WorkspaceDraftTab] {
        workspaceDraftTabs
            .filter { $0.workspaceKey == workspaceKey }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// Whether any foreground workspace tab (session, draft, terminal, or
    /// document) still lives in `key`. Used when closing one tab so we don't
    /// tear down the shared worktree/branch while other tabs remain open.
    func workspaceHasOpenTabs(in key: WorkspaceKey, excludingSessionId: UUID? = nil) -> Bool {
        if !WorkspaceKey.siblings(of: key, in: registry.sessions, excluding: excludingSessionId).isEmpty {
            return true
        }
        if !workspaceDraftTabs(in: key).isEmpty { return true }
        if !workspaceTerminalTabs(in: key).isEmpty { return true }
        if !workspaceDocumentTabs(in: key).isEmpty { return true }
        return false
    }

    /// Workspace keys with open client-side tabs (drafts/terminals/documents)
    /// for a repo. Keeps sidebar worktree rows visible when every session tab
    /// was closed but unsent drafts still reference the branch.
    func openWorkspaceTabKeys(inRepo repoKey: String) -> [WorkspaceKey] {
        let canonical = WorkspaceKey.canonicalPath(repoKey)
        var keys = Set<WorkspaceKey>()
        for draft in workspaceDraftTabs where WorkspaceKey.canonicalPath(draft.workspaceKey.repoKey) == canonical {
            keys.insert(draft.workspaceKey)
        }
        for tab in workspaceTerminalTabs where WorkspaceKey.canonicalPath(tab.workspaceKey.repoKey) == canonical {
            keys.insert(tab.workspaceKey)
        }
        for tab in workspaceDocumentTabs where WorkspaceKey.canonicalPath(tab.workspaceKey.repoKey) == canonical {
            keys.insert(tab.workspaceKey)
        }
        return Array(keys)
    }

    private func promoteWorkspaceForegroundSelection(in key: WorkspaceKey?) {
        guard let key else { return }
        if openSessionId != nil
            || selectedWorkspaceDraftTabId != nil
            || selectedWorkspaceTerminalTabId != nil
            || selectedWorkspaceDocumentTabId != nil {
            return
        }
        if let session = WorkspaceKey.siblings(of: key, in: registry.sessions).last {
            openSession(session)
            return
        }
        if let draft = workspaceDraftTabs(in: key).last {
            selectDraftWorkspaceTab(draft)
            return
        }
        if let terminal = workspaceTerminalTabs(in: key).last {
            selectWorkspaceTerminalTab(terminal)
            return
        }
        if let document = workspaceDocumentTabs(in: key).last {
            selectWorkspaceDocumentTab(document)
        }
    }

    private func finalizeWorkspaceIfEmpty(in key: WorkspaceKey) async {
        guard !workspaceHasOpenTabs(in: key) else { return }
        _ = try? await WorktreeManager.shared.delete(
            repoRoot: key.repoKey,
            worktreePath: key.workspacePath,
            registryOwned: true,
            attachedPanePaths: []
        )
    }

    @discardableResult
    func openDraftWorkspaceTab(
        from session: AgentSession,
        defaults: ComposerStore.ChipDefaults
    ) -> WorkspaceDraftTab? {
        guard let key = WorkspaceKey.of(session) else { return nil }
        return openDraftWorkspaceTab(in: key, mode: defaults.mode, defaults: defaults)
    }

    @discardableResult
    func openDraftWorkspaceTab(
        in key: WorkspaceKey,
        mode: SessionMode,
        defaults: ComposerStore.ChipDefaults
    ) -> WorkspaceDraftTab {
        selectedWorkspaceTerminalTabId = nil
        selectedWorkspaceDocumentTabId = nil
        openOutsideJSONLPath = nil
        let tab = WorkspaceDraftTab(
            workspaceKey: key,
            mode: mode,
            agent: defaults.agent,
            modelId: defaults.modelId,
            effort: defaults.effort
        )
        workspaceDraftTabs.append(tab)
        selectedWorkspaceDraftTabId = tab.id
        openSessionId = nil
        return tab
    }

    @discardableResult
    func openDraftWorkspaceTab(from draft: WorkspaceDraftTab) -> WorkspaceDraftTab {
        openDraftWorkspaceTab(
            in: draft.workspaceKey,
            mode: draft.mode,
            defaults: ComposerStore.ChipDefaults(
                agent: draft.agent,
                modelId: draft.modelId,
                effort: draft.effort,
                mode: draft.mode,
                planMode: false
            )
        )
    }

    func canOpenNewWorkspaceChatDraftTab() -> Bool {
        openSession != nil || draftWorkspaceTab != nil
    }

    func clearDraftWorkspaceTab(_ tab: WorkspaceDraftTab? = nil) {
        guard let id = tab?.id ?? selectedWorkspaceDraftTabId else { return }
        let removed = workspaceDraftTabs.first { $0.id == id }
        workspaceDraftTabs.removeAll { $0.id == id }
        if selectedWorkspaceDraftTabId == id {
            if let workspaceKey = removed?.workspaceKey,
               let replacement = workspaceDraftTabs(in: workspaceKey).last {
                selectedWorkspaceDraftTabId = replacement.id
                openSessionId = nil
            } else {
                selectedWorkspaceDraftTabId = nil
            }
        }
        draftComposerStores.removeValue(forKey: id)
        if let workspaceKey = removed?.workspaceKey {
            promoteWorkspaceForegroundSelection(in: workspaceKey)
            let key = workspaceKey
            Task { await finalizeWorkspaceIfEmpty(in: key) }
        }
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
        let draft = openDraftWorkspaceTab(from: session, defaults: defaults)
        return draft?.workspaceKey == key ? draft?.id : nil
    }

    /// #185-named convenience around `openOrCreateWorkspaceTerminalTab(from:)`.
    /// Resolves the parent session by id, validates the worktree-terminal gate,
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
              session.tmuxPaneId == nil,
              session.tmuxWindowId == nil
        else { return false }
        return true
    }

    func sourceForNewWorkspaceTerminalTab() -> AgentSession? {
        if let session = openSession, canOpenWorkspaceTerminalTab(from: session) {
            return session
        }
        guard let draft = draftWorkspaceTab else { return nil }
        return WorkspaceKey.siblings(of: draft.workspaceKey, in: registry.sessions)
            .first(where: { canOpenWorkspaceTerminalTab(from: $0) })
    }

    func canOpenNewWorkspaceTerminalTab() -> Bool {
        sourceForNewWorkspaceTerminalTab() != nil
    }

    func selectWorkspaceTerminalTab(_ tab: WorkspaceTerminalTab) {
        guard let session = registry.session(id: tab.sessionId),
              canOpenWorkspaceTerminalTab(from: session),
              let sessionKey = WorkspaceKey.of(session),
              sessionKey == tab.workspaceKey
        else { return }
        selectedWorkspaceDraftTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = tab.sessionId
        selectedWorkspaceDocumentTabId = nil
        selectedWorkspaceTerminalTabId = tab.id
    }

    @discardableResult
    func openWorkspaceTerminalTab(
        from session: AgentSession,
        paneRefId: UUID? = nil,
        createdAt: Date = Date()
    ) -> WorkspaceTerminalTab? {
        guard canOpenWorkspaceTerminalTab(from: session),
              let workspaceKey = WorkspaceKey.of(session)
        else { return nil }
        if let existing = workspaceTerminalTabs.first(where: {
            $0.sessionId == session.id && $0.paneRefId == paneRefId && $0.workspaceKey == workspaceKey
        }) {
            selectWorkspaceTerminalTab(existing)
            return existing
        }
        let tab = WorkspaceTerminalTab(
            sessionId: session.id,
            workspaceKey: workspaceKey,
            paneRefId: paneRefId,
            createdAt: createdAt
        )
        workspaceTerminalTabs.append(tab)
        selectWorkspaceTerminalTab(tab)
        return tab
    }

    func openOrCreateWorkspaceTerminalTab(from session: AgentSession) async {
        guard canOpenWorkspaceTerminalTab(from: session),
              let workspaceKey = WorkspaceKey.of(session) else { return }
        let existingTabs = workspaceTerminalTabs.filter {
            $0.sessionId == session.id && $0.workspaceKey == workspaceKey
        }
        let visibleTitle = existingTabs.isEmpty ? "Shell" : "Pane \(existingTabs.count + 1)"
        guard let pendingTab = openPendingWorkspaceTerminalTab(
            from: session,
            workspaceKey: workspaceKey,
            title: visibleTitle
        ) else {
            if let last = existingTabs.sorted(by: { $0.createdAt < $1.createdAt }).last {
                selectWorkspaceTerminalTab(last)
            }
            return
        }

        let ticket = UUID()
        let previousPromotion = terminalPanePromotionTasks[session.id]
        terminalPanePromotionTickets[session.id] = ticket
        let promotion = Task { @MainActor [weak self] in
            await previousPromotion?.value
            guard let self else { return }
            await self.completePendingWorkspaceTerminalTab(
                tabId: pendingTab.id,
                sessionId: session.id,
                requestedTitle: visibleTitle
            )
            if self.terminalPanePromotionTickets[session.id] == ticket {
                self.terminalPanePromotionTickets.removeValue(forKey: session.id)
                self.terminalPanePromotionTasks.removeValue(forKey: session.id)
            }
        }
        terminalPanePromotionTasks[session.id] = promotion
    }

    @discardableResult
    private func openPendingWorkspaceTerminalTab(
        from session: AgentSession,
        workspaceKey: WorkspaceKey,
        title: String,
        createdAt: Date = Date()
    ) -> WorkspaceTerminalTab? {
        guard canOpenWorkspaceTerminalTab(from: session),
              WorkspaceKey.of(session) == workspaceKey else { return nil }
        let tab = WorkspaceTerminalTab(
            sessionId: session.id,
            workspaceKey: workspaceKey,
            paneRefId: nil,
            isPendingDirectShell: true,
            pendingTitle: title,
            createdAt: createdAt
        )
        workspaceTerminalTabs.append(tab)
        selectWorkspaceTerminalTab(tab)
        return tab
    }

    private func completePendingWorkspaceTerminalTab(
        tabId: UUID,
        sessionId: UUID,
        requestedTitle: String?
    ) async {
        guard workspaceTerminalTabs.contains(where: { $0.id == tabId }) else { return }
        guard let paneRef = await addTerminalPane(sessionId: sessionId, title: requestedTitle) else {
            removePendingWorkspaceTerminalTab(tabId: tabId)
            return
        }

        let promoted = promotePendingWorkspaceTerminalTab(tabId: tabId, paneRefId: paneRef.id)
        if !promoted {
            await closeTerminalPane(sessionId: sessionId, paneRef: paneRef)
        }
    }

    @discardableResult
    private func promotePendingWorkspaceTerminalTab(tabId: UUID, paneRefId: UUID) -> Bool {
        guard let index = workspaceTerminalTabs.firstIndex(where: { $0.id == tabId }) else { return false }
        let pending = workspaceTerminalTabs[index]
        let wasSelected = selectedWorkspaceTerminalTabId == pending.id
        workspaceTerminalTabs[index] = WorkspaceTerminalTab(
            id: pending.id,
            sessionId: pending.sessionId,
            workspaceKey: pending.workspaceKey,
            paneRefId: paneRefId,
            isPendingDirectShell: false,
            pendingTitle: nil,
            createdAt: pending.createdAt
        )
        if wasSelected {
            selectedWorkspaceTerminalTabId = pending.id
        }
        return true
    }

    private func removePendingWorkspaceTerminalTab(tabId: UUID) {
        workspaceTerminalTabs.removeAll { $0.id == tabId }
        if selectedWorkspaceTerminalTabId == tabId {
            selectedWorkspaceTerminalTabId = nil
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
                openOutsideJSONLPath = nil
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
        selectedWorkspaceDraftTabId = nil
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
                openOutsideJSONLPath = nil
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
            if !sessions(for: repo.key, aliases: canonical.keyAliases, includeArchived: false).isEmpty {
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
        /// Runtime spawn did not complete in time. Surfaced (not hung) so the
        /// user can relaunch + retry.
        case spawnTimedOut
        public var errorDescription: String? {
            switch self {
            case .missingBinary(let m): return m
            case .unsupportedMode(let m): return m
            case .antigravityNotReady(let m): return m
            case .spawnTimedOut:
                return "Timed out starting the agent. Quit and relaunch Clawdmeter, then try again."
            }
        }
    }

    /// Race an async op against a deadline. If a runtime spawn never resumes its
    /// continuation, abandon it and surface a timeout instead of hanging forever.
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

    /// v27 Code-tab harness migration: spawn a paneless harness session
    /// (codex/cursor/gemini) by delegating to the daemon's `POST /sessions`
    /// over the loopback, then adopt it into the open-state. `existingWorkspacePath`/`sessionId` are set by the
    /// optimistic "+" path so the Mac-provisioned worktree + pre-minted row are
    /// reused; nil for the New Session sheet (the daemon provisions + mints).
    private func spawnHarnessSessionViaDaemon(
        repoPath: String,
        agent: AgentKind,
        planMode: Bool,
        goal: String?,
        mode: SessionMode,
        model: String?,
        effort: ReasoningEffort?,
        providerInstanceId: String? = nil,
        existingWorkspacePath: String?,
        sessionId: UUID?,
        customProviderId: String? = nil
    ) async throws -> AgentSession {
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort else {
            throw SpawnError.missingBinary("Daemon not started — relaunch Clawdmeter.")
        }
        let sender = MacComposerSender(
            port: Int(port),
            token: runtime.agentControlServer.localLoopbackToken
        )
        let req = NewSessionRequest(
            repoKey: repoPath,
            agent: agent,
            model: model,
            planMode: planMode,
            goal: goal,
            useWorktree: mode == .worktree,
            effort: effort,
            providerInstanceId: providerInstanceId,
            existingWorkspacePath: existingWorkspacePath,
            sessionId: sessionId,
            customProviderId: customProviderId
        )
        let session = try await sender.createSession(req)
        recordWorkspaceSession(repoRoot: repoPath, sessionId: session.id)
        expandedRepoKeys.insert(repoPath)
        selectedWorkspaceDraftTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = session.id
        await refresh()
        return registry.session(id: session.id) ?? session
    }

    public func spawnSession(
        repoPath: String,
        agent: AgentKind,
        planMode: Bool,
        goal: String?,
        mode: SessionMode,
        resumeSessionId: String? = nil,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        acceptEdits: Bool = false,
        // v0.7.15: empty-state composer can now pick Bypass and have it
        // actually reach the spawned CLI. Caller is responsible for the
        // trust-gate UX (AutopilotState.trustRepo) before passing true.
        autopilot: Bool = false,
        // Multi-account (wire v28): pin the spawn to a configured account
        // (`ProviderInstanceId.wireId`). nil = primary.
        providerInstanceId: String? = nil,
        pinnedJSONLURL: URL? = nil,
        // v0.8.1 agy-migration: full first-prompt text for agentapi
        // spawn. Direct PTY sessions receive the prompt via the post-spawn
        // /send call, but Antigravity 2's
        // `agentapi new-conversation` requires the actual first turn at
        // spawn-time. Callers (EmptyStateCenteredComposer) pass the
        // composer's rendered body; nil falls back to `goal` for paths
        // that don't have a composer (resume flows, daemon-side spawns).
        initialMessage: String? = nil,
        customProviderId: String? = nil
    ) async throws -> AgentSession {
        try assertProviderEnabled(agent)
        if resumeSessionId != nil {
            throw SpawnError.unsupportedMode("Resume existing JSONL sessions through Continue Here.")
        }
        if agent == .cursor {
            if planMode {
                throw SpawnError.unsupportedMode("Cursor plan mode requires a resumable Cursor session. Start Cursor in another permission mode.")
            }
            let cursorState = await CursorModelProbe.shared.currentState()
            guard cursorState.binaryPath != nil else {
                throw SpawnError.missingBinary("Cursor Agent CLI not found or failed identity check: cursor-agent or agent. Install the CLI and ensure it's on your PATH.")
            }
            guard cursorState.authenticated else {
                throw SpawnError.missingBinary("Run cursor-agent login, then try again.")
            }
            if let model,
               !CursorModelCatalog.isAutoModel(model),
               !cursorState.models.contains(where: { $0.id == model || $0.cliAlias == model }) {
                throw SpawnError.missingBinary("Cursor model is not available for the authenticated account.")
            }
        } else if agent != .gemini, agent != .opencode, let reason = AgentSpawner.preflight(agent: agent) {
            throw SpawnError.missingBinary(reason)
        }
        _ = acceptEdits
        _ = autopilot
        _ = pinnedJSONLURL
        _ = initialMessage
        return try await spawnHarnessSessionViaDaemon(
            repoPath: repoPath, agent: agent, planMode: planMode, goal: goal, mode: mode,
            model: model, effort: effort, providerInstanceId: providerInstanceId,
            existingWorkspacePath: nil, sessionId: nil,
            customProviderId: customProviderId
        )
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
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        acceptEdits: Bool = false,
        autopilot: Bool = false,
        providerInstanceId: String? = nil,
        initialMessage: String? = nil,
        inheritedContextSourceIds: [UUID] = [],
        customProviderId: String? = nil
    ) async throws -> AgentSession {
        try assertProviderEnabled(agent)
        let paths = Self.existingWorkspaceRecordPaths(
            repoPath: repoPath,
            workspacePath: workspacePath,
            mode: mode
        )
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
        // Route into the EXISTING worktree via the daemon (reuse the worktree —
        // existingWorkspace tells the daemon to skip provisioning).
        do {
            if agent == .cursor {
                if planMode {
                    throw SpawnError.unsupportedMode("Cursor plan mode requires a resumable Cursor session. Start Cursor in another permission mode.")
                }
                let cursorState = await CursorModelProbe.shared.currentState()
                guard cursorState.binaryPath != nil else {
                    throw SpawnError.missingBinary("Cursor Agent CLI not found or failed identity check: cursor-agent or agent. Install the CLI and ensure it's on your PATH.")
                }
                guard cursorState.authenticated else {
                    throw SpawnError.missingBinary("Run cursor-agent login, then try again.")
                }
                if let model,
                   !CursorModelCatalog.isAutoModel(model),
                   !cursorState.models.contains(where: { $0.id == model || $0.cliAlias == model }) {
                    throw SpawnError.missingBinary("Cursor model is not available for the authenticated account.")
                }
            } else if agent != .gemini, let reason = AgentSpawner.preflight(agent: agent) {
                throw SpawnError.missingBinary(reason)
            }
            let session = try await spawnHarnessSessionViaDaemon(
                repoPath: repoPath, agent: agent, planMode: planMode, goal: goal, mode: mode,
                model: model, effort: effort, providerInstanceId: providerInstanceId,
                existingWorkspacePath: workspacePath, sessionId: nil,
                customProviderId: customProviderId
            )
            try await registry.setInheritedContextSources(sessionId: session.id, sourceIds: inheritedContextSourceIds)
            return registry.session(id: session.id) ?? session
        } catch {
            _ = paths
            _ = acceptEdits
            _ = autopilot
            _ = initialMessage
            throw error
        }
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
        selectedWorkspaceDraftTabId = nil
        openOutsideJSONLPath = nil
        openSessionId = session.id
        await self.refresh()
        return registry.session(id: session.id) ?? session
    }

    /// G2: switch a live session's mode (Local ↔ Worktree) through the active
    /// direct runtime.
    public func switchMode(sessionId: UUID, to newMode: SessionMode) async {
        guard let session = registry.session(id: sessionId) else { return }
        guard newMode != session.mode, newMode != .cloud else { return }
        WorkspaceFeedback.info("Mode → \(newMode.rawValue.capitalized)")
        let changer = SessionConfigChanger(registry: registry, repoEnvResolver: repoEnvResolver)
        let result = await changer.swap(sessionId: sessionId, newMode: newMode)
        surfaceSwap(result, succeeded: "Mode updated", failed: "Couldn't change mode", successToast: false)
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

    /// A bound runtime cannot change provider mid-session — model plurality
    /// lives in workspace tabs. Cross-provider picks open a sibling draft
    /// configured for the picked provider/model instead of mutating the
    /// running session: the old path respawned e.g. `claude --model
    /// cursor-default`, which never becomes ready and strands the session
    /// on "Connecting to Claude" with a Cursor chip.
    @discardableResult
    func openCrossProviderDraft(
        from session: AgentSession,
        entry: ModelCatalogEntry,
        effort: ReasoningEffort?
    ) -> WorkspaceDraftTab? {
        WorkspaceFeedback.info("New \(entry.displayName) tab in this worktree")
        return openDraftWorkspaceTab(
            from: session,
            defaults: ComposerStore.ChipDefaults(
                agent: entry.provider,
                modelId: entry.id,
                effort: entry.supportsEffort ? effort : nil,
                mode: session.mode,
                planMode: false
            )
        )
    }

    public func switchModel(sessionId: UUID, to entry: ModelCatalogEntry, effort: ReasoningEffort? = nil) async {
        // Cross-provider guard: never hand another provider's model id to the
        // session's own runtime respawn.
        if let session = registry.session(id: sessionId), entry.provider != session.agent {
            openCrossProviderDraft(from: session, entry: entry, effort: effort)
            return
        }
        // Visible feedback within the click (sub-250ms): the chip already
        // shows the new value; the respawn confirms asynchronously and only
        // failure needs a follow-up toast.
        WorkspaceFeedback.info("Model → \(entry.displayName)")
        let changer = SessionConfigChanger(
            registry: registry,
            repoEnvResolver: repoEnvResolver
        )
        let modelToUse = entry.cliAlias ?? entry.id
        let result = await changer.swap(sessionId: sessionId, newModel: modelToUse, newEffort: .some(effort))
        surfaceSwap(result, succeeded: "Model → \(entry.displayName)", failed: "Couldn't switch model", successToast: false)
    }

    /// Sessions v2 Phase 1: swap the effort dial mid-session.
    public func switchEffort(sessionId: UUID, to effort: ReasoningEffort) async {
        let changer = SessionConfigChanger(
            registry: registry,
            repoEnvResolver: repoEnvResolver
        )
        let result = await changer.swap(sessionId: sessionId, newEffort: .some(effort))
        surfaceSwap(result, succeeded: "Reasoning effort updated", failed: "Couldn't change effort", successToast: false)
    }

    /// Sessions v2 Phase 1: toggle plan/code mid-session (Claude only).
    public func switchPlanMode(sessionId: UUID, planMode: Bool) async {
        WorkspaceFeedback.success(planMode ? "Switched to Plan mode" : "Switched to Code mode")
        let changer = SessionConfigChanger(
            registry: registry,
            repoEnvResolver: repoEnvResolver
        )
        let result = await changer.swap(sessionId: sessionId, newPlanMode: planMode)
        surfaceSwap(result,
                    succeeded: planMode ? "Switched to Plan mode" : "Switched to Code mode",
                    failed: "Couldn't change mode",
                    successToast: false)
    }

    /// Revive a degraded session through its direct runtime.
    @discardableResult
    public func revive(sessionId: UUID) async -> Bool {
        let changer = SessionConfigChanger(
            registry: registry,
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
        // Visible feedback within the click (sub-250ms). The store flip above
        // is the optimistic state change; waiting for the kill+respawn round
        // trip made this toast land seconds after the click. Failure below
        // still replaces it with the rollback explanation.
        WorkspaceFeedback.success("Permission mode → \(newMode.displayName)")
        let changer = SessionConfigChanger(
            registry: registry,
            repoEnvResolver: repoEnvResolver
        )
        let result = await changer.swap(sessionId: sessionId, newPlanMode: newMode == .plan)
        if case .swapped = result {} else {
            // Respawn didn't take — restore the flags so the chip reflects the
            // CLI that's actually running, not the mode the user attempted.
            store.setAcceptEdits(priorAcceptEdits, sessionId: sessionId)
            store.setBypass(priorBypass, sessionId: sessionId)
        }
        surfaceSwap(result, succeeded: "Permission mode updated", failed: "Couldn't change permission mode", successToast: false)
    }

    public func endSession(id: UUID) async {
        guard let session = registry.session(id: id) else {
            try? await registry.delete(id: id)
            return
        }
        // Tear down live runtime state before removing the registry row.
        await AppDelegate.runtime?.agentControlServer.teardownHarnessSession(id)
        await ClaudePtyRegistry.shared.suspend(id)
        for pane in session.terminalPanes {
            await TerminalPtyRegistry.shared.kill(id: pane.paneId)
        }
        // v0.8 REV-DELETE: code sessions go through WorktreeManager; chat
        // sessions get ChatCwdCleaner in Phase 4. Guard here so Phase 2
        // doesn't crash on a chat session reaching this path.
        //
        // Closing ONE tab must not tear down the shared worktree/branch while
        // other tabs still live in it. Every tab in a workspace shares one
        // worktree, so only delete it when this is the last tab — no other
        // live sibling session AND no open draft tab in the same workspace.
        // (The last tab to close still cleans up, so no worktree is leaked.)
        let workspaceKey = WorkspaceKey.of(session)
        if session.kind == .code, session.ownsWorktree, let worktreePath = session.worktreePath, let repoRoot = session.repoKey {
            let liveSiblings = workspaceKey.map {
                WorkspaceKey.siblings(of: $0, in: registry.sessions, excluding: session.id)
            } ?? []
            let hasRemainingTabs = workspaceKey.map {
                workspaceHasOpenTabs(in: $0, excludingSessionId: session.id)
            } ?? false
            if !hasRemainingTabs {
                // Last tab in the workspace — safe to delete the shared worktree/branch.
                _ = try? await WorktreeManager.shared.delete(
                    repoRoot: repoRoot,
                    worktreePath: worktreePath,
                    registryOwned: true,
                    attachedPanePaths: []
                )
            } else if let heir = liveSiblings.first {
                // Other live session tabs still run in this worktree. Hand ownership
                // to a surviving sibling so whichever tab closes LAST cleans it up.
                registry.transferWorktreeOwnership(to: heir.id)
            }
            // Draft/terminal/document tabs also keep the worktree alive until the
            // last foreground tab in the workspace closes.
        }
        if openSessionId == id { openSessionId = nil }
        promoteWorkspaceForegroundSelection(in: workspaceKey)
        closeChatStore(for: id)
        try? await registry.delete(id: id)
    }

    // MARK: - G17 threaded sub-chats

    /// Spawn a child session linked to the parent via `parentSessionId`.
    /// The child runs in the same cwd as the parent (worktree-aware) but
    /// uses the daemon-owned direct runtime.
    @discardableResult
    public func spawnSubchat(parentId: UUID) async -> AgentSession? {
        guard let parent = registry.session(id: parentId) else { return nil }
        // v0.8: sub-chats are a code-session-only feature (G17 nested
        // threaded rows). Chat-tab sessions don't carry sub-chats.
        guard parent.kind == .code, let parentRepoKey = parent.repoKey else { return nil }
        do {
            let child = try await spawnSessionInExistingWorkspace(
                repoPath: parentRepoKey,
                workspacePath: parent.effectiveCwd,
                agent: parent.agent,
                planMode: false,
                goal: nil,
                mode: parent.mode,
                model: parent.model,
                effort: parent.effort
            )
            openOutsideJSONLPath = nil
            openSessionId = child.id
            await refresh()
            return child
        } catch {
            return nil
        }
    }

    // MARK: - G12 multi-terminal

    /// Spawn a new direct shell terminal and add a TerminalPaneRef to the registry.
    @discardableResult
    public func addTerminalPane(sessionId: UUID, title requestedTitle: String? = nil) async -> TerminalPaneRef? {
        guard let session = registry.session(id: sessionId),
              session.tmuxPaneId == nil,
              session.tmuxWindowId == nil else { return nil }
        let trimmedTitle = requestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedTitle.isEmpty ? "Pane \(session.terminalPanes.count + 2)" : trimmedTitle
        do {
            let host = try await TerminalPtyRegistry.shared.spawnShell(
                cwd: session.effectiveCwd,
                title: title
            )
            let ref = TerminalPaneRef(
                paneId: host.id.uuidString,
                title: title,
                isPrimary: false
            )
            try await registry.addTerminalPane(sessionId: sessionId, pane: ref)
            return ref
        } catch {
            return nil
        }
    }

    /// Close one terminal pane (non-primary).
    public func closeTerminalPane(sessionId: UUID, paneRef: TerminalPaneRef) async {
        guard !paneRef.isPrimary else { return }
        await TerminalPtyRegistry.shared.kill(id: paneRef.paneId)
        try? await registry.removeTerminalPane(sessionId: sessionId, paneRefId: paneRef.id)
    }

    public func approvePlan(id: UUID) async {
        guard let runtime = AppDelegate.runtime,
              let session = registry.session(id: id),
              let port = runtime.agentControlServer.boundPort,
              session.status == .planning,
              (session.planText?.isEmpty == false || session.agent == .codex)
        else { return }
        do {
            let sender = MacComposerSender(
                port: Int(port),
                token: runtime.agentControlServer.localLoopbackToken
            )
            try await sender.approvePlan(sessionId: id)
            WorkspaceFeedback.success("Plan approved — running")
        } catch {
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

}
