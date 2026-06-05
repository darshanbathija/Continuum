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

    // C1 (Phase 2): rows compute moved off-main via .detached(.utility).
    // The rows derivation runs three dict merges + a sort + percentage
    // math; for users with many repos on allTime window, that's a real
    // main-thread stall today. .detached keeps the analytics view
    // responsive; the existing "No usage in this window" empty-state
    // covers the brief placeholder window before the worker lands.
    @StateObject private var rowsStore = MemoizedDerivedStore<RowsInput, [Row]>(
        placeholder: [],
        mode: .detached(priority: .utility),
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
    nonisolated fileprivate static func computeRows(_ input: RowsInput) -> [Row] {
        let snapshot = input.snapshot
        let window = input.window
        let providerFilter = input.providerFilter
        var claudeByRepo: [RepoKey: TokenTotals] = [:]
        var codexByRepo: [RepoKey: TokenTotals] = [:]
        var geminiByRepo: [RepoKey: TokenTotals] = [:]
        var opencodeByRepo: [RepoKey: TokenTotals] = [:]
        var cursorByRepo: [RepoKey: TokenTotals] = [:]
        var grokByRepo: [RepoKey: TokenTotals] = [:]
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
        if providerFilter.includes(.opencode) {
            for row in snapshot.opencode.window(window).byRepo where row.repo != "__rest__" {
                opencodeByRepo[row.repo, default: .zero] += row.totals
            }
        }
        if providerFilter.includes(.cursor) {
            for row in snapshot.cursor.window(window).byRepo where row.repo != "__rest__" {
                cursorByRepo[row.repo, default: .zero] += row.totals
            }
        }
        if providerFilter.includes(.grok) {
            for row in snapshot.grok.window(window).byRepo where row.repo != "__rest__" {
                grokByRepo[row.repo, default: .zero] += row.totals
            }
        }

        // Build a combined keyset so a repo that's Codex-only OR Gemini-
        // only still shows.
        let allRepoKeys = Set(claudeByRepo.keys)
            .union(codexByRepo.keys)
            .union(geminiByRepo.keys)
            .union(opencodeByRepo.keys)
            .union(cursorByRepo.keys)
            .union(grokByRepo.keys)
        var combinedByRepo: [RepoKey: (claude: Decimal, codex: Decimal, opencode: Decimal, cursor: Decimal, grok: Decimal, total: Decimal, tokens: Int, geminiReqs: Int, grokTokens: Int)] = [:]
        for key in allRepoKeys {
            let cl = claudeByRepo[key, default: .zero]
            let cx = codexByRepo[key, default: .zero]
            let gm = geminiByRepo[key, default: .zero]
            let op = opencodeByRepo[key, default: .zero]
            let cu = cursorByRepo[key, default: .zero]
            let gr = grokByRepo[key, default: .zero]
            let total = cl.costUSD + cx.costUSD + op.costUSD + cu.costUSD + gr.costUSD
            combinedByRepo[key] = (
                claude: cl.costUSD,
                codex: cx.costUSD,
                opencode: op.costUSD,
                cursor: cu.costUSD,
                grok: gr.costUSD,
                total: total,
                tokens: cl.totalTokens + cx.totalTokens + op.totalTokens + cu.totalTokens + gr.totalTokens,
                geminiReqs: gm.requestCount,
                grokTokens: gr.totalTokens
            )
        }

        let totalCost = combinedByRepo.values.reduce(Decimal.zero, { $0 + $1.total })
        let totalGeminiReqs = combinedByRepo.values.reduce(0, { $0 + $1.geminiReqs })
        let totalTokenActivity = combinedByRepo.values.reduce(0, { $0 + $1.tokens })
        // Skip the list when there's neither cost nor request data.
        guard totalCost > 0 || totalGeminiReqs > 0 || totalTokenActivity > 0 else { return [] }

        // Composite rank: cost-bearing repos sort by $, ties / cost-zero
        // rows fall through to gemini request count. Per X3-C trunk-level
        // refactor — without this Gemini-only repos would never appear.
        let sorted = combinedByRepo.sorted { a, b in
            if a.value.total != b.value.total {
                return a.value.total > b.value.total
            }
            if a.value.geminiReqs != b.value.geminiReqs {
                return a.value.geminiReqs > b.value.geminiReqs
            }
            return a.value.tokens > b.value.tokens
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
            let tokenShare: Double = (totalTokenActivity > 0 && value.total == 0)
                ? Double(value.tokens) / Double(totalTokenActivity)
                : 0
            let costShare = NSDecimalNumber(decimal: costShareDec).doubleValue
            return Row(
                id: key,
                repo: key,
                displayName: RepoIdentity.displayName(for: key),
                cost: value.total,
                claudeCost: value.claude,
                codexCost: value.codex,
                opencodeCost: value.opencode,
                cursorCost: value.cursor,
                grokCost: value.grok,
                tokens: value.tokens,
                geminiRequests: value.geminiReqs,
                grokTokens: value.grokTokens,
                share: max(costShare, max(geminiShare, tokenShare)),
                isRest: false,
                restCount: 0
            )
        }
        if !rest.isEmpty {
            let restClaude = rest.map(\.value.claude).reduce(Decimal.zero, +)
            let restCodex = rest.map(\.value.codex).reduce(Decimal.zero, +)
            let restOpencode = rest.map(\.value.opencode).reduce(Decimal.zero, +)
            let restCursor = rest.map(\.value.cursor).reduce(Decimal.zero, +)
            let restGrok = rest.map(\.value.grok).reduce(Decimal.zero, +)
            let restGemini = rest.map(\.value.geminiReqs).reduce(0, +)
            let restGrokTokens = rest.map(\.value.grokTokens).reduce(0, +)
            let restCost = restClaude + restCodex + restOpencode + restCursor + restGrok
            let restTokens = rest.map(\.value.tokens).reduce(0, +)
            let restShareDec: Decimal = totalCost > 0 ? (restCost / totalCost) : 0
            let restCostShare: Double = totalCost > 0 ? NSDecimalNumber(decimal: restShareDec).doubleValue : 0
            let restGeminiShare: Double = (totalGeminiReqs > 0 && totalCost == 0) ? Double(restGemini) / Double(totalGeminiReqs) : 0
            let restTokenShare: Double = (totalTokenActivity > 0 && restCost == 0) ? Double(restTokens) / Double(totalTokenActivity) : 0
            out.append(Row(
                id: "__rest__",
                repo: "__rest__",
                displayName: "…\(rest.count) more",
                cost: restCost,
                claudeCost: restClaude,
                codexCost: restCodex,
                opencodeCost: restOpencode,
                cursorCost: restCursor,
                grokCost: restGrok,
                tokens: restTokens,
                geminiRequests: restGemini,
                grokTokens: restGrokTokens,
                share: max(restCostShare, max(restGeminiShare, restTokenShare)),
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
        // Inline-compute fallback for the first body call (and any cache
        // miss frame): the store's `.task(id:)` driver fires AFTER body
        // returns, so the placeholder `[]` would otherwise surface for one
        // runloop tick — causing the misleading "No usage in this window"
        // empty-state to flash even when there IS usage. Falling back to
        // the static compute when `output == nil` keeps the first-render
        // semantics identical to pre-A4 (one compute on first body), while
        // subsequent body invocations cache-hit through the store.
        let data = rowsStore.output ?? Self.computeRows(input)
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
                    .font(ContinuumFont.body(13, weight: .semibold))
                    .foregroundStyle(ContinuumTokens.fg2)
                Spacer()
                Text("$")
                    .font(ContinuumFont.mono(11))
                    .foregroundStyle(ContinuumTokens.fg3)
                Text("Share")
                    .font(ContinuumFont.mono(11))
                    .foregroundStyle(ContinuumTokens.fg3)
            }

            if data.isEmpty {
                Text("No usage in this window")
                    .font(ContinuumFont.body(12))
                    .foregroundStyle(ContinuumTokens.fg3)
            } else {
                ForEach(data) { row in
                    RepoRow(row: row)
                }
            }

            if !snapshot.unpricedModelTokens.isEmpty {
                let totalUnpricedTokens = snapshot.unpricedModelTokens.values.map(\.totalTokens).reduce(0, +)
                Text("\(AnalyticsTokenFormatter.format(totalUnpricedTokens)) tokens against \(snapshot.unpricedModelTokens.count) unpriced model\(snapshot.unpricedModelTokens.count == 1 ? "" : "s") — update pricing.json")
                    .font(ContinuumFont.body(11))
                    .foregroundStyle(ContinuumTokens.fg3)
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
        let opencodeCost: Decimal
        let cursorCost: Decimal
        let grokCost: Decimal
        let tokens: Int
        /// Gemini's contribution to this repo, expressed as request count.
        /// cloudcode-pa doesn't surface tokens or cost, so this is a
        /// distinct unit from `claudeCost` / `codexCost`. Rendered as a
        /// small "+N gem" badge in the row instead of a stacked bar segment
        /// to keep the cost-comparable bar honest.
        let geminiRequests: Int
        let grokTokens: Int
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
    private var opencodeShare: Double {
        guard row.cost > 0 else { return 0 }
        return NSDecimalNumber(decimal: row.opencodeCost / row.cost).doubleValue
    }
    private var cursorShare: Double {
        guard row.cost > 0 else { return 0 }
        return NSDecimalNumber(decimal: row.cursorCost / row.cost).doubleValue
    }
    private var grokShare: Double {
        guard row.cost > 0 else { return 0 }
        return NSDecimalNumber(decimal: row.grokCost / row.cost).doubleValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.displayName)
                    .font(ContinuumFont.mono(12, weight: .medium))
                    .foregroundStyle(ContinuumTokens.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.geminiRequests > 0 {
                    // Antigravity contributes request count, not $. A small
                    // inline pill keeps per-repo Antigravity activity visible
                    // without distorting the cost-comparable stacked bar.
                    HStack(spacing: 4) {
                        ProviderDot(.gemini, size: 5)
                        Text("+\(row.geminiRequests)")
                            .font(ContinuumFont.mono(10, weight: .semibold))
                            .foregroundStyle(ContinuumTokens.fg3)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(ContinuumTokens.surface2, in: Capsule())
                    .overlay(Capsule().strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5))
                }
                if row.grokTokens > 0 {
                    HStack(spacing: 4) {
                        ProviderDot(.grok, size: 5)
                        Text("+\(AnalyticsTokenFormatter.format(row.grokTokens))")
                            .font(ContinuumFont.mono(10, weight: .semibold))
                            .foregroundStyle(ContinuumTokens.fg3)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(ContinuumTokens.surface2, in: Capsule())
                    .overlay(Capsule().strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5))
                }
                Spacer()
                if row.cost > 0 {
                    Text(AnalyticsCurrencyFormatter.format(row.cost))
                        .font(ContinuumFont.mono(12, weight: .semibold))
                        .foregroundStyle(ContinuumTokens.fg)
                        .monospacedDigit()
                } else if row.geminiRequests > 0 {
                    Text("\(row.geminiRequests) reqs")
                        .font(ContinuumFont.mono(12, weight: .semibold))
                        .foregroundStyle(ContinuumTokens.fg)
                        .monospacedDigit()
                } else if row.grokTokens > 0 {
                    Text(AnalyticsTokenFormatter.format(row.grokTokens) + " tok")
                        .font(ContinuumFont.mono(12, weight: .semibold))
                        .foregroundStyle(ContinuumTokens.fg)
                        .monospacedDigit()
                }
                Text(percentString(row.share))
                    .font(ContinuumFont.mono(11))
                    .foregroundStyle(ContinuumTokens.fg2)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            // Stacked progress bar. The widths sum to `row.share` of
            // the total window cost, and each cost-bearing provider keeps
            // its canonical T2 fill.
            providerSegmentedBar
                .frame(height: 7)
                .clipShape(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.rail, style: .continuous))

            if expanded && !row.isRest {
                Text(row.repo)
                    .font(ContinuumFont.mono(10))
                    .foregroundStyle(ContinuumTokens.fg3)
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
            let opencodeWidth = totalWidth * opencodeShare * row.share
            let cursorWidth = totalWidth * cursorShare * row.share
            let grokWidth = row.cost > 0
                ? totalWidth * grokShare * row.share
                : (row.grokTokens > 0 ? totalWidth * row.share : 0)
            ZStack(alignment: .leading) {
                // Track
                Rectangle()
                    .fill(ContinuumTokens.railTrack)
                HStack(spacing: 0) {
                    // Horizontal by-repo order: Claude -> Codex -> Antigravity
                    // request pill -> OpenCode -> Cursor -> Grok.
                    Rectangle()
                        .fill(ProviderFill.gradient(for: .claude))
                        .frame(width: claudeWidth)
                    Rectangle()
                        .fill(ProviderFill.gradient(for: .codex))
                        .frame(width: codexWidth)
                    Rectangle()
                        .fill(ProviderFill.gradient(for: .opencode))
                        .frame(width: opencodeWidth)
                    Rectangle()
                        .fill(ProviderFill.gradient(for: .cursor))
                        .frame(width: cursorWidth)
                    Rectangle()
                        .fill(ProviderFill.gradient(for: .grok))
                        .frame(width: grokWidth)
                    Spacer(minLength: 0)
                }
            }
        }
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
        if row.opencodeCost > 0 {
            parts.append("OpenCode " + AnalyticsCurrencyFormatter.format(row.opencodeCost))
        }
        if row.cursorCost > 0 {
            parts.append("Cursor " + AnalyticsCurrencyFormatter.format(row.cursorCost))
        }
        if row.grokCost > 0 {
            parts.append("Grok " + AnalyticsCurrencyFormatter.format(row.grokCost))
        }
        if row.geminiRequests > 0 {
            parts.append("Antigravity \(row.geminiRequests) reqs")
        }
        if row.grokTokens > 0 {
            parts.append("Grok \(AnalyticsTokenFormatter.format(row.grokTokens)) tok")
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
