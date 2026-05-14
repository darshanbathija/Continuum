import SwiftUI
import ClawdmeterShared

/// Token paste + sign-out. Surfaced as a sheet from the main screen's gear
/// button. No theme picker yet — the iPhone honors the system theme.
struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.dismiss) private var dismiss

    @State private var tokenDraft: String = ""
    @State private var showingClearConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.tokenProvider.hasToken {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected")
                            Spacer()
                            Button("Sign out") {
                                showingClearConfirm = true
                            }
                            .foregroundStyle(.red)
                        }
                    } else {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Anthropic token")
                } footer: {
                    Text("Stored in iCloud Keychain. The Mac app writes here automatically when it has a token; the iPhone and Watch read from the same entry. Never sent anywhere else.")
                }

                Section {
                    TextField("sk-ant-oat01-…", text: $tokenDraft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3, reservesSpace: true)
                        .font(.system(.body, design: .monospaced))

                    Button("Save token") {
                        let trimmed = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        model.setToken(trimmed)
                        tokenDraft = ""
                        dismiss()
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text(model.tokenProvider.hasToken ? "Replace token" : "Paste token (fallback)")
                } footer: {
                    Text("Only needed if iCloud Keychain sync isn't an option. Open Keychain Access on a Mac with Claude Code installed, find “Claude Code-credentials,” reveal the password, and copy the `accessToken` value (starts with `sk-ant-oat01-…`).")
                }

                Section {
                    Text("Clawdmeter polls the Anthropic API every 60 seconds while the app is open. We never store or send your usage values anywhere else.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Sign out?", isPresented: $showingClearConfirm) {
                Button("Sign out", role: .destructive) {
                    model.setToken("")
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your token will be removed from this device.")
            }
        }
    }
}
