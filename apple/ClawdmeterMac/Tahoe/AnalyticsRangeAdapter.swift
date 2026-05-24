import Foundation
import ClawdmeterShared

/// v0.22.8 — converts a real `UsageHistorySnapshot` into the
/// `TahoeDemo.RangeData` shape the Tahoe analytics card was wired to.
/// Before this, the Spend Over Time + Spend By Repo card rendered the
/// canned `TahoeDemo.ranges[...]` placeholder ($39.32 / 7d / defx-frontend
/// $17.42 etc.) regardless of actual usage — see the user's screenshot
/// reporting "the data here is completely wrong".
///
/// The chart's bucketing matches ccusage's daily model:
///   - "today" → today only (single bar)
///   - "7d"    → 7 daily buckets, ticks Mon–Sun ordered ending today
///   - "30d"   → 4 weekly buckets, ticks `["W1","W2","W3","W4"]`
///   - "90d"   → 12 weekly buckets, ticks W1..W12 ending most recent
///   - "all"   → 12 monthly buckets ending current month (or fewer if less history)
///
/// Per-bucket per-provider dollar splits come from the snapshot's
/// `byProvider[p].byDay` slot. Repos come from `byProvider[p].past*.byRepo`
/// (PR #27 added opencode). The result is the same shape the Tahoe view
/// already knows how to render — just with truthful numbers.
///
/// v0.22.17: replaced the "24h" range with "today". The previous
/// "past 24h" view split today's total across 6 equally-weighted
/// four-hour buckets — pure smoke-and-mirrors since
/// UsageHistoryLoader stores data at day-resolution. ccusage uses
/// per-day buckets too; "today" tells the truth.
enum AnalyticsRangeAdapter {

    static func rangeData(snapshot: UsageHistorySnapshot, range: String) -> TahoeDemo.RangeData {
        switch range {
        case "today": return self.today(snapshot)
        // Back-compat with persisted user state from v0.22.16 and
        // earlier — fall through to the new "today" implementation
        // rather than re-rendering the misleading 6-bar split.
        case "24h":   return self.today(snapshot)
        case "7d":    return self.daily7(snapshot)
        case "30d":   return self.weekly4(snapshot)
        case "90d":   return self.weekly12(snapshot)
        case "all":   return self.allTime(snapshot)
        default:      return self.daily7(snapshot)
        }
    }

    // MARK: - Today: a single bar showing today's per-provider spend

    private static func today(_ snapshot: UsageHistorySnapshot) -> TahoeDemo.RangeData {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Single bar — full magnitude (no scale) so the height
        // accurately reflects what we billed today.
        let series = [self.spendPoint(snapshot, day: today, scale: 1.0)]
        // Day-of-week label on the X axis so the user knows which
        // day this bar represents (matches the 7d view's tick style).
        let totals = self.totalsFor(snapshot, range: .today, label: "today")
        let repos = self.reposFor(snapshot, range: .today)
        return TahoeDemo.RangeData(
            label: "today",
            ticks: [Self.weekdayLabel(for: today)],
            series: series,
            total: totals,
            repos: repos
        )
    }

    // MARK: - 7d: today + 6 prior days, Mon..Sun-ordered by user's calendar

    private static func daily7(_ snapshot: UsageHistorySnapshot) -> TahoeDemo.RangeData {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days: [Date] = (0..<7).reversed().map { offset in
            cal.date(byAdding: .day, value: -offset, to: today) ?? today
        }
        let series = days.map { self.spendPoint(snapshot, day: $0, scale: 1.0) }
        let ticks = days.map { Self.weekdayLabel(for: $0) }
        let totals = self.totalsFor(snapshot, range: .past7d, label: "7d")
        let repos = self.reposFor(snapshot, range: .past7d)
        return TahoeDemo.RangeData(
            label: "7d",
            ticks: ticks,
            series: series,
            total: totals,
            repos: repos
        )
    }

    // MARK: - 30d: 4 weekly buckets

    private static func weekly4(_ snapshot: UsageHistorySnapshot) -> TahoeDemo.RangeData {
        let series = self.weeklySeries(snapshot, weeks: 4)
        let ticks = ["W1", "W2", "W3", "W4"]
        let totals = self.totalsFor(snapshot, range: .past30d, label: "30d")
        let repos = self.reposFor(snapshot, range: .past30d)
        return TahoeDemo.RangeData(
            label: "30d",
            ticks: ticks,
            series: series,
            total: totals,
            repos: repos
        )
    }

    // MARK: - 90d: 12 weekly buckets

