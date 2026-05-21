import SwiftUI
import ClawdmeterShared

/// Mac chat surface — one session's transcript + a basic prompt input.
/// v0.8 minimum-viable; full ComposerInputCore parity (model picker chip,
/// effort chip, attachments) follows in v0.8.x polish. The send path
/// flows through SessionsModel → AgentControlServer's POST /sessions/:id/send
/// handler, which routes SDK chat to CodexSubscriptionRelay and CLI chat
/// to tmux per Phase 4.5 dispatch.
@available(macOS 14, *)
struct ChatSoloView: View {
    let session: AgentSession
    @ObservedObject var model: SessionsModel

    @State private var prompt: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    private var chatStore: SessionChatStore? {
        model.chatStore(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let store = chatStore {
                PermissionPromptCard(store: store, sessionId: session.id)
            }
            Divider()
            composer
        }
        .navigationTitle(session.displayLabel)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(session.displayLabel)
                .font(.system(size: 16, weight: .semibold))
            if let model = session.model, !model.isEmpty {
                Text(model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
            if session.agent == .codex, let backend = session.codexChatBackend {
                Text(backend == .sdk ? "SDK" : "CLI")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(backend == .sdk ? Color.green.opacity(0.15) : Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(backend == .sdk ? .green : .blue)
            }
            Text("plan-mode")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
            Spacer()
            Button(action: { Task { await deleteChat() } }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("End chat")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var transcript: some View {
        if let store = chatStore {
            // v0.8 QA: SessionChatStore is an ObservableObject, but reading
            // it through a computed `var chatStore` doesn't subscribe the
            // view to its @Published snapshot — changes from the daemon's
            // CodexSDKEventIngestor were silently dropped on the UI floor.
            // The TranscriptObservingView wraps the store as @ObservedObject
            // so SwiftUI actually tracks snapshot updates and re-renders
            // when assistant messages stream in.
            TranscriptObservingView(store: store, renderRow: messageRow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading chat…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func messageRow(_ item: ChatItem) -> some View {
        switch item {
        case .message(let m):
            switch m.kind {
            case .userText:
                HStack {
                    Spacer(minLength: 60)
                    Text(m.body)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
            case .assistantText:
                Text(m.body)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .toolCall, .toolResult:
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if !m.title.isEmpty {
                            Text(m.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Text(m.body).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(6)
                    }
                }
            case .meta:
                Text(m.body)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        case .toolRun(_, let pairs):
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Ran \(pairs.count) command\(pairs.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 38, maxHeight: 140)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3), lineWidth: 1))
                    .disabled(isSending)
                Button(action: { Task { await send() } }) {
                    Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.borderless)
                .disabled(isSending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(12)
    }

    /// Send goes through the local daemon's HTTP `/sessions/:id/send`
    /// endpoint via MacComposerSender so SDK chat reaches
    /// CodexSubscriptionRelay and CLI chat reaches tmux through the
    /// same dispatch iOS uses. Routes audit + rate-limit cleanly.
    private func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort else {
            errorMessage = "Daemon not running."
            return
        }
        isSending = true
        defer { isSending = false }
        errorMessage = nil
        let sender = MacComposerSender(
            port: Int(port),
            token: PairingTokenStore.shared.currentToken()
        )
        do {
            try await sender.send(sessionId: session.id, body: text, asFollowUp: false)
            prompt = ""
        } catch MacComposerSender.Error.http(let status, _) {
            errorMessage = "Daemon error \(status)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete via HTTP DELETE /sessions/:id so the daemon runs its full
    /// cleanup path (SDK teardown via teardownSDKChat + chat-cwd removal
    /// via ChatCwdManager).
    private func deleteChat() async {
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort else { return }
        let token = PairingTokenStore.shared.currentToken()
        guard let url = URL(string: "http://127.0.0.1:\(port)/sessions/\(session.id.uuidString)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
        // Local registry mirror catches up via the next refresh.
        await model.refresh()
    }
}

/// v0.8 QA: AskUserQuestion-style card surfacing a CLI permission prompt.
/// Renders when the SessionChatStore has a pending prompt (e.g. Codex's
/// "Trust this directory?"); user clicks an option → POST to daemon →
/// daemon dispatches the corresponding keys to the CLI's TUI → card
/// disappears. Recommended option gets the prominent button style.
@available(macOS 14, *)
struct PermissionPromptCard: View {
    @ObservedObject var store: SessionChatStore
    let sessionId: UUID

    @State private var isResponding: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        if let prompt = store.pendingPermissionPrompt {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(prompt.header)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                    Spacer()
                    if isResponding {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(prompt.title)
                    .font(.system(size: 14, weight: .semibold))
                if let detail = prompt.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    ForEach(prompt.options) { option in
                        Button(action: { respond(promptId: prompt.id, optionId: option.id) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 12, weight: .medium))
                                if let desc = option.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(buttonTint(for: option))
                        .disabled(isResponding)
                    }
                }
                if let err = errorMessage {
                    Text(err).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func buttonTint(for option: PermissionOption) -> Color {
        if option.isDestructive { return .red }
        if option.isRecommended { return .accentColor }
        return .gray
    }

    private func respond(promptId: String, optionId: String) {
        guard !isResponding else { return }
        isResponding = true
        errorMessage = nil
        Task {
            defer { Task { @MainActor in isResponding = false } }
            guard let runtime = AppDelegate.runtime,
                  let port = runtime.agentControlServer.boundPort else {
                await MainActor.run { errorMessage = "Daemon not running." }
                return
            }
            let token = PairingTokenStore.shared.currentToken()
            guard let url = URL(string: "http://127.0.0.1:\(port)/sessions/\(sessionId.uuidString)/permission-respond") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 5
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = PermissionRespondRequest(promptId: promptId, optionId: optionId)
            req.httpBody = try? JSONEncoder().encode(body)
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    await MainActor.run { errorMessage = "Daemon HTTP \(http.statusCode)" }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

/// Holds the `SessionChatStore` as `@ObservedObject` so SwiftUI subscribes
/// to its `@Published snapshot` and re-renders when the daemon's
/// `CodexSDKEventIngestor` writes new messages. Without this wrapper, the
/// parent view reads `store.snapshot` through a plain computed property and
/// SwiftUI never installs a dependency on the store — assistant responses
/// land in the store but the chat thread stays frozen on the user bubble.
@available(macOS 14, *)
private struct TranscriptObservingView<Row: View>: View {
    @ObservedObject var store: SessionChatStore
    let renderRow: (ChatItem) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.snapshot.items) { item in
                        renderRow(item).id(item.id)
                    }
                }
                .padding(.horizontal, 18)
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
