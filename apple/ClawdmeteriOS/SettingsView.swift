import SwiftUI
import UIKit
import ClawdmeterShared

/// Token paste + sign-out. Surfaced as a sheet from the main screen's gear
/// button. No theme picker yet — the iPhone honors the system theme.
struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.dismiss) private var dismiss

    @State private var tokenDraft: String = ""
    @State private var showingClearConfirm: Bool = false
    @State private var saveError: String?
    /// Mirrors ContentView's `clawdmeter.appearance` AppStorage. Writes
    /// from this Picker propagate through the @AppStorage observer to
    /// the root TabView's `.preferredColorScheme` modifier — the whole
    /// app re-themes the moment the user lifts their finger off the
    /// segmented control.
    @AppStorage("clawdmeter.appearance") private var appearanceRaw: String = AppearanceMode.system.rawValue
    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: appearanceBinding) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemIcon)
                                .tag(mode)
                        }
                    } label: {
                        Label("Theme", systemImage: "paintbrush")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows iOS Settings → Display & Brightness. Light and Dark pin the app regardless of system state.")
                }

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

                    Button(action: pasteFromClipboard) {
                        Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                    }

                    Button("Save token") {
                        let trimmed = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if model.setToken(trimmed) {
                            tokenDraft = ""
                            saveError = nil
                            dismiss()
                        } else {
                            saveError = "Couldn't find an `sk-ant-oat01-…` token in what you pasted. Try copying just the password value from Keychain Access (the JSON starting with `{\"claudeAiOauth\":…`), or the bare token if you have it."
                        }
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let saveError {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(model.tokenProvider.hasToken ? "Replace token" : "Paste token (fallback)")
                } footer: {
                    Text("Only needed if iCloud Keychain sync isn't an option (always the case in the iOS Simulator — its keychain is isolated from the host Mac). On a Mac with Claude Code installed, open Keychain Access, find “Claude Code-credentials,” reveal the password, and copy the `accessToken` value that starts with `sk-ant-oat01-…`. In the Simulator, the host Mac's clipboard is shared — copy on Mac, tap “Paste from clipboard” here.")
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex requires the Mac app")
                                .font(.subheadline.weight(.semibold))
                            Text("The Codex CLI runs locally on your Mac and writes session usage to `~/.codex/sessions/`. We can't read those files from iOS. The macOS app surfaces Codex; an iCloud sync to bring it here is on the roadmap.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Codex")
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
        // SwiftUI sheets capture `preferredColorScheme` at presentation
        // time and don't pick up later changes from the presenter's
        // @AppStorage updates. Applying it here on the sheet's own root
        // makes the active sheet re-theme the instant the user picks a
        // new value from the Theme menu above.
        .preferredColorScheme(
            (AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme
        )
    }

    /// Pull the clipboard contents into the token draft. The iOS Simulator
    /// shares its pasteboard with the host Mac, so a user can `cmd+C` the
    /// `accessToken` from Keychain Access on the Mac and one-tap it into the
    /// Simulator's draft field here.
    private func pasteFromClipboard() {
        guard let s = UIPasteboard.general.string,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        tokenDraft = s
    }
}
