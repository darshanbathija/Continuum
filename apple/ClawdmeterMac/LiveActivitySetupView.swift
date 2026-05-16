import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sessions v2 Phase 10 wizard. One-time setup that ingests a .p8 APNS
/// auth-key file, takes the Team ID + Key ID + iOS bundle ID, stores
/// the .p8 PEM in the macOS Keychain, and deletes the source file from
/// disk (D9 — Keychain custody is the load-bearing mitigation).
///
/// Lives inside the Settings → Live Activities panel. The Settings
/// shell calls this view's body; the actual save runs on tap.
struct LiveActivitySetupView: View {
    @State private var p8SourceURL: URL?
    @State private var p8PreviewSummary: String = ""
    @State private var keyId: String = ""
    @State private var teamId: String = ""
    @State private var bundleId: String = "com.clawdmeter.iOS"
    @State private var environment: APNSCredentialStore.Environment = .sandbox

    @State private var statusMessage: String?
    @State private var isError: Bool = false
    @State private var isConfigured: Bool = APNSCredentialStore.shared.isConfigured

    var body: some View {
        Form {
            Section {
                Text("APNS credentials let the Mac daemon push aggregate Live Activity updates to iOS even when the iPhone is in your pocket. Without them, the Lock Screen pill only refreshes when the iOS app is foregrounded or BGAppRefreshTask fires.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Auth Key (.p8)") {
                HStack {
                    Text(p8SourceURL?.lastPathComponent ?? "No file selected")
                        .font(.callout.monospaced())
                        .foregroundStyle(p8SourceURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose .p8…") { chooseP8File() }
                        .buttonStyle(.bordered)
                }
                if !p8PreviewSummary.isEmpty {
                    Text(p8PreviewSummary)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Text("Get this from Apple Developer → Keys → APNs Authentication Key. The file is deleted from disk after we copy it into Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Identifiers") {
                TextField("Key ID (10 chars)", text: $keyId)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("Team ID (10 chars)", text: $teamId)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("iOS Bundle ID", text: $bundleId)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Picker("APNS environment", selection: $environment) {
                    Text("Sandbox (TestFlight / dev)")
                        .tag(APNSCredentialStore.Environment.sandbox)
                    Text("Production (App Store / DMG)")
                        .tag(APNSCredentialStore.Environment.production)
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack {
                    Button(isConfigured ? "Update credentials" : "Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    if isConfigured {
                        Button("Remove credentials", role: .destructive) {
                            APNSCredentialStore.shared.clear()
                            isConfigured = false
                            statusMessage = "Cleared."
                            isError = false
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    if isConfigured {
                        Label("Configured", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout.weight(.medium))
                    }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(isError ? .red : .green)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
        .onAppear { refreshStatus() }
    }

    private var canSave: Bool {
        p8SourceURL != nil
            && keyId.count == 10
            && teamId.count == 10
            && !bundleId.isEmpty
    }

    private func chooseP8File() {
        let panel = NSOpenPanel()
        panel.title = "Choose APNS Auth Key (.p8)"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "p8") ?? UTType.data
        ]
        if panel.runModal() == .OK, let url = panel.url {
            p8SourceURL = url
            // Show a small preview so the user can see they picked the
            // right file (PEM header + first line of base64).
            if let body = try? String(contentsOf: url, encoding: .utf8) {
                let lines = body.split(separator: "\n").prefix(2)
                p8PreviewSummary = lines.joined(separator: " · ")
            }
        }
    }

    private func save() {
        guard let sourceURL = p8SourceURL else { return }
        statusMessage = nil
        do {
            let pem = try String(contentsOf: sourceURL, encoding: .utf8)
            try APNSCredentialStore.shared.save(
                p8Pem: pem,
                keyId: keyId.trimmingCharacters(in: .whitespacesAndNewlines),
                teamId: teamId.trimmingCharacters(in: .whitespacesAndNewlines),
                bundleId: bundleId.trimmingCharacters(in: .whitespacesAndNewlines),
                environment: environment
            )
            // Delete the source file off disk — Keychain is now the
            // single custodian (D9).
            try? FileManager.default.removeItem(at: sourceURL)
            isConfigured = true
            statusMessage = "Saved. Source .p8 file removed from disk."
            isError = false
            p8SourceURL = nil
            p8PreviewSummary = ""
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            isError = true
        }
    }

    private func refreshStatus() {
        isConfigured = APNSCredentialStore.shared.isConfigured
        if isConfigured, let creds = try? APNSCredentialStore.shared.load() {
            keyId = creds.keyId
            teamId = creds.teamId
            bundleId = creds.bundleId
            environment = creds.environment
        }
    }
}
