// Settings → Codex tab. Surfaces the v0.7.x Codex SDK observation mode
// toggle + provisioning status + diagnostics + clean-reinstall button.
//
// The toggle UI is the only user-visible surface for `clawdmeter.codex.sdkMode`
// — before v0.7.2 the toggle was functional via UserDefaults but had to
// be flipped via `defaults write`. This view makes it actually
// discoverable.
//
// Flow on toggle ON:
//   1. Set isProvisioning = true; progressMessage = "Starting…"
//   2. Call CodexSDKManager.shared.enableSDKMode(progress:) with a
//      closure that updates progressMessage on each step.
//   3. On success: enabled = true, dismiss progress, clear error.
//   4. On failure: enabled = false, dismiss progress, surface the error
//      via lastProvisioningError (rendered as a soft-red banner).
//
// Flow on toggle OFF: synchronous call to disableSDKMode(). Keeps the
// AppSupport install on disk for fast re-enable.
//
// "Wipe SDK install" action: confirms then calls wipeProvisionedState()
// — useful after a Node major version upgrade or a corrupt install.

import SwiftUI
import ClawdmeterShared

public struct CodexSDKSettingsView: View {

    @AppStorage("clawdmeter.codex.sdkMode") private var sdkModeEnabled: Bool = false
    @State private var isProvisioning: Bool = false
    @State private var progressMessage: String = ""
    @State private var lastError: String?
    @State private var provisionedVersion: String?
    @State private var isProvisioned: Bool = false
    @State private var showWipeConfirm: Bool = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                toggleRow
                if isProvisioning { provisioningRow }
                if let error = lastError, !error.isEmpty { errorBanner(error) }
                Divider()
                statusGrid
                Divider()
                actionsRow
                Divider()
                authNote
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { refreshState() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Codex SDK")
                .font(.title2.bold())
            Text("Real-time observation via @openai/codex-sdk. Streams agent messages, reasoning, tool calls, and token usage. Draws against your ChatGPT subscription quota — no per-token API billing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toggleRow: some View {
        Toggle(isOn: Binding(
            get: { sdkModeEnabled },
            set: { newValue in handleToggle(newValue: newValue) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable SDK mode")
                    .font(.body.weight(.medium))
                Text(sdkModeEnabled
                     ? "Active — Codex sessions stream events live."
                     : "Off — Codex sessions use disk-mode JSONL tail polling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .disabled(isProvisioning)
    }

    private var provisioningRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(progressMessage.isEmpty ? "Working…" : progressMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Provisioning failed").font(.callout.weight(.medium))
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
    }

    private var statusGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Mode").foregroundStyle(.secondary).font(.caption)
                    Text(sdkModeEnabled ? "SDK mode" : "Disk mode")
                        .font(.caption.monospaced())
                }
                GridRow {
                    Text("Provisioned").foregroundStyle(.secondary).font(.caption)
                    Text(isProvisioned ? "Yes" : "No")
                        .font(.caption.monospaced())
                        .foregroundStyle(isProvisioned ? .green : .secondary)
                }
                if let version = provisionedVersion, !version.isEmpty {
                    GridRow {
                        Text("SDK version").foregroundStyle(.secondary).font(.caption)
                        Text(version).font(.caption.monospaced())
                    }
                }
                GridRow {
                    Text("Install path").foregroundStyle(.secondary).font(.caption)
                    Text(CodexSDKManager.shared.appSupportDir().path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
            }
        }
    }

    private var actionsRow: some View {
        HStack {
            Button("Open install folder") {
                let dir = CodexSDKManager.shared.appSupportDir()
                if FileManager.default.fileExists(atPath: dir.path) {
                    NSWorkspace.shared.open(dir)
                } else {
                    NSWorkspace.shared.open(dir.deletingLastPathComponent())
                }
            }
            .disabled(!isProvisioned)

            Spacer()

            Button("Wipe SDK install", role: .destructive) {
                showWipeConfirm = true
            }
            .disabled(!isProvisioned || isProvisioning)
            .confirmationDialog(
                "Wipe Codex SDK install?",
                isPresented: $showWipeConfirm,
                titleVisibility: .visible
            ) {
                Button("Wipe", role: .destructive) {
                    do {
                        try CodexSDKManager.shared.wipeProvisionedState()
                        refreshState()
                    } catch {
                        lastError = "Wipe failed: \(error.localizedDescription)"
                    }
                }
                Button("Cancel", role: .cancel) { showWipeConfirm = false }
            } message: {
                Text("Removes ~/Library/Application Support/Clawdmeter/codex-sdk/ entirely. Next toggle ON will re-run `npm install @openai/codex-sdk`.")
            }
        }
    }

    private var authNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("How auth works", systemImage: "key")
                .font(.subheadline.weight(.medium))
            Text("The Codex SDK reads `~/.codex/auth.json` on every startup. When you ran `codex login` and chose the ChatGPT plan path, that file was populated with OAuth tokens (no API key required). The SDK inherits this auth automatically — `thread.runStreamed()` calls draw against your ChatGPT subscription quota, never the per-token API.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func handleToggle(newValue: Bool) {
        if newValue {
            // Toggle ON: provision (if needed) then probe.
            isProvisioning = true
            progressMessage = "Starting…"
            lastError = nil
            Task { @MainActor in
                let result = await CodexSDKManager.shared.enableSDKMode { msg in
                    progressMessage = msg
                }
                isProvisioning = false
                progressMessage = ""
                switch result {
                case .success:
                    sdkModeEnabled = true
                    lastError = nil
                case .failure(let err):
                    sdkModeEnabled = false
                    lastError = err.errorDescription ?? "Unknown error"
                }
                refreshState()
            }
        } else {
            CodexSDKManager.shared.disableSDKMode()
            sdkModeEnabled = false
            refreshState()
        }
    }

    private func refreshState() {
        // The manager owns the canonical state; mirror it into local
        // @State so the view re-renders when the user takes an action.
        isProvisioned = CodexSDKManager.shared.isProvisioned
        provisionedVersion = CodexSDKManager.shared.provisionedSDKVersion
        // Don't clobber an in-progress error message.
        if !isProvisioning {
            lastError = CodexSDKManager.shared.lastProvisioningError
        }
    }
}

#Preview {
    CodexSDKSettingsView()
        .frame(width: 540, height: 480)
}
