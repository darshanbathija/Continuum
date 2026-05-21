import SwiftUI
import ClawdmeterShared

/// Mac Usage dashboard — three provider columns + analytics row.
/// Ports `mac-dashboard.jsx`.
public struct MacUsageView: View {
    @Environment(\.tahoe) private var t

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ProviderColumn(
                        provider: .claude, percent: 67, weekly: 42,
                        resetIn: "2h 18m", weeklyIn: "4d 6h", model: "Sonnet 4.5",
                        autoReviveOn: true, autoReviveAgo: "4h ago", menuBarDefault: true
                    )
                    ProviderColumn(
                        provider: .codex, percent: 34, weekly: 28,
                        resetIn: "4h 02m", weeklyIn: "6d 1h", model: "gpt-5",
                        autoReviveOn: true, autoReviveAgo: "3h ago", menuBarDefault: true
                    )
                    ProviderColumn(
                        provider: .gemini, percent: 89, weekly: 61,
                        resetIn: "58m", weeklyIn: "5d 2h", model: "antigravity-pro",
                        autoReviveOn: true, autoReviveAgo: "2h ago", menuBarDefault: true
                    )
                }
                .padding(.horizontal, 6).padding(.bottom, 18)

                TahoeHair()

                AnalyticsRow()
                    .padding(.top, 14)
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Provider column

private struct ProviderColumn: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var percent: Double
    var weekly: Double
    var resetIn: String
    var weeklyIn: String
    var model: String
    var autoReviveOn: Bool
    var autoReviveAgo: String
    var menuBarDefault: Bool

    @State private var menuBar: Bool
    @State private var autoRevive: Bool

    init(provider: TahoeProvider, percent: Double, weekly: Double,
         resetIn: String, weeklyIn: String, model: String,
         autoReviveOn: Bool, autoReviveAgo: String, menuBarDefault: Bool) {
        self.provider = provider; self.percent = percent; self.weekly = weekly
        self.resetIn = resetIn; self.weeklyIn = weeklyIn; self.model = model
        self.autoReviveOn = autoReviveOn; self.autoReviveAgo = autoReviveAgo
        self.menuBarDefault = menuBarDefault
        _menuBar = State(initialValue: menuBarDefault)
        _autoRevive = State(initialValue: autoReviveOn)
    }

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    TahoeProviderGlyph(provider: provider, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(TahoeFont.body(16, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(t.fg)
                        Text(model)
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                    }
                    Spacer()
                    MenuBarCheckbox(on: $menuBar)
                }

                // QuotaBar
                TahoeQuotaBar(provider: provider, percent: percent, size: 260,
                              label: "session", sublabel: "resets in \(resetIn)")
                .padding(.vertical, 28)

                // Weekly row
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Weekly · all models")
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg2)
                        Spacer()
                        Text("\(Int(weekly))% · \(weeklyIn)")
                            .font(TahoeFont.mono(11.5))
                            .foregroundStyle(t.fg3)
                    }
                    TahoePillBar(percent: weekly, provider: provider, height: 6)
                }

                Spacer(minLength: 12)

                // Auto-revive card
                TahoeGlass(radius: 12, tone: .chip) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keep 5h timer ticking")
                                .font(TahoeFont.body(12, weight: .semibold))
                                .foregroundStyle(t.fg)
                            Text("Auto-revive · " + (autoRevive ? "last fired \(autoReviveAgo)" : "off"))
                                .font(TahoeFont.body(10.5))
                                .foregroundStyle(t.fg3)
                        }
                        Spacer()
                        TahoeToggleView(on: $autoRevive)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .padding(.top, 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)
        }
    }
}

private struct MenuBarCheckbox: View {
    @Environment(\.tahoe) private var t
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(on ? t.accent : .clear)
                        .frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(on ? t.accent : t.fg4, lineWidth: 1)
                        .frame(width: 12, height: 12)
                    if on {
                        TahoeIcon("check", size: 9, weight: .bold)
                            .foregroundStyle(.white)
                    }
                }
                Text("Menu bar")
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(on ? t.accent : t.fg3)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(t.glassTintHi)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Analytics

private struct AnalyticsRow: View {
    @Environment(\.tahoe) private var t
    @State private var range: String = "7d"

    private var data: TahoeDemo.RangeData { TahoeDemo.ranges[range] ?? TahoeDemo.ranges["7d"]! }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("ANALYTICS")
                    .font(TahoeFont.body(11.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                TahoeHair(vertical: true).frame(height: 14)
                Legend()
                Spacer()
                RangeSelector(value: $range)
            }
            .padding(.horizontal, 14)

            HStack(alignment: .top, spacing: 14) {
                TahoeGlass(radius: 20, tone: .panel) {
                    VStack(alignment: .leading, spacing: 0) {
                        ChartHeader(title: "Spend over time", range: data.label, total: data.total)
                        SpendChart(series: data.series, ticks: data.ticks)
                    }
                    .padding(18)
                }
                .frame(maxWidth: .infinity)
                .frame(idealHeight: 280)

                TahoeGlass(radius: 20, tone: .panel) {
                    VStack(alignment: .leading, spacing: 0) {
                        ChartHeader(title: "Spend by repo", range: data.label, total: nil)
                        RepoList(repos: data.repos)
                    }
                    .padding(18)
                }
                .frame(width: 380)
                .frame(idealHeight: 280)
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 14)
    }
}

