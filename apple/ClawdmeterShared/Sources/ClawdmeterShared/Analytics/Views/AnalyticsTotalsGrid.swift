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

    /// Providers to render, in display order. Missing `enabledProviderIDs`
    /// keeps legacy all-provider behavior for old payloads; an explicit
    /// envelope, including `[]`, is the product-visible provider set.
    static func visibleProviders(for snapshot: UsageHistorySnapshot) -> [UsageRecord.Provider] {
        let candidates: [UsageRecord.Provider]
        if let enabledProviderIDs = snapshot.enabledProviderIDs {
            let enabled = Set(enabledProviderIDs.map { ProviderRegistry.rootProviderID(for: $0) })
            candidates = UsageRecord.Provider.analyticsDisplayOrder.filter {
                enabled.contains(ProviderRegistry.rootProviderID(for: $0.rawValue))
            }
        } else {
            candidates = UsageRecord.Provider.analyticsDisplayOrder
        }

        let active = candidates.filter { snapshot.byProvider[$0] != nil }
        if !active.isEmpty { return active }
        return snapshot.enabledProviderIDs == nil ? [.claude, .codex] : candidates
    }

    private var visibleProviders: [UsageRecord.Provider] {
        Self.visibleProviders(for: snapshot)
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
                        .font(ContinuumFont.body(12, weight: .medium))
                        .foregroundStyle(ContinuumTokens.fg2)

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
        let tahoeProvider = TahoeProvider(analyticsProvider: provider)
        HStack(spacing: 5) {
            TahoeProviderGlyph(provider: tahoeProvider, size: 16)
            ProviderDot(tahoeProvider, size: 6)
            Text(tahoeProvider.displayName)
                .font(ContinuumFont.body(12, weight: .semibold))
                .foregroundStyle(ContinuumTokens.fg2)
        }
    }

    enum CellDisplay: Equatable {
        case cost(primary: String, secondary: String)
        case tokens(String)
        case requests(String)
        case empty
    }

    static func cellDisplay(for totals: TokenTotals) -> CellDisplay {
        if totals.costUSD > 0 {
            return .cost(
                primary: AnalyticsCurrencyFormatter.format(totals.costUSD),
                secondary: AnalyticsTokenFormatter.format(totals.totalTokens) + " tok"
            )
        }
        if totals.totalTokens > 0 {
            return .tokens(AnalyticsTokenFormatter.format(totals.totalTokens) + " tok")
        }
        if totals.requestCount > 0 {
            return .requests("\(totals.requestCount) reqs")
        }
        return .empty
    }

    /// Per-cell renderer. Picks cost, token, then request-count display by
    /// which metric is non-zero. Unpriced token providers (Grok today) must
    /// show token volume rather than collapsing to "1 reqs".
    @ViewBuilder
    private func cell(provider: UsageRecord.Provider, window: WindowTotals) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch Self.cellDisplay(for: window.totals) {
            case .cost(let primary, let secondary):
                Text(primary)
                    .font(ContinuumFont.mono(14, weight: .semibold))
                    .foregroundStyle(ContinuumTokens.fg)
                    .monospacedDigit()
                    .redacted(reason: isLoading ? .placeholder : [])
                Text(secondary)
                    .font(ContinuumFont.mono(10))
                    .foregroundStyle(ContinuumTokens.fg3)
                    .monospacedDigit()
                    .redacted(reason: isLoading ? .placeholder : [])
            case .tokens(let value):
                Text(value)
                    .font(ContinuumFont.mono(14, weight: .semibold))
                    .foregroundStyle(ContinuumTokens.fg)
                    .monospacedDigit()
                    .redacted(reason: isLoading ? .placeholder : [])
            case .requests(let value):
                Text(value)
                    .font(ContinuumFont.mono(14, weight: .semibold))
                    .foregroundStyle(ContinuumTokens.fg)
                    .monospacedDigit()
                    .redacted(reason: isLoading ? .placeholder : [])
            case .empty:
                Text("—")
                    .font(ContinuumFont.mono(14, weight: .semibold))
                    .foregroundStyle(ContinuumTokens.fg3)
            }
        }
    }

}
#endif
