import SwiftUI
import AppKit
import ClawdmeterShared

struct CenterThread: View {
    let session: AgentSession
    let isReadOnly: Bool
    @ObservedObject var model: SessionsModel
    let catalog: ModelCatalog
    @ObservedObject var workbenchState: WorkbenchState
    @ObservedObject var presentationStore: SessionPresentationStore
    let density: TranscriptDensity
    let onDensityChange: (TranscriptDensity) -> Void
    let onModeSwitch: (SessionMode) -> Void
    let onPreviewRequested: () -> Void

    /// Sourced from `SessionsModel.composerStore(for:)` (a per-session cache)
    /// rather than a locally-constructed `@StateObject`. This is what lets the
    /// center thread keep SwiftUI identity across Code-tab switches (no
    /// `.id(session.id)` teardown): on each switch `init` re-points this
    /// observed wrapper at the newly-selected session's cached store, so the
    /// draft + chip selections of every open tab are preserved instead of
    /// being rebuilt from scratch. Mirrors the existing `prMirror` pattern.
    @ObservedObject private var composerStore: ComposerStore
    /// PR mirror for the open session — drives the header branch chip's
    /// color (open/merged/closed). Synthetic read-only sessions get a
    /// mirror too; it just never resolves a PR URL.
    @ObservedObject private var prMirror: PRMirror
    /// Observed so the permission-mode chip re-renders when the user
    /// flips bypass or accept-edits from another surface. AutopilotState
    /// is a singleton without ObservableObject conformance; all autopilot
    /// flips go through `PermissionModeStore.setBypass` below so this one
    /// observer is enough.
    @ObservedObject private var permissionModeStore = PermissionModeStore.shared
    @State private var showingScheduler = false
    @State private var showingTerminalOverlay = false
    @State private var showingAutopilotConfirm = false
    @State private var isDispatchingQueuedSend = false
    @State private var dispatchedQueuedTurnForCurrentIdle = false
    @State private var checkpointStatusText: String?
    @State private var restorePlan: CheckpointRestorePlan?
    @State private var isPreparingCheckpointRestore = false
    @State private var isRestoringCheckpoint = false
    /// Captured target mode for the bypass-mode trust-grant confirm sheet.
    /// When the user picks `.bypass` from the chip we stash it here and
    /// surface the existing autopilot confirm sheet, then commit on
    /// approval.
    @State private var pendingBypassMode = false
    /// Tab-switch perf guard: CenterThread now keeps SwiftUI identity across
    /// Code-tab switches, so re-pointing the observed `composerStore` to a
    /// different session transitions `composerStore.modelId`/`.effort` from the
    /// previous session's value to the new one's — which would fire the chip
    /// `.onChange` handlers below and spuriously respawn the agent on every
    /// switch. We track the session id each chip handler last observed and skip
    /// the change when it was caused by a session switch (re-point) rather than
    /// a genuine in-session user edit. Seeded in `.onAppear`.
    @State private var lastModelChipSessionId: UUID?
    @State private var lastEffortChipSessionId: UUID?

