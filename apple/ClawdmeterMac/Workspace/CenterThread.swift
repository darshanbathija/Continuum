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
    let onModeSwitch: (SessionMode) -> Void
    let onPreviewRequested: () -> Void

    /// Transcript verbosity for the chat thread. The picker moved out of the
    /// chat header into Settings → Visual ("Code and diff themes"), so this is
    /// now a global read from the shared presentation store rather than a
    /// per-window WorkbenchState value.
    private var density: TranscriptDensity { presentationStore.snapshot.transcriptDensity }

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
    @State private var showingTerminalOverlay = false
    @State private var showingAutopilotConfirm = false
    @State private var isDispatchingQueuedSend = false
    @State private var dispatchedQueuedTurnForCurrentIdle = false
    @State private var checkpointStatusText: String?
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
    /// When the composer contains vendor env vars, hold the detection here
    /// and surface `ChatEnvImportSheet` before the prompt reaches the model.
    @State private var pendingChatEnvImport: PendingChatEnvImport?
    /// A cross-vendor model pick made while a turn is mid-stream. The switch
    /// kills the in-flight response + starts a new conversation, so we confirm
    /// first; an idle pick switches immediately (no sheet).
    @State private var pendingAgentSwitch: PendingAgentSwitch?

    init(
        session: AgentSession,
        isReadOnly: Bool,
        model: SessionsModel,
        catalog: ModelCatalog,
        workbenchState: WorkbenchState,
        presentationStore: SessionPresentationStore,
        onModeSwitch: @escaping (SessionMode) -> Void,
        onPreviewRequested: @escaping () -> Void = {}
    ) {
        self.session = session
        self.isReadOnly = isReadOnly
        self.model = model
        self.catalog = catalog
        self.workbenchState = workbenchState
        self.presentationStore = presentationStore
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
            chatPane
        }
        // The visible session-detail metadata strip is gone (the Code tab's
        // favicon + label already identify the session). Bound sessions still
        // publish a headless AX marker so UI tests can assert the
        // session/provider/model state machine on tab switches. Zero-size and
        // clear: no visual chrome, no layout cost. Containment keeps the bare
        // `code.center.header` identifier off the child `.state` marker (same
        // AX-addressability bug class as the WorkspaceReviewPane fix).
        .overlay(alignment: .topLeading) {
            ZStack {
                Text(headerAccessibilityValue)
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(headerAccessibilityValue)
                    .accessibilityIdentifier("code.center.header.state")
                    .accessibilityValue(headerAccessibilityValue)
            }
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("code.center.header")
            .accessibilityValue(headerAccessibilityValue)
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
        .sheet(isPresented: $showingTerminalOverlay) {
            terminalOverlay
        }
        .sheet(isPresented: $showingAutopilotConfirm) {
            autopilotConfirm
        }
        .sheet(item: $pendingAgentSwitch) { pending in
            agentSwitchConfirm(pending)
        }
        .sheet(item: $pendingChatEnvImport) { pending in
            ChatEnvImportSheet(
                detection: pending.detection,
                workspaceId: pending.workspaceId,
                envSetIds: pending.envSetIds,
                service: AppDelegate.runtime?.vendorProvisioningService,
                envStore: AppDelegate.runtime?.repoEnvStore,
                onSaveAndSend: {
                    let keys = pending.detection.keys
                    pendingChatEnvImport = nil
                    composerStore.text = ChatEnvPasteDetector.redactEnvLines(
                        from: composerStore.text,
                        keys: keys
                    )
                    Task { await performBoundSend(skipEnvCheck: true) }
                },
                onSendWithoutSaving: {
                    pendingChatEnvImport = nil
                    Task { await performBoundSend(skipEnvCheck: true) }
                },
                onCancel: {
                    pendingChatEnvImport = nil
                }
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
            showingTerminalOverlay = false
            showingAutopilotConfirm = false
            pendingChatEnvImport = nil
            pendingBypassMode = false
            checkpointStatusText = nil
            isDispatchingQueuedSend = false
            dispatchedQueuedTurnForCurrentIdle = false
            // The newly-selected session may have a queued first send waiting
            // on readiness; onAppear won't fire again (identity is stable), so
            // re-run the recovery hook explicitly.
            applyPendingFirstSendRecovery()
        }
    }

    private var liveSession: AgentSession {
        model.registry.session(id: session.id) ?? session
    }

    // The visible session-detail metadata strip (model · effort · host ·
    // runtime · branch) was removed — the Code tab (favicon + label on
    // `WorkspaceTabStrip`) already identifies the session, so the body opens
    // straight onto the thread. Only the headless AX value survives, so the
    // bound-session state machine (id · title · provider · model) stays
    // assertable on tab switches without re-stating the tab visually.
    private var headerAccessibilityValue: String {
        [
            liveSession.id.uuidString,
            headerLabel(for: liveSession),
            model.displayAgent(for: liveSession, catalog: catalog).rawValue,
            model.displayModelId(for: liveSession, catalog: catalog) ?? ""
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
                    Button(action: ContinuumAnalytics.wrapButton(
                            "close_terminal_overlay",
                            {
 showingTerminalOverlay = false 
                            }
                        )) {
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
                Button("Cancel", action: ContinuumAnalytics.wrapButton(
                        "cancel",
                        {
                    showingAutopilotConfirm = false
                    pendingBypassMode = false
                
                        }
                    ))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("code.permission.bypass.cancel")
                Button(autopilotConfirmCTA(willEnable: true, needsTrustGrant: needsTrustGrant), action: ContinuumAnalytics.wrapButton("confirm_autopilot_bypass", {
                    showingAutopilotConfirm = false
                    pendingBypassMode = false
                    if needsTrustGrant, let repoKey = session.repoKey {
                        AutopilotState.shared.trustRepo(repoKey)
                    }
                    Task { await model.setPermissionMode(sessionId: session.id, to: .bypass) }
                }))
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

    /// Mid-turn cross-vendor switch confirm. Only shown while a turn is
    /// streaming, because switching kills the in-flight response and starts a
    /// new conversation on a different provider (and billing) stack.
    private func agentSwitchConfirm(_ pending: PendingAgentSwitch) -> some View {
        let fromAgent = AgentKindUI.displayName(for: liveSession.agent)
        let toAgent = AgentKindUI.displayName(for: pending.entry.provider)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Switch to \(pending.entry.displayName)?", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("code.agent-switch.title")
            Text("This stops the current \(fromAgent) turn and starts a new \(toAgent) conversation. Your previous messages are carried over as context, and billing moves to \(toAgent).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 420, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", action: ContinuumAnalytics.wrapButton("cancel_agent_switch", {
                    pendingAgentSwitch = nil
                }))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("code.agent-switch.cancel")
                Button("Switch + restart", action: ContinuumAnalytics.wrapButton("confirm_agent_switch", {
                    let entry = pending.entry
                    let effort = pending.effort
                    pendingAgentSwitch = nil
                    Task { await model.switchModel(sessionId: liveSession.id, to: entry, effort: effort) }
                }))
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
                .accessibilityIdentifier("code.agent-switch.confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("code.agent-switch-sheet")
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            messageList
            // The inline "Checkpoint · <date> · <summary> · Restore" strip was
            // removed per user feedback. Checkpoints are still created on
            // lifecycle events and surfaced via the header status text.
            // Setup Trail — animated, non-blocking provisioning ribbon for an
            // optimistic "+" session. Sits just above the composer (which stays
            // usable the whole time) and confirms each step with a fact.
            if #available(macOS 14, *), let progress = model.provisioningProgress[session.id] {
                ProvisioningTrailView(
                    progress: progress,
                    agent: model.displayAgent(for: liveSession, catalog: catalog)
                )
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
                isReadOnly: isReadOnly,
                onPlanRefine: primePlanRefinement,
                onPlanApprove: {
                    Task {
                        guard await createLifecycleCheckpoint(summary: "Before plan approval") else { return }
                        await model.approvePlan(id: session.id)
                    }
                },
                onPreviewTurn: onPreviewRequested,
                onRetryFailedTurn: { promptBody in
                    Task { await performTurnRetry(promptBody: promptBody) }
                },
                onRetryFailedTurnInNewChat: { promptBody in
                    Task { await model.retryFailedTurnInNewChat(from: session, promptBody: promptBody) }
                }
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
            TranscriptEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var composerArea: some View {
        ComposerInputCore(
            store: composerStore,
            presentationStore: presentationStore,
            catalog: catalog,
            agentForModelPicker: composerStore.agent,
            modelSupportsEffort: modelSupportsEffort,
            onSend: { Task { await performBoundSend() } },
            onQueue: { queueCurrentDraft() },
            onInterrupt: { Task { await performInterrupt() } },
            onToggleAutopilot: { Task { await changePermissionMode(to: .bypass) } },
            onChangePermissionMode: { newMode in
                Task { await changePermissionMode(to: newMode) }
            },
            onSelectModelConfiguration: { choice, modelId, effort in
                handleModelConfigurationSelection(
                    choice: choice,
                    modelId: modelId,
                    effort: effort
                )
            },
            customProviderIdForModelPicker: session.customProviderId,
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
            repoRoot: session.effectiveCwd,
            mentionSourceProvider: {
                let openSessions = model.registry.sessions.filter { $0.id != session.id && $0.archivedAt == nil }
                let store = model.chatStore(for: session)
                let sourceEntries = store?.snapshot.sourceEntries ?? []
                return (openSessions, sourceEntries)
            },
            usageStatus: usageStatusInfo,
            projectSkillsRoot: URL(fileURLWithPath: session.effectiveCwd).appendingPathComponent(".claude/skills", isDirectory: true),
            chatStore: model.chatStore(for: session),
            onRetryPending: { Task { await performPendingRetry() } },
            queuedSends: workbenchState.queuedSends(for: session.id),
            isDispatchingQueuedSend: isDispatchingQueuedSend,
            onQueuedSendUpdate: { id, text in
                workbenchState.updateQueuedSend(id: id, text: text)
            },
            onQueuedSendDelete: { id in
                workbenchState.removeQueuedSend(id: id)
            },
            onQueuedSendSteer: { draft in
                Task { await steerQueuedDraft(draft) }
            }
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
                let pendingAgent = catalog.entry(
                    forId: new,
                    customProviderId: composerStore.customProviderId ?? liveSession.customProviderId
                )?.provider ?? composerStore.agent
                model.configureProvisionalLaunch(
                    sessionId: session.id,
                    agent: pendingAgent,
                    modelId: new,
                    effort: composerStore.effort,
                    customProviderId: composerStore.customProviderId ?? liveSession.customProviderId
                )
            }
        }
        .onChange(of: composerStore.effort) { _, new in
            let isRepoint = lastEffortChipSessionId != session.id
            lastEffortChipSessionId = session.id
            guard !isRepoint, !isReadOnly, let new else { return }
            if model.isProvisioning(session.id),
               let pendingModelId = composerStore.modelId ?? effectiveModelId {
                let pendingAgent = catalog.entry(
                    forId: pendingModelId,
                    customProviderId: composerStore.customProviderId ?? session.customProviderId
                )?.provider ?? composerStore.agent
                model.configureProvisionalLaunch(
                    sessionId: session.id,
                    agent: pendingAgent,
                    modelId: pendingModelId,
                    effort: new,
                    customProviderId: composerStore.customProviderId ?? session.customProviderId
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

    private func steerQueuedDraft(_ draft: QueuedWorkbenchSend) async {
        await dispatchQueuedDraft(draft, manual: true, steerMidTurn: true)
    }

    private func dispatchQueuedDraft(
        _ draft: QueuedWorkbenchSend,
        manual: Bool,
        steerMidTurn: Bool = false
    ) async {
        guard steerMidTurn || !turnIsStreaming else { return }
        guard draft.payload.hasContent else {
            workbenchState.removeQueuedSend(id: draft.id)
            return
        }
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else {
            if steerMidTurn {
                model.chatStore(for: session)?.markPendingQueuedOffline(
                    error: "Daemon offline — steer when it returns."
                )
            } else {
                composerStore.endSend(error: .offline)
            }
            if !manual { dispatchedQueuedTurnForCurrentIdle = false }
            return
        }
        isDispatchingQueuedSend = true
        if steerMidTurn {
            injectOptimisticPending(for: draft)
        } else {
            composerStore.beginSend()
        }
        defer {
            isDispatchingQueuedSend = false
        }

        let target = session
        var stagedPaths: [URL] = []
        if !draft.attachmentPaths.isEmpty {
            guard let dir = AttachmentStaging.stagingDir(for: target) else {
                finishQueuedDispatchFailure(
                    steerMidTurn: steerMidTurn,
                    error: .daemonError(message: "Couldn't create attachment staging directory."),
                    manual: manual
                )
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
                    finishQueuedDispatchFailure(
                        steerMidTurn: steerMidTurn,
                        error: .daemonError(message: "Couldn't stage queued attachment: \(error.localizedDescription)"),
                        manual: manual
                    )
                    return
                }
            }
        }

        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        let body = QueuedPromptRenderer.render(payload: draft.payload, attachmentPaths: stagedPaths)
        do {
            if !steerMidTurn {
                guard await createLifecycleCheckpoint(summary: "Before queued prompt") else {
                    finishQueuedDispatchFailure(
                        steerMidTurn: steerMidTurn,
                        error: .daemonError(message: "Safety checkpoint failed. Prompt was not sent."),
                        manual: manual
                    )
                    return
                }
            }
            try await sender.send(
                sessionId: target.id,
                body: body,
                asFollowUp: true,
                origin: .userComposer,
                idempotencyKey: steerMidTurn ? "steer-send:\(draft.id.uuidString)" : "queued-send:\(draft.id.uuidString)",
                clientIntentId: draft.id.uuidString
            )
            workbenchState.removeQueuedSend(id: draft.id)
            if steerMidTurn {
                // Optimistic pending reconciles when the echoed user row lands.
            } else {
                composerStore.endSend()
            }
        } catch MacComposerSender.Error.http(let status, let retry, _) {
            let sendError: ComposerStore.SendError = switch status {
            case 401: .unauthorized
            case 404: .sessionGone
            case 429: .rateLimited(retryAfter: retry)
            default: .daemonError(message: "HTTP \(status)")
            }
            finishQueuedDispatchFailure(steerMidTurn: steerMidTurn, error: sendError, manual: manual)
        } catch MacComposerSender.Error.transport(let message) {
            finishQueuedDispatchFailure(
                steerMidTurn: steerMidTurn,
                error: .daemonError(message: message),
                manual: manual
            )
        } catch {
            finishQueuedDispatchFailure(
                steerMidTurn: steerMidTurn,
                error: .daemonError(message: error.localizedDescription),
                manual: manual
            )
        }
    }

    private func finishQueuedDispatchFailure(
        steerMidTurn: Bool,
        error: ComposerStore.SendError,
        manual: Bool
    ) {
        if steerMidTurn {
            model.chatStore(for: session)?.markPendingQueuedOffline(error: error.localizedDescription)
        } else {
            composerStore.endSend(error: error)
        }
        if !manual { dispatchedQueuedTurnForCurrentIdle = false }
    }

    private func injectOptimisticPending(for draft: QueuedWorkbenchSend) {
        guard let chatStore = model.chatStore(for: session) else { return }
        let trimmed = draft.payload.render().trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentRefs = draft.attachmentPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard !trimmed.isEmpty || !attachmentRefs.isEmpty || !draft.browserComments.isEmpty else { return }
        chatStore.injectPending(text: trimmed, attachmentRefs: attachmentRefs)
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

    private func performBoundSend(skipEnvCheck: Bool = false) async {
        if !skipEnvCheck,
           !isReadOnly,
           session.kind == .code,
           let workspace = resolveWorkspace(for: session),
           let chatStore = model.chatStore(for: session),
           let detection = ChatEnvPasteDetector.detect(
               in: composerStore.text,
               contextHints: ChatEnvPasteDetector.contextHints(from: chatStore.messages)
           ) {
            pendingChatEnvImport = PendingChatEnvImport(
                detection: detection,
                workspaceId: workspace.id,
                envSetIds: resolveEnvSetIds(for: session, workspaceId: workspace.id)
            )
            return
        }

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

    /// Re-send the user prompt that preceded a model-failure row in the
    /// current session. Mirrors the pending-send retry path: re-seed the
    /// composer with the captured prompt body, then run the normal send
    /// pipeline so attachments/checkpoints/idempotency stay consistent.
    @MainActor
    private func performTurnRetry(promptBody: String) async {
        guard !isReadOnly else { return }
        guard currentTurnState != .streaming else { return }

        let liveDraft = composerStore.text
        let liveDraftAttachments = composerStore.attachments
        let liveDraftBrowserComments = composerStore.browserComments
        let liveDraftPayload = ComposerDraftPayload(
            text: liveDraft,
            attachmentPaths: liveDraftAttachments.map(\.sourceURL.path),
            browserComments: liveDraftBrowserComments
        )
        let liveDraftMatchesRetry = liveDraftPayload
            .render()
            .trimmingCharacters(in: .whitespacesAndNewlines) == promptBody.trimmingCharacters(in: .whitespacesAndNewlines)

        composerStore.text = promptBody
        composerStore.clearBrowserComments()
        await performBoundSend()

        let trimmedLive = liveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveDraftMatchesRetry && (!trimmedLive.isEmpty || !liveDraftBrowserComments.isEmpty) {
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
        // Optimistically clear the streaming/"thinking…" indicator on the
        // UI-side store. For direct-PTY Claude Code sessions the UI observes a
        // SEPARATE SessionChatStore from the daemon's — the daemon's
        // handleInterrupt only flips .interrupted on its own store, and an ESC
        // abort writes no terminal JSONL line, so the UI store would otherwise
        // stay .streaming forever. Idempotent + a harmless no-op for
        // shared-store (.chat / live-harness) sessions the daemon already flips.
        model.chatStore(for: session)?.setCurrentTurnState(.interrupted)
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
        // `.bypass` is the trust-gated path. Only the first-time trust grant
        // (untrusted repo → "give agents free rein") warrants a confirm sheet.
        // Once a repo is on the trust list, flipping into bypass is a one-click
        // action — no redundant "already on your trust list" prompt.
        if newMode == .bypass {
            let repoTrusted = AutopilotState.shared.isRepoTrusted(session.repoKey ?? "")
            if repoTrusted {
                await model.setPermissionMode(sessionId: session.id, to: .bypass)
                return
            }
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
        let limit = entry?.contextWindow
        let contextBreakdown = resolvedContextBreakdown(
            snapshot: snap,
            usedTokens: used,
            limitTokens: limit
        )
        let claudePlan = (session.agent == .claude) ? AppDelegate.runtime?.claudeModel.usage : nil
        let cursorPlan = (session.agent == .cursor) ? AppDelegate.runtime?.cursorModel.usage?.cursorQuota : nil
        return UsageStatusInfo(
            modelDisplay: entry?.displayName ?? modelId,
            effortDisplay: effort.map(effortLabel) ?? "Default",
            contextUsedTokens: used,
            contextLimitTokens: limit,
            costDollar: dollar,
            contextBreakdown: contextBreakdown,
            sessionPct: claudePlan?.sessionPct,
            sessionResetMins: claudePlan?.sessionResetMins,
            weeklyPct: claudePlan?.weeklyPct,
            weeklyResetMins: claudePlan?.weeklyResetMins,
            cursorQuota: cursorPlan
        )
    }

    /// Prefer a provider-published breakdown from the chat snapshot; fall
    /// back to a local estimate so the Code tab popover always renders the
    /// Cursor-style category rows instead of session cost.
    private func resolvedContextBreakdown(
        snapshot: SessionChatStore.ChatSnapshot?,
        usedTokens: Int,
        limitTokens: Int?
    ) -> ContextWindowBreakdown? {
        if let published = snapshot?.contextBreakdown {
            return published
        }
        guard let limitTokens, limitTokens > 0 else { return nil }
        return ContextWindowBreakdownParser.estimate(
            usedTokens: usedTokens,
            limitTokens: limitTokens,
            messages: snapshot?.messages ?? []
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
        Self.effectiveModelId(for: liveSession, catalog: catalog)
    }

    private func effectiveEffort(forModelId modelId: String?) -> ReasoningEffort? {
        Self.effectiveEffort(for: liveSession, modelId: modelId, catalog: catalog)
    }

    private func handleModelConfigurationSelection(
        choice: ProviderChoice,
        modelId: String,
        effort: ReasoningEffort?
    ) {
        let customProviderId = choice.customProviderId
        let selectedAgent = choice.backingAgent(in: catalog) ?? composerStore.agent
        if model.isProvisioning(liveSession.id) {
            model.configureProvisionalLaunch(
                sessionId: liveSession.id,
                agent: selectedAgent,
                modelId: modelId,
                effort: effort,
                customProviderId: customProviderId
            )
            return
        }
        guard !isReadOnly,
              let entry = catalog.entry(forId: modelId, customProviderId: customProviderId)
        else { return }
        if entry.provider != liveSession.agent {
            // Cross-vendor: a REAL runtime switch (tear down the running agent +
            // spawn the new vendor's, carrying the transcript) — not the old
            // chip-only no-op that left Codex running while the chip said Opus.
            // This must run even when the source is harness-driven (e.g.
            // Codex → Opus), so it's handled BEFORE the `isHarnessDriven` gate.
            // Confirm only when a turn is mid-stream (the switch kills the
            // in-flight response); an idle pick switches immediately.
            if turnIsStreaming {
                pendingAgentSwitch = PendingAgentSwitch(entry: entry, effort: effort)
            } else {
                Task { await model.switchModel(sessionId: liveSession.id, to: entry, effort: effort) }
            }
            return
        }
        guard !isHarnessDriven else { return }
        Task { await model.switchModel(sessionId: liveSession.id, to: entry, effort: effort) }
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

    private func resolveWorkspace(for session: AgentSession) -> CodeWorkspaceRecord? {
        guard let runtime = AppDelegate.runtime else { return nil }
        if let workspaceId = session.workspaceId,
           let workspace = runtime.workspaceStore.workspace(id: workspaceId) {
            return workspace
        }
        if let repoKey = session.repoKey {
            return runtime.workspaceStore.workspace(forRepoRoot: repoKey)
        }
        return nil
    }

    private func resolveEnvSetIds(for session: AgentSession, workspaceId: UUID) -> Set<UUID> {
        guard let runtime = AppDelegate.runtime else { return [] }
        let envStore = runtime.repoEnvStore
        _ = envStore.ensureDefaultSet(workspaceId: workspaceId)
        let sets = envStore.sets(for: workspaceId)
        if let envSetId = session.envSetId,
           sets.contains(where: { $0.id == envSetId }) {
            return [envSetId]
        }
        if let active = sets.first(where: \.isActive) ?? sets.first {
            return [active.id]
        }
        return []
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}

private struct PendingChatEnvImport: Identifiable {
    let id = UUID()
    let detection: ChatEnvPasteDetection
    let workspaceId: UUID
    let envSetIds: Set<UUID>
}

/// A cross-vendor model pick awaiting confirmation (raised only when a turn is
/// mid-stream — the switch interrupts it). Carries the picked entry + effort so
/// the confirm CTA can run the same `switchModel` an idle pick would.
private struct PendingAgentSwitch: Identifiable {
    let id = UUID()
    let entry: ModelCatalogEntry
    let effort: ReasoningEffort?
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
