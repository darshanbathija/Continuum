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
        case live(sessionId: UUID)
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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholderText, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .lineLimit(1...6)
                    .background(fieldBackground, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
                    .disabled(isSending)

                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.top, 6)
        }
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
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
        case .live(let sessionId):
            await client.sendPrompt(sessionId: sessionId, text: trimmed, asFollowUp: true)
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
