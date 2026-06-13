import SwiftUI
import ClawdmeterShared

/// Code-tab draft composer: branch label, sibling transcript opt-in, and a
/// bottom-pinned input bar for unsent workspace chat tabs (`+` / Cmd+T).
struct CodeWorkspaceDraftComposer: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var launcher: SessionLauncherModel
    @ObservedObject var presentationStore: SessionPresentationStore
    let workspaceDraft: WorkspaceDraftTab

    @StateObject private var store: ComposerStore
    @State private var selectedAccountWireId: String?
    @Environment(\.tahoe) private var t

    init(
        model: SessionsModel,
        launcher: SessionLauncherModel,
        presentationStore: SessionPresentationStore,
        workspaceDraft: WorkspaceDraftTab
    ) {
        self.model = model
        self.launcher = launcher
        self.presentationStore = presentationStore
        self.workspaceDraft = workspaceDraft
        _store = StateObject(wrappedValue: model.composerStore(for: workspaceDraft))
    }

    var body: some View {
        let siblings = siblingSessions
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New chat in \(draftBranchLabel(siblings: siblings)).")
                    .font(TahoeFont.body(13))
                    .foregroundStyle(t.fg2)
                    .accessibilityIdentifier("code.draft.branch-label")
                if !siblings.isEmpty {
                    InheritedContextChips(
                        siblings: siblings,
                        selectedSourceIds: $store.inheritedContextSourceIds,
                        style: .inline
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Spacer(minLength: 0)

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
                placeholderOverride: "Ask to make changes, @mention files, run /commands",
                selectedAccountWireId: $selectedAccountWireId,
                repoRoot: workspaceDraft.workspaceKey.workspacePath
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            launcher.normalize(store)
        }
        .onChange(of: launcher.availability) { _, _ in
            launcher.normalize(store)
        }
        .onChange(of: launcher.modelCatalog.updatedAt) { _, _ in
            launcher.normalize(store)
        }
        .onChange(of: store.agent) { _, _ in
            persistWorkspaceDraftChips()
        }
        .onChange(of: store.modelId) { _, _ in
            persistWorkspaceDraftChips()
        }
        .onChange(of: store.effort) { _, _ in
            persistWorkspaceDraftChips()
        }
        .onReceive(NotificationCenter.default.publisher(for: .composeDraftIncoming)) { note in
            applyIncomingDraft(note: note)
        }
    }

    private var siblingSessions: [AgentSession] {
        WorkspaceKey.siblings(of: workspaceDraft.workspaceKey, in: model.registry.sessions)
    }

    private func draftBranchLabel(siblings: [AgentSession]) -> String {
        if let sibling = siblings.first {
            return "/\(sibling.workspaceBranchLabel)"
        }
        let path = workspaceDraft.workspaceKey.workspacePath
        let slug = (path as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.isEmpty { return path }
        return "/\(slug)"
    }

    private var modelSupportsEffort: Bool {
        launcher.supportsEffort(modelId: store.modelId)
    }

    private func persistWorkspaceDraftChips() {
        model.updateDraftWorkspaceTabConfiguration(
            id: workspaceDraft.id,
            agent: store.agent,
            modelId: store.modelId,
            effort: launcher.supportsEffort(modelId: store.modelId) ? store.effort : nil
        )
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
            let selectedSourceIds = revalidatedInheritedSourceIds()
            let unavailableSourceIds = unavailableInheritedSourceIds(validSourceIds: selectedSourceIds)
            let firstSendPlan = EmptyStateFirstSendPlan.make(
                repoKey: repoKey,
                workspaceDraft: workspaceDraft,
                agent: store.agent,
                customProviderId: store.customProviderId,
                model: store.modelId,
                effort: store.effort,
                storeMode: store.mode,
                permissionMode: store.permissionMode,
                modelSupportsEffort: launcher.supportsEffort(modelId: store.modelId),
                goal: goal,
                inheritedContextSourceIds: selectedSourceIds
            )
            var stagedPaths: [URL] = []
            var pendingStagingDir: URL?
            defer {
                if let pendingStagingDir {
                    AttachmentStaging.cleanupPendingStagingDir(pendingStagingDir)
                }
            }
            if !store.attachments.isEmpty || !selectedSourceIds.isEmpty || !unavailableSourceIds.isEmpty {
                let dir = try AttachmentStaging.makePendingStagingDir()
                pendingStagingDir = dir
                for att in store.attachments {
                    if let staged = try? AttachmentStaging.stage(source: att.sourceURL, into: dir, attachmentId: att.id) {
                        stagedPaths.append(staged)
                    }
                }
                stagedPaths.append(contentsOf: try stageInheritedContext(
                    into: dir,
                    selectedSourceIds: selectedSourceIds,
                    unavailableSourceIds: unavailableSourceIds
                ))
            }
            let initialBody = draftPayload.render(attachmentPaths: stagedPaths)
            let hasInitialSendContent = draftPayload.hasContent
                || !selectedSourceIds.isEmpty
                || !unavailableSourceIds.isEmpty
            let session = try await model.spawnSessionInExistingWorkspace(
                repoPath: firstSendPlan.repoPath,
                workspacePath: firstSendPlan.existingWorkspacePath ?? workspaceDraft.workspaceKey.workspacePath,
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
                inheritedContextSourceIds: firstSendPlan.inheritedContextSourceIds,
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
                    stagedPaths.append(contentsOf: try stageInheritedContext(
                        into: dir,
                        selectedSourceIds: selectedSourceIds,
                        unavailableSourceIds: unavailableSourceIds
                    ))
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
            model.clearDraftWorkspaceTab(workspaceDraft)
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

    @MainActor
    private func revalidatedInheritedSourceIds() -> [UUID] {
        let allowed = Set(
            WorkspaceKey.siblings(of: workspaceDraft.workspaceKey, in: model.registry.sessions)
                .map(\.id)
        )
        return store.inheritedContextSourceIds
            .filter { allowed.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    @MainActor
    private func unavailableInheritedSourceIds(validSourceIds: [UUID]) -> [UUID] {
        let valid = Set(validSourceIds)
        return store.inheritedContextSourceIds
            .filter { !valid.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    @MainActor
    private func stageInheritedContext(
        into dir: URL,
        selectedSourceIds: [UUID],
        unavailableSourceIds: [UUID]
    ) throws -> [URL] {
        guard !selectedSourceIds.isEmpty || !unavailableSourceIds.isEmpty else { return [] }
        var staged: [URL] = []
        var sourceSessions: [AgentSession] = []

        for sourceId in unavailableSourceIds {
            let warningURL = dir.appendingPathComponent("inherited-\(sourceId.uuidString).md")
            try """
            # Inherited context unavailable

            Source session \(sourceId.uuidString) is no longer available in this workspace.
            """.write(to: warningURL, atomically: true, encoding: .utf8)
            staged.append(warningURL)
        }

        for sourceId in selectedSourceIds {
            guard let sourceSession = model.registry.session(id: sourceId),
                  sourceSession.archivedAt == nil,
                  WorkspaceKey.of(sourceSession) == workspaceDraft.workspaceKey
            else { continue }
            sourceSessions.append(sourceSession)
            let digest = ContextDigest.render(
                snapshot: wireSnapshot(for: sourceSession),
                sourceSession: sourceSession
            )
            let digestURL = dir.appendingPathComponent("inherited-\(sourceId.uuidString).md")
            try digest.write(to: digestURL, atomically: true, encoding: .utf8)
            staged.append(digestURL)
        }

        staged.append(contentsOf: try InheritedAttachmentStager.stage(sourceSessions: sourceSessions, into: dir))
        return staged
    }

    @MainActor
    private func wireSnapshot(for session: AgentSession) -> WireChatSnapshot {
        let snapshot = model.chatStore(for: session)?.snapshot
        return WireChatSnapshot(
            sessionId: session.id,
            items: snapshot?.items ?? [],
            planSteps: snapshot?.planSteps ?? [],
            sourceEntries: snapshot?.sourceEntries ?? [],
            artifactEntries: snapshot?.artifactEntries ?? [],
            codexTodos: snapshot?.codexTodos ?? [],
            pendingPermissionPrompt: model.chatStore(for: session)?.pendingPermissionPrompt,
            totalInputTokens: snapshot?.totalInputTokens ?? 0,
            totalOutputTokens: snapshot?.totalOutputTokens ?? 0,
            cacheReadTokens: snapshot?.totalCacheReadTokens ?? 0,
            cacheCreationTokens: snapshot?.totalCacheCreationTokens ?? 0,
            lastEventAt: snapshot?.lastEventAt ?? session.lastEventAt,
            updateCounter: snapshot?.updateCounter ?? session.lastEventSeq,
            currentTurnState: snapshot?.currentTurnState ?? .idle
        )
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
