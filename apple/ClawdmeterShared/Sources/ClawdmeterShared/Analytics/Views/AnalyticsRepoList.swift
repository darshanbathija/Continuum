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
    /// share, re-rank, and keep top-8 + rollup.
    private var rows: [Row] {
        var totalsByRepo: [RepoKey: TokenTotals] = [:]
        if providerFilter != .codex {
            for row in snapshot.claude.window(window).byRepo where row.repo != "__rest__" {
                totalsByRepo[row.repo, default: .zero] += row.totals
            }
        }
        if providerFilter != .claude {
            for row in snapshot.codex.window(window).byRepo where row.repo != "__rest__" {
                totalsByRepo[row.repo, default: .zero] += row.totals
            }
        }

        let totalCost = totalsByRepo.values.reduce(Decimal.zero, { $0 + $1.costUSD })
        guard totalCost > 0 else { return [] }

        let sorted = totalsByRepo.sorted { $0.value.costUSD > $1.value.costUSD }
        let top = Array(sorted.prefix(8))
        let rest = Array(sorted.dropFirst(8))

        var out: [Row] = top.map { (key, value) in
            Row(
                id: key,
                repo: key,
                displayName: RepoIdentity.displayName(for: key),
                cost: value.costUSD,
                tokens: value.totalTokens,
                share: NSDecimalNumber(decimal: value.costUSD / totalCost).doubleValue,
                isRest: false,
                restCount: 0
            )
        }
        if !rest.isEmpty {
            let restCost = rest.map(\.value.costUSD).reduce(Decimal.zero, +)
            let restTokens = rest.map(\.value.totalTokens).reduce(0, +)
            out.append(Row(
                id: "__rest__",
                repo: "__rest__",
                displayName: "…\(rest.count) more",
                cost: restCost,
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
            ProgressView(value: row.share)
                .progressViewStyle(.linear)
                .tint(Color(red: 217.0/255, green: 119.0/255, blue: 87.0/255))

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
        .help(row.isRest ? "" : row.repo)
#else
        .onTapGesture {
            if !row.isRest { withAnimation(.snappy) { expanded.toggle() } }
        }
#endif
    }

    private func percentString(_ share: Double) -> String {
        let pct = share * 100
        if pct < 1 { return String(format: "%.1f%%", pct) }
        return String(format: "%.0f%%", pct)
    }
}
#endif
