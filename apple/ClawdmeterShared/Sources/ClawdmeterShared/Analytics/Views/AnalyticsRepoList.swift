#if !os(watchOS)
import SwiftUI

/// Per-repo $/% breakdown for the active window. Top 8 + optional "…N more"
/// rollup row. Plan A7 + A17: hover/tap shows the full path on Mac/iOS;
/// footer row surfaces unpriced model tokens.
@available(macOS 13, iOS 16, *)
public struct AnalyticsRepoList: View {

    public let snapshot: UsageHistorySnapshot
    public let window: UsageHistorySnapshot.Window
    public let providerFilter: UsageHistoryStore.ProviderFilter

    public init(
        snapshot: UsageHistorySnapshot,
        window: UsageHistorySnapshot.Window,
        providerFilter: UsageHistoryStore.ProviderFilter
    ) {
        self.snapshot = snapshot
        self.window = window
        self.providerFilter = providerFilter
    }

    /// Merge the two providers' byRepo for the active window, recompute %
    /// share, re-rank, and keep top-8 + rollup. Each row carries BOTH the
    /// combined cost AND the per-provider breakdown so the progress bar
    /// renderer can stack Claude (orange) and Codex (blue) segments,
    /// rather than showing a single solid tint that hides which provider
    /// contributed how much.
    private var rows: [Row] {
        var claudeByRepo: [RepoKey: TokenTotals] = [:]
        var codexByRepo: [RepoKey: TokenTotals] = [:]
        if providerFilter != .codex {
            for row in snapshot.claude.window(window).byRepo where row.repo != "__rest__" {
                claudeByRepo[row.repo, default: .zero] += row.totals
            }
        }
        if providerFilter != .claude {
            for row in snapshot.codex.window(window).byRepo where row.repo != "__rest__" {
                codexByRepo[row.repo, default: .zero] += row.totals
            }
        }

        // Build a combined keyset so a repo that's Codex-only still shows.
        let allRepoKeys = Set(claudeByRepo.keys).union(codexByRepo.keys)
        var combinedByRepo: [RepoKey: (claude: Decimal, codex: Decimal, total: Decimal, tokens: Int)] = [:]
        for key in allRepoKeys {
            let cl = claudeByRepo[key, default: .zero]
            let cx = codexByRepo[key, default: .zero]
            combinedByRepo[key] = (
                claude: cl.costUSD,
                codex: cx.costUSD,
                total: cl.costUSD + cx.costUSD,
                tokens: cl.totalTokens + cx.totalTokens
            )
        }

        let totalCost = combinedByRepo.values.reduce(Decimal.zero, { $0 + $1.total })
        guard totalCost > 0 else { return [] }

        let sorted = combinedByRepo.sorted { $0.value.total > $1.value.total }
        let top = Array(sorted.prefix(8))
        let rest = Array(sorted.dropFirst(8))

        var out: [Row] = top.map { (key, value) in
            Row(
                id: key,
                repo: key,
                displayName: RepoIdentity.displayName(for: key),
                cost: value.total,
                claudeCost: value.claude,
                codexCost: value.codex,
                tokens: value.tokens,
                share: NSDecimalNumber(decimal: value.total / totalCost).doubleValue,
                isRest: false,
                restCount: 0
            )
        }
        if !rest.isEmpty {
            let restClaude = rest.map(\.value.claude).reduce(Decimal.zero, +)
            let restCodex = rest.map(\.value.codex).reduce(Decimal.zero, +)
            let restCost = restClaude + restCodex
            let restTokens = rest.map(\.value.tokens).reduce(0, +)
            out.append(Row(
                id: "__rest__",
                repo: "__rest__",
                displayName: "…\(rest.count) more",
                cost: restCost,
                claudeCost: restClaude,
                codexCost: restCodex,
                tokens: restTokens,
                share: NSDecimalNumber(decimal: restCost / totalCost).doubleValue,
                isRest: true,
                restCount: rest.count
            ))
        }
        return out
    }