    private static func weekly12(_ snapshot: UsageHistorySnapshot) -> TahoeDemo.RangeData {
        let series = self.weeklySeries(snapshot, weeks: 12)
        let ticks = (1...12).map { "W\($0)" }
        let totals = self.totalsFor(snapshot, range: .allTime, label: "90d")
        let repos = self.reposFor(snapshot, range: .allTime)
        return TahoeDemo.RangeData(
            label: "90d",
            ticks: ticks,
            series: series,
            total: totals,
            repos: repos
        )
    }

    // MARK: - All-time: monthly buckets across the activity span

    private static func allTime(_ snapshot: UsageHistorySnapshot) -> TahoeDemo.RangeData {
        let cal = Calendar.current
        // Union of activity days across all providers.
        var allDays = Set<Date>()
        for (_, totals) in snapshot.byProvider {
            for day in totals.byDay.keys { allDays.insert(day) }
        }
        if allDays.isEmpty {
            return TahoeDemo.RangeData(
                label: "all time",
                ticks: [],
                series: [],
                total: self.totalsFor(snapshot, range: .allTime, label: "all time"),
                repos: self.reposFor(snapshot, range: .allTime)
            )
        }
        let sortedDays = allDays.sorted()
        guard let first = sortedDays.first, let last = sortedDays.last else {
            return TahoeDemo.RangeData(
                label: "all time",
                ticks: [],
                series: [],
                total: self.totalsFor(snapshot, range: .allTime, label: "all time"),
                repos: self.reposFor(snapshot, range: .allTime)
            )
        }
        let firstMonth = cal.dateInterval(of: .month, for: first)?.start ?? first
        let lastMonth = cal.dateInterval(of: .month, for: last)?.start ?? last
        var months: [Date] = []
        var cursor = firstMonth
        while cursor <= lastMonth, months.count < 24 {
            months.append(cursor)
            guard let next = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        let series = months.map { monthStart -> TahoeDemo.SpendPoint in
            let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            return self.spendPointForRange(snapshot, start: monthStart, end: monthEnd)
        }
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"
        let ticks = months.map { monthFormatter.string(from: $0) }
        return TahoeDemo.RangeData(
            label: "all time",
            ticks: ticks,
            series: series,
            total: self.totalsFor(snapshot, range: .allTime, label: "all time"),
            repos: self.reposFor(snapshot, range: .allTime)
        )
    }

    // MARK: - Helpers

    /// Bucket dollar values across `weeks` weekly windows ending today.
    private static func weeklySeries(_ snapshot: UsageHistorySnapshot, weeks: Int) -> [TahoeDemo.SpendPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<weeks).reversed().map { weekOffset -> TahoeDemo.SpendPoint in
            let weekEnd = cal.date(byAdding: .day, value: -7 * weekOffset, to: today) ?? today
            let weekStart = cal.date(byAdding: .day, value: -6, to: weekEnd) ?? weekEnd
            return self.spendPointForRange(snapshot, start: weekStart, end: cal.date(byAdding: .day, value: 1, to: weekEnd) ?? weekEnd)
        }
    }

    /// Sum dollar values across `[start, end)` for each provider.
    private static func spendPointForRange(_ snapshot: UsageHistorySnapshot, start: Date, end: Date) -> TahoeDemo.SpendPoint {
        var sums: [UsageRecord.Provider: Double] = [:]
        for (provider, totals) in snapshot.byProvider {
            var sum: Double = 0
            for (day, dayTotals) in totals.byDay where day >= start && day < end {
                sum += NSDecimalNumber(decimal: dayTotals.costUSD).doubleValue
            }
            sums[provider] = sum
        }
        return TahoeDemo.SpendPoint(
            c: sums[.claude] ?? 0,
            x: sums[.codex] ?? 0,
            g: sums[.gemini] ?? 0,
            o: sums[.opencode] ?? 0
        )
    }

    /// Per-provider dollar amount for a single day, optionally scaled
    /// (used by the 24h faux split).
    private static func spendPoint(_ snapshot: UsageHistorySnapshot, day: Date, scale: Double) -> TahoeDemo.SpendPoint {
        var sums: [UsageRecord.Provider: Double] = [:]
        for (provider, totals) in snapshot.byProvider {
            let value = totals.byDay[day]?.costUSD ?? 0
            sums[provider] = NSDecimalNumber(decimal: value).doubleValue * scale
        }
        return TahoeDemo.SpendPoint(
            c: sums[.claude] ?? 0,
            x: sums[.codex] ?? 0,
            g: sums[.gemini] ?? 0,
            o: sums[.opencode] ?? 0
        )
    }

