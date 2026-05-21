import SwiftUI
import ClawdmeterShared

/// v0.9.x — iOS Frontier compare surface.
///
/// Mac uses a 3-pane HSplitView; iOS uses a segmented control across
/// the top (one tab per child) with a single chat thread visible at a
/// time. The composer at the bottom is shared — sending fans out to
/// ALL children via `POST /chat-sessions/frontier/:groupId/send`, the
/// segment just controls which transcript you're reading.
///
/// Long-pressing a segment opens the pick-winner action sheet for that
/// child. Archived children disappear from the segments automatically
/// after pick-winner.
@available(iOS 16, *)
struct iOSChatFrontierView: View {
    let groupId: UUID
    @ObservedObject var client: AgentControlClient

    @State private var selectedIndex: Int = 0
    @State private var prompt: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    @State private var showingPickWinnerConfirm: AgentSession?

    private var children: [AgentSession] {
        client.frontierChildren(groupId: groupId)
    }

    private var selectedChild: AgentSession? {
        guard !children.isEmpty else { return nil }
        let idx = min(max(selectedIndex, 0), children.count - 1)
        return children[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            if children.isEmpty {
                ContentUnavailableView(
                    "Frontier ended",
                    systemImage: "rectangle.split.3x1",
                    description: Text("All children were archived. Start a new Royal Frontier from the Chat tab.")
                )
            } else {
                segmentBar
                Divider()
                threadArea
                Divider()
                composer
            }
        }
        .navigationTitle("Royal Frontier")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Pick this pane as winner?",
            isPresented: Binding(
                get: { showingPickWinnerConfirm != nil },
                set: { if !$0 { showingPickWinnerConfirm = nil } }
            ),
            presenting: showingPickWinnerConfirm
        ) { child in
            Button("Pick \(child.displayLabel)", role: .destructive) {
                Task { await pickWinner(child) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Archives the other panes. You can keep chatting with the winner as a regular Solo chat.")
        }
    }

    private var segmentBar: some View {
        Picker("Pane", selection: $selectedIndex) {
            ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                Text(paneLabel(child))
                    .tag(idx)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func paneLabel(_ child: AgentSession) -> String {
        switch child.agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    @ViewBuilder
    private var threadArea: some View {
        if let child = selectedChild {
            // Reuse iOSChatSoloView for the per-pane transcript +
            // permission card + delete action. Hides its own composer
            // when we want — but to keep this MVP small we just let
            // ChatSoloView own the bottom composer for the visible pane
            // (sending from there only hits that child) AND we add the
            // shared frontier composer below for fan-out. v0.9.x.1
            // could polish this by hiding the per-pane composer when
            // inside a Frontier wrapper.
            iOSChatSoloView(session: child, client: client)
                .id(child.id)
        }
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
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(isSending)
                Menu {
                    if let child = selectedChild {
                        Button("Pick this pane as winner") {
                            showingPickWinnerConfirm = child
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                Button(action: { Task { await send() } }) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    private func send() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !children.isEmpty else { return }
        isSending = true
        errorMessage = nil
        let ok = await client.frontierSend(groupId: groupId, text: trimmed)
        isSending = false
        if ok {
            prompt = ""
        } else {
            errorMessage = client.lastError ?? "Send failed."
        }
    }

    private func pickWinner(_ child: AgentSession) async {
        guard let idx = child.frontierChildIndex else { return }
        let winner = await client.frontierPickWinner(groupId: groupId, childIndex: idx)
        if winner == nil {
            errorMessage = client.lastError ?? "Pick winner failed."
        } else {
            // Refresh sessions so the archived children drop out of the
            // children list immediately.
            await client.refreshAll()
        }
    }
}
