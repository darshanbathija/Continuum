import SwiftUI
import AppKit
import ClawdmeterShared
import OSLog

private let apiKeySheetLogger = Logger(subsystem: "com.clawdmeter.mac", category: "OpencodeAPIKeySheet")

/// Native API-key entry sheet for OpenCode providers.
///
/// Replaces the embedded `opencode auth login` terminal pane for the
/// (common) case of pasting an API key — OpenRouter, Anthropic API,
/// OpenAI API, Moonshot, Google AI Studio, Mistral, Groq, xAI, DeepSeek.
/// The terminal sheet (`OpencodeSetupSheet`) remains for OAuth flows
/// that need a browser handoff (Anthropic Pro, GitHub Copilot, ChatGPT
/// OAuth).
///
/// Flow:
///   1. User picks a provider from the curated dropdown (or "Custom…").
///   2. User pastes the key into a `SecureField`.
///   3. Hit Save → `OpencodeAuthFile.shared.setAPIKey(...)` writes
///      `~/.local/share/opencode/auth.json` with file mode 0600.
///   4. `OpencodeProcessManager.shared.reprobe()` triggers the O5
///      auth-aware serve restart so the new provider is live.
///   5. Sheet dismisses, row refreshes.
public struct OpencodeAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Curated list of API-key-capable opencode providers. The
    /// `providerId` strings MUST match opencode's internal provider
    /// registry (these are the keys that show up in `opencode auth list`).
    public enum Provider: String, CaseIterable, Identifiable {
        case openrouter
        case anthropicAPI = "anthropic"
        case openaiAPI = "openai"
        case moonshotai
        case google
        case mistral
        case groq
        case xai
        case deepseek
        case custom

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .openrouter:    return "OpenRouter"
            case .anthropicAPI:  return "Anthropic (API key)"
            case .openaiAPI:     return "OpenAI (API key)"
            case .moonshotai:    return "Moonshot AI"
            case .google:        return "Google AI Studio"
            case .mistral:       return "Mistral"
            case .groq:          return "Groq"
            case .xai:           return "xAI (Grok)"
            case .deepseek:      return "DeepSeek"
            case .custom:        return "Custom provider…"
            }
        }

        /// Provider ID written to auth.json. Nil for `.custom` — the
        /// user supplies it via a text field.
        public var providerId: String? {
            self == .custom ? nil : rawValue
        }

        public var keyHint: String {
            switch self {
            case .openrouter:    return "sk-or-…"
            case .anthropicAPI:  return "sk-ant-…"
            case .openaiAPI:     return "sk-…"
            case .moonshotai:    return "sk-…"
            case .google:        return "AIza…"
            case .mistral:       return "…"
            case .groq:          return "gsk_…"
            case .xai:           return "xai-…"
            case .deepseek:      return "sk-…"
            case .custom:        return "API key"
            }
        }

        public var docsURL: URL? {
            switch self {
            case .openrouter:
                return URL(string: "https://openrouter.ai/keys")
            case .anthropicAPI:
                return URL(string: "https://console.anthropic.com/settings/keys")
            case .openaiAPI:
                return URL(string: "https://platform.openai.com/api-keys")
            case .moonshotai:
                return URL(string: "https://platform.moonshot.ai/console/api-keys")
            case .google:
                return URL(string: "https://aistudio.google.com/apikey")
            case .mistral:
                return URL(string: "https://console.mistral.ai/api-keys/")
            case .groq:
                return URL(string: "https://console.groq.com/keys")
            case .xai:
                return URL(string: "https://console.x.ai/")
            case .deepseek:
                return URL(string: "https://platform.deepseek.com/api_keys")
            case .custom:
                return nil
            }
        }
    }

    @State private var selectedProvider: Provider
    @State private var customProviderId: String = ""
    @State private var apiKey: String = ""
    @State private var showPlainKey: Bool = false
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    /// Called after the credentials file has been updated and the
    /// process manager has reprobed. Row uses this to refresh state.
    private let onCompletion: () -> Void

    public init(
        defaultProvider: Provider = .openrouter,
        onCompletion: @escaping () -> Void = {}
    ) {
        self._selectedProvider = State(initialValue: defaultProvider)
        self.onCompletion = onCompletion
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                form
                    .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520)
        .frame(minHeight: 360)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Add OpenCode API key")
                .font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedProvider) {
                    ForEach(Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if selectedProvider == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider ID")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("e.g. openrouter, perplexity", text: $customProviderId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Use the same ID opencode expects in its provider registry. Case-sensitive.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API key")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showPlainKey.toggle()
                    } label: {
                        Image(systemName: showPlainKey ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showPlainKey ? "Hide key" : "Show key")
                }
                Group {
                    if showPlainKey {
                        TextField("", text: $apiKey, prompt: Text(selectedProvider.keyHint))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                    } else {
                        SecureField("", text: $apiKey, prompt: Text(selectedProvider.keyHint))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Text("Stored at ~/.local/share/opencode/auth.json with file mode 0600. Same location opencode auth login writes to.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let docsURL = selectedProvider.docsURL {
                Button {
                    NSWorkspace.shared.open(docsURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                        Text("Get a \(selectedProvider.displayName) key")
                    }
                    .font(.footnote)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                .font(.callout)
            }
        }
    }

    private var footer: some View {
        HStack {
            if saving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid || saving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Validation + save

    private var isValid: Bool {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if selectedProvider == .custom {
            return !customProviderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func save() {
        saving = true
        errorMessage = nil
        let providerId: String = {
            if let id = selectedProvider.providerId {
                return id
            }
            return customProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let key = apiKey  // do NOT trim — keys CAN contain trailing chars
        let displayName = selectedProvider.displayName
        Task {
            do {
                try await OpencodeAuthFile.shared.setAPIKey(
                    providerId: providerId,
                    key: key
                )
                await OpencodeProcessManager.shared.reprobe()
                await ChatProviderProbe.shared.invalidate()
                apiKeySheetLogger.info(
                    "opencode api key saved provider=\(providerId, privacy: .public) display=\(displayName, privacy: .public)"
                )
                await MainActor.run {
                    saving = false
                    onCompletion()
                    dismiss()
                }
            } catch {
                apiKeySheetLogger.error(
                    "opencode api key save failed: \(error.localizedDescription, privacy: .public)"
                )
                await MainActor.run {
                    saving = false
                    errorMessage = "Couldn't save: \(error.localizedDescription)"
                }
            }
        }
    }
}