private struct Legend: View {
    @Environment(\.tahoe) private var t
    var body: some View {
        HStack(spacing: 14) {
            ForEach(TahoeProvider.allCases) { p in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient(colors: [p.glow.color, p.base.color],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 9, height: 9)
                        .shadow(color: p.base.color(opacity: 0.6), radius: 3, x: 0, y: 0)
                    Text(p.displayName)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg2)
                }
            }
        }
    }
}

private struct RangeSelector: View {
    @Environment(\.tahoe) private var t
    @Binding var value: String
    private let items: [(String, String)] = [
        ("24h","24h"),("7d","7d"),("30d","30d"),("90d","90d"),("all","All time"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { (k, label) in
                let active = k == value
                Button { value = k } label: {
                    Text(label)
                        .font(TahoeFont.mono(11.5, weight: active ? .bold : .semibold))
                        .foregroundStyle(active ? t.fg : t.fg3)
                        .tracking(0.2)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background {
                            if active {
                                Capsule(style: .continuous)
                                    .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                                    .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            Capsule(style: .continuous)
                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
        }
        .overlay {
            Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }
}

private struct ChartHeader: View {
    @Environment(\.tahoe) private var t
    var title: String
    var range: String
    var total: TahoeDemo.Totals?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(TahoeFont.body(11.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                Text(range == "all time" ? "all time" : "past \(range)")
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg4)
            }
            Spacer()
            if let total {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(total.all)
                        .font(TahoeFont.rounded(22, weight: .bold))
                        .monospacedDigit()
                        .tracking(-0.6)
                        .foregroundStyle(t.fg)
                    Text("\(total.delta) vs prior")
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(total.delta.hasPrefix("+") ? Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0) : t.fg3)
                }
            }
        }
    }
}

private struct SpendChart: View {
    @Environment(\.tahoe) private var t
    var series: [TahoeDemo.SpendPoint]
    var ticks: [String]
    private let lines = 4
    private let chartHeight: CGFloat = 170

    var body: some View {
        let maxTotal = (series.map { $0.c + $0.x + $0.g }.max() ?? 1) * 1.08
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                // Y axis labels
                VStack(alignment: .trailing) {
                    ForEach(0..<lines, id: \.self) { i in
                        let v = maxTotal * (1 - Double(i) / Double(lines - 1))
                        Text(v < 10 ? String(format: "$%.1f", v) : String(format: "$%d", Int(v)))
                            .font(TahoeFont.mono(10))
                            .foregroundStyle(t.fg4)
                        if i < lines - 1 { Spacer() }
                    }
                }
                .frame(width: 28, height: chartHeight, alignment: .topTrailing)

                ZStack(alignment: .bottom) {
                    // gridlines
                    VStack(spacing: 0) {
                        ForEach(0..<lines, id: \.self) { i in
                            TahoeHair()
                            if i < lines - 1 { Spacer() }
                        }
                    }
                    .frame(height: chartHeight)

                    // bars
                    GeometryReader { geo in
                        let barSpacing: CGFloat = 6
                        let barCount = max(series.count, 1)
                        let barW = max((geo.size.width - barSpacing * CGFloat(barCount - 1)) / CGFloat(barCount) * 0.78, 4)
                        HStack(alignment: .bottom, spacing: barSpacing) {
                            ForEach(Array(series.enumerated()), id: \.offset) { _, d in
                                stackedBar(d: d, max: maxTotal, w: barW)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: chartHeight)
                }
            }

            // X labels
            HStack {
                Spacer().frame(width: 36)
                HStack {
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        Text(tick)
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.top, 14)
    }

    private func stackedBar(d: TahoeDemo.SpendPoint, max: Double, w: CGFloat) -> some View {
        let total = d.c + d.x + d.g
        let h = total / max * chartHeight
        return VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                Rectangle().fill(grad(.gemini)).frame(height: d.g / total * h)
                Rectangle().fill(grad(.codex)).frame(height: d.x / total * h)
                Rectangle().fill(grad(.claude)).frame(height: d.c / total * h)
            }
            .frame(width: w)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: TahoeProvider.claude.base.color(opacity: 0.18), radius: 7, x: 0, y: 0)
        }
    }

    private func grad(_ p: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: [p.glow.color, p.base.color], startPoint: .top, endPoint: .bottom)
    }
}

private struct RepoList: View {
    @Environment(\.tahoe) private var t
    var repos: [TahoeDemo.SpendRepo]
    var body: some View {
        let maxTotal = repos.map { $0.c + $0.x + $0.g }.max() ?? 1
        VStack(spacing: 12) {
            ForEach(Array(repos.enumerated()), id: \.offset) { _, r in
                let total = r.c + r.x + r.g
                let width = total / maxTotal
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        HStack(spacing: 6) {
                            TahoeIcon("folder", size: 11).foregroundStyle(t.fg3)
                            Text(r.name).font(TahoeFont.body(11.5, weight: .medium))
                        }
                        Spacer()
                        Text(String(format: "$%.2f", total))
                            .font(TahoeFont.mono(11.5))
                            .monospacedDigit()
                            .foregroundStyle(t.fg2)
                    }
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            Rectangle().fill(grad(.claude)).frame(width: geo.size.width * width * (r.c / total))
                            Rectangle().fill(grad(.codex)).frame(width: geo.size.width * width * (r.x / total))
                            Rectangle().fill(grad(.gemini)).frame(width: geo.size.width * width * (r.g / total))
                            Spacer()
                        }
                    }
                    .frame(height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: TahoeProvider.claude.base.color(opacity: 0.15), radius: 5, x: 0, y: 0)
                }
            }
        }
        .padding(.top, 14)
    }

    private func grad(_ p: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: [p.glow.color, p.base.color], startPoint: .top, endPoint: .bottom)
    }
}
