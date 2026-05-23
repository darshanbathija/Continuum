// Settings → Antigravity SDK card content. v0.24 strip-down: one toggle.
//
// Matches the Codex SDK rewrite — every developer-grade affordance
// (StatusPill row with Mode + Backing key, "What changes when SDK mode
// is on" bullet list, "What stays the same" bullet list, duplicate
// inline header) is gone. The customer-facing question is binary: do
// you want live event streaming for Antigravity, yes or no?
//
// Manager API used:
//   - AntigravitySidecarManager.shared.enableSDKMode() — provisions
//     the Python sidecar if needed, persists the UserDefaults flag.
//   - .disableSDKMode() — flips the flag off. Provisioned install
//     stays on disk so re-enable is instant.
//   - .lastProvisioningError — read on appear so a stale failure still
//     surfaces.

import SwiftUI
import ClawdmeterShared

public struct AntigravitySDKSettingsView: View {
    @Environment(\.tahoe) private var t

    @AppStorage("clawdmeter.antigravity.sdkMode")
    private var sdkModeEnabled: Bool = false
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
                    set: { newValue in Task { await applyToggle(newValue) } }
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
            : "Off. Plan view reads the cached brain instead."
    }

    // MARK: - Inline chrome

    private var progressChip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Setting up (first run takes about 15 seconds)…")
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

    private func applyToggle(_ newValue: Bool) async {
        guard !isProvisioning else { return }
        if newValue {
            isProvisioning = true
            defer { isProvisioning = false }
            let result = await AntigravitySidecarManager.shared.enableSDKMode()
            switch result {
            case .success:
                lastError = nil
            case .failure(let err):
                lastError = err.errorDescription ?? "Couldn't turn on live events."
                // Manager reverts the toggle itself; AppStorage re-reads
                // on the next pass.
            }
        } else {
            AntigravitySidecarManager.shared.disableSDKMode()
            lastError = nil
        }
        refreshErrorIfIdle()
    }

    private func refreshErrorIfIdle() {
        guard !isProvisioning else { return }
        lastError = AntigravitySidecarManager.shared.lastProvisioningError
    }
}

#Preview {
    AntigravitySDKSettingsView()
        .padding(20)
        .frame(width: 540)
}