    init(
        session: AgentSession,
        isReadOnly: Bool,
        model: SessionsModel,
        catalog: ModelCatalog,
        workbenchState: WorkbenchState,
        presentationStore: SessionPresentationStore,
        density: TranscriptDensity,
        onDensityChange: @escaping (TranscriptDensity) -> Void,
        onModeSwitch: @escaping (SessionMode) -> Void,
        onPreviewRequested: @escaping () -> Void = {}
    ) {
        self.session = session
        self.isReadOnly = isReadOnly
        self.model = model
        self.catalog = catalog
        self.workbenchState = workbenchState
        self.presentationStore = presentationStore
        self.density = density
        self.onDensityChange = onDensityChange
        self.onModeSwitch = onModeSwitch
        self.onPreviewRequested = onPreviewRequested
        _composerStore = ObservedObject(wrappedValue: model.composerStore(for: session, catalog: catalog))
        _prMirror = ObservedObject(wrappedValue: model.prMirror(for: session))
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(spacing: 0) {
            if let workspaceKey = WorkspaceKey.of(session) {
                WorkspaceTabStrip(
                    model: model,
                    workspaceKey: workspaceKey,
                    activeSession: session,
                    activeSessionId: session.id,
                    draftTabs: model.workspaceDraftTabs(in: workspaceKey),
                    activeDraftTabId: model.draftWorkspaceTab?.id,
                    terminalTabs: model.workspaceTerminalTabs(in: workspaceKey),
                    activeTerminalTabId: nil,
                    documentTabs: model.workspaceDocumentTabs(in: workspaceKey),
                    activeDocumentTabId: model.selectedWorkspaceDocumentTab?.id,
                    terminalAvailable: model.canOpenWorkspaceTerminalTab(from: session),
                    onNewChat: {
                        model.openDraftWorkspaceTab(from: session, defaults: workspaceDraftDefaults)
                    },
                    onNewTerminal: {
                        Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
                    },
                    onSelectTerminal: { model.selectWorkspaceTerminalTab($0) },
                    onCloseTerminal: { terminalTab in
                        Task { await model.closeWorkspaceTerminalTab(terminalTab) }
                    },
                    onSelectDocument: { model.selectWorkspaceDocumentTab($0) },
                    onCloseDocument: { model.closeWorkspaceDocumentTab($0) }
                )
            }
            header
            Divider()
            chatPane
        }
        .onAppear {
            applyPendingFirstSendRecovery()
            // Seed the chip-handler session trackers to the mounted session so
            // the first genuine in-session edit isn't mistaken for a re-point.
            lastModelChipSessionId = session.id
            lastEffortChipSessionId = session.id
        }
        .onChange(of: model.pendingFirstSendRecoveryVersion) { _, _ in
            applyPendingFirstSendRecovery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerSetPermissionMode)) { note in
            guard !isReadOnly,
                  let raw = note.userInfo?["mode"] as? String,
                  let mode = PermissionMode(rawValue: raw),
                  ComposerInputCore.availablePermissionModes(for: session.agent).contains(mode)
            else { return }
            Task { await changePermissionMode(to: mode) }
        }
        .sheet(isPresented: $showingScheduler) {
            FollowUpSchedulerSheet(session: session, registry: model.registry)
        }
        .sheet(isPresented: $showingTerminalOverlay) {
            terminalOverlay
        }
        .sheet(isPresented: $showingAutopilotConfirm) {
            autopilotConfirm
        }
        .sheet(item: $restorePlan) { plan in
            CheckpointRestoreSheet(
                plan: plan,
                isRestoring: isRestoringCheckpoint,
                onCancel: { restorePlan = nil },
                onRestore: { Task { await restoreCheckpoint(plan) } }
            )
        }
        .onChange(of: session.status) { _, newValue in
            if newValue == .running {
                dispatchedQueuedTurnForCurrentIdle = false
            }
        }
        .onChange(of: currentTurnState) { _, newValue in
            if newValue == .streaming {
                dispatchedQueuedTurnForCurrentIdle = false
            }
        }
        .task(id: queueDrainKey) {
            await drainQueuedSendsIfPossible()
        }
        // Tab-switch perf: the center thread now keeps SwiftUI identity across
        // Code-tab switches (the `.id(session.id)` that used to force a full
        // teardown was removed so switching is cheap). Identity-scoped @State
        // therefore survives a switch and would leak the previously-open
        // session's transient UI into the newly-selected one, so reset it by
        // hand here. The composer/transcript/prMirror are already keyed per
        // session via caches, so they don't need this.
        .onChange(of: session.id) { _, _ in
            showingScheduler = false
            showingTerminalOverlay = false
            showingAutopilotConfirm = false
            pendingBypassMode = false
            restorePlan = nil
            isPreparingCheckpointRestore = false
            isRestoringCheckpoint = false
            checkpointStatusText = nil
            isDispatchingQueuedSend = false
            dispatchedQueuedTurnForCurrentIdle = false
            // The newly-selected session may have a queued first send waiting
            // on readiness; onAppear won't fire again (identity is stable), so
            // re-run the recovery hook explicitly.
            applyPendingFirstSendRecovery()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                // v0.5.4: user-supplied customName takes precedence
                // over the session's goal in the chat header.
                Text(headerLabel(for: session))
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                    .accessibilityIdentifier("code.center.header.title")
                HStack(spacing: 6) {
                    Text(sessionConfigurationSummary)
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                        .accessibilityIdentifier("code.center.header.configuration")
                    if let checkpointStatusText {
                        Text("· \(checkpointStatusText)")
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                            .accessibilityIdentifier("code.header.checkpoint-status")
                    }
                }
            }
            Spacer()
            if let branch = branchLabel {
                TahoePill(tone: .chip) {
                    HStack(spacing: 5) {
                        Image(systemName: prBranchIcon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(branch)
                            .font(TahoeFont.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(prBranchColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                }
                .frame(maxWidth: 190)
                .help(branchTooltip)
            }
            // v0.29.25: header `⚡ ask` permission-mode pill removed per
            // user feedback. The composer's `PermissionModeChip` already
            // sits to the right of the model+effort chip and exposes the
            // same `ask / accept edits / plan / bypass` Menu plus the
            // ⇧⌘1-4 shortcuts — so the header copy was just a duplicate
            // floating to the right of the branch chip. Keeping the
            // composer pill keeps mode-selection adjacent to where the
            // user is about to type, which is the better mental model.
            // Read-only transcripts already disable composer actions, so a
            // second header badge would duplicate the same state.
            if isReadOnly {
                EmptyView()
            } else {
                Menu {
                    ForEach(TranscriptDensity.allCases, id: \.self) { option in
                        Button {
                            onDensityChange(option)
                        } label: {
                            if option == density {
                                Label(densityLabel(option), systemImage: "checkmark")
                            } else {
                                Text(densityLabel(option))
                            }
                        }
                        .accessibilityIdentifier("code.header.density.\(option.rawValue)")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .help("Transcript density")
                .accessibilityLabel("Transcript density")
                .accessibilityIdentifier("code.header.density")
                .accessibilityValue(density.rawValue)
                .overlay(alignment: .topLeading) {
                    Text(density.rawValue)
                        .font(.system(size: 1))
                        .frame(width: 1, height: 1)
                        .opacity(0.001)
                        .accessibilityLabel("Selected density \(densityLabel(density))")
                        .accessibilityIdentifier("code.header.density.selected.\(density.rawValue)")
                }
                Menu {
                    Button("Open terminal tab (⇧⌘T)") {
                        Task { await model.openOrCreateWorkspaceTerminalTab(from: session) }
                    }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                        .disabled(!model.canOpenWorkspaceTerminalTab(from: session))
                        .accessibilityIdentifier("code.header.more-actions.terminal")
                    Button("Schedule follow-up…", systemImage: "clock") {
                        showingScheduler = true
                    }
                    .accessibilityIdentifier("code.header.more-actions.schedule-follow-up")
                    Button("Create checkpoint", systemImage: "bookmark") {
                        Task { await createCheckpoint() }
                    }
                    .accessibilityIdentifier("code.header.more-actions.create-checkpoint")
                    if let latest = workbenchState.latestCheckpoint(for: session.id) {
                        Button("Restore latest checkpoint…", systemImage: "arrow.uturn.backward") {
                            Task { await prepareCheckpointRestore(latest) }
                        }
                        .accessibilityIdentifier("code.header.more-actions.restore-latest-checkpoint")
                    }
                    Button("Pop out window", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                        NotificationCenter.default.post(
                            name: .popOutSession,
                            object: nil,
                            userInfo: ["sessionId": session.id]
                        )
                    }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .accessibilityIdentifier("code.header.more-actions.pop-out")
                    Divider()
                    if session.archivedAt == nil {
                        Button("Archive") {
                            Task { @MainActor in
                                try? await model.registry.archive(id: session.id)
                            }
                            postArchiveUndoToast(for: session)
                            workbenchState.clearSessionState(sessionId: session.id)
                            AttachmentStaging.cleanup(sessionId: session.id)
                            if let wt = session.worktreePath {
                                AttachmentStaging.cleanupWorktree(at: wt, sessionId: session.id)
                            }
                        }
                        .accessibilityIdentifier("code.header.more-actions.archive")
                    }
                    Button("End session", role: .destructive) {
                        Task {
                            await model.endSession(id: session.id)
                            workbenchState.clearSessionState(sessionId: session.id)
                            AttachmentStaging.cleanup(sessionId: session.id)
                            if let wt = session.worktreePath {
                                AttachmentStaging.cleanupWorktree(at: wt, sessionId: session.id)
                            }
                        }
                    }
                    .accessibilityIdentifier("code.header.more-actions.end-session")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .accessibilityLabel("More actions")
                .accessibilityIdentifier("code.header.more-actions")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("code.center.header")
        .accessibilityValue(headerAccessibilityValue)
        .overlay(alignment: .topLeading) {
            Text(headerAccessibilityValue)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headerAccessibilityValue)
                .accessibilityIdentifier("code.center.header.state")
                .accessibilityValue(headerAccessibilityValue)
        }
    }

    // v0.29.25: `permissionModeLabel` + `headerPermissionModes` deleted
    // alongside the redundant header pill. Composer's `PermissionModeChip`
    // owns mode-selection now.

    private var headerAccessibilityValue: String {
        [
            session.id.uuidString,
            headerLabel(for: session),
            session.agent.rawValue,
            session.model ?? "",
            sessionConfigurationSummary
        ].joined(separator: " ")
    }

    private var workspaceDraftDefaults: ComposerStore.ChipDefaults {
        ComposerStore.ChipDefaults(
            agent: session.agent,
            modelId: session.model ?? Self.effectiveModelId(for: session, catalog: catalog),
            effort: session.effort ?? Self.effectiveEffort(
                for: session,
                modelId: session.model ?? Self.effectiveModelId(for: session, catalog: catalog),
                catalog: catalog
            ),
            mode: session.mode,
            planMode: false
        )
    }

    private func densityLabel(_ density: TranscriptDensity) -> String {
        switch density {
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }

    /// v0.5.4 header-label helper. User-set `customName` wins over the
    /// session's goal, with the repo name as the final fallback. Mirrors
    /// `AgentSession.displayLabel` but keeps the existing "goal" tier
    /// because the chat header has historically preferred the user-typed
    /// prompt as a label.
    private func headerLabel(for session: AgentSession) -> String {
        if let custom = session.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let goal = session.goal, !goal.isEmpty { return goal }
        return session.repoDisplayName
    }

    @ViewBuilder
    private var terminalOverlay: some View {
        TahoeGlass(radius: 8, tone: .raised, shadow: .prominent) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(t.accent)
                        .frame(width: 26, height: 26)
                        .background(t.accentAlpha(t.dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raw terminal")
                            .font(TahoeFont.body(12.5, weight: .semibold))
                            .foregroundStyle(t.fg)
                        Text(headerLabel(for: session))
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { showingTerminalOverlay = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .foregroundStyle(t.fg3)
                    .background(t.surfaceSolid2.opacity(0.70), in: RoundedRectangle(cornerRadius: 8))
                    .keyboardShortcut(.cancelAction)
                    .help("Close terminal")
                }
                .padding(12)
                TahoeHairline()
                if let runtime = AppDelegate.runtime,
                   let port = runtime.agentControlServer.boundWsPort {
                    TerminalTabContainer(
                        session: session,
                        model: model,
                        wsPort: Int(port),
                        token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? "")
                    )
                } else {
                    ContentUnavailableView(
                        "Daemon offline",
                        systemImage: "wifi.exclamationmark",
                        description: Text("Restart Clawdmeter to reconnect.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    @ViewBuilder
    private var autopilotConfirm: some View {
        // The sheet is only invoked when the user picks `.bypass` from the
        // PermissionModeChip — we're always asking to ENABLE bypass here.
        // Disabling is a safe direct setPermissionMode call (no sheet).
        // v0.8: chat sessions have no repoKey and bypass-mode doesn't
        // apply; `?? ""` evaluates as untrusted, which is the right
        // default for any chat session that somehow reaches this sheet.
        let repoTrusted = AutopilotState.shared.isRepoTrusted(session.repoKey ?? "")
        let needsTrustGrant = !repoTrusted
        let confirmBody = autopilotConfirmBody(willEnable: true, needsTrustGrant: needsTrustGrant)
        VStack(alignment: .leading, spacing: 12) {
            Label(
                needsTrustGrant ? "Trust this repo for bypass mode?" : "Enable bypass mode?",
                systemImage: needsTrustGrant ? "lock.shield.fill" : "bolt.fill"
            )
            .font(.system(size: 14, weight: .semibold))
            .accessibilityIdentifier("code.permission.bypass.title")
            BypassPermissionWarningText(text: confirmBody)
                .frame(width: 420, alignment: .leading)
            if needsTrustGrant, let repoKey = session.repoKey {
                Text("Repo: \((repoKey as NSString).lastPathComponent)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityIdentifier("code.permission.bypass.repo")
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    showingAutopilotConfirm = false
                    pendingBypassMode = false
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("code.permission.bypass.cancel")
                Button(autopilotConfirmCTA(willEnable: true, needsTrustGrant: needsTrustGrant)) {
                    showingAutopilotConfirm = false
                    pendingBypassMode = false
                    if needsTrustGrant, let repoKey = session.repoKey {
                        AutopilotState.shared.trustRepo(repoKey)
                    }
                    Task { await model.setPermissionMode(sessionId: session.id, to: .bypass) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
                .accessibilityIdentifier("code.permission.bypass.confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("code.permission.bypass-sheet")
    }

    private func autopilotConfirmBody(willEnable: Bool, needsTrustGrant: Bool) -> String {
        if needsTrustGrant {
            return "Bypass mode respawns the CLI with --dangerously-skip-permissions (Claude) or --dangerously-bypass-approvals-and-sandbox (Codex). It skips every tool-call approval prompt in this session, and any future session in this repo can be flipped to bypass with one click. Grant trust only if you intend to give agents free rein in this repo."
        }
        return "This will interrupt the current turn to respawn the CLI with the dangerously-* flags. The repo is already on your trust list."
    }

    private func autopilotConfirmCTA(willEnable: Bool, needsTrustGrant: Bool) -> String {
        if needsTrustGrant { return "Trust repo + enable bypass" }
        return "Enable + respawn"
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            messageList
            if !workbenchState.queuedSends(for: session.id).isEmpty {
                Divider()
                queuedSendsPanel
            }
            if let latest = workbenchState.latestCheckpoint(for: session.id) {
                Divider()
                checkpointStrip(latest)
            }
            // Setup Trail — animated, non-blocking provisioning ribbon for an
            // optimistic "+" session. Sits just above the composer (which stays
            // usable the whole time) and confirms each step with a fact.
            if #available(macOS 14, *), let progress = model.provisioningProgress[session.id] {
                ProvisioningTrailView(progress: progress, agent: session.agent)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            composerArea
        }
    }

    private var shouldShowInlinePlanHalo: Bool {
        guard let plan = session.planText?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !plan.isEmpty
    }

    private func primePlanRefinement() {
        if composerStore.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerStore.text = "Refine the plan above: "
        }
    }

    private var queuedSendsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Queued follow-ups", systemImage: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    workbenchState.clearQueuedSends(sessionId: session.id)
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("code.queue.clear")
            }
            ForEach(workbenchState.queuedSends(for: session.id)) { draft in
                queuedDraftRow(draft)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.035))
        .accessibilityIdentifier("code.queue.panel")
    }

    private func queuedDraftRow(_ draft: QueuedWorkbenchSend) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(
                "Queued prompt",
                text: Binding(
                    get: { draft.text },
                    set: { workbenchState.updateQueuedSend(id: draft.id, text: $0) }
                ),
                axis: .vertical
            )
            .font(.system(size: 11))
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("code.queue.prompt")
            if !draft.attachmentPaths.isEmpty {
                Label("\(draft.attachmentPaths.count)", systemImage: "paperclip")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .help(draft.attachmentPaths.joined(separator: "\n"))
            }
            if !draft.browserComments.isEmpty {
                Label("\(draft.browserComments.count)", systemImage: "safari")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SessionsV2Theme.accent)
                    .padding(.top, 6)
                    .help(draft.browserComments.map(\.chipLabel).joined(separator: "\n"))
            }
            Button {
                Task { await dispatchQueuedDraft(draft, manual: true) }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(turnIsStreaming || isDispatchingQueuedSend)
            .help(turnIsStreaming ? "Dispatches when the current turn finishes" : "Send queued prompt now")
            .padding(.top, 6)
            .accessibilityIdentifier("code.queue.send")
            Button(role: .destructive) {
                workbenchState.removeQueuedSend(id: draft.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(PressableButtonStyle())
            .help("Delete queued follow-up")
            .padding(.top, 6)
            .accessibilityIdentifier("code.queue.delete")
        }
    }

    private func checkpointStrip(_ checkpoint: CheckpointStateSnapshot) -> some View {
        HStack(spacing: 8) {
            Label("Checkpoint", systemImage: "bookmark.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            if let summary = checkpoint.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await prepareCheckpointRestore(checkpoint) }
            } label: {
                Text("Restore")
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(PressableButtonStyle())
            .help("Preview and restore this checkpoint")
            .accessibilityIdentifier("code.checkpoint-strip.restore")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.03))
        .accessibilityIdentifier("code.checkpoint-strip")
    }

    @ViewBuilder
    private var messageList: some View {
        if let store = model.chatStore(for: session) {
            ChatThreadScroll(
                store: store,
                session: session,
                model: model,
                presentationStore: presentationStore,
                density: density,
                showPlanHalo: shouldShowInlinePlanHalo,
                canApprovePlan: !isReadOnly,
                // v0.29.25: thread the right-pane visibility flag in so
                // ChatThreadScroll can re-anchor to the bottom sentinel
                // after the workspace width changes. Without this, the
                // scroll view kept its absolute offset and the user
                // landed mid-history every time they toggled the pane.
                isReviewPaneVisible: workbenchState.showingReviewPane,
                onPlanRefine: primePlanRefinement,
                onPlanApprove: {
                    Task {
                        guard await createLifecycleCheckpoint(summary: "Before plan approval") else { return }
                        await model.approvePlan(id: session.id)
                    }
                },
                onPreviewTurn: onPreviewRequested
            )
                .id(session.id)
                .onAppear {
                    // T8 wiring: push session.planText into the store so
                    // the staging actor's precompute can mark steps
                    // referenced from the plan as found.
                    store.setPlanText(session.planText)
                }
                .onChange(of: session.planText) { _, newValue in
                    store.setPlanText(newValue)
                }
        } else {
            ConnectingTranscriptState(session: session)
        }
    }

    private var composerArea: some View {
        ComposerInputCore(
            store: composerStore,
            presentationStore: presentationStore,
            catalog: catalog,
            agentForModelPicker: model.isProvisioning(session.id) ? composerStore.agent : session.agent,
            modelSupportsEffort: modelSupportsEffort,
            onSend: { Task { await performBoundSend() } },
            onQueue: { queueCurrentDraft() },
            onInterrupt: { Task { await performInterrupt() } },
            onToggleAutopilot: { showingAutopilotConfirm = true },
            onChangePermissionMode: { newMode in
                Task { await changePermissionMode(to: newMode) }
            },
            onSelectModelConfiguration: model.isProvisioning(session.id) ? { agent, modelId, effort in
                model.configureProvisionalLaunch(
                    sessionId: session.id,
                    agent: agent,
                    modelId: modelId,
                    effort: effort
                )
            } : nil,
            permissionMode: PermissionModeStore.shared.currentMode(for: session),
            onApprovePlan: {
                Task {
                    guard await createLifecycleCheckpoint(summary: "Before plan approval") else { return }
                    await model.approvePlan(id: session.id)
                }
            },
            showApprovePlan: session.planText != nil,
            sessionIsRunning: turnIsStreaming && !composerStore.isSending,
            isReadOnly: isReadOnly,
            mentionSourceProvider: {
                let openSessions = model.registry.sessions.filter { $0.id != session.id && $0.archivedAt == nil }
                let store = model.chatStore(for: session)
                let sourceEntries = store?.snapshot.sourceEntries ?? []
                return (openSessions, sourceEntries)
            },
            usageStatus: usageStatusInfo,
            projectSkillsRoot: URL(fileURLWithPath: session.effectiveCwd).appendingPathComponent(".claude/skills", isDirectory: true),
            chatStore: model.chatStore(for: session),
            onRetryPending: { Task { await performPendingRetry() } }
        )
        .onChange(of: composerStore.modelId) { _, new in
            // Skip the value change caused by re-pointing the observed composer
            // store to a different session on a tab switch (not a user edit) —
            // otherwise switching tabs would respawn the agent. See
            // lastModelChipSessionId.
            let isRepoint = lastModelChipSessionId != session.id
            lastModelChipSessionId = session.id
            // v27: harness Code sessions (codex/cursor/gemini) have no
            // mid-session reconfigure in v1 — the AgentDriver spawns with the
            // agent's defaults, so the chip is cosmetic. Skip the PTY-only
            // SessionConfigChanger swap so it doesn't fail with a toast.
            guard !isRepoint, !isReadOnly, let new else { return }
            if model.isProvisioning(session.id) {
                let pendingAgent = catalog.entry(forId: new)?.provider ?? composerStore.agent
                model.configureProvisionalLaunch(
                    sessionId: session.id,
                    agent: pendingAgent,
                    modelId: new,
                    effort: composerStore.effort
                )
                return
            }
            guard !isHarnessDriven, new != session.model else { return }
            if let entry = catalog.entry(forId: new) {
                Task { await model.switchModel(sessionId: session.id, to: entry, effort: composerStore.effort) }
            }
        }
        .onChange(of: composerStore.effort) { _, new in
            let isRepoint = lastEffortChipSessionId != session.id
            lastEffortChipSessionId = session.id
            guard !isRepoint, !isReadOnly, let new else { return }
            if model.isProvisioning(session.id),
               let pendingModelId = composerStore.modelId ?? effectiveModelId {
                let pendingAgent = catalog.entry(forId: pendingModelId)?.provider ?? composerStore.agent
                model.configureProvisionalLaunch(
                    sessionId: session.id,
                    agent: pendingAgent,
                    modelId: pendingModelId,
                    effort: new
                )
                return
            }
            guard !isHarnessDriven, new != session.effort else { return }
            Task { await model.switchEffort(sessionId: session.id, to: new) }
        }
        .onChange(of: composerStore.mode) { _, new in
            guard !isReadOnly, !isHarnessDriven, new != session.mode else { return }
            onModeSwitch(new)
        }
    }

    // MARK: - Send / interrupt / autopilot via daemon (P0 fixes)

    private var queueDrainKey: String {
        "\(session.id.uuidString):\(currentTurnState.rawValue):\(model.isProvisioning(session.id)):\(workbenchState.queuedSendCount(for: session.id))"
    }

    private func queueCurrentDraft() {
        guard composerStore.canSend else { return }
        let draft = QueuedWorkbenchSend(
            sessionId: session.id,
            payload: composerStore.draftPayload()
        )
        workbenchState.queueSend(draft)
        composerStore.clearAfterSend()
    }

    private func drainQueuedSendsIfPossible() async {
        guard !model.isProvisioning(session.id),
              !turnIsStreaming,
              !isDispatchingQueuedSend,
              !dispatchedQueuedTurnForCurrentIdle,
              let draft = workbenchState.nextQueuedSend(for: session.id),
              draft.dispatchPolicy == .autoCurrentProcess
        else { return }
        dispatchedQueuedTurnForCurrentIdle = true
        await dispatchQueuedDraft(draft, manual: false)
    }

    private func dispatchQueuedDraft(_ draft: QueuedWorkbenchSend, manual: Bool) async {
        guard !turnIsStreaming else { return }
        guard draft.payload.hasContent else {
            workbenchState.removeQueuedSend(id: draft.id)
            return
        }
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else {
            composerStore.endSend(error: .offline)
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
            return
        }
        isDispatchingQueuedSend = true
        composerStore.beginSend()
        defer {
            isDispatchingQueuedSend = false
        }

        let target = session
        var stagedPaths: [URL] = []
        if !draft.attachmentPaths.isEmpty {
            guard let dir = AttachmentStaging.stagingDir(for: target) else {
                composerStore.endSend(error: .daemonError(message: "Couldn't create attachment staging directory."))
                if !manual { dispatchedQueuedTurnForCurrentIdle = false }
                return
            }
            for path in draft.attachmentPaths {
                do {
                    let staged = try AttachmentStaging.stage(
                        source: URL(fileURLWithPath: path),
                        into: dir,
                        attachmentId: UUID()
                    )
                    stagedPaths.append(staged)
                } catch {
                    composerStore.endSend(error: .daemonError(message: "Couldn't stage queued attachment: \(error.localizedDescription)"))
                    if !manual { dispatchedQueuedTurnForCurrentIdle = false }
                    return
                }
            }
        }

        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        let body = QueuedPromptRenderer.render(payload: draft.payload, attachmentPaths: stagedPaths)
        do {
            guard await createLifecycleCheckpoint(summary: "Before queued prompt") else {
                composerStore.endSend(error: .daemonError(message: "Safety checkpoint failed. Prompt was not sent."))
                if !manual { dispatchedQueuedTurnForCurrentIdle = false }
                return
            }
            try await sender.send(
                sessionId: target.id,
                body: body,
                asFollowUp: true,
                origin: .userComposer,
                idempotencyKey: "queued-send:\(draft.id.uuidString)",
                clientIntentId: draft.id.uuidString
            )
            workbenchState.removeQueuedSend(id: draft.id)
            composerStore.endSend()
        } catch MacComposerSender.Error.http(let status, let retry, _) {
            switch status {
            case 401: composerStore.endSend(error: .unauthorized)
            case 404: composerStore.endSend(error: .sessionGone)
            case 429: composerStore.endSend(error: .rateLimited(retryAfter: retry))
            default: composerStore.endSend(error: .daemonError(message: "HTTP \(status)"))
            }
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
        } catch MacComposerSender.Error.transport(let message) {
            composerStore.endSend(error: .daemonError(message: message))
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
        } catch {
            composerStore.endSend(error: .daemonError(message: error.localizedDescription))
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
        }
    }

    private func createCheckpoint() async {
        let service = CheckpointService()
        do {
            let checkpoint = try await service.createCheckpoint(
                session: session,
                summary: "Manual checkpoint"
            )
            workbenchState.recordCheckpoint(checkpoint)
            checkpointStatusText = "checkpoint saved"
        } catch {
            checkpointStatusText = error.localizedDescription
        }
    }

    private func prepareCheckpointRestore(_ checkpoint: CheckpointStateSnapshot) async {
        let service = CheckpointService()
        isPreparingCheckpointRestore = true
        checkpointStatusText = "preparing restore preview"
        defer { isPreparingCheckpointRestore = false }
        do {
            let plan = try await service.prepareRestore(checkpoint, session: session)
            workbenchState.recordCheckpoint(plan.safety)
            restorePlan = plan
            checkpointStatusText = plan.isBlocked ? "restore blocked" : "restore preview ready"
        } catch {
            checkpointStatusText = error.localizedDescription
        }
    }

    private func restoreCheckpoint(_ plan: CheckpointRestorePlan) async {
        let service = CheckpointService()
        isRestoringCheckpoint = true
        defer { isRestoringCheckpoint = false }
        do {
            try await service.restore(plan, in: session.effectiveCwd)
            restorePlan = nil
            checkpointStatusText = "checkpoint restored"
        } catch {
            checkpointStatusText = error.localizedDescription
        }
    }

    private func createLifecycleCheckpoint(summary: String, for targetSession: AgentSession? = nil) async -> Bool {
        let service = CheckpointService()
        let checkpointSession = targetSession ?? session
        do {
            let checkpoint = try await service.createCheckpoint(session: checkpointSession, summary: summary)
            workbenchState.recordCheckpoint(checkpoint)
            checkpointStatusText = "checkpoint saved"
            return true
        } catch {
            checkpointStatusText = "checkpoint failed: \(error.localizedDescription)"
            return false
        }
    }

    private func performBoundSend() async {
        composerStore.beginSend()
        let draftText = composerStore.text
        let draftAttachments = composerStore.attachments
        let draftBrowserComments = composerStore.browserComments
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else {
            composerStore.endSend(error: .offline)
            // A13: optimistic pending becomes "queued offline" so the user
            // can see their message is staged for replay when the daemon
            // returns. Retry triggers another performBoundSend() pass.
            model.chatStore(for: session)?.markPendingQueuedOffline(
                error: "Daemon offline — tap retry when it returns."
            )
            return
        }
        let target = session
        let promotedReadOnlyTarget: AgentSession? = nil

        // Optimistic "+" session whose worktree/agent are still provisioning in
        // the background: there's no pane yet, so don't POST (it'd 503). Queue
        // the prompt so it auto-sends the instant provisioning completes, and
        // clear the composer. (Common case: by the time the user finishes typing
        // a prompt, provisioning is already done and this branch is skipped.)
        if model.isProvisioning(target.id) {
            model.queueFirstSendRecovery(
                sessionId: target.id,
                text: draftText,
                attachments: draftAttachments,
                browserComments: draftBrowserComments,
                error: .offline,
                autoSendWhenReady: true
            )
            composerStore.endSend()
            model.chatStore(for: target)?.markPendingQueuedOffline(
                error: "Setting up the worktree — your prompt sends automatically when ready."
            )
            return
        }

        guard await createLifecycleCheckpoint(summary: "Before prompt", for: target) else {
            finishBoundSendWithError(
                .daemonError(message: "Safety checkpoint failed. Prompt was not sent."),
                promotedTarget: promotedReadOnlyTarget,
                draftText: draftText,
                draftAttachments: draftAttachments,
                draftBrowserComments: draftBrowserComments
            )
            return
        }

        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        let chatStore = model.chatStore(for: target)
        let asFollowUp = Self.shouldSendPromptAsFollowUp(snapshot: chatStore?.snapshot)
        var stagedPaths: [URL] = []
        if let dir = AttachmentStaging.stagingDir(for: target) {
            for att in composerStore.attachments {
                do {
                    let staged = try AttachmentStaging.stage(source: att.sourceURL, into: dir, attachmentId: att.id)
                    stagedPaths.append(staged)
                } catch {
                    finishBoundSendWithError(
                        .daemonError(message: "Couldn't stage \(att.displayName): \(error.localizedDescription)"),
                        promotedTarget: promotedReadOnlyTarget,
                        draftText: draftText,
                        draftAttachments: draftAttachments,
                        draftBrowserComments: draftBrowserComments
                    )
                    return
                }
            }
        }
        let body = composerStore.renderPromptBody(attachmentPaths: stagedPaths)
        do {
            let intentId = UUID().uuidString
            try await sender.send(
                sessionId: target.id,
                body: body,
                asFollowUp: asFollowUp,
                origin: asFollowUp ? .userComposer : .userComposerFirstTurn,
                idempotencyKey: "composer-send:\(target.id.uuidString):\(intentId)",
                clientIntentId: intentId
            )
            composerStore.endSend()
            // A13: daemon accepted the send. The auto-reconcile in
            // SessionChatStore clears the pending bubble once the real
            // user line lands in the JSONL — typically within a few
            // hundred ms. If the JSONL tail is slow, leaving the bubble
            // up as "Sending…" is still correct UX (the message IS in
            // flight). We do NOT clear it here proactively because the
            // ack-vs-JSONL race could flicker the bubble out and back in.
            // A13: drain any messages that piled up while the daemon was
            // offline — now that one send succeeded, the daemon is reachable.
            // Offline queued messages stay visible for explicit retry. A
            // successful foreground send must not silently replay older bodies.
        } catch MacComposerSender.Error.http(let status, let retry, _) {
            finishBoundSendWithError(
                sendError(forHTTPStatus: status, retryAfter: retry),
                promotedTarget: promotedReadOnlyTarget,
                draftText: draftText,
                draftAttachments: draftAttachments,
                draftBrowserComments: draftBrowserComments
            )
        } catch MacComposerSender.Error.transport(let m) {
            finishBoundSendWithError(
                .daemonError(message: m),
                promotedTarget: promotedReadOnlyTarget,
                draftText: draftText,
                draftAttachments: draftAttachments,
                draftBrowserComments: draftBrowserComments
            )
        } catch {
            finishBoundSendWithError(
                .daemonError(message: error.localizedDescription),
                promotedTarget: promotedReadOnlyTarget,
                draftText: draftText,
                draftAttachments: draftAttachments,
                draftBrowserComments: draftBrowserComments
            )
        }
    }

    /// A13 — Retry handler for the failed/queued pending bubble in the
    /// composer. Flips the chat store's pending slot back to `.sending`
    /// (no flicker) and re-runs the regular send path against the
    /// existing pending body. When the bubble is in `.failed` we don't
    /// have the composer text anymore (the user already cleared it on
    /// the first send) — but `performBoundSend` reads from
    /// `composerStore.text`. We re-seed the composer with the pending
    /// body so the existing pipeline can replay it, then restore the
    /// user's in-flight draft if they typed something new during the
    /// failure window.
    @MainActor
    private func performPendingRetry() async {
        guard let chatStore = model.chatStore(for: session),
              let pending = chatStore.pendingMessage,
              pending.canRetry
        else { return }

        // Preserve any new draft the user typed since the failure.
        let liveDraft = composerStore.text
        let liveDraftAttachments = composerStore.attachments
        let liveDraftBrowserComments = composerStore.browserComments
        let liveDraftPayload = ComposerDraftPayload(
            text: liveDraft,
            attachmentPaths: liveDraftAttachments.map(\.sourceURL.path),
            browserComments: liveDraftBrowserComments
        )
        let liveDraftMatchesPending = liveDraftPayload
            .render()
            .trimmingCharacters(in: .whitespacesAndNewlines) == pending.body.trimmingCharacters(in: .whitespacesAndNewlines)

        composerStore.text = pending.body
        composerStore.clearBrowserComments()
        chatStore.markPendingRetrying()
        await performBoundSend()

        // Restore the user's in-flight draft if they typed something new
        // during the failure window. `performBoundSend` clears the
        // composer on success, so we only restore when the slot was
        // already populated by something other than the pending body.
        let trimmedLive = liveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveDraftMatchesPending && (!trimmedLive.isEmpty || !liveDraftBrowserComments.isEmpty) {
            composerStore.restoreDraft(
                text: liveDraft,
                attachments: liveDraftAttachments,
                browserComments: liveDraftBrowserComments
            )
        }
    }

    /// A13 — drain queued pending messages onto the daemon. Best-effort:
    /// each queued body is sent in FIFO order; on the first failure the
    /// failing entry + every un-drained entry behind it are re-queued
    /// at the head so the next successful send picks up where this one
    /// left off. Runs after a successful primary send (signal that the
    /// daemon is reachable again).
    @MainActor
    private func drainOfflineQueueIfAny(target: AgentSession, port: Int) async {
        guard let chatStore = model.chatStore(for: session) else { return }
        let queued = chatStore.dequeueOfflineQueue()
        guard !queued.isEmpty else { return }
        let sender = MacComposerSender(port: port, token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        for (index, entry) in queued.enumerated() {
            // Bodies in the offline queue were captured pre-trim, so re-add the
            // terminal newline the prompt submitter expects.
            let body = entry.body.isEmpty ? "\n" : entry.body + "\n"
            do {
                try await sender.send(sessionId: target.id, body: body, asFollowUp: true)
            } catch {
                // Failed to drain — re-queue the failing entry + every
                // remaining entry behind it so we don't lose them on the
                // next successful primary send. The pending slot
                // mutation here describes the failure on the *current*
                // pending bubble (which is the user-visible context for
                // the drain), but the actual un-drained bodies are
                // preserved in `queuedPendingMessages`.
                let remaining = Array(queued[index..<queued.count])
                chatStore.requeueOfflinePending(remaining)
                chatStore.markPendingFailed(
                    error: "Couldn't replay queued message: \(error.localizedDescription)"
                )
                break
            }
        }
    }

    private func sendError(forHTTPStatus status: Int, retryAfter retry: Int?) -> ComposerStore.SendError {
        switch status {
        case 401: return .unauthorized
        case 404: return .sessionGone
        case 429: return .rateLimited(retryAfter: retry)
        default: return .daemonError(message: "HTTP \(status)")
        }
    }

    private func finishBoundSendWithError(
        _ error: ComposerStore.SendError,
        promotedTarget: AgentSession?,
        draftText: String,
        draftAttachments: [ComposerStore.Attachment],
        draftBrowserComments: [BrowserCommentContext]
    ) {
        if let promotedTarget {
            model.queueFirstSendRecovery(
                sessionId: promotedTarget.id,
                text: draftText,
                attachments: draftAttachments,
                browserComments: draftBrowserComments,
                error: error
            )
        }
        composerStore.endSend(error: error)
        // A13 (D24 rejection handling): the daemon rejected the send. The
        // optimistic pending bubble stays visible with a chip + retry
        // affordance — NOT silently dropped. Offline transport gets a
        // distinct state so the chip can offer "will retry when daemon
        // returns" copy instead of the explicit-error copy.
        let chatStore = model.chatStore(for: session)
        switch error {
        case .offline:
            chatStore?.markPendingQueuedOffline(
                error: "Daemon offline — tap retry when it returns."
            )
        default:
            chatStore?.markPendingFailed(error: error.errorDescription ?? "Send failed.")
        }
    }

    private func performInterrupt() async {
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else {
            WorkspaceFeedback.failure("Couldn't stop the run", detail: "Local control server is unavailable.")
            return
        }
        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        do {
            try await sender.interrupt(sessionId: session.id)
        } catch {
            WorkspaceFeedback.failure("Couldn't stop the run", detail: error.localizedDescription)
        }
    }

    /// Translate a `PermissionMode` pick into an argv respawn. Picks of
    /// `.bypass` re-use the existing autopilot trust-grant sheet — for
    /// untrusted repos we surface the same confirm UX before flipping
    /// the daemon-side bypass flag.
    @MainActor
    private func changePermissionMode(to newMode: PermissionMode) async {
        // `.bypass` is the trust-gated path; defer to the existing
        // autopilot confirm sheet so the user explicitly opts in.
        if newMode == .bypass {
            // Only show the confirm if we're moving INTO bypass — flipping
            // back out is always safe.
            pendingBypassMode = true
            showingAutopilotConfirm = true
            return
        }
        await model.setPermissionMode(sessionId: session.id, to: newMode)
    }

    /// Right-side composer chip data: model + effort label, single-turn
    /// context window utilisation, running session cost, and the live
    /// Claude plan-window percentages from AppModel.
    ///
    /// **Context window math**: uses the SNAPSHOT's `contextWindowUsedTokens`
    /// (single-turn `last*` fields) — NOT the cumulative `totalTokens`. A
    /// long-running session re-counts cache reads on every turn, so the
    /// cumulative totals balloon to 100s of M and produce 1500% readings
    /// against a 1M window. The single-turn number is the model's actual
    /// working-memory size for the next prompt.
    ///
    /// **Model resolution**: trusts `session.model` over `snapshot.modelHint`
    /// because the user explicitly selected the session model — the JSONL
    /// hint can lag the chip selection and may report `claude-opus-4-7`
    /// (200K) when the user is actually running the 1M variant.
    private var usageStatusInfo: UsageStatusInfo? {
        let modelId = effectiveModelId ?? model.chatStore(for: session)?.snapshot.modelHint
        guard let modelId, !modelId.isEmpty else { return nil }
        let entry = catalog.entry(forId: modelId)
        let snap = model.chatStore(for: session)?.snapshot
        let effort = effectiveEffort(forModelId: modelId)
        let used = snap?.contextWindowUsedTokens ?? 0
        let totals = TokenTotals(
            inputTokens: snap?.totalInputTokens ?? 0,
            outputTokens: snap?.totalOutputTokens ?? 0,
            cacheCreationTokens: snap?.totalCacheCreationTokens ?? 0,
            cacheReadTokens: snap?.totalCacheReadTokens ?? 0
        )
        let dollar = Pricing.shared.cost(for: modelId, tokens: totals)
        let claudePlan = (session.agent == .claude) ? AppDelegate.runtime?.claudeModel.usage : nil
        let cursorPlan = (session.agent == .cursor) ? AppDelegate.runtime?.cursorModel.usage?.cursorQuota : nil
        return UsageStatusInfo(
            modelDisplay: entry?.displayName ?? modelId,
            effortDisplay: effort.map(effortLabel) ?? "Default",
            contextUsedTokens: used,
            contextLimitTokens: entry?.contextWindow,
            costDollar: dollar,
            sessionPct: claudePlan?.sessionPct,
            sessionResetMins: claudePlan?.sessionResetMins,
            weeklyPct: claudePlan?.weeklyPct,
            weeklyResetMins: claudePlan?.weeklyResetMins,
            cursorQuota: cursorPlan
        )
    }

    /// Display label for a ReasoningEffort — friendlier than `.rawValue`
    /// for `xhigh`/`max`. Matches Claude Code's "Extra high"/"Max" copy.
    private func effortLabel(_ e: ReasoningEffort) -> String {
        switch e {
        case .minimal: return "Minimal"
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        case .xhigh:   return "Extra high"
        case .max:     return "Max"
        }
    }

    private var effectiveModelId: String? {
        Self.effectiveModelId(for: session, catalog: catalog)
    }

    private func effectiveEffort(forModelId modelId: String?) -> ReasoningEffort? {
        Self.effectiveEffort(for: session, modelId: modelId, catalog: catalog)
    }

    private var sessionConfigurationSummary: String {
        let modelText: String
        if let id = effectiveModelId, !id.isEmpty {
            modelText = catalog.entry(forId: id)?.displayName ?? id
        } else {
            modelText = "default model"
        }
        let effortText = effectiveEffort(forModelId: effectiveModelId).map(effortLabel) ?? "Default effort"
        return "\(session.agent.tahoeProvider.displayName) · \(modelText) · \(effortText) · \(session.mode.rawValue) mode"
    }

    static func effectiveModelId(for session: AgentSession, catalog: ModelCatalog) -> String? {
        let candidates = [
            session.runtimeBinding?.providerModelId,
            session.model
        ]
        if let explicit = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
            return explicit
        }
        return ComposerStore.ChipDefaults.for(agent: session.agent, catalog: catalog).modelId
    }

    static func effectiveEffort(
        for session: AgentSession,
        modelId: String?,
        catalog: ModelCatalog
    ) -> ReasoningEffort? {
        if let effort = session.effort { return effort }
        if let modelId,
           let entry = catalog.entry(forId: modelId),
           !entry.supportsEffort {
            return nil
        }
        return ComposerStore.ChipDefaults.for(agent: session.agent, catalog: catalog).effort
    }

    private func toggleAutopilot(enable: Bool, grantingTrust: Bool = false) async {
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else { return }
        // E7: enable requires the repo to be on the autopilot trust list.
        // The confirm sheet asks for trust grant explicitly; if the user
        // accepted, record it before the wire-level enforcement kicks in.
        if grantingTrust, let repoKey = session.repoKey {
            // Chat sessions have no repo and can't grant trust; guard
            // here so we never persist trust for an empty string.
            AutopilotState.shared.trustRepo(repoKey)
        }
        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        // Daemon-side: flip state. We then respawn via SessionConfigChanger so
        // the running CLI restarts with the appropriate --dangerously-* flags.
        do {
            try await sender.setAutopilot(sessionId: session.id, enabled: enable)
            composerStore.autopilotEnabled = enable
            let changer = SessionConfigChanger(
                registry: model.registry,
                repoEnvResolver: runtime.repoEnvRuntimeResolver
            )
            _ = await changer.swap(sessionId: session.id)
        } catch MacComposerSender.Error.http(let status, _, _) where status == 403 {
            composerStore.endSend(error: .daemonError(message: "Repo not trusted for autopilot. (You can grant trust from this dialog.)"))
        } catch {
            composerStore.endSend(error: .daemonError(message: "Autopilot toggle failed: \(error.localizedDescription)"))
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return terraCotta
        // DESIGN.md Session Status: degraded → #ff5f57 (danger), not a muted gray.
        case .degraded: return Color(.sRGB, red: 1.0, green: 95.0 / 255.0, blue: 87.0 / 255.0, opacity: 1.0)
        }
    }

    /// Header branch chip label. Falls back to the worktree segment when
    /// `session.mode == .worktree`; otherwise hidden.
    private var branchLabel: String? {
        if let wt = session.worktreePath {
            return (wt as NSString).lastPathComponent
        }
        return nil
    }

    /// Icon for the branch chip. Filled when a PR is open or merged so the
    /// chip reads at a glance — empty branch glyph when no PR is linked.
    private var prBranchIcon: String {
        guard let state = prMirror.state?.state.uppercased() else {
            return "arrow.triangle.branch"
        }
        switch state {
        case "OPEN", "MERGED": return "arrow.triangle.pull"
        default: return "arrow.triangle.branch"
        }
    }

    /// Branch-chip color follows GitHub's PR badge palette: green for an
    /// open PR, purple for a merged PR, dark red for a closed-without-merge
    /// PR, and the Clawdmeter terra-cotta when no PR has been detected yet.
    private var prBranchColor: Color {
        guard let state = prMirror.state?.state.uppercased() else {
            return terraCotta
        }
        switch state {
        case "OPEN":   return .green
        case "MERGED": return Color(red: 0x8A / 255.0, green: 0x3F / 255.0, blue: 0xFC / 255.0)
        case "CLOSED": return .red
        default:       return terraCotta
        }
    }

    private var branchTooltip: String {
        var pieces: [String] = []
        if let wt = session.worktreePath {
            pieces.append("Worktree: \(wt)")
        }
        if let pr = prMirror.state {
            pieces.append("PR #\(pr.number) · \(pr.state.lowercased())")
            if !pr.title.isEmpty {
                pieces.append(pr.title)
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// Whether the current model supports an effort dial. Uses the live
    /// launcher catalog so account-scoped Cursor models get the same
    /// effort semantics in bound sessions as they do at launch.
    private var modelSupportsEffort: Bool {
        guard let id = composerStore.modelId ?? effectiveModelId,
              let entry = catalog.entry(forId: id)
        else { return true }
        return entry.supportsEffort
    }

    /// v27: true when this Code session is driven by a live harness bridge.
    /// Gates the mid-session config chips (no driver reconfigure in v1) and
    /// first-send readiness.
    private var isHarnessDriven: Bool {
        AppDelegate.runtime?.agentControlServer.isHarnessLive(session.id) == true
    }

    private var currentTurnState: TurnState {
        model.chatStore(for: session)?.snapshot.currentTurnState ?? .idle
    }

    /// A session can be `.running` because the provider process is idle and
    /// ready for its first prompt. Only the per-turn stream state means a prompt
    /// should become a follow-up instead of a normal send.
    private var turnIsStreaming: Bool {
        let chatStore = model.chatStore(for: session)
        return Self.hasActiveProviderTurn(
            snapshot: chatStore?.snapshot,
            pendingMessage: chatStore?.pendingMessage
        )
    }

    static func shouldSendPromptAsFollowUp(snapshot: SessionChatStore.ChatSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.messages.contains { message in
            switch message.kind {
            case .userText, .assistantText, .toolCall, .toolResult:
                return true
            case .meta:
                return false
            }
        }
    }

    static func hasActiveProviderTurn(
        snapshot: SessionChatStore.ChatSnapshot?,
        pendingMessage: SessionChatStore.PendingMessage?
    ) -> Bool {
        guard snapshot?.currentTurnState == .streaming else { return false }
        if pendingMessage?.state == .sending {
            return true
        }
        return shouldSendPromptAsFollowUp(snapshot: snapshot)
    }

    private func applyPendingFirstSendRecovery() {
        guard let recovery = model.takeFirstSendRecovery(sessionId: session.id) else { return }
        composerStore.restoreDraft(
            text: recovery.text,
            attachments: recovery.attachments,
            browserComments: recovery.browserComments,
            error: recovery.autoSendWhenReady ? nil : recovery.error
        )
        // Auto-flush a prompt queued while the "+" session was provisioning,
        // once the direct PTY/harness can accept it. If the ready signal raced
        // ahead of the session update, the draft is safely restored to the
        // composer for a manual send.
        let harnessReady = AppDelegate.runtime?.agentControlServer.isHarnessLive(session.id) == true
        if Self.shouldAutoFlushFirstSendRecovery(
            recovery: recovery,
            session: session,
            harnessReady: harnessReady,
            selectedSessionId: workbenchState.selectedSessionId
        ) {
            Task { await performBoundSend() }
        }
    }

    static func shouldAutoFlushFirstSendRecovery(
        recovery: PendingFirstSendRecovery,
        session: AgentSession,
        harnessReady: Bool,
        selectedSessionId: UUID?,
        now: Date = Date()
    ) -> Bool {
        guard recovery.autoSendWhenReady else { return false }
        let fresh = now.timeIntervalSince(recovery.createdAt) <= 90
        let selected = selectedSessionId == nil || selectedSessionId == session.id
        let claudePtyReady = session.agent == .claude
            && session.tmuxPaneId == nil
            && session.tmuxWindowId == nil
        return fresh && selected && (claudePtyReady || harnessReady)
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}

private struct BypassPermissionWarningText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 420
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setAccessibilityIdentifier("code.permission.bypass.body")
        field.setAccessibilityLabel(text)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
        field.setAccessibilityLabel(text)
    }
}
