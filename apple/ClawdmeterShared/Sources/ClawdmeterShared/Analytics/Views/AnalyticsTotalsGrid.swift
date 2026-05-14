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
            // Header
            GridRow {
                Text("")
                Text("Claude")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text("Codex")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
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
