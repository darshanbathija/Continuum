#if !os(watchOS) && canImport(SwiftUI)
import SwiftUI
import Charts

/// Per-day stacked spend chart. Iterates `snapshot.byProvider` so it
/// stacks Claude + Codex (cost) + Gemini (req count) per the user's
/// `providerFilter`. Per plan A6 + verified note: `BarMark` stacks by
/// default when two marks share an X value — we do NOT use `.position(by:)`
/// (that would group, not stack).
///
/// **Heterogeneous metrics**: Claude and Codex carry $cost values;
/// Gemini's `costUSD` is always 0 (cloudcode-pa doesn't expose tokens) so
/// we don't include it in the $-stacked chart. The Requests panel (rendered
/// below the cost chart) shows Gemini's per-day request count separately —
/// see plan §Analytics schema split.
///
/// **A4 memoization (Phase 2):** `costPoints` and `reqsPoints` used to be
/// computed properties that re-ran the calendar loop on every body
/// invalidation. Now they're held in `MemoizedDerivedStore<ChartInput, [Point]>`
/// (from A4-pre). Cache key includes `snapshot.computedAt`, `window`, and
/// `providerFilter` — same shape codex eng-review #4 prescribed. Cache hit
/// when the parent re-renders without an analytics change ⇒ no work.
@available(macOS 13, iOS 16, *)
public struct AnalyticsDailyChart: View {

    public let snapshot: UsageHistorySnapshot
    public let window: UsageHistorySnapshot.Window
    public let providerFilter: UsageHistoryStore.ProviderFilter

