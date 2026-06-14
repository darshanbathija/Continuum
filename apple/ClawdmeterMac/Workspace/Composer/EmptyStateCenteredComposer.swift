import SwiftUI
import ClawdmeterShared

struct EmptyStateFirstSendPlan: Equatable, Sendable {
    let repoPath: String
    let existingWorkspacePath: String?
    let agent: AgentKind
    let customProviderId: String?
    let planMode: Bool
    let goal: String?
    let mode: SessionMode
    let model: String?
    let effort: ReasoningEffort?
    let acceptEdits: Bool
    let autopilot: Bool
    let inheritedContextSourceIds: [UUID]
    let sendAsFollowUp: Bool
    let sendOrigin: ProviderPromptOrigin

    static func make(
        repoKey: String,
        workspaceDraft: WorkspaceDraftTab?,
        agent: AgentKind,
        customProviderId: String? = nil,
        model: String?,
        effort: ReasoningEffort?,
        storeMode: SessionMode,
        permissionMode: PermissionMode,
        modelSupportsEffort: Bool,
        goal: String?,
        inheritedContextSourceIds: [UUID]
    ) -> EmptyStateFirstSendPlan {
        EmptyStateFirstSendPlan(
            repoPath: workspaceDraft?.workspaceKey.repoKey ?? repoKey,
            existingWorkspacePath: workspaceDraft?.workspaceKey.workspacePath,
            agent: agent,
            customProviderId: customProviderId,
            planMode: permissionMode == .plan,
            goal: goal,
            mode: workspaceDraft?.mode ?? storeMode,
            model: model,
            effort: modelSupportsEffort ? effort : nil,
            acceptEdits: permissionMode == .acceptEdits,
            autopilot: permissionMode == .bypass,
            inheritedContextSourceIds: inheritedContextSourceIds,
            sendAsFollowUp: false,
            sendOrigin: .userComposerFirstTurn
        )
    }
}

/// Codex-style centered composer for the Code tab when no session or draft is
/// open. First send spawns a fresh session via `SessionsModel.spawnSession`.
///
/// Workspace draft tabs use `CodeWorkspaceDraftComposer` instead.
struct EmptyStateCenteredComposer: View {

