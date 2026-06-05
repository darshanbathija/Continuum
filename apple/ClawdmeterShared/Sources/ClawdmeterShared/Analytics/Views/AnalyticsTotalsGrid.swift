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
        let order: [UsageRecord.Provider] = [.claude, .codex, .gemini, .opencode, .cursor, .grok]
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
        HStack(spacing: 5) {
            TahoeProviderGlyph(provider: Self.tahoeProvider(for: provider), size: 16)
            ProviderDot(Self.tahoeProvider(for: provider), size: 6)
            Text(Self.displayName(for: provider))
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

    // MARK: - Provider metadata helpers

    private static func displayName(for provider: UsageRecord.Provider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Antigravity"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        }
    }

    private static func tahoeProvider(for provider: UsageRecord.Provider) -> TahoeProvider {
        switch provider {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode
        case .cursor: return .cursor
        case .grok: return .grok
        }
    }
}
#endif
