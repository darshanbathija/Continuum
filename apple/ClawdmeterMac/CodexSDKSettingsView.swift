// Settings → Codex SDK card content. v0.24 strip-down: one toggle.
//
// Everything that was here before (status grid with Mode/Provisioned/
// SDK version/Install path, Open install folder + Wipe SDK install
// buttons, "How auth works" explainer paragraph, duplicate inline
// title) talked to developers, not users. The user-facing question is
// binary: do you want live event streaming for Codex, yes or no?
//
// Manager API used:
//   - CodexSDKManager.shared.enableSDKMode() — provisions if needed,
//     probes the sidecar, persists the UserDefaults flag on success.
//   - .disableSDKMode() — flips the flag off. Provisioned install stays
//     on disk so re-enable is instant. Wipe is no longer surfaced in
//     Settings; users who need it can delete the directory manually.
//   - .lastProvisioningError — read on appear so a failure from a
//     previous launch still shows.

import SwiftUI
import ClawdmeterShared

public struct CodexSDKSettingsView: View {
    @Environment(\.tahoe) private var t

    @AppStorage("clawdmeter.codex.sdkMode") private var sdkModeEnabled: Bool = false
    @State private var isProvisioning: Bool = false
    @State private var lastError: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live events")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(statusLine)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                Spacer()
                TahoeToggleView(on: Binding(
                    get: { sdkModeEnabled },
                    set: { handleToggle($0) }
                ))
                .opacity(isProvisioning ? 0.4 : 1)
                .allowsHitTesting(!isProvisioning)
            }
            if isProvisioning { progressChip }
            if let lastError, !lastError.isEmpty { errorChip(lastError) }
        }
        .onAppear { refreshErrorIfIdle() }
    }

    // MARK: - Status copy

    private var statusLine: String {
        if isProvisioning { return "Setting up…" }
        return sdkModeEnabled
            ? "Streaming live. Token usage updates in real time."
            : "Off. Updates lag a couple of seconds behind the CLI."
    }

    // MARK: - Inline chrome

    private var progressChip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Setting up (first run installs ~25 MB)…")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
        }
    }

    private func errorChip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(TahoeFont.body(12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func handleToggle(_ newValue: Bool) {
        if newValue {
            isProvisioning = true
            lastError = nil
            Task { @MainActor in
                let result = await CodexSDKManager.shared.enableSDKMode()
                isProvisioning = false
                switch result {
                case .success:
                    sdkModeEnabled = true
                case .failure(let err):
                    sdkModeEnabled = false
                    lastError = err.errorDescription ?? "Couldn't turn on live events."
                }
            }
        } else {
            CodexSDKManager.shared.disableSDKMode()
            sdkModeEnabled = false
            lastError = nil
        }
    }

    private func refreshErrorIfIdle() {
        guard !isProvisioning else { return }
        lastError = CodexSDKManager.shared.lastProvisioningError
    }
}

#Preview {
    CodexSDKSettingsView()
        .padding(20)
        .frame(width: 540)
}
