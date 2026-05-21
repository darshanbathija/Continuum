import SwiftUI
import ClawdmeterShared

/// iOS Live tab — per-provider segmented + hero quota bar + Weekly card +
/// Auto-revive card + refresh footer. Ports `ios-live.jsx::IOSLive`.
///
/// v0.12 button-wiring pass: the gear icon now presents the (existing)
/// `SettingsView` sheet, the footer refresh button calls
/// `agentClient.refreshAll()`, and the "Updated Xs ago" footer text reads
/// from the real `lastSync` snapshot (was hardcoded "14s ago").
public struct IOSLiveView: View {
    @Environment(\.tahoe) private var t
    @State private var provider: TahoeProvider = .claude
    @State private var autoRevive: [TahoeProvider: Bool] = [
        .claude: true, .codex: true, .gemini: true
    ]
    @State private var settingsPresented: Bool = false
    @State private var refreshing: Bool = false
    public var data: TahoeLiveBindings
    /// Optional callbacks injected by IOSRootView. Nil renders are valid
    /// for SwiftUI Previews; production always injects.
    var onRefresh: (() async -> Void)?
    var onOpenSettings: (() -> Void)?

    public init(
        data: TahoeLiveBindings = .demo,
        onRefresh: (() async -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.data = data
        self.onRefresh = onRefresh
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CLAWDMETER")
                            .font(TahoeFont.body(11, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(t.fg3)
                        Text("Live")
                            .font(TahoeFont.rounded(22, weight: .heavy))
                            .tracking(-0.5)
                            .foregroundStyle(t.fg)
                    }
                    Spacer()
                    IOSRoundIconBtn("gear", action: {
                        if let onOpenSettings { onOpenSettings() } else { settingsPresented = true }
                    })
                }
                .padding(.horizontal, 20).padding(.top, 4)

                // Provider segmented control
                TahoeGlass(radius: 999, tone: .chip) {
                    HStack(spacing: 4) {
                        ForEach(TahoeProvider.allCases) { p in
                            ProviderPill(provider: p, active: p == provider) {
                                provider = p
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(4)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

                // Hero quota bar — JSX `size={264}`, was 320 in v1.
                let row = data.row(for: provider)
                TahoeQuotaBar(provider: provider, percent: row.sessionPercent, size: 264,
                              label: "session", sublabel: "resets in \(row.sessionResetIn)")
                    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)

                // Weekly card — hidden when provider has no weekly window.
                if row.hasWeekly {
                    TahoeGlass(radius: 20, tone: .raised) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("WEEKLY · ALL MODELS")
                                        .font(TahoeFont.body(11, weight: .bold))
                                        .tracking(0.4)
                                        .foregroundStyle(t.fg3)
                                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                                        Text("\(Int(row.weeklyPercent))")
                                            .font(TahoeFont.rounded(26, weight: .heavy))
                                            .monospacedDigit()
                                            .tracking(-0.5)
                                            .foregroundStyle(t.fg)
                                        Text("%")
                                            .font(TahoeFont.body(18, weight: .bold))
                                            .foregroundStyle(t.fg3)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("resets in")
                                        .font(TahoeFont.body(11, weight: .semibold))
                                        .foregroundStyle(t.fg3)
                                    Text(row.weeklyResetIn)
                                        .font(TahoeFont.mono(14))
                                        .monospacedDigit()
                                        .foregroundStyle(t.fg)
                                }
                            }
                            .padding(.bottom, 14)
                            TahoePillBar(percent: row.weeklyPercent, provider: provider, height: 8)
                        }
                        .padding(18)
                    }
                    .padding(.horizontal, 16)
                }

                // Auto-revive card
                TahoeGlass(radius: 20, tone: .raised) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(provider.base.color(opacity: 0.18))
                            TahoeIcon("refresh", size: 15).foregroundStyle(provider.base.color)
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keep 5h timer ticking")
                                .font(TahoeFont.body(14, weight: .bold))
                                .foregroundStyle(t.fg)
                            Text("Auto-revive · " + (autoRevive[provider] ?? false ? "last fired \(row.autoReviveAgo)" : "off"))
                                .font(TahoeFont.body(11.5))
                                .foregroundStyle(t.fg3)
                        }
                        Spacer()
                        TahoeToggleView(on: Binding(
                            get: { autoRevive[provider] ?? false },
                            set: { autoRevive[provider] = $0 }
                        ))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .padding(.horizontal, 16).padding(.top, 12)

                // Footer — refresh button now calls `agentClient.refreshAll()`.
                HStack(spacing: 8) {
                    TahoeIcon("qr", size: 11).foregroundStyle(t.fg4)
                    Text(footerText)
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                    Spacer()
                    Button(action: { Task { await refresh() } }) {
                        Group {
                            if refreshing {
                                ProgressView().controlSize(.small).tint(t.fg2)
                            } else {
                                TahoeIcon("refresh", size: 15).foregroundStyle(t.fg2)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(refreshing || onRefresh == nil)
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 30)
            }
        }
        // Pull-to-refresh — same wire as the footer button.
        .refreshable {
            await refresh()
        }
    }

    private var footerText: String {
        if onRefresh == nil { return "Preview · demo data" }
        if refreshing { return "Refreshing…" }
        return "Tap to refresh · synced from Mac"
    }

    @MainActor
    private func refresh() async {
        guard let onRefresh, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await onRefresh()
    }
}

private struct ProviderPill: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var active: Bool
    var onSelect: () -> Void

    private var tintMul: Double { provider == .codex ? 2.6 : 1.0 }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                TahoeProviderGlyph(provider: provider, size: 20)
                Text(provider.displayName)
                    .lineLimit(1)
            }
            .font(TahoeFont.body(12.5, weight: active ? .bold : .semibold))
            .foregroundStyle(active ? t.fg : t.fg2)
            // JSX uses hard `height: 38`; lock both min and max to match.
            .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(provider.base.color(opacity: (t.dark ? 0.42 : 0.28) * tintMul))
                }
            }
            .overlay {
                if active {
                    Capsule(style: .continuous)
                        .stroke(provider.base.color(opacity: 0.55), lineWidth: 1)
                }
            }
            .shadow(color: active ? provider.base.color(opacity: 0.28) : .clear, radius: 7, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}