    @ObservedObject var model: SessionsModel
    @ObservedObject var launcher: SessionLauncherModel
    @ObservedObject var presentationStore: SessionPresentationStore
    @StateObject private var store: ComposerStore
    @State private var appeared = false
    @State private var selectedAccountWireId: String?
    @State private var accountChoices: [ProviderInstanceId] = []
    @State private var executionHosts: [ExecutionHost] = []
    @State private var localExecutionHostId: UUID?
    /// Selected execution host. nil = run on this Mac (local default).
    @State private var selectedHostId: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        model: SessionsModel,
        launcher: SessionLauncherModel,
        presentationStore: SessionPresentationStore
    ) {
        self.model = model
        self.launcher = launcher
        self.presentationStore = presentationStore
        let s = ComposerStore(mode: .emptyState(repoKey: nil, agent: .claude))
        s.resetChipsForRepo(nil, defaults: .default)
        _store = StateObject(wrappedValue: s)
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Text(headline)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ComposerInputCore(
                    store: store,
                    presentationStore: presentationStore,
                    catalog: launcher.modelCatalog,
                    agentForModelPicker: store.agent,
                    modelSupportsEffort: modelSupportsEffort,
                    onSend: { Task { await firstSend() } },
                    onChangePermissionMode: { newMode in
                        store.permissionMode = newMode
                        store.planMode = (newMode == .plan)
                    },
                    permissionMode: store.permissionMode,
                    minimalChrome: true,
                    selectedAccountWireId: $selectedAccountWireId
                )
                metaChipRow
            }
            .frame(maxWidth: 760)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .opacity(appeared ? 1 : 0)
        .offset(y: (appeared || reduceMotion) ? 0 : 10)
        .onAppear {
            withAnimation(SessionsV2Theme.bannerSlideUp(reduceMotion: reduceMotion)) {
                appeared = true
            }
            if store.repoKey == nil,
               let firstRepo = model.repos.first,
               let defaultAgent = launcher.selectableAgents.first(where: { $0 == .codex }) ?? launcher.selectableAgents.first {
                store.resetChipsForRepo(
                    firstRepo.key,
                    defaults: launcher.chipDefaults(for: defaultAgent)
                )
            }
            launcher.normalize(store)
            store.permissionMode = .bypass
            store.planMode = false
        }
        .onChange(of: launcher.availability) { _, _ in
            launcher.normalize(store)
        }
        .onChange(of: launcher.modelCatalog.updatedAt) { _, _ in
            launcher.normalize(store)
        }
        .task { await refreshMetaChoices() }
        .onChange(of: store.agent) { _, _ in
            Task { await refreshMetaChoices() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .composeDraftIncoming)) { note in
            applyIncomingDraft(note: note)
        }
    }

    private var headline: String {
        if let repo = store.repoKey, !repo.isEmpty {
            let last = (repo as NSString).lastPathComponent
            return "What should we build in \(last)?"
        }
        return "What should we build?"
    }

    private var modelSupportsEffort: Bool {
        launcher.supportsEffort(modelId: store.modelId)
    }

    // MARK: - Below-box meta chips (repo · account · device)

    /// Borderless ghost chips under the composer box — Codex-style. Repo and
    /// the execution-host "device" picker always show; the preferred-account
    /// picker shows only for kinds that support multi-account (Claude / Codex).
    private var metaChipRow: some View {
        HStack(spacing: 4) {
            repoMenu
            if showsAccountMenu {
                metaChipDivider
                accountMenu
            }
            metaChipDivider
            deviceMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var metaChipDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1, height: 13)
            .padding(.horizontal, 2)
    }

    private func ghostChipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
    }

    // Repo
    private var repoLabel: String {
        if let key = store.repoKey, !key.isEmpty {
            if let repo = model.repos.first(where: { $0.key == key }) {
                return repo.displayName
            }
            return (key as NSString).lastPathComponent
        }
        return "Choose repo"
    }

    private var repoMenu: some View {
        Menu {
            ForEach(model.repos, id: \.key) { repo in
                Button {
                    selectRepo(repo.key)
                } label: {
                    if store.repoKey == repo.key {
                        Label(repo.displayName, systemImage: "checkmark")
                    } else {
                        Text(repo.displayName)
                    }
                }
            }
        } label: {
            ghostChipLabel(icon: "folder", text: repoLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Repository this session runs in")
    }

    private func selectRepo(_ key: String) {
        let resolved = key.isEmpty ? nil : key
        if let defaultAgent = launcher.selectableAgents.first(where: { $0 == .codex }) ?? launcher.selectableAgents.first {
            store.resetChipsForRepo(resolved, defaults: launcher.chipDefaults(for: defaultAgent))
        } else {
            store.repoKey = resolved
        }
    }

    // Account (preferred subscription) — only Claude / Codex have multi-account.
    private var showsAccountMenu: Bool {
        ProviderInstanceEnvironment.configDirVariable(for: store.agent) != nil
    }

    private func accountItemLabel(_ instance: ProviderInstanceId) -> String {
        instance.isPrimary ? "Default" : instance.name
    }

    private var accountMenu: some View {
        Menu {
            ForEach(accountChoices, id: \.wireId) { instance in
                Button {
                    let wire = instance.isPrimary ? nil : instance.wireId
                    selectedAccountWireId = wire
                    CodePreferredAccountStore.setPreferred(wireId: wire, for: store.agent)
                } label: {
                    let isCurrent = instance.isPrimary
                        ? selectedAccountWireId == nil
                        : selectedAccountWireId == instance.wireId
                    if isCurrent {
                        Label(accountItemLabel(instance), systemImage: "checkmark")
                    } else {
                        Text(accountItemLabel(instance))
                    }
                }
            }
            Divider()
            Button {
                openSettings(section: "providers")
            } label: {
                Label("Add account…", systemImage: "plus")
            }
        } label: {
            ghostChipLabel(
                icon: "person.crop.circle",
                text: ProviderAccountChip.displayLabel(for: selectedAccountWireId, in: accountChoices)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which account runs this session")
    }

    // Device (execution host) — This Mac / second Mac / VPC.
    private var remoteHosts: [ExecutionHost] {
        executionHosts.filter { $0.id != localExecutionHostId }
    }

    private var isThisMacSelected: Bool {
        selectedHostId == nil || selectedHostId == localExecutionHostId
    }

    private var deviceLabel: String {
        if let id = selectedHostId, id != localExecutionHostId,
           let host = executionHosts.first(where: { $0.id == id }) {
            return host.displayName
        }
        return "This Mac"
    }

    private var deviceMenu: some View {
        Menu {
            Button {
                selectedHostId = nil
            } label: {
                if isThisMacSelected {
                    Label("This Mac", systemImage: "checkmark")
                } else {
                    Text("This Mac")
                }
            }
            ForEach(remoteHosts) { host in
                Button {
                    selectedHostId = host.id
                } label: {
                    if selectedHostId == host.id {
                        Label(host.displayName, systemImage: "checkmark")
                    } else {
                        Text(host.displayName)
                    }
                }
            }
            Divider()
            Button {
                openSettings(section: "devices")
            } label: {
                Label("Add device…", systemImage: "plus")
            }
        } label: {
            ghostChipLabel(
                icon: isThisMacSelected ? "laptopcomputer" : "server.rack",
                text: deviceLabel
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where this session runs")
    }

    private func openSettings(section: String) {
        NotificationCenter.default.post(
            name: .clawdmeterOpenSettingsSection,
            object: nil,
            userInfo: ["section": section]
        )
    }

    /// Loads the account list (for the current agent) and the registered
    /// execution hosts. Re-read on appear and on agent change so a newly added
    /// account/device joins the pickers without a relaunch.
    @MainActor
    private func refreshMetaChoices() async {
        if let registry = AppDelegate.runtime?.providerInstanceRegistry,
           ProviderInstanceEnvironment.configDirVariable(for: store.agent) != nil {
            accountChoices = await registry.instances(for: store.agent)
        } else {
            accountChoices = []
        }
        if let client = AppDelegate.runtime?.loopbackClient, client.supportsExecutionHosts {
            await client.refreshExecutionHosts()
            executionHosts = client.executionHosts
            localExecutionHostId = client.localExecutionHostId
            if let id = selectedHostId, !executionHosts.contains(where: { $0.id == id }) {
                selectedHostId = nil
            }
        } else {
            executionHosts = []
            localExecutionHostId = nil
            selectedHostId = nil
        }
    }

    @MainActor
    private func firstSend() async {
        store.beginSend()
        launcher.normalize(store)
        let draftText = store.text
        let draftAttachments = store.attachments
        let draftPayload = store.draftPayload()
        let firstSendIntentId = UUID().uuidString
        var spawnedSession: AgentSession?
        guard let runtime = AppDelegate.runtime else {
            store.endSend(error: .offline)
            return
        }
        guard let repoKey = store.repoKey, !repoKey.isEmpty else {
            store.endSend(error: .spawnFailed(message: "Pick a repo first."))
            return
        }
        guard launcher.selectableAgents.contains(store.agent) else {
            store.endSend(error: .spawnFailed(message: "Enable a provider in Settings → Providers."))
            return
        }
        let prompt = store.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal: String? = {
            if prompt.isEmpty { return nil }
            return String(prompt.prefix(80))
        }()
        let bypassPicked = store.permissionMode == .bypass
        if bypassPicked {
            AutopilotState.shared.trustRepo(repoKey)
        }
        // Remote execution host selected → spawn on that host (mirrors the New
        // Session sheet's remote path). The full prompt rides along as the goal;
        // loopback attachment-staging + MacComposerSender are local-only, so
        // attachments aren't carried to a remote host here.
        if let client = runtime.loopbackClient,
           client.supportsExecutionHosts,
           let targetId = selectedHostId,
           targetId != localExecutionHostId {
            let session = await client.createSession(NewSessionRequest(
                repoKey: repoKey,
                agent: store.agent,
                model: store.modelId,
                planMode: store.permissionMode == .plan,
                goal: prompt.isEmpty ? nil : prompt,
                useWorktree: true,
                effort: launcher.supportsEffort(modelId: store.modelId) ? store.effort : nil,
                providerInstanceId: selectedAccountWireId,
                customProviderId: store.customProviderId,
                targetHostId: targetId
            ))
            guard let session else {
                store.endSend(error: .spawnFailed(message: client.lastError ?? "Remote spawn failed."))
                return
            }
            model.openSessionId = session.id
            store.endSend()
            return
        }
        do {
            let firstSendPlan = EmptyStateFirstSendPlan.make(
                repoKey: repoKey,
                workspaceDraft: nil,
                agent: store.agent,
                customProviderId: store.customProviderId,
                model: store.modelId,
                effort: store.effort,
                storeMode: store.mode,
                permissionMode: store.permissionMode,
                modelSupportsEffort: launcher.supportsEffort(modelId: store.modelId),
                goal: goal,
                inheritedContextSourceIds: []
            )
            var stagedPaths: [URL] = []
            var pendingStagingDir: URL?
            defer {
                if let pendingStagingDir {
                    AttachmentStaging.cleanupPendingStagingDir(pendingStagingDir)
                }
            }
            if !store.attachments.isEmpty {
                let dir = try AttachmentStaging.makePendingStagingDir()
                pendingStagingDir = dir
                for att in store.attachments {
                    if let staged = try? AttachmentStaging.stage(source: att.sourceURL, into: dir, attachmentId: att.id) {
                        stagedPaths.append(staged)
                    }
                }
            }
            let initialBody = draftPayload.render(attachmentPaths: stagedPaths)
            let hasInitialSendContent = draftPayload.hasContent
            let session = try await model.spawnSession(
                repoPath: firstSendPlan.repoPath,
                agent: firstSendPlan.agent,
                planMode: firstSendPlan.planMode,
                goal: firstSendPlan.goal,
                mode: firstSendPlan.mode,
                model: firstSendPlan.model,
                effort: firstSendPlan.effort,
                acceptEdits: firstSendPlan.acceptEdits,
                autopilot: firstSendPlan.autopilot,
                providerInstanceId: selectedAccountWireId,
                initialMessage: initialBody.isEmpty ? nil : initialBody,
                customProviderId: firstSendPlan.customProviderId
            )
            spawnedSession = session
            if store.permissionMode == .acceptEdits {
                PermissionModeStore.shared.setAcceptEdits(true, sessionId: session.id)
            } else if bypassPicked {
                PermissionModeStore.shared.setBypass(true, sessionId: session.id)
            }
            if hasInitialSendContent, let port = runtime.agentControlServer.boundPort {
                let sender = MacComposerSender(port: Int(port), token: runtime.agentControlServer.localLoopbackToken)
                stagedPaths.removeAll()
                if let dir = AttachmentStaging.stagingDir(for: session) {
                    for att in draftAttachments {
                        if let staged = try? AttachmentStaging.stage(source: att.sourceURL, into: dir, attachmentId: att.id) {
                            stagedPaths.append(staged)
                        }
                    }
                }
                let body = draftPayload.render(attachmentPaths: stagedPaths)
                if !body.isEmpty {
                    try await sender.send(
                        sessionId: session.id,
                        body: body,
                        asFollowUp: firstSendPlan.sendAsFollowUp,
                        origin: firstSendPlan.sendOrigin,
                        idempotencyKey: "first-send:\(session.id.uuidString):\(firstSendIntentId)",
                        clientIntentId: firstSendIntentId
                    )
                }
            }
            store.endSend()
        } catch let err as MacComposerSender.Error {
            recoverDraftIfNeeded(
                session: spawnedSession,
                text: draftText,
                attachments: draftAttachments,
                error: .daemonError(
                    message: "Session started, but the first message did not send: \(err.localizedDescription)"
                )
            )
        } catch {
            if let spawnedSession {
                recoverDraftIfNeeded(
                    session: spawnedSession,
                    text: draftText,
                    attachments: draftAttachments,
                    error: .daemonError(
                        message: "Session started, but the first message did not send: \(error.localizedDescription)"
                    )
                )
            } else {
                store.endSend(error: .spawnFailed(message: error.localizedDescription))
            }
        }
    }

    @MainActor
    private func recoverDraftIfNeeded(
        session: AgentSession?,
        text: String,
        attachments: [ComposerStore.Attachment],
        error: ComposerStore.SendError
    ) {
        if let session {
            model.queueFirstSendRecovery(
                sessionId: session.id,
                text: text,
                attachments: attachments,
                error: error
            )
        }
        store.endSend(error: error)
    }

    private func applyIncomingDraft(note: Notification) {
        guard let draft = note.userInfo?["draft"] as? ComposeDraft else { return }
        store.text = draft.text
        if let repoKey = draft.repoKey { store.repoKey = repoKey }
        if let agent = draft.suggestedAgent { store.agent = agent }
        if let model = draft.suggestedModel { store.modelId = model }
        if let effort = draft.suggestedEffort { store.effort = effort }
        launcher.normalize(store)
    }
}