    public var body: some View {
        let data = rows
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("By repo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("$").font(.caption).foregroundStyle(.secondary)
                Text("Share").font(.caption).foregroundStyle(.secondary)
            }

            if data.isEmpty {
                Text("No usage in this window")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(data) { row in
                    RepoRow(row: row)
                }
            }

            if !snapshot.unpricedModelTokens.isEmpty {
                let totalUnpricedTokens = snapshot.unpricedModelTokens.values.map(\.totalTokens).reduce(0, +)
                Text("\(AnalyticsTokenFormatter.format(totalUnpricedTokens)) tokens against \(snapshot.unpricedModelTokens.count) unpriced model\(snapshot.unpricedModelTokens.count == 1 ? "" : "s") — update pricing.json")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    struct Row: Identifiable {
        let id: String
        let repo: RepoKey
        let displayName: String
        let cost: Decimal
        /// Claude's contribution to this repo's cost. Used to draw the
        /// orange (Claude) segment of the stacked progress bar.
        let claudeCost: Decimal
        /// Codex's contribution to this repo's cost. Used to draw the
        /// blue (Codex) segment of the stacked progress bar — without
        /// this, a Codex-heavy repo would render as solid orange and
        /// the user couldn't see Codex's share.
        let codexCost: Decimal
        let tokens: Int
        let share: Double
        let isRest: Bool
        let restCount: Int
    }
}

@available(macOS 13, iOS 16, *)
private struct RepoRow: View {
    let row: AnalyticsRepoList.Row
    @State private var expanded = false

    /// Claude's share of THIS repo's cost (not the whole window).
    private var claudeShare: Double {
        guard row.cost > 0 else { return 0 }
        return NSDecimalNumber(decimal: row.claudeCost / row.cost).doubleValue
    }
    private var codexShare: Double {
        guard row.cost > 0 else { return 0 }
        return NSDecimalNumber(decimal: row.codexCost / row.cost).doubleValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(AnalyticsCurrencyFormatter.format(row.cost))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(percentString(row.share))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            // Stacked progress bar — Claude (terra-cotta) below, Codex
            // (accent blue) on top. The widths sum to `row.share` of
            // the total window cost. Without this split, a Codex-heavy
            // repo looked identical to a Claude-heavy one in the UI.
            providerSegmentedBar
                .frame(height: 6)
                .clipShape(Capsule())

            if expanded && !row.isRest {
                Text(row.repo)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
#if os(macOS)
        .help(providerBreakdownTooltip)
#else
        .onTapGesture {
            if !row.isRest { withAnimation(.snappy) { expanded.toggle() } }
        }
#endif
    }

    private var providerSegmentedBar: some View {
        // We size each segment by its share of the TOTAL window cost so
        // bars across rows are comparable. Inside a row the segments
        // sum to `row.share`; the remaining width is the unused track.
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let claudeWidth = totalWidth * claudeShare * row.share
            let codexWidth = totalWidth * codexShare * row.share
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(claudeColor)
                        .frame(width: claudeWidth)
                    Rectangle()
                        .fill(codexColor)
                        .frame(width: codexWidth)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var claudeColor: Color {
        Color(red: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255)
    }
    private var codexColor: Color {
        Color.accentColor
    }

    private var providerBreakdownTooltip: String {
        guard !row.isRest else { return "" }
        var parts: [String] = [row.repo]
        if row.claudeCost > 0 {
            parts.append("Claude " + AnalyticsCurrencyFormatter.format(row.claudeCost))
        }
        if row.codexCost > 0 {
            parts.append("Codex " + AnalyticsCurrencyFormatter.format(row.codexCost))
        }
        return parts.joined(separator: " · ")
    }

    private func percentString(_ share: Double) -> String {
        let pct = share * 100
        if pct < 1 { return String(format: "%.1f%%", pct) }
        return String(format: "%.0f%%", pct)
    }
}
#endif
