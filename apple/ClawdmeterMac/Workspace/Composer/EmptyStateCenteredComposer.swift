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
    @StateObject private var store: ComposerStore = {
        let s = ComposerStore(mode: .emptyState(repoKey: nil, agent: .claude))
        s.resetChipsForRepo(nil, defaults: .default)
        return s
    }()

    init(model: SessionsModel, launcher: SessionLauncherModel, presentationStore: SessionPresentationStore) {
        self.model = model
        self.launcher = launcher
        self.presentationStore = presentationStore
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 6) {
                Text(headline)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text("Pick a repo and start typing. ⌘N if you'd rather configure advanced options first.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            quickChips
            VStack(spacing: 0) {
                repoPickerRow
                Divider()
                ComposerInputCore(
                    store: store,
                    presentationStore: presentationStore,
                    catalog: launcher.modelCatalog,
                    agentForModelPicker: store.agent,
                    modelSupportsEffort: modelSupportsEffort,
                    availableAgents: launcher.selectableAgents,
                    onSend: { Task { await firstSend() } },
                    onChangePermissionMode: { newMode in
                        store.permissionMode = newMode
                        store.planMode = (newMode == .plan)
                    },
                    permissionMode: store.permissionMode
                )
            }
            .frame(maxWidth: 760)
            .background(panelBg, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .onAppear {
            // Seed repo to the most recently active one if available.
            if store.repoKey == nil, let firstRepo = model.repos.first {
                store.resetChipsForRepo(firstRepo.key, defaults: launcher.chipDefaults(for: .claude))
            }
            launcher.normalize(store)
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
            return "What should we work on in \(last)?"
        }
        return "What should we work on?"
    }

    private var repoPickerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Picker("Repo", selection: Binding(
                get: { store.repoKey ?? "" },
                set: { newKey in
                    let key = newKey.isEmpty ? nil : newKey
                    store.resetChipsForRepo(key, defaults: launcher.chipDefaults(for: .claude))
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
            Text("Goal becomes the first user message.")
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
        model.registry.sessions
            .sorted { $0.lastEventAt > $1.lastEventAt }
            .compactMap { $0.goal?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
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
        .buttonStyle(.plain)
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
        var spawnedSession: AgentSession?
        guard let runtime = AppDelegate.runtime else {
            store.endSend(error: .offline)
            return
        }
        guard let repoKey = store.repoKey, !repoKey.isEmpty else {
            store.endSend(error: .spawnFailed(message: "Pick a repo first."))
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
            // v0.8.1 agy-migration: stage attachments BEFORE spawn so
            // Antigravity 2's `agentapi new-conversation` receives the
            // user's actual full prompt (incl. attachment refs), not the
            // 80-char `goal` slice. tmux-based sessions restage below into
            // the final per-session/worktree directory before /send.
            var stagedPaths: [URL] = []
            if let dir = AttachmentStaging.emptyStateStagingDir {
                for att in store.attachments {
                    if let staged = try? AttachmentStaging.stage(source: att.sourceURL, into: dir, attachmentId: att.id) {
                        stagedPaths.append(staged)
                    }
                }
            }
            let initialBody = store.renderPromptBody(attachmentPaths: stagedPaths)
            let session = try await model.spawnSession(
                repoPath: repoKey,
                agent: store.agent,
                planMode: store.permissionMode == .plan,
                goal: goal,
                mode: store.mode,
                tmux: runtime.tmuxClient,
                model: store.modelId,
                effort: launcher.supportsEffort(modelId: store.modelId) ? store.effort : nil,
                acceptEdits: store.permissionMode == .acceptEdits,
                autopilot: bypassPicked,
                initialMessage: initialBody.isEmpty ? nil : initialBody
            )
            spawnedSession = session
            // Record the empty-state composer's mode pick on the session
            // so the chip in the bound view reflects it without needing
            // an extra round-trip.
            if store.permissionMode == .acceptEdits {
                PermissionModeStore.shared.setAcceptEdits(true, sessionId: session.id)
            } else if bypassPicked {
                PermissionModeStore.shared.setBypass(true, sessionId: session.id)
            }
            // Codex P1.2: skip the post-spawn /send for agentapi
            // sessions — `agentapi new-conversation` already consumed the
            // first prompt via `initialMessage`. Sending it again would
            // either fail (no tmux pane, P1.3 unfixed) or duplicate the
            // first user turn into the SQLite conversation DB.
            let isAgentapiSpawn = session.geminiBackend == .agentapi
            // Wait briefly for the pane to be ready, then post the first prompt.
            try await Task.sleep(nanoseconds: 600_000_000)
            if !isAgentapiSpawn, store.canSend, let port = runtime.agentControlServer.boundPort {
                let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
                // Stage attachments under the new session's dir.
                stagedPaths.removeAll()
                if let dir = AttachmentStaging.stagingDir(for: session) {
                    for att in store.attachments {
                        if let staged = try? AttachmentStaging.stage(source: att.sourceURL, into: dir, attachmentId: att.id) {
                            stagedPaths.append(staged)
                        }
                    }
                }
                let body = store.renderPromptBody(attachmentPaths: stagedPaths)
                if !body.isEmpty {
                    try await sender.send(sessionId: session.id, body: body, asFollowUp: false)
                }
            }
            store.endSend()
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
