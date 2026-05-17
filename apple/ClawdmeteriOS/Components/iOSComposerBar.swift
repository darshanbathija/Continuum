import SwiftUI
import ClawdmeterShared

/// Minimal-but-functional chat composer for the iOS Sessions tab.
/// Renders a multi-line text field with "Continue the session here"
/// placeholder + a send arrow. Two modes mirror the Mac:
/// - `.live(sessionId)` — POSTs the prompt to `/sessions/:id/send`.
/// - `.outside(recent, repo)` — POSTs to `/sessions/continue-readonly`
///   (which spawns a live `--resume`/`resume` pane and forwards the
///   prompt as the first turn). Receives the new session id back and
///   notifies the host via `onPromoted` so the open-state can flip from
///   the JSONL path to the live AgentSession.
///
/// Read-only outside sessions stay read-only until the user actually
/// presses Send — tapping in and typing does nothing to the session.
struct iOSComposerBar: View {
    enum Mode {
        case live(session: AgentSession)
        case outside(recent: RecentSession, repo: AgentRepo)
    }

    let mode: Mode
    @ObservedObject var client: AgentControlClient
    /// Notified when a `.outside` send promotes the session to live.
    /// Hosts use this to flip navigation / pop the read-only screen.
    var onPromoted: ((UUID) -> Void)? = nil

    @State private var text: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    @State private var showingAttachmentSheet: Bool = false
    /// Local mirror of the live session's model + effort so the
    /// composer's pill renders without a round-trip through the daemon.
    /// `onChange` handlers fire the actual respawn via the client.
    @State private var modelId: String?
    @State private var effort: ReasoningEffort?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
            // Card wraps the textfield + the bottom row so the whole
            // composer reads as one control (matches Claude Desktop /
                // Codex screenshots).
            VStack(alignment: .leading, spacing: 8) {
                TextField(placeholderText, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .font(.system(size: 15))
                    .lineLimit(1...8)
                    .disabled(isSending)

                bottomRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(fieldBackground, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .padding(.top, 6)
        }
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
        .onAppear { syncModelEffortFromSession() }
        .onChange(of: modelId) { _, new in handleModelChange(new) }
        .onChange(of: effort)   { _, new in handleEffortChange(new) }
        .alert("Attachments are Mac-only for now",
               isPresented: $showingAttachmentSheet) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Files attached on the iPhone would need to upload to the paired Mac before the agent could see them — that endpoint isn't wired yet. Drop files on the Mac composer for now.")
        }
    }

    /// Compact bottom row that mirrors the Mac composer's layout:
    /// model+effort pill on the left, mic + attach + send on the right.
    @ViewBuilder
    private var bottomRow: some View {
        HStack(spacing: 8) {
            if case .live(let session) = mode {
                iOSModelEffortPill(
                    agent: session.agent,
                    catalog: client.modelCatalog,
                    selectedModelId: $modelId,
                    selectedEffort: $effort
                )
            } else if case .outside(let recent, _) = mode {
                // Outside rows haven't promoted yet — show the agent
                // they'll spawn with as a static chip so the user knows.
                Text(recent.provider == .claude ? "Claude" : "Codex")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(recent.provider == .claude ? accent : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
            }
            Spacer(minLength: 0)
            attachButton
            micButton
            sendButton
        }
    }

    private var attachButton: some View {
        Button(action: { showingAttachmentSheet = true }) {
            Image(systemName: "paperclip")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var micButton: some View {
        Button(action: { showingAttachmentSheet = true }) {
            Image(systemName: "mic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func syncModelEffortFromSession() {
        if case .live(let session) = mode {
            // Seed the pill from the session's current config the first
            // time the composer mounts. After that, onChange handlers
            // own the round-trip.
            if modelId == nil { modelId = session.model }
            if effort  == nil { effort  = session.effort }
        }
    }

    @MainActor
    private func handleModelChange(_ new: String?) {
        guard case .live(let session) = mode,
              let new, new != session.model
        else { return }
        Task {
            await client.changeModel(
                sessionId: session.id,
                request: ChangeModelRequest(model: new, effort: effort)
            )
        }
    }

    @MainActor
    private func handleEffortChange(_ new: ReasoningEffort?) {
        guard case .live(let session) = mode,
              let new, new != session.effort
        else { return }
        Task {
            await client.changeEffort(sessionId: session.id, effort: new)
        }
    }

    private var sendButton: some View {
        Button(action: { Task { await performSend() } }) {
            Group {
                if isSending {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? accent : Color.secondary.opacity(0.4))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(!canSend || isSending)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholderText: String {
        switch mode {
        case .live:    return "Message the agent…"
        case .outside: return "Continue the session here"
        }
    }

    private var fieldBackground: Color {
        Color(.tertiarySystemBackground)
    }

    private var borderColor: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0).opacity(0.5)
    }

    private var accent: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

    @MainActor
    private func performSend() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        switch mode {
        case .live(let session):
            await client.sendPrompt(sessionId: session.id, text: trimmed, asFollowUp: true)
            text = ""
        case .outside(let recent, let repo):
            // Promote the read-only synthetic to a live --resume pane on
            // the Mac. If the Mac can't extract the CLI session id (rare
            // — happens on truncated JSONLs), surface an inline error
            // and leave the text in place so the user can retry.
            let newSessionId = await client.continueReadOnly(
                jsonlPath: recent.path,
                repoKey: repo.key,
                agent: recent.provider,
                prompt: trimmed
            )
            if let newSessionId {
                text = ""
                // Refresh the sessions list so the new live session
                // shows up alongside the existing rows.
                await client.refreshSessions()
                onPromoted?(newSessionId)
            } else {
                errorMessage = "Couldn't continue this session — the JSONL header doesn't carry a CLI session id, or the Mac isn't reachable."
            }
        }
    }
}
