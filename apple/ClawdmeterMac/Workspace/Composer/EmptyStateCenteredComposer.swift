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
    @State private var accountChoices: [ProviderInstanceId] = []
    @State private var selectedAccountWireId: String?
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
            VStack(spacing: 0) {
                repoPickerRow
                Divider()
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
                    minimalChrome: true
                )
            }
            .frame(maxWidth: 760)
            .background(panelBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
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

    private var repoPickerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Picker("Repo", selection: Binding(
                get: { store.repoKey ?? "" },
                set: { newKey in
                    let key = newKey.isEmpty ? nil : newKey
                    if let defaultAgent = launcher.selectableAgents.first(where: { $0 == .codex }) ?? launcher.selectableAgents.first {
                        store.resetChipsForRepo(
                            key,
                            defaults: launcher.chipDefaults(for: defaultAgent)
                        )
                    } else {
                        store.repoKey = key
                    }
                }
            )) {
                Text("(custom path)").tag("")
                ForEach(model.repos, id: \.key) { repo in
                    Text(repo.displayName).tag(repo.key)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Spacer()
            if accountChoices.count >= 2 {
                accountMenu
            }
            Text("Goal becomes the first user message.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .task(id: store.agent) { await refreshAccountChoices() }
    }

    private var accountMenu: some View {
        Menu {
            ForEach(accountChoices, id: \.wireId) { instance in
                Button {
                    selectedAccountWireId = instance.isPrimary ? nil : instance.wireId
                } label: {
                    let label = instance.isPrimary ? "default" : instance.name
                    let isCurrent = instance.isPrimary
                        ? selectedAccountWireId == nil
                        : selectedAccountWireId == instance.wireId
                    if isCurrent { Label(label, systemImage: "checkmark") }
                    else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text(currentAccountMenuLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which \(store.agent.rawValue) account runs this session")
        .accessibilityIdentifier("code.account.menu")
    }

    private var currentAccountMenuLabel: String {
        if let selectedAccountWireId,
           let match = accountChoices.first(where: { $0.wireId == selectedAccountWireId }) {
            return match.name
        }
        return "default"
    }

    private func refreshAccountChoices() async {
        guard let registry = AppDelegate.runtime?.providerInstanceRegistry,
              ProviderInstanceEnvironment.configDirVariable(for: store.agent) != nil else {
            accountChoices = []
            selectedAccountWireId = nil
            return
        }
        let choices = await registry.instances(for: store.agent)
        accountChoices = choices
        selectedAccountWireId = CodePreferredAccountStore.providerInstanceId(
            for: store.agent,
            available: choices
        )
    }

    private var modelSupportsEffort: Bool {
        launcher.supportsEffort(modelId: store.modelId)
    }

    private var panelBg: Color {
        Color.secondary.opacity(0.06)
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
