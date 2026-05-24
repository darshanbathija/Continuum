#if !os(watchOS) && canImport(SwiftUI)
import SwiftUI

/// The provider-keyed totals grid shown on both Mac and iOS. Iterates
/// `snapshot.byProvider` so the column count tracks providers — 2 cells
/// (Claude + Codex) pre-Gemini, 3 cells (Claude + Codex + Gemini) post-v6.
///
/// **Cell renderer split** (Codex P0(3) / Section 2 nit): providers with
/// per-request cost telemetry (Claude/Codex) render `$X.YZ` primary +
/// `N tok` subscript. Providers without token-level telemetry (Gemini —
/// cloudcode-pa quota endpoint exposes request counts but not tokens)
/// render `N reqs` primary, NO subscript (do not emit "0 tok" — it's
/// misleading). Empty cells (provider keyed but window has no activity)
/// render nothing.
@available(macOS 13, iOS 16, *)
public struct AnalyticsTotalsGrid: View {

    public let snapshot: UsageHistorySnapshot
    public let isLoading: Bool

    public init(snapshot: UsageHistorySnapshot, isLoading: Bool = false) {
        self.snapshot = snapshot
        self.isLoading = isLoading
    }

    /// Providers to render, in display order. Claude first, Codex second,
    /// then Gemini. Only includes providers that have a key in the
    /// snapshot's `byProvider` dict (no zero-state empty columns for
    /// providers the user never used). Falls back to the legacy 2-column
    /// view when the snapshot is empty so first-launch users see a
    /// familiar shape.
    private var visibleProviders: [UsageRecord.Provider] {
        let order: [UsageRecord.Provider] = [.claude, .codex, .gemini, .opencode, .cursor]
        let active = order.filter { snapshot.byProvider[$0] != nil }
        return active.isEmpty ? [.claude, .codex] : active
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
            // Header — provider logo + name per visible column.
            GridRow {
                Text("")
                ForEach(visibleProviders, id: \.self) { provider in
                    providerHeader(provider)
                        .gridColumnAlignment(.trailing)
                }
            }

            ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { window in
                GridRow {
                    Text(window.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    ForEach(visibleProviders, id: \.self) { provider in
                        cell(provider: provider, window: snapshot.totals(for: provider).window(window))
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    /// Header label: small logo + provider name. Matches existing pattern.
    @ViewBuilder
    private func providerHeader(_ provider: UsageRecord.Provider) -> some View {
        HStack(spacing: 5) {
            ProviderBadgeImage(
                assetName: Self.logoAsset(for: provider),
                isTemplate: Self.isTemplateAsset(for: provider),
                size: 14
            )
            Text(Self.displayName(for: provider))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Per-cell renderer. Picks cost vs request-count display by which
    /// metric is non-zero. Providers with both ($ and reqs) prefer cost.
    @ViewBuilder
    private func cell(provider: UsageRecord.Provider, window: WindowTotals) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if window.totals.costUSD > 0 {
                Text(AnalyticsCurrencyFormatter.format(window.totals.costUSD))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .redacted(reason: isLoading ? .placeholder : [])
                Text(AnalyticsTokenFormatter.format(window.totals.totalTokens) + " tok")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .redacted(reason: isLoading ? .placeholder : [])
            } else if window.totals.requestCount > 0 {
                // Gemini: per-request count, no token subscript.
                Text("\(window.totals.requestCount) reqs")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .redacted(reason: isLoading ? .placeholder : [])
            } else {
                Text("—")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Provider metadata helpers

    private static func displayName(for provider: UsageRecord.Provider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        }
    }

    private static func logoAsset(for provider: UsageRecord.Provider) -> String {
        switch provider {
        case .claude: return "ClaudeLogo"
        case .codex:  return "CodexLogo"
        case .gemini: return "GeminiLogo"
        case .opencode: return "OpencodeLogo"
        case .cursor: return "CodexLogo"
        }
    }

    private static func isTemplateAsset(for provider: UsageRecord.Provider) -> Bool {
        // Both Codex (silhouette) and Gemini (G mark) are template assets;
        // Claude (terra-cotta burst) keeps its color. OpenCode is a
        // silhouette too — template-tints with the violet accent.
        switch provider {
        case .claude: return false
        case .codex:  return true
        case .gemini: return true
        case .opencode: return true
        case .cursor: return true
        }
    }
}
#endif
