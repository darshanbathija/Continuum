import SwiftUI
import ClawdmeterShared

/// "+ New Chat" sheet on Mac. Provider + model + (for Codex) backend.
/// POSTs to local daemon's `/chat-sessions` via MacComposerSender (rate
/// limit + audit run uniformly with iOS). Gemini row is disabled until
/// the v0.9 Antigravity replacement lands.
@available(macOS 14, *)
struct ChatNewSessionSheet: View {
    @ObservedObject var model: SessionsModel
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: AgentKind = .claude
    @State private var selectedModelId: String?
    @State private var selectedCodexBackend: CodexChatBackend = .sdk
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New chat")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                Text("Provider").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    providerButton(.claude, label: "Claude")
                    providerButton(.codex, label: "Codex")
                    providerButton(.gemini, label: "Gemini", disabled: true)
                }
                if selectedProvider == .codex {
                    Text("Backend").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("", selection: $selectedCodexBackend) {
                        Text("SDK (recommended)").tag(CodexChatBackend.sdk)
                        Text("CLI").tag(CodexChatBackend.cli)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("Model").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: $selectedModelId) {
                    ForEach(currentModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isCreating ? "Starting…" : "Start") {
                    Task { await create() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || selectedProvider == .gemini || selectedModelId == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { syncModel() }
        .onChange(of: selectedProvider) { _, _ in syncModel() }
    }

    @ViewBuilder
    private func providerButton(_ provider: AgentKind, label: String, disabled: Bool = false) -> some View {
        Button(action: { if !disabled { selectedProvider = provider } }) {
            VStack(spacing: 4) {
                Text(label).font(.system(size: 13, weight: .semibold))
                if disabled {
                    Text("v0.9").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                selectedProvider == provider
                ? Color.accentColor.opacity(0.18)
                : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
    }

    private var currentModels: [ModelCatalogEntry] {
        switch selectedProvider {
        case .claude: return ModelCatalog.bundled.claude
        case .codex:  return ModelCatalog.bundled.codex
        case .gemini: return ModelCatalog.bundled.gemini
        }
    }

    private func syncModel() {
        selectedModelId = currentModels.first?.id
    }

    private func create() async {
        guard let modelId = selectedModelId else { return }
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort else {
            errorMessage = "Daemon not running."
            return
        }
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil
        let token = PairingTokenStore.shared.currentToken()
        let req = CreateChatSessionRequest(
            provider: selectedProvider,
            model: modelId,
            codexChatBackend: selectedProvider == .codex ? selectedCodexBackend : nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(req),
              let url = URL(string: "http://127.0.0.1:\(port)/chat-sessions") else {
            errorMessage = "Bad request"
            return
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = body
        urlReq.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: urlReq)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                errorMessage = "Daemon HTTP \(status)"
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(AgentSession.self, from: data)
            await model.refresh()
            onCreated(session.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
