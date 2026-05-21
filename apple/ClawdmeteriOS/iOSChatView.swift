import SwiftUI
import ClawdmeterShared

/// Root of the v0.8 Chat tab on iOS. Shows the list of existing chat
/// sessions grouped by provider; tapping a session opens
/// `iOSChatSoloView` with a long-lived `iOSChatStore` subscription.
/// "+ New Chat" toolbar button presents `iOSChatProviderPicker` for
/// provider + model selection.
///
/// Frontier compare deferred to v0.9 alongside the Antigravity (agy)
/// replacement for the gemini CLI. v0.8 ships Solo Chat for Claude +
/// Codex (SDK default, CLI fallback per RE1). Gemini sidebar row is
/// disabled with "Coming with Antigravity" footer.
@available(iOS 16, *)
struct iOSChatView: View {
    @ObservedObject var client: AgentControlClient

    @State private var showingNewChatPicker: Bool = false
    @State private var providers: ChatProvidersResponse?
    @State private var openSessionId: UUID?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { showingNewChatPicker = true }) {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New chat")
                        .disabled(!supportsChat)
                    }
                }
                .sheet(isPresented: $showingNewChatPicker) {
                    iOSChatProviderPicker(
                        client: client,
                        providers: providers,
                        onCreated: { session in
                            openSessionId = session.id
                            showingNewChatPicker = false
                        }
                    )
                }
                .navigationDestination(item: $openSessionId) { id in
                    if let session = client.chatSessions.first(where: { $0.id == id }) {
                        iOSChatSoloView(session: session, client: client)
                    } else {
                        ContentUnavailableView(
                            "Chat not found",
                            systemImage: "exclamationmark.bubble",
                            description: Text("It may have been deleted on the Mac.")
                        )
                    }
                }
                .task {
                    await client.refreshAll()
                    providers = await client.fetchChatProviders()
                }
                .refreshable {
                    await client.refreshAll()
                    providers = await client.fetchChatProviders()
                }
        }
    }

    /// True when the paired Mac is wire v9+ (supports the Chat tab
    /// endpoints). Older Macs see a "Update Clawdmeter on Mac" banner.
    private var supportsChat: Bool {
        AgentControlWireVersion.supportsChat(serverWireVersion: client.serverWireVersion)
    }

    @ViewBuilder
    private var content: some View {
        if !client.isConfigured {
            ContentUnavailableView(
                "Pair with your Mac",
                systemImage: "macbook.and.iphone",
                description: Text("Open Clawdmeter on your Mac and tap Sync with iPhone, then scan the QR code.")
            )
        } else if !supportsChat {
            ContentUnavailableView(
                "Update Clawdmeter on Mac",
                systemImage: "arrow.up.circle",
                description: Text("The Chat tab needs Clawdmeter v0.8 or later on the paired Mac.")
            )
        } else {
            chatList
        }
    }

    @ViewBuilder
    private var chatList: some View {
        if client.chatSessions.isEmpty {
            ContentUnavailableView {
                Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Tap the compose icon above to start a chat with Claude or Codex.")
            } actions: {
                Button("New chat") { showingNewChatPicker = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(groupedSessions, id: \.provider) { group in
                    Section(header: Text(providerLabel(group.provider))) {
                        ForEach(group.sessions) { session in
                            Button(action: { openSessionId = session.id }) {
                                ChatSessionRow(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            Task {
                                for idx in offsets {
                                    let id = group.sessions[idx].id
                                    await client.deleteSession(id: id)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private struct ProviderGroup {
        let provider: AgentKind
        let sessions: [AgentSession]
    }

    private var groupedSessions: [ProviderGroup] {
        let groups = Dictionary(grouping: client.chatSessions, by: { $0.agent })
        // Stable provider order: Claude → Codex → Gemini.
        let order: [AgentKind] = [.claude, .codex, .gemini]
        return order.compactMap { agent in
            guard let sessions = groups[agent], !sessions.isEmpty else { return nil }
            let sorted = sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt })
            return ProviderGroup(provider: agent, sessions: sorted)
        }
    }

    private func providerLabel(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }
}

@available(iOS 16, *)
private struct ChatSessionRow: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayLabel)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                if let model = session.model, !model.isEmpty {
                    Text(model)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if session.agent == .codex, let backend = session.codexChatBackend {
                    Text("·").foregroundStyle(.tertiary)
                    Text(backend == .sdk ? "SDK" : "CLI")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.lastEventAt, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