    @StateObject private var costStore = MemoizedDerivedStore<ChartInput, [CostPoint]>(
        placeholder: [],
        mode: .sync,
        compute: { Self.computeCostPoints($0) }
    )
    @StateObject private var reqsStore = MemoizedDerivedStore<ChartInput, [ReqsPoint]>(
        placeholder: [],
        mode: .sync,
        compute: { Self.computeReqsPoints($0) }
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

    // MARK: - Cache key + chart data types

    /// A4 cache key. Equatable comparison compares snapshot via
    /// `computedAt` only — same identity ⇒ same byProvider content
    /// (`UsageHistorySnapshot.computedAt` is monotonically updated by
    /// the loader on every fresh aggregation). Cheap to compare; cache
    /// hits dominate.
    fileprivate struct ChartInput: Equatable {
        let snapshot: UsageHistorySnapshot
        let window: UsageHistorySnapshot.Window
        let providerFilter: UsageHistoryStore.ProviderFilter

        static func == (lhs: ChartInput, rhs: ChartInput) -> Bool {
            lhs.snapshot.computedAt == rhs.snapshot.computedAt
                && lhs.window == rhs.window
                && lhs.providerFilter == rhs.providerFilter
        }
    }

    fileprivate struct CostPoint: Identifiable, Equatable {
        let id: String
        let day: Date
        let cost: Decimal
        let provider: String
    }

    fileprivate struct ReqsPoint: Identifiable, Equatable {
        let id: String
        let day: Date
        let reqs: Int
    }

    // MARK: - A4 compute closures (pure, static)

    fileprivate static func costProviders(in snapshot: UsageHistorySnapshot, filter: UsageHistoryStore.ProviderFilter) -> [UsageRecord.Provider] {
        // Cost-bearing providers only. Gemini's $0 doesn't go in the
        // stacked dollar chart — it gets a separate request-count panel.
        let order: [UsageRecord.Provider] = [.claude, .codex, .opencode, .cursor]
        return order.filter { snapshot.byProvider[$0] != nil && filter.includes($0) }
    }

    fileprivate static func computeCostPoints(_ input: ChartInput) -> [CostPoint] {
        let snapshot = input.snapshot
        let window = input.window
        let providerFilter = input.providerFilter
        let providers = costProviders(in: snapshot, filter: providerFilter)
        let cal = Calendar.current
        var out: [CostPoint] = []
        switch window {
        case .today, .past7d, .past30d:
            let today = cal.startOfDay(for: Date())
            let length: Int = (window == .today) ? 1 : (window == .past7d) ? 7 : 30
            for offset in 0..<length {
                guard let day = cal.date(byAdding: .day, value: -(length - 1 - offset), to: today) else { continue }
                for p in providers {
                    let c = snapshot.totals(for: p).byDay[day]?.costUSD ?? 0
                    out.append(CostPoint(id: "\(p.rawValue)-\(day.timeIntervalSince1970)", day: day, cost: c, provider: displayName(p)))
                }
            }
        case .allTime:
            var keys = Set<Date>()
            for p in providers { keys.formUnion(snapshot.totals(for: p).byDay.keys) }
            guard let earliest = keys.min(), let latest = keys.max() else { return [] }
            var day = cal.startOfDay(for: earliest)
            let end = cal.startOfDay(for: latest)
            while day <= end {
                for p in providers {
                    let c = snapshot.totals(for: p).byDay[day]?.costUSD ?? 0
                    out.append(CostPoint(id: "\(p.rawValue)-\(day.timeIntervalSince1970)", day: day, cost: c, provider: displayName(p)))
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return out
    }

    fileprivate static func computeReqsPoints(_ input: ChartInput) -> [ReqsPoint] {
        let snapshot = input.snapshot
        let window = input.window
        let providerFilter = input.providerFilter
        // Gemini-only for now. If other providers expose `requestCount > 0`
        // in the future, extend by adding them here.
        guard providerFilter.includes(.gemini),
              let gemini = snapshot.byProvider[.gemini] else { return [] }
        let cal = Calendar.current
        var out: [ReqsPoint] = []
        switch window {
        case .today, .past7d, .past30d:
            let today = cal.startOfDay(for: Date())
            let length: Int = (window == .today) ? 1 : (window == .past7d) ? 7 : 30
            for offset in 0..<length {
                guard let day = cal.date(byAdding: .day, value: -(length - 1 - offset), to: today) else { continue }
                let r = gemini.byDay[day]?.requestCount ?? 0
                out.append(ReqsPoint(id: "g-\(day.timeIntervalSince1970)", day: day, reqs: r))
            }
        case .allTime:
            guard let earliest = gemini.byDay.keys.min(), let latest = gemini.byDay.keys.max() else { return [] }
            var day = cal.startOfDay(for: earliest)
            let end = cal.startOfDay(for: latest)
            while day <= end {
                let r = gemini.byDay[day]?.requestCount ?? 0
                out.append(ReqsPoint(id: "g-\(day.timeIntervalSince1970)", day: day, reqs: r))
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return out
    }

    // MARK: - Body

    public var body: some View {
        let input = ChartInput(
            snapshot: snapshot,
            window: window,
            providerFilter: providerFilter
        )
        let cost = costStore.output ?? []
        let reqs = reqsStore.output ?? []
        Group {
            if cost.isEmpty && reqs.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if !cost.isEmpty { costChart(cost) }
                    if !reqs.isEmpty { reqsChart(reqs) }
                }
            }
        }
        // A4: drive the memoized derived stores from the input key. Both
        // stores share the same key shape so they invalidate together when
        // snapshot.computedAt / window / providerFilter changes; on
        // identical input (parent re-render with no analytics change),
        // both stores cache-hit and the body returns the previous Point
        // arrays unchanged.
        .task(id: input) {
            costStore.update(input: input)
            reqsStore.update(input: input)
        }
    }

    @ViewBuilder
    private func costChart(_ data: [CostPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily spend — \(window.label.lowercased())")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Chart(data) { pt in
                BarMark(
                    x: .value("Day", pt.day, unit: .day),
                    y: .value("USD", NSDecimalNumber(decimal: pt.cost).doubleValue)
                )
                .foregroundStyle(by: .value("Provider", pt.provider))
            }
            .chartForegroundStyleScale([
                "Claude": Color(red: 217.0/255, green: 119.0/255, blue: 87.0/255),
                "Codex": Color.accentColor,
            ])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(1, data.count / 14))) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text(Decimal(d).formatted(.currency(code: "USD").precision(.fractionLength(0))))
                        }
                    }
                }
            }
            .frame(height: 160)

            costLegendRow

            if let max = maxCostDay(data) {
                Text("Max day \(AnalyticsCurrencyFormatter.format(max.cost)) · \(max.day.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func reqsChart(_ data: [ReqsPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily requests — \(window.label.lowercased())")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Chart(data) { pt in
                BarMark(
                    x: .value("Day", pt.day, unit: .day),
                    y: .value("Requests", pt.reqs)
                )
                .foregroundStyle(Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(1, data.count / 14))) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 100)

            HStack(spacing: 5) {
                ProviderBadgeImage(assetName: "GeminiLogo", isTemplate: true, size: 11)
                Circle()
                    .fill(Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0))
                    .frame(width: 6, height: 6)
                Text("Gemini · token cost unavailable from CLI logs")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var costLegendRow: some View {
        HStack(spacing: 14) {
            if providerFilter.includes(.claude) {
                HStack(spacing: 5) {
                    ProviderBadgeImage(assetName: "ClaudeLogo", isTemplate: false, size: 11)
                    Circle()
                        .fill(Color(red: 217.0/255, green: 119.0/255, blue: 87.0/255))
                        .frame(width: 6, height: 6)
                    Text("Claude")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if providerFilter.includes(.codex) {
                HStack(spacing: 5) {
                    ProviderBadgeImage(assetName: "CodexLogo", isTemplate: true, size: 11)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text("Codex")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func maxCostDay(_ data: [CostPoint]) -> (cost: Decimal, day: Date)? {
        let grouped = Dictionary(grouping: data, by: \.day)
        guard let best = grouped.max(by: { lhs, rhs in
            lhs.value.reduce(Decimal.zero, { $0 + $1.cost }) < rhs.value.reduce(Decimal.zero, { $0 + $1.cost })
        }) else { return nil }
        let total = best.value.reduce(Decimal.zero, { $0 + $1.cost })
        if total == 0 { return nil }
        return (cost: total, day: best.key)
    }

    private static func displayName(_ p: UsageRecord.Provider) -> String {
        switch p {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        }
    }
}
#endif