    private static func totalsFor(_ snapshot: UsageHistorySnapshot, range: UsageHistorySnapshot.Window, label: String) -> TahoeDemo.Totals {
        func sum(_ provider: UsageRecord.Provider) -> Decimal {
            guard let totals = snapshot.byProvider[provider] else { return 0 }
            switch range {
            case .today:    return totals.today.totals.costUSD
            case .past7d:   return totals.past7d.totals.costUSD
            case .past30d:  return totals.past30d.totals.costUSD
            case .allTime:  return totals.allTime.totals.costUSD
            }
        }
        let c = sum(.claude)
        let x = sum(.codex)
        let g = sum(.gemini)
        let o = sum(.opencode)
        let all = c + x + g + o
        return TahoeDemo.Totals(
            c: Self.formatUSD(c),
            x: Self.formatUSD(x),
            g: Self.formatUSD(g),
            o: Self.formatUSD(o),
            all: Self.formatUSD(all),
            delta: "" // skip delta-vs-prior for v0.22.8; punt to a follow-up
        )
    }

    /// Build the top-N repo list, merging across all providers so each
    /// row's per-provider tint shows what fraction came from where.
    /// Mirrors the demo shape: top 4 by total + "Other" rest bucket.
    private static func reposFor(_ snapshot: UsageHistorySnapshot, range: UsageHistorySnapshot.Window) -> [TahoeDemo.SpendRepo] {
        var byRepo: [RepoKey: (c: Decimal, x: Decimal, g: Decimal, o: Decimal)] = [:]
        for (provider, providerTotals) in snapshot.byProvider {
            let window: WindowTotals = {
                switch range {
                case .today:   return providerTotals.today
                case .past7d:  return providerTotals.past7d
                case .past30d: return providerTotals.past30d
                case .allTime: return providerTotals.allTime
                }
            }()
            for entry in window.byRepo {
                var slot = byRepo[entry.repo] ?? (0, 0, 0, 0)
                switch provider {
                case .claude:   slot.c += entry.totals.costUSD
                case .codex:    slot.x += entry.totals.costUSD
                case .gemini:   slot.g += entry.totals.costUSD
                case .opencode: slot.o += entry.totals.costUSD
                case .cursor:   break
                }
                byRepo[entry.repo] = slot
            }
        }
        // Sort by total cost descending, take top 4, lump the rest as "Other".
        let sorted = byRepo
            .map { (repo: $0.key, sums: $0.value) }
            .sorted { (a, b) -> Bool in
                let aTotal = a.sums.c + a.sums.x + a.sums.g + a.sums.o
                let bTotal = b.sums.c + b.sums.x + b.sums.g + b.sums.o
                return aTotal > bTotal
            }
        let topN = 4
        let top = Array(sorted.prefix(topN))
        let rest = Array(sorted.dropFirst(topN))
        var out: [TahoeDemo.SpendRepo] = top.map { row in
            TahoeDemo.SpendRepo(
                name: RepoIdentity.displayName(for: row.repo),
                c: NSDecimalNumber(decimal: row.sums.c).doubleValue,
                x: NSDecimalNumber(decimal: row.sums.x).doubleValue,
                g: NSDecimalNumber(decimal: row.sums.g).doubleValue,
                o: NSDecimalNumber(decimal: row.sums.o).doubleValue
            )
        }
        if !rest.isEmpty {
            let restTotal = rest.reduce(into: (c: Decimal(0), x: Decimal(0), g: Decimal(0), o: Decimal(0))) { acc, row in
                acc.c += row.sums.c
                acc.x += row.sums.x
                acc.g += row.sums.g
                acc.o += row.sums.o
            }
            out.append(TahoeDemo.SpendRepo(
                name: "Other",
                c: NSDecimalNumber(decimal: restTotal.c).doubleValue,
                x: NSDecimalNumber(decimal: restTotal.x).doubleValue,
                g: NSDecimalNumber(decimal: restTotal.g).doubleValue,
                o: NSDecimalNumber(decimal: restTotal.o).doubleValue
            ))
        }
        return out
    }

    private static func weekdayLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"   // Mon, Tue, Wed, …
        return f.string(from: date)
    }

    private static func formatUSD(_ amount: Decimal) -> String {
        let n = NSDecimalNumber(decimal: amount)
        let value = n.doubleValue
        if value < 0.01 { return "$0.00" }
        if value < 10   { return String(format: "$%.2f", value) }
        return String(format: "$%.2f", value)
    }
}
