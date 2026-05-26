#if !os(watchOS) && canImport(SwiftUI)
import SwiftUI

/// Per-repo $/% breakdown for the active window. Top 8 + optional "…N more"
/// rollup row. Plan A7 + A17: hover/tap shows the full path on Mac/iOS;
/// footer row surfaces unpriced model tokens.
/// **A4 memoization (Phase 2):** the `rows` derivation used to be a
/// computed property running three dict merges + a sort + percentage math
/// on every body call. Now it's held in a `MemoizedDerivedStore` (from
/// A4-pre) keyed on `(snapshot.computedAt, window, providerFilter)` —
/// cache key matches the chart's. Cache hit ⇒ no work.
@available(macOS 13, iOS 16, *)
public struct AnalyticsRepoList: View {

    public let snapshot: UsageHistorySnapshot
    public let window: UsageHistorySnapshot.Window
    public let providerFilter: UsageHistoryStore.ProviderFilter

    @StateObject private var rowsStore = MemoizedDerivedStore<RowsInput, [Row]>(
        placeholder: [],
        mode: .sync,
        compute: { Self.computeRows($0) }
    )

    public init(
        snapshot: UsageHistorySnapshot,
        window: UsageHistorySnapshot.Window,
        providerFilter: UsageHistoryStore.ProviderFilter
    ) {
        self.snapshot = snapshot
        self.window = window
        self.providerFilter = providerFilter
    }

    /// A4 cache key. Equatable comparison compares snapshot via
    /// `computedAt` only — same identity ⇒ same byProvider/byRepo content.
    fileprivate struct RowsInput: Equatable {
        let snapshot: UsageHistorySnapshot
        let window: UsageHistorySnapshot.Window
        let providerFilter: UsageHistoryStore.ProviderFilter

        static func == (lhs: RowsInput, rhs: RowsInput) -> Bool {
            lhs.snapshot.computedAt == rhs.snapshot.computedAt
                && lhs.window == rhs.window
                && lhs.providerFilter == rhs.providerFilter
        }
    }

