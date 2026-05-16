#if !os(watchOS)
import SwiftUI

/// The 5 × 3 totals grid shown on both Mac and iOS. Header row carries
/// provider names; the four data rows are the time windows.
///
/// Plan A5 + A16: $ is the primary cell text using adaptive precision;
/// tokens appear as a `.secondary` sub-line in compact-name notation.
@available(macOS 13, iOS 16, *)
public struct AnalyticsTotalsGrid: View {

    public let snapshot: UsageHistorySnapshot
    public let isLoading: Bool

    public init(snapshot: UsageHistorySnapshot, isLoading: Bool = false) {
        self.snapshot = snapshot
        self.isLoading = isLoading
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
            // Header — provider logo + name, matching the Live tab's
            // ClaudeSection / CodexSection treatment so users get the
            // same visual anchor for "which column is which" across
            // every screen that splits by provider.
            GridRow {
                Text("")
                providerHeader(
                    name: "Claude",
                    asset: "ClaudeLogo",
                    isTemplate: false
                )
                .gridColumnAlignment(.trailing)
                providerHeader(
                    name: "Codex",
                    asset: "CodexLogo",
                    isTemplate: true
                )
                .gridColumnAlignment(.trailing)
            }

            ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { window in
                GridRow {
                    Text(window.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    cell(for: snapshot.claude.window(window))
                        .gridColumnAlignment(.trailing)
                    cell(for: snapshot.codex.window(window))
                        .gridColumnAlignment(.trailing)
                }
            }
        }
    }

    /// Header label: small logo on the left, provider name on the right.
    /// Codex's silhouette is a flat black PNG on a transparent canvas, so
    /// we mark it `.template` and let SwiftUI tint it with the surrounding
    /// `.secondary` foreground style — otherwise it disappears on dark
    /// backgrounds. Claude's burst keeps its full terra-cotta color.
    @ViewBuilder
    private func providerHeader(name: String, asset: String, isTemplate: Bool) -> some View {
        HStack(spacing: 5) {
            ProviderBadgeImage(assetName: asset, isTemplate: isTemplate, size: 14)
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cell(for window: WindowTotals) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
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
        }
    }
}
#endif
