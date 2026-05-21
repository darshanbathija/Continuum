import SwiftUI
import ClawdmeterShared

/// Sheet for "+ New Chat" — pick provider + model + (for Codex) backend.
/// POSTs to `/chat-sessions` and calls `onCreated` with the new session.
///
/// v0.8 IA: 3 provider rows; Gemini row is disabled with "Coming with
/// Antigravity" footer until the agy replacement lands in v0.9. Codex
/// row carries a backend picker (SDK / CLI) per RE1; default SDK.
@available(iOS 16, *)
struct iOSChatProviderPicker: View {
    @ObservedObject var client: AgentControlClient
    let providers: ChatProvidersResponse?
    let onCreated: (AgentSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: AgentKind = .claude
    @State private var selectedModelId: String?
    @State private var selectedCodexBackend: CodexChatBackend = .sdk
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    providerRow(.claude, label: "Claude", subtitle: "Subscription-billed via your Anthropic Pro/Max plan")
                    providerRow(.codex,  label: "Codex",  subtitle: "Subscription-billed via your ChatGPT Plus/Pro plan")
                    geminiRow
                }

                if selectedProvider == .codex {
                    Section {
                        Picker("Backend", selection: $selectedCodexBackend) {
                            Text("SDK (recommended)").tag(CodexChatBackend.sdk)
                            Text("CLI (uniform)").tag(CodexChatBackend.cli)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Codex backend")
                    } footer: {
                        Text(selectedCodexBackend == .sdk
                             ? "Server-side thread via @openai/codex-sdk — typed events, multi-device handoff, no tmux pane."
                             : "Local tmux pane running `codex --sandbox read-only`. Uniform with Claude/Gemini.")
                    }
                }

                Section("Model") {
                    if currentModels.isEmpty {
                        Text("No models available for \(providerLabel(selectedProvider)).")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $selectedModelId) {
                            ForEach(currentModels) { model in
                                Text(model.displayName).tag(Optional(model.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isCreating ? "Starting…" : "Start") { Task { await startChat() } }
                        .disabled(isCreating || selectedProvider == .gemini || selectedModelId == nil)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { syncModelDefault() }
            .onChange(of: selectedProvider) { _, _ in syncModelDefault() }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: AgentKind, label: String, subtitle: String) -> some View {
        Button(action: { selectedProvider = provider }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedProvider == provider {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var geminiRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gemini")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Coming with Antigravity integration")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        }
        .opacity(0.6)
    }

    private var currentModels: [ModelCatalogEntry] {
        switch selectedProvider {
        case .claude: return ModelCatalog.bundled.claude
        case .codex:  return ModelCatalog.bundled.codex
        case .gemini: return ModelCatalog.bundled.gemini
        }
    }

    private func providerLabel(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }

    private func syncModelDefault() {
        selectedModelId = currentModels.first?.id
    }

    private func startChat() async {
        guard let modelId = selectedModelId else { return }
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil
        let session = await client.createChatSession(
            provider: selectedProvider,
            model: modelId,
            codexBackend: selectedProvider == .codex ? selectedCodexBackend : nil
        )
        if let session {
            onCreated(session)
        } else {
            errorMessage = client.lastError ?? "Couldn't create chat. Try again."
        }
    }
}