    /// Merge each provider's byRepo for the active window, recompute %
    /// share, re-rank, and keep top-8 + rollup. Each row carries BOTH the
    /// combined cost AND the per-provider breakdown so the progress bar
    /// renderer can stack Claude (orange) and Codex (blue) segments,
    /// rather than showing a single solid tint that hides which provider
    /// contributed how much.
    ///
    /// X3-C trunk refactor: Gemini contributes `requestCount`, not
    /// `costUSD` (cloudcode-pa doesn't expose tokens). Each row tracks
    /// `geminiRequests` separately; ranking still keys on $ so cost-bearing
    /// providers dominate sort order, but the row badge surfaces Gemini's
    /// per-repo request count when present. Repos with ONLY Gemini activity
    /// still appear (with $0 cost) when `.gemini` is in the filter.
    fileprivate static func computeRows(_ input: RowsInput) -> [Row] {
        let snapshot = input.snapshot
        let window = input.window
        let providerFilter = input.providerFilter
        var claudeByRepo: [RepoKey: TokenTotals] = [:]
        var codexByRepo: [RepoKey: TokenTotals] = [:]
        var geminiByRepo: [RepoKey: TokenTotals] = [:]
        if providerFilter.includes(.claude) {
            for row in snapshot.claude.window(window).byRepo where row.repo != "__rest__" {
                claudeByRepo[row.repo, default: .zero] += row.totals
            }
        }
        if providerFilter.includes(.codex) {
            for row in snapshot.codex.window(window).byRepo where row.repo != "__rest__" {
                codexByRepo[row.repo, default: .zero] += row.totals
            }
        }
        if providerFilter.includes(.gemini) {
            for row in snapshot.gemini.window(window).byRepo where row.repo != "__rest__" {
                geminiByRepo[row.repo, default: .zero] += row.totals
            }
        }

        // Build a combined keyset so a repo that's Codex-only OR Gemini-
        // only still shows.
        let allRepoKeys = Set(claudeByRepo.keys)
            .union(codexByRepo.keys)
            .union(geminiByRepo.keys)
        var combinedByRepo: [RepoKey: (claude: Decimal, codex: Decimal, total: Decimal, tokens: Int, geminiReqs: Int)] = [:]
        for key in allRepoKeys {
            let cl = claudeByRepo[key, default: .zero]
            let cx = codexByRepo[key, default: .zero]
            let gm = geminiByRepo[key, default: .zero]
            combinedByRepo[key] = (
                claude: cl.costUSD,
                codex: cx.costUSD,
                total: cl.costUSD + cx.costUSD,
                tokens: cl.totalTokens + cx.totalTokens,
                geminiReqs: gm.requestCount
            )
        }

        let totalCost = combinedByRepo.values.reduce(Decimal.zero, { $0 + $1.total })
        let totalGeminiReqs = combinedByRepo.values.reduce(0, { $0 + $1.geminiReqs })
        // Skip the list when there's neither cost nor request data.
        guard totalCost > 0 || totalGeminiReqs > 0 else { return [] }

        // Composite rank: cost-bearing repos sort by $, ties / cost-zero
        // rows fall through to gemini request count. Per X3-C trunk-level
        // refactor — without this Gemini-only repos would never appear.
        let sorted = combinedByRepo.sorted { a, b in
            if a.value.total != b.value.total {
                return a.value.total > b.value.total
            }
            return a.value.geminiReqs > b.value.geminiReqs
        }
        let top = Array(sorted.prefix(8))
        let rest = Array(sorted.dropFirst(8))

        // Keep cost shares in Decimal end-to-end and only collapse to
        // Double at the UI boundary. Going via NSDecimalNumber.doubleValue
        // mid-flight truncates to 53-bit mantissa and the rows visibly
        // fail to sum to 100% after enough divisions.
        var out: [Row] = top.map { (key, value) in
            let costShareDec: Decimal = totalCost > 0 ? (value.total / totalCost) : 0
            let geminiShare: Double = (totalGeminiReqs > 0 && totalCost == 0)
                ? Double(value.geminiReqs) / Double(totalGeminiReqs)
                : 0
            let costShare = NSDecimalNumber(decimal: costShareDec).doubleValue
            return Row(
                id: key,
                repo: key,
                displayName: RepoIdentity.displayName(for: key),
                cost: value.total,
                claudeCost: value.claude,
                codexCost: value.codex,
                tokens: value.tokens,
                geminiRequests: value.geminiReqs,
                share: max(costShare, geminiShare),
                isRest: false,
                restCount: 0
            )
        }
        if !rest.isEmpty {
            let restClaude = rest.map(\.value.claude).reduce(Decimal.zero, +)
            let restCodex = rest.map(\.value.codex).reduce(Decimal.zero, +)
            let restGemini = rest.map(\.value.geminiReqs).reduce(0, +)
            let restCost = restClaude + restCodex
            let restTokens = rest.map(\.value.tokens).reduce(0, +)
            let restShareDec: Decimal = totalCost > 0 ? (restCost / totalCost) : 0
            let restShare: Double = totalCost > 0
                ? NSDecimalNumber(decimal: restShareDec).doubleValue
                : (totalGeminiReqs > 0 ? Double(restGemini) / Double(totalGeminiReqs) : 0)
            out.append(Row(
                id: "__rest__",
                repo: "__rest__",
                displayName: "…\(rest.count) more",
                cost: restCost,
                claudeCost: restClaude,
                codexCost: restCodex,
                tokens: restTokens,
                geminiRequests: restGemini,
                share: restShare,
                isRest: true,
                restCount: rest.count
            ))
        }
        return out
    }

    public var body: some View {
        let input = RowsInput(
            snapshot: snapshot,
            window: window,
            providerFilter: providerFilter
        )
        let data = rowsStore.output ?? []
        return bodyWithData(data: data)
            .task(id: input) {
                rowsStore.update(input: input)
            }
    }

    @ViewBuilder
    private func bodyWithData(data: [Row]) -> some View {
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
        /// Gemini's contribution to this repo, expressed as request count.
        /// cloudcode-pa doesn't surface tokens or cost, so this is a
        /// distinct unit from `claudeCost` / `codexCost`. Rendered as a
        /// small "+N gem" badge in the row instead of a stacked bar segment
        /// to keep the cost-comparable bar honest.
        let geminiRequests: Int
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
                if row.geminiRequests > 0 {
                    // Gemini contributes request count, not $. Render as a
                    // small inline pill so the user sees per-repo Gemini
                    // activity without distorting the cost-comparable
                    // stacked bar below. Distinct shape (capsule with
                    // gemini blue) keeps it visually separable from cost.
                    Text("+\(row.geminiRequests) gem")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(geminiColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(geminiColor.opacity(0.15), in: Capsule())
                }
                Spacer()
                if row.cost > 0 {
                    Text(AnalyticsCurrencyFormatter.format(row.cost))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                } else if row.geminiRequests > 0 {
                    Text("\(row.geminiRequests) reqs")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
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
    private var geminiColor: Color {
        Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0)
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
        if row.geminiRequests > 0 {
            parts.append("Gemini \(row.geminiRequests) reqs")
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
