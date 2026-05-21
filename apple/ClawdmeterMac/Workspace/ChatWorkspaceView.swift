import SwiftUI
import ClawdmeterShared

/// v0.8 Chat tab on Mac. NavigationSplitView with chat sessions in the
/// sidebar (grouped by provider) and the active chat pane on the right.
/// Pairs the iOS Chat tab — chat sessions live in the same registry +
/// daemon stores, so what iPhone sees is what Mac sees.
///
/// v0.8 minimum-viable surface: list + select + send. Mid-conv model
/// swap, frontier compare UI, and full ComposerInputCore parity follow
/// in v0.8.x polish. Gemini chat is deferred to v0.9 (Antigravity
/// replacement); its sidebar row is disabled with "Coming with
/// Antigravity".
@available(macOS 14, *)
struct ChatWorkspaceView: View {
    @ObservedObject var model: SessionsModel

    @State private var openSessionId: UUID?
    @State private var showingNewChat: Bool = false

    private var chatSessions: [AgentSession] {
        model.registry.sessions
            .filter { $0.kind == .chat && $0.archivedAt == nil }
            .sorted(by: { $0.lastEventAt > $1.lastEventAt })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let openSessionId,
               let session = chatSessions.first(where: { $0.id == openSessionId }) {
                ChatSoloView(session: session, model: model)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showingNewChat) {
            ChatNewSessionSheet(model: model) { sessionId in
                openSessionId = sessionId
                showingNewChat = false
            }
        }
        .onChange(of: model.registry.sessions.count) { _, _ in
            // Force sidebar refresh when registry mutates outside our
            // direct observation (e.g., daemon-side chat-cwd cleanup).
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { showingNewChat = true }) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New chat")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            List(selection: $openSessionId) {
                // v0.8 QA: flat list sorted by recency (chatSessions is
                // already `lastEventAt` desc). Per-provider grouping was
                // making the user scan two sections to find their most
                // recent chat — easier to see them all in chronological
                // order with the provider tag inline on each row.
                ForEach(chatSessions) { session in
                    sessionRow(session)
                        .tag(Optional(session.id))
                }
                Section {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gemini")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("Coming with Antigravity")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .opacity(0.6)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.displayLabel)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 5) {
                // v0.8 QA: provider tag inline on each row, since the
                // sidebar no longer groups by provider.
                Text(providerLabel(session.agent))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.12), in: Capsule())
                if let model = session.model, !model.isEmpty {
                    Text(model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if session.agent == .codex, let backend = session.codexChatBackend {
                    Text("·").foregroundStyle(.tertiary)
                    Text(backend == .sdk ? "SDK" : "CLI")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func providerLabel(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("No chat selected")
                .font(.system(size: 18, weight: .semibold))
            if chatSessions.isEmpty {
                Text("Tap the compose icon to start your first chat.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("New chat") { showingNewChat = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Pick a chat from the sidebar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
