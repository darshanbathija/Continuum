import SwiftUI
import ClawdmeterShared

/// Settings tab listing all configured providers with connection status.
/// Insertion-point for future per-provider config (e.g., OpenRouter API key
/// in v0.7) — today it surfaces Claude (Keychain mirror state), Codex (CLI
/// auth file presence), and Gemini (CLI OAuth file + expiry detection).
struct ProvidersSettingsView: View {
    @ObservedObject var claudeModel: AppModel
    @ObservedObject var codexModel: AppModel
    @ObservedObject var geminiModel: AppModel

    var body: some View {
        Form {
            Section {
                providerRow(
                    title: claudeModel.config.displayName,
                    asset: claudeModel.config.logoAssetName,
                    isConnected: claudeModel.usage != nil,
                    detailLabel: claudeStatusLabel,
                    actionTitle: "Force poll",
                    action: { claudeModel.forcePoll() }
                )
            } header: {
                Text("Claude")
            } footer: {
                Text("Reads Claude Code's OAuth token from your Keychain (service: \"Claude Code-credentials\"). Mirrored into iCloud Keychain so the iPhone + Watch apps pick up the same token automatically.")
                    .font(.caption)
            }

            Section {
                providerRow(
                    title: codexModel.config.displayName,
                    asset: codexModel.config.logoAssetName,
                    isConnected: codexModel.usage != nil,
                    detailLabel: codexStatusLabel,
                    actionTitle: "Force poll",
                    action: { codexModel.forcePoll() }
                )
            } header: {
                Text("Codex")
            } footer: {
                Text("Reads the Codex CLI's auth file at ~/.codex/auth.json plus the live wham/usage endpoint. Run `codex` once if not detected.")
                    .font(.caption)
            }

            Section {
                providerRow(
                    title: geminiModel.config.displayName,
                    asset: geminiModel.config.logoAssetName,
                    isConnected: geminiModel.usage != nil,
                    detailLabel: geminiStatusLabel,
                    actionTitle: "Force poll",
                    action: { geminiModel.forcePoll() }
                )

                if geminiNeedsReauth {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Token expired")
                                .font(.subheadline.weight(.semibold))
                            Text("Run `gemini auth login` in a terminal, then click Force poll above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Copy command") {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString("gemini auth login", forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Gemini")
            } footer: {
                Text("Reads the Gemini CLI's OAuth token at ~/.gemini/oauth_creds.json and polls Google's Cloud Code Assist API (the same endpoint Antigravity uses for its 5h-window quota bars). Install the CLI from gemini.google.com if not detected.")
                    .font(.caption)
            }

            Section {
                Text("More providers (OpenRouter, custom endpoints) ship in a follow-up branch. See the v0.7 entries in TODOS.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Coming soon")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
    }

    // MARK: - Provider row

    @ViewBuilder
    private func providerRow(
        title: String,
        asset: String,
        isConnected: Bool,
        detailLabel: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            ProviderBadgeImage(assetName: asset, isTemplate: MenuBarGaugeView.isTemplateAsset(asset), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(detailLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(isConnected ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(isConnected ? "Connected" : "Not detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Per-provider status labels

    private var claudeStatusLabel: String {
        guard let usage = claudeModel.usage else { return "Claude Code not detected" }
        return "Session \(usage.sessionPct)% · Weekly \(usage.weeklyPct)%"
    }

    private var codexStatusLabel: String {
        guard let usage = codexModel.usage else { return "Codex CLI not detected" }
        return "Session \(usage.sessionPct)% · Weekly \(usage.weeklyPct)%"
    }

    private var geminiStatusLabel: String {
        if geminiNeedsReauth { return "Token expired — re-run `gemini auth login`" }
        guard let usage = geminiModel.usage else { return "Gemini CLI not detected (~/.gemini/oauth_creds.json)" }
        return "Session \(usage.sessionPct)% (5h refresh)"
    }

    /// Reads the Gemini token provider's expiry state via the AppModel's
    /// `needsReauth` flag (set by the poller when the source surfaces
    /// `.unauthenticated`). On stale-token, the D4 UX surfaces both here
    /// in Settings and inline in the dashboard column.
    private var geminiNeedsReauth: Bool {
        geminiModel.needsReauth
    }
}
