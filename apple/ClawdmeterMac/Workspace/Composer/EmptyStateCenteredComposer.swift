import SwiftUI
import ClawdmeterShared

/// Codex-style centered composer for the dashboard's empty state (no session open).
/// First send spawns a fresh session via `SessionsModel.spawnSession` (with the
/// composer's repo/agent/model/effort/mode chips), then posts the prompt as
/// the opening user turn through the daemon (Wave D).
///
/// Listens for `compose-draft` notifications (X1) so an iPhone draft pre-fills
/// the text + suggested chips.
struct EmptyStateCenteredComposer: View {

    @ObservedObject var model: SessionsModel
    @ObservedObject var launcher: SessionLauncherModel
    @ObservedObject var presentationStore: SessionPresentationStore
    private let workspaceDraft: WorkspaceDraftTab?
    @StateObject private var store: ComposerStore
    /// Drives the one-shot fade+rise entrance when the empty state appears.
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        model: SessionsModel,
        launcher: SessionLauncherModel,
        presentationStore: SessionPresentationStore,
        workspaceDraft: WorkspaceDraftTab? = nil
    ) {
        self.model = model
        self.launcher = launcher
        self.presentationStore = presentationStore
        self.workspaceDraft = workspaceDraft
        let s = ComposerStore(mode: .emptyState(repoKey: workspaceDraft?.workspaceKey.repoKey, agent: workspaceDraft?.agent ?? .claude))
        if let workspaceDraft {
            s.resetChipsForRepo(
                workspaceDraft.workspaceKey.repoKey,
                defaults: ComposerStore.ChipDefaults(
                    agent: workspaceDraft.agent,
                    modelId: workspaceDraft.modelId,
                    effort: workspaceDraft.effort,
                    mode: workspaceDraft.mode,
                    planMode: false
                )
            )
        } else {
            s.resetChipsForRepo(nil, defaults: .default)
        }
        _store = StateObject(wrappedValue: s)
    }

    var body: some View {
        VStack(spacing: workspaceDraft == nil ? 18 : 14) {
            Spacer(minLength: workspaceDraft == nil ? 0 : 14)
            if workspaceDraft != nil {
                inheritedContextControls
            }
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
        // Restrained entrance (DESIGN.md: no oversized hero) — the block fades
        // and rises 10pt once on appear; instant under Reduce Motion.
        .opacity(appeared ? 1 : 0)
        .offset(y: (appeared || reduceMotion) ? 0 : 10)
        .onAppear {
            withAnimation(SessionsV2Theme.bannerSlideUp(reduceMotion: reduceMotion)) {
                appeared = true
            }
            // Seed repo to the most recently active one if available.
            if workspaceDraft == nil,
               store.repoKey == nil,
               let firstRepo = model.repos.first,
               let defaultAgent = launcher.selectableAgents.first(where: { $0 == .codex }) ?? launcher.selectableAgents.first {
                store.resetChipsForRepo(
                    firstRepo.key,
                    defaults: launcher.chipDefaults(for: defaultAgent)
                )
            }
            launcher.normalize(store)
            // New-session default = Full access (bypass) per product decision.
            // The per-repo trust gate still applies on first spawn; draft
            // handoffs from iOS keep whatever mode they arrived with.
            if workspaceDraft == nil {
                store.permissionMode = .bypass
                store.planMode = false
            }
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

    @ViewBuilder
    private var inheritedContextControls: some View {
        if let workspaceDraft {
            InheritedContextChips(
                siblings: siblingSessions(for: workspaceDraft),
                selectedSourceIds: $store.inheritedContextSourceIds
            )
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
            if let workspaceDraft {
                VStack(alignment: .leading, spacing: 2) {
                    Text((workspaceDraft.workspaceKey.repoKey as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                    Text(workspaceDraft.workspaceKey.workspacePath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
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
            }
            Spacer()
            Text(workspaceDraft == nil ? "Goal becomes the first user message." : "New tab stays in this workspace.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var quickChips: some View {
        HStack(spacing: 6) {
            quickChip("Plan a feature", systemImage: "list.bullet.rectangle", template: "Plan a feature: ")
            quickChip("Fix a bug", systemImage: "exclamationmark.triangle", template: "Fix a bug: ")
            quickChip("Refactor", systemImage: "wrench.and.screwdriver", template: "Refactor: ")
            quickChip("Ask a question", systemImage: "questionmark.bubble", template: "Question: ")
            if let lastPrompt {
                quickChip("Use last prompt", systemImage: "clock.arrow.circlepath", template: lastPrompt)
            }
        }
        .frame(maxWidth: 760, alignment: .center)
    }

    private var lastPrompt: String? {
        let sourceSessions: [AgentSession] = {
            if let workspaceDraft {
                return siblingSessions(for: workspaceDraft)
            }
            return model.registry.sessions
        }()
        return sourceSessions
            .sorted { $0.lastEventAt > $1.lastEventAt }
            .compactMap { $0.goal?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func siblingSessions(for draft: WorkspaceDraftTab) -> [AgentSession] {
        WorkspaceKey.siblings(of: draft.workspaceKey, in: model.registry.sessions)
    }

    private func quickChip(_ title: String, systemImage: String, template: String) -> some View {
        Button {
            store.text = template
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.secondary)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var modelSupportsEffort: Bool {
        launcher.supportsEffort(modelId: store.modelId)
    }

    private var panelBg: Color {
        Color.secondary.opacity(0.06)
    }

    // MARK: - First-send flow (spawn + send)

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
        // Goal preview: first 80 chars of prompt for sidebar display.
        let goal: String? = {
            if prompt.isEmpty { return nil }
            return String(prompt.prefix(80))
        }()
        // v0.7.15: bypass mode picked at empty-state needs to (1) reach
        // the spawned CLI argv via `autopilot: true`, (2) record per-repo
        // trust so subsequent sessions in the same repo can be flipped
        // to bypass without re-prompting, (3) seed AutopilotState for
        // the new session id so the bound chip + analytics row stay in
        // sync. Without this whole chain, picking Bypass at empty state
        // silently downgrades to Ask.
        let bypassPicked = store.permissionMode == .bypass
        if bypassPicked {
            AutopilotState.shared.trustRepo(repoKey)
        }
        do {
            let selectedSourceIds = revalidatedInheritedSourceIds()
            let unavailableSourceIds = unavailableInheritedSourceIds(validSourceIds: selectedSourceIds)
            // Stage attachments before spawn so managed/direct runtimes receive
            // the user's actual full prompt (including attachment refs), not
            // the 80-char `goal` slice. Sessions restage below into the final
            // per-session/worktree directory before /send.
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
            let session: AgentSession
            if let workspaceDraft {
                session = try await model.spawnSessionInExistingWorkspace(
                    repoPath: workspaceDraft.workspaceKey.repoKey,
                    workspacePath: workspaceDraft.workspaceKey.workspacePath,
                    agent: store.agent,
                    planMode: store.permissionMode == .plan,
                    goal: goal,
                    mode: workspaceDraft.mode,
                    model: store.modelId,
                    effort: launcher.supportsEffort(modelId: store.modelId) ? store.effort : nil,
                    acceptEdits: store.permissionMode == .acceptEdits,
                    autopilot: bypassPicked,
                    initialMessage: initialBody.isEmpty ? nil : initialBody,
                    inheritedContextSourceIds: selectedSourceIds
                )
            } else {
                session = try await model.spawnSession(
                    repoPath: repoKey,
                    agent: store.agent,
                    planMode: store.permissionMode == .plan,
                    goal: goal,
                    mode: store.mode,
                    model: store.modelId,
                    effort: launcher.supportsEffort(modelId: store.modelId) ? store.effort : nil,
                    acceptEdits: store.permissionMode == .acceptEdits,
                    autopilot: bypassPicked,
                    initialMessage: initialBody.isEmpty ? nil : initialBody
                )
            }
            spawnedSession = session
            // Record the empty-state composer's mode pick on the session
            // so the chip in the bound view reflects it without needing
            // an extra round-trip.
            if store.permissionMode == .acceptEdits {
                PermissionModeStore.shared.setAcceptEdits(true, sessionId: session.id)
            } else if bypassPicked {
                PermissionModeStore.shared.setBypass(true, sessionId: session.id)
            }
            // Post the captured first prompt through the daemon once the
            // session is up. Do not re-read the mutable composer here: the
            // provider turn must be the exact draft the user submitted.
            if hasInitialSendContent, let port = runtime.agentControlServer.boundPort {
                // Local loopback: authenticate with the in-process token, not
                // the pairing keychain (which would prompt on first send).
                let sender = MacComposerSender(port: Int(port), token: runtime.agentControlServer.localLoopbackToken)
                // Stage attachments under the new session's dir.
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
                        asFollowUp: false,
                        origin: .userComposerFirstTurn,
                        idempotencyKey: "first-send:\(session.id.uuidString):\(firstSendIntentId)",
                        clientIntentId: firstSendIntentId
                    )
                }
            }
            store.endSend()
            model.clearDraftWorkspaceTab()
        } catch let err as MacComposerSender.Error {
            let error = ComposerStore.SendError.daemonError(
                message: "Session started, but the first message did not send: \(err.localizedDescription)"
            )
            recoverDraftIfNeeded(
                session: spawnedSession,
                text: draftText,
                attachments: draftAttachments,
                error: error
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
        guard let workspaceDraft else { return [] }
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
        guard workspaceDraft != nil else { return [] }
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
        guard let workspaceDraft,
              !selectedSourceIds.isEmpty || !unavailableSourceIds.isEmpty
        else { return [] }
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
