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
    @StateObject private var store: ComposerStore = {
        let s = ComposerStore(mode: .emptyState(repoKey: nil, agent: .claude))
        s.resetChipsForRepo(nil, defaults: .default)
        return s
    }()

    init(model: SessionsModel) {
        self.model = model
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
            VStack(spacing: 0) {
                repoPickerRow
                Divider()
                ComposerInputCore(
                    store: store,
                    catalog: .bundled,
                    agentForModelPicker: store.agent,
                    modelSupportsEffort: modelSupportsEffort,
                    onSend: { Task { await firstSend() } }
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
                store.resetChipsForRepo(firstRepo.key, defaults: .default)
            }
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
                    store.resetChipsForRepo(key, defaults: .default)
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

    private var modelSupportsEffort: Bool {
        guard let id = store.modelId,
              let entry = ModelCatalog.bundled.entry(forId: id)
        else { return true }
        return entry.supportsEffort
    }

    private var panelBg: Color {
        Color.secondary.opacity(0.06)
    }

    // MARK: - First-send flow (spawn + send)

    @MainActor
    private func firstSend() async {
        store.beginSend()
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
        do {
            let session = try await model.spawnSession(
                repoPath: repoKey,
                agent: store.agent,
                planMode: store.planMode,
                goal: goal,
                mode: store.mode,
                tmux: runtime.tmuxClient
            )
            // Wait briefly for the pane to be ready, then post the first prompt.
            try await Task.sleep(nanoseconds: 600_000_000)
            if store.canSend, let port = runtime.agentControlServer.boundPort {
                let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
                // Stage attachments under the new session's dir.
                var stagedPaths: [URL] = []
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
            store.endSend(error: .daemonError(message: err.localizedDescription))
        } catch {
            store.endSend(error: .spawnFailed(message: error.localizedDescription))
        }
    }

    private func applyIncomingDraft(note: Notification) {
        guard let draft = note.userInfo?["draft"] as? ComposeDraft else { return }
        store.text = draft.text
        if let repoKey = draft.repoKey { store.repoKey = repoKey }
        if let agent = draft.suggestedAgent { store.agent = agent }
        if let model = draft.suggestedModel { store.modelId = model }
        if let effort = draft.suggestedEffort { store.effort = effort }
    }
}
