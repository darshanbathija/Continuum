#if !os(watchOS)
import SwiftUI
import Charts

/// Per-day stacked spend chart. Claude + Codex (or one) over the active
/// window. Plan A6 + verified note: `BarMark` stacks by default when two
/// marks share an X value — we do NOT use `.position(by:)` (that would
/// group, not stack).
@available(macOS 13, iOS 16, *)
public struct AnalyticsDailyChart: View {

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

    // MARK: - Chart data

    private struct Point: Identifiable {
        let id: String
        let day: Date
        let cost: Decimal
        let provider: String
    }

    private var points: [Point] {
        // Plan A6: "All time" hides the chart.
        guard window != .allTime else { return [] }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let length: Int
        switch window {
        case .today: length = 1
        case .past7d: length = 7
        case .past30d: length = 30
        case .allTime: length = 0
        }
        guard length > 0 else { return [] }

        var out: [Point] = []
        for offset in 0..<length {
            guard let day = cal.date(byAdding: .day, value: -(length - 1 - offset), to: today) else { continue }
            if providerFilter != .codex {
                let c = snapshot.claude.byDay[day]?.costUSD ?? 0
                out.append(Point(id: "claude-\(day.timeIntervalSince1970)", day: day, cost: c, provider: "Claude"))
            }
            if providerFilter != .claude {
                let c = snapshot.codex.byDay[day]?.costUSD ?? 0
                out.append(Point(id: "codex-\(day.timeIntervalSince1970)", day: day, cost: c, provider: "Codex"))
            }
        }
        return out
    }

    // MARK: - Body

    public var body: some View {
        let data = points
        if data.isEmpty {
            EmptyView()
        } else {
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
                // Replace the auto-generated colored-dot legend with our
                // own provider-logo legend below. Matches the Live tab's
                // section headers so users get the same visual anchor
                // across screens.
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

                legendRow

                if let max = maxDay(data) {
                    Text("Max day \(AnalyticsCurrencyFormatter.format(max.cost)) · \(max.day.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Custom legend: provider logo + name + matching colored dot, in
    /// place of Swift Charts's auto legend (which only carries the
    /// colored dot + name string).
    private var legendRow: some View {
        HStack(spacing: 14) {
            if providerFilter != .codex {
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
            if providerFilter != .claude {
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

    private func maxDay(_ data: [Point]) -> (cost: Decimal, day: Date)? {
        // Sum across providers per day, then find the max.
        let grouped = Dictionary(grouping: data, by: \.day)
        guard let best = grouped.max(by: { lhs, rhs in
            lhs.value.reduce(Decimal.zero, { $0 + $1.cost }) < rhs.value.reduce(Decimal.zero, { $0 + $1.cost })
        }) else { return nil }
        let total = best.value.reduce(Decimal.zero, { $0 + $1.cost })
        if total == 0 { return nil }
        return (cost: total, day: best.key)
    }
}
#endif
