// Settings → Antigravity tab. v0.7.7 surface for the v0.6.0 plan's D3
// SDK-mode toggle. Mirrors `CodexSDKSettingsView` (same shape, different
// backing manager) so the two SDK modes feel symmetric to the user.
//
// Before v0.7.7 the toggle was functional via UserDefaults but had to be
// flipped manually with `defaults write com.clawdmeter.mac
// clawdmeter.antigravity.sdkMode -bool YES`. This view makes it
// discoverable.
//
// Backing store: `clawdmeter.antigravity.sdkMode` UserDefaults bool +
// `AntigravitySidecarManager.shared`.

import SwiftUI
import ClawdmeterShared

public struct AntigravitySDKSettingsView: View {

    @AppStorage("clawdmeter.antigravity.sdkMode")
    private var sdkModeEnabled: Bool = false

    @State private var isProvisioning: Bool = false
    @State private var lastError: String?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                toggleRow
                if isProvisioning { provisioningRow }
                if let lastError, !lastError.isEmpty { errorBanner(lastError) }
                Divider()
                explainerSection
                Divider()
                statusRow
                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { refreshError() }
    }

    // MARK: - Sections

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Antigravity").font(.title2).bold()
            Text("Google Antigravity SDK observation mode for the Gemini provider. Mirrors the Codex SDK toggle pattern. Disk mode (default) reads `~/.gemini/antigravity/` directly; SDK mode runs a `google-antigravity` Python sidecar for live token streaming.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var toggleRow: some View {
        Toggle(isOn: Binding(
            get: { sdkModeEnabled },
            set: { newValue in
                Task { await applyToggle(newValue) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SDK mode (recommended for paid Antigravity users)")
                    .font(.system(size: 13, weight: .medium))
                Text(sdkModeEnabled
                     ? "Active. Sidecar provisioning + observer agents enabled."
                     : "Off. Disk mode reads brain/ directly with zero Python dependency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .disabled(isProvisioning)
    }

    @ViewBuilder private var provisioningRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Provisioning Python sidecar… (~15s on first enable)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var explainerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What changes when SDK mode is on")
                .font(.headline)
            row("Live token streaming via `agent.conversation.total_usage`")
            row("3 helper agents available: session-summarizer, cost-pulse-watcher, repo-context-extractor")
            row("Policy `ask_user(...)` prompts route through Mac inline + iOS APNS")
            Text("What stays the same")
                .font(.headline)
                .padding(.top, 6)
            row("Plan pane (Mac + iOS) — still reads `~/.gemini/antigravity/brain/<uuid>/` plaintext")
            row("Watch task complication — still reads `task.md` first line")
            row("Analytics — still surfaces `gemini-3.5-flash` pricing")
        }
    }

    @ViewBuilder private func row(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 12) {
            StatusPill(label: "Mode",
                       value: sdkModeEnabled ? "SDK" : "Disk",
                       tint: sdkModeEnabled ? .green : .secondary)
            StatusPill(label: "Backing key",
                       value: "clawdmeter.antigravity.sdkMode",
                       tint: .secondary)
            Spacer()
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
                lastError = err.errorDescription
                // toggle is reverted by the manager itself; AppStorage
                // re-reads on the next pass.
            }
        } else {
            AntigravitySidecarManager.shared.disableSDKMode()
            lastError = nil
        }
        refreshError()
    }

    private func refreshError() {
        lastError = AntigravitySidecarManager.shared.lastProvisioningError
    }
}

/// Small chip showing a labeled value. Local to this view; the Codex
/// equivalent has its own variant in `CodexSDKSettingsView`.
private struct StatusPill: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).foregroundStyle(tint).monospaced()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
