import SwiftUI
import ClawdmeterShared

/// Solo chat surface — one chat session, full-height thread + composer.
/// Reuses `iOSChatStore` for the chat-subscribe WS subscription (SDK
/// chat populates the store via `CodexSDKEventIngestor.appendSDKMessages`
/// on the Mac side, so the wire shape is identical to CLI chat).
///
/// v0.8 minimum-viable: plain thread + composer. ModelPicker mid-conv
/// swap (D7) is wired via the existing iOSComposerBar `.live` mode chips.
/// Plan-mode is enforced server-side for chat sessions (Phase 3), so the
/// composer's PermissionMode chip — which v0.7.18 added — is not exposed
/// here for chat (REV-Composer-mode: force `.plan`, hide picker).
@available(iOS 16, *)
struct iOSChatSoloView: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    @StateObject private var store: iOSChatStore

    init(session: AgentSession, client: AgentControlClient) {
        self.session = session
        self.client = client
        _store = StateObject(wrappedValue: iOSChatStore(sessionId: session.id, client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            thread
            Divider()
            iOSComposerBar(mode: .live(session: session), client: client)
        }
        .navigationTitle(session.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive, action: {
                        Task { await client.deleteSession(id: session.id) }
                    }) {
                        Label("End chat", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        // v0.8 QA F5: floating permission-prompt tray (mirror of Mac
        // PermissionPromptCard). Renders when the WS snapshot carries a
        // pendingPermissionPrompt; user taps an option → POST
        // /permission-respond → daemon dismisses the prompt.
        .overlay(alignment: .bottom) {
            iOSPermissionPromptCard(store: store, sessionId: session.id, client: client)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var thread: some View {
        if store.snapshot.items.isEmpty {
            ContentUnavailableView {
                Label("Say something", systemImage: "bubble.left")
            } description: {
                emptyStateDescription
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.snapshot.items) { item in
                            messageRow(item)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
                .onChange(of: store.snapshot.updateCounter) { _, _ in
                    if let last = store.snapshot.items.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var emptyStateDescription: Text {
        if session.agent == .codex, session.codexChatBackend == .sdk {
            return Text("Codex SDK chat — your first message starts a server-side thread that survives across devices.")
        }
        switch session.agent {
        case .claude: return Text("Claude is running in plan-mode. Reads + proposes, no writes.")
        case .codex:  return Text("Codex is running in --sandbox read-only. Reads + proposes, no writes.")
        case .gemini: return Text("Gemini chat is coming in v0.9.")
        }
    }

    @ViewBuilder
    private func messageRow(_ item: ChatItem) -> some View {
        switch item {
        case .message(let m):
            chatMessageRow(m)
        case .toolRun(_, let pairs):
            toolRunRow(pairs)
        }
    }

    @ViewBuilder
    private func chatMessageRow(_ m: ChatMessage) -> some View {
        switch m.kind {
        case .userText:
            HStack {
                Spacer(minLength: 36)
                Text(m.body)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistantText:
            HStack(alignment: .top, spacing: 8) {
                providerInitial
                Text(m.body)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
        case .toolCall, .toolResult:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    if !m.title.isEmpty {
                        Text(m.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(m.body)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
        case .meta:
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(m.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func toolRunRow(_ pairs: [ToolPair]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("Ran \(pairs.count) command\(pairs.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var providerInitial: some View {
        let letter: String = {
            switch session.agent {
            case .claude: return "C"
            case .codex:  return "X"
            case .gemini: return "G"
            }
        }()
        return Text(letter)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 20, height: 20)
            .background(Color.secondary.opacity(0.2), in: Circle())
            .foregroundStyle(.primary)
            .padding(.top, 2)
    }
}

/// v0.8 QA F5: iOS counterpart of the Mac `PermissionPromptCard`. Reads
/// the pending permission prompt off the WS-streamed snapshot, renders
/// it as a floating bottom tray with option rows, and POSTs the user's
/// choice through `AgentControlClient.respondToPermissionPrompt`. Same
/// "never auto-dismiss, no skip" semantics as the Mac surface.
@available(iOS 16, *)
struct iOSPermissionPromptCard: View {
    @ObservedObject var store: iOSChatStore
    let sessionId: UUID
    @ObservedObject var client: AgentControlClient

    @State private var isResponding: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        if let prompt = store.snapshot.pendingPermissionPrompt {
            VStack(spacing: 0) {
                // Header row: chip + title
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(prompt.header)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.18), in: Capsule())
                    Text(prompt.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if isResponding {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

                if let detail = prompt.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                // Option rows
                VStack(spacing: 1) {
                    ForEach(Array(prompt.options.enumerated()), id: \.element.id) { idx, option in
                        Button(action: { respond(promptId: prompt.id, optionId: option.id) }) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(option.label)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(option.isDestructive ? Color.red : Color.primary)
                                        if option.isRecommended {
                                            Text("recommended")
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(.secondary.opacity(0.15), in: Capsule())
                                        }
                                    }
                                    if let desc = option.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if idx + 1 <= 9 {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 20)
                                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isResponding)
                    }
                }
                .padding(.bottom, 8)

                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 6)
        }
    }

    private func respond(promptId: String, optionId: String) {
        guard !isResponding else { return }
        isResponding = true
        errorMessage = nil
        Task {
            await client.respondToPermissionPrompt(
                sessionId: sessionId,
                promptId: promptId,
                optionId: optionId
            )
            await MainActor.run { isResponding = false }
        }
    }
}
