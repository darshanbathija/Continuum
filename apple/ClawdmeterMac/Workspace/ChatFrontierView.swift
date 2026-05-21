import SwiftUI
import ClawdmeterShared

/// v0.9 Mac Frontier UI — 3-pane comparison view that shows N (2-3)
/// chat sessions side-by-side and sends one prompt to all of them.
///
/// MVP shape:
///   - HStack of ChatSoloViews for each child in the frontier group
///   - shared composer at the bottom; pressing Send POSTs
///     `POST /chat-sessions/frontier/:groupId/send` with the text
///   - "Pick winner" button on each pane archives the other two
///
/// Polish deferred to v0.9.x:
///   - per-pane stop button (currently relies on per-session interrupt
///     via the existing trash icon in ChatSoloView's header)
///   - frontier-subscribe WS for typed snapshots (this MVP relies on
///     each child's own chat-subscribe stream)
///   - row dividers + per-pane drag-resizable widths
///   - sub-second send dispatch indicator
@available(macOS 14, *)
struct ChatFrontierView: View {
    let groupId: UUID
    @ObservedObject var model: SessionsModel

    @State private var prompt: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    private var children: [AgentSession] {
        let filtered: [AgentSession] = model.registry.sessions.filter { session in
            session.frontierGroupId == groupId && session.archivedAt == nil
        }
        return filtered.sorted { a, b in
            (a.frontierChildIndex ?? Int.max) < (b.frontierChildIndex ?? Int.max)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panes
            Divider()
            composer
        }
        .navigationTitle("Royal Frontier")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1.fill")
                .foregroundStyle(.orange)
            Text("Royal Frontier")
                .font(.system(size: 16, weight: .semibold))
            Text("\(children.count) live")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var panes: some View {
        HStack(spacing: 0) {
            ForEach(children, id: \.id) { child in
                VStack(spacing: 0) {
                    paneHeader(for: child)
                    Divider()
                    ChatSoloView(session: child, model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                if child.id != children.last?.id {
                    Divider()
                }
            }
        }
    }

    private func paneHeader(for child: AgentSession) -> some View {
        HStack(spacing: 6) {
            Text(child.displayLabel)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button("Pick winner") {
                Task { await pickWinner(child) }
            }
            .controlSize(.mini)
            .help("Archive the other two panes; promote this one to Solo chat.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.05))
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            HStack(spacing: 8) {
                TextField("Send to all \(children.count) panes…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .disabled(isSending)
                Button(action: { Task { await send() } }) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func sender() -> MacComposerSender? {
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort else { return nil }
        return MacComposerSender(
            port: Int(port),
            token: PairingTokenStore.shared.currentToken()
        )
    }

    private func send() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !children.isEmpty else { return }
        guard let s = sender() else {
            errorMessage = "Daemon not running."
            return
        }
        isSending = true
        defer { isSending = false }
        errorMessage = nil
        do {
            try await s.frontierSend(groupId: groupId, text: trimmed)
            prompt = ""
        } catch MacComposerSender.Error.http(let status, _) {
            errorMessage = "Daemon error \(status)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pickWinner(_ child: AgentSession) async {
        guard let idx = child.frontierChildIndex, let s = sender() else { return }
        do {
            try await s.frontierPickWinner(groupId: groupId, childIndex: idx)
        } catch {
            errorMessage = "Pick winner failed: \(error.localizedDescription)"
        }
    }
}
