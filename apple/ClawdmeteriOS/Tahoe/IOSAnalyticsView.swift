import SwiftUI
import ClawdmeterShared

/// iOS Analytics tab. Period segmented + total card + mini chart + by-repo.
/// Ports `ios-other.jsx::IOSAnalytics`.
///
/// v0.12 button-wiring pass: the view now consumes the real
/// `UsageHistorySnapshot` from `AgentControlClient.fetchAnalytics()`
/// instead of the JSX demo fixture. Period segmented control switches
/// the displayed window (today / 7d / 30d / all). The "sliders" header
/// button now triggers a manual refresh (no filter sheet exists yet —
/// the gesture replaces a silent no-op).
public struct IOSAnalyticsView: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var agentClient: AgentControlClient
    @State private var window: UsageHistorySnapshot.Window = .past7d
    @State private var snapshot: UsageHistorySnapshot?
    @State private var refreshing: Bool = false

    /// v0.14.0 (plan v2.1 D1): optional Live gauges header. When set,
    /// renders the per-provider live quota gauges above the analytics
    /// scroll, folding the retired standalone Live tab into Analytics.
    /// Nil-passing keeps the view backward-compatible.
    private let liveHeader: AnyView?

    public init(agentClient: AgentControlClient) {
        self.agentClient = agentClient
        self.liveHeader = nil
    }

    public init<Header: View>(agentClient: AgentControlClient, @ViewBuilder liveHeader: () -> Header) {
        self.agentClient = agentClient
        self.liveHeader = AnyView(liveHeader())
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                IOSLargeTitle(title: "Analytics") {
                    IOSRoundIconBtn("sliders", action: { Task { await refresh() } })
                }
                if let liveHeader {
                    liveHeader
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                // Period segmented
                TahoeGlass(radius: 12, tone: .chip) {
                    HStack(spacing: 0) {
                        ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { w in
                            let active = w == window
                            Button { window = w } label: {
                                Text(label(for: w))
                                    .font(TahoeFont.body(13, weight: .semibold))
                                    .foregroundStyle(active ? t.fg : t.fg2)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background {
                                        if active {
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.16) : .white)
                                                .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)

                if let snapshot {
                    let totalUSD = totalCost(in: snapshot, window: window)
                    let claudeUSD = providerCost(snapshot, .claude, window)
                    let codexUSD = providerCost(snapshot, .codex, window)
                    let geminiUSD = providerCost(snapshot, .gemini, window)

                    // Total card
                    TahoeGlass(radius: 22, tone: .raised) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("TOTAL · \(window.label.uppercased())")
                                .font(TahoeFont.body(11, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(t.fg3)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(formatUSD(totalUSD))
                                    .font(TahoeFont.rounded(42, weight: .heavy))
                                    .monospacedDigit()
                                    .tracking(-1)
                                    .foregroundStyle(t.fg)
                                Text("\(snapshot.sessionCount) session\(snapshot.sessionCount == 1 ? "" : "s")")
                                    .font(TahoeFont.body(13, weight: .semibold))
                                    .foregroundStyle(t.fg3)
                            }
                            .padding(.top, 6)

                            MiniSpendChart(byProvider: snapshot.byProvider, window: window)
                                .padding(.top, 16)

                            HStack(spacing: 8) {
                                providerStat(.claude, formatUSD(claudeUSD))
                                providerStat(.codex,  formatUSD(codexUSD))
                                providerStat(.gemini, formatUSD(geminiUSD))
                            }
                            .padding(.top, 16)
                        }
                        .padding(18)
                    }
                    .padding(.horizontal, 16)

                    // By repo — merge top-8 byRepo lists across providers.
                    let merged = mergedByRepo(snapshot, window: window)
                    if !merged.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("BY REPO")
                                    .font(TahoeFont.body(11, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(t.fg3)
                                Spacer()
                                Text(window.label.lowercased()).font(TahoeFont.body(11)).foregroundStyle(t.fg3)
                            }
                            .padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 8)

                            TahoeGlass(radius: 22, tone: .raised) {
                                VStack(spacing: 0) {
                                    let maxTotal = merged.map { $0.total }.max() ?? 1
                                    ForEach(Array(merged.enumerated()), id: \.offset) { _, r in
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                HStack(spacing: 6) {
                                                    TahoeIcon("folder", size: 12).foregroundStyle(t.fg3)
                                                    Text(r.label).font(TahoeFont.body(13)).foregroundStyle(t.fg)
                                                        .lineLimit(1)
                                                }
                                                Spacer()
                                                Text(formatUSD(r.total))
                                                    .font(TahoeFont.mono(12))
                                                    .monospacedDigit()
                                                    .foregroundStyle(t.fg2)
                                            }
                                            GeometryReader { geo in
                                                let width = r.total / maxTotal
                                                HStack(spacing: 0) {
                                                    Rectangle().fill(grad(.claude)).frame(width: geo.size.width * width * (r.total == 0 ? 0 : (r.claude / r.total)))
                                                    Rectangle().fill(grad(.codex)).frame(width: geo.size.width * width * (r.total == 0 ? 0 : (r.codex / r.total)))
                                                    Rectangle().fill(grad(.gemini)).frame(width: geo.size.width * width * (r.total == 0 ? 0 : (r.gemini / r.total)))
                                                    Spacer()
                                                }
                                            }
                                            .frame(height: 8)
                                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                        }
                                        .padding(.horizontal, 4).padding(.vertical, 10)
                                    }
                                }
                                .padding(14)
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 30)
                    }
                } else {
                    // Loading / empty state — `fetchAnalytics()` hasn't
                    // returned yet (or returned nil).
                    VStack(spacing: 8) {
                        if refreshing {
                            ProgressView()
                            Text("Loading analytics…")
                                .font(TahoeFont.body(13))
                                .foregroundStyle(t.fg3)
                        } else {
                            TahoeIcon("diff", size: 22).foregroundStyle(t.fg4)
                            Text("No analytics yet")
                                .font(TahoeFont.body(14, weight: .semibold))
                                .foregroundStyle(t.fg2)
                            Text("Run a session to see spend breakdowns here.")
                                .font(TahoeFont.body(12))
                                .foregroundStyle(t.fg3)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    // MARK: - Data plumbing

    private func label(for w: UsageHistorySnapshot.Window) -> String {
        switch w {
        case .today: return "Today"
        case .past7d: return "7d"
        case .past30d: return "30d"
        case .allTime: return "All"
        }
    }

    @MainActor
    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        snapshot = await agentClient.fetchAnalytics()
    }

    private func providerCost(_ s: UsageHistorySnapshot, _ p: TahoeProvider, _ w: UsageHistorySnapshot.Window) -> Double {
        let prov = mapProvider(p)
        let totals = s.totals(for: prov).window(w).totals
        return doubleFrom(totals.costUSD)
    }

    private func totalCost(in s: UsageHistorySnapshot, window: UsageHistorySnapshot.Window) -> Double {
        providerCost(s, .claude, window)
            + providerCost(s, .codex, window)
            + providerCost(s, .gemini, window)
            + providerCost(s, .cursor, window)
    }

    private func mapProvider(_ p: TahoeProvider) -> UsageRecord.Provider {
        switch p {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode  // PR #31
        case .cursor: return .cursor
        }
    }

    private struct MergedRepoRow {
        let label: String
        let claude: Double
        let codex: Double
        let gemini: Double
        var total: Double { claude + codex + gemini }
    }

    private func mergedByRepo(_ s: UsageHistorySnapshot, window: UsageHistorySnapshot.Window) -> [MergedRepoRow] {
        var bag: [String: (c: Double, x: Double, g: Double)] = [:]
        for prov in [UsageRecord.Provider.claude, .codex, .gemini] {
            let rows = s.totals(for: prov).window(window).byRepo
            for row in rows {
                let key = row.repo  // RepoKey is a typealias for String
                let cost = doubleFrom(row.totals.costUSD)
                var current = bag[key] ?? (0, 0, 0)
                switch prov {
                case .claude: current.c += cost
                case .codex:  current.x += cost
                case .gemini: current.g += cost
                case .opencode:
                    // PR #29: MergedRepoRow is a 3-column structure for
                    // claude/codex/gemini. Surfacing OpenCode in this
                    // chart needs the row struct extended to 4 columns
                    // + the chart legend updated — queued for the
                    // OpenCode analytics polish PR. For now, the outer
                    // iteration only walks 3 providers, so this case
                    // is unreachable; kept for switch exhaustiveness.
                    break
                case .cursor:
                    break
                }
                bag[key] = current
            }
        }
        return bag.map { (key, v) in
            MergedRepoRow(label: displayName(forRepo: key), claude: v.c, codex: v.x, gemini: v.g)
        }
        .filter { $0.total > 0 }
        .sorted { $0.total > $1.total }
        .prefix(8)
        .map { $0 }
    }

    private func displayName(forRepo key: String) -> String {
        if key == "__rest__" { return "Other repos" }
        if key == "(unknown)" { return "(unknown)" }
        return (key as NSString).lastPathComponent
    }

    private func doubleFrom(_ d: Decimal) -> Double {
        NSDecimalNumber(decimal: d).doubleValue
    }

    private func formatUSD(_ v: Double) -> String {
        if v < 0.01 { return "$0.00" }
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    private func grad(_ p: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: [p.glow.color, p.base.color], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private func providerStat(_ p: TahoeProvider, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TahoeProviderGlyph(provider: p, size: 14)
                Text(p.displayName)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg3)
            }
            Text(value)
                .font(TahoeFont.rounded(16, weight: .bold))
                .monospacedDigit()
                .tracking(-0.3)
                .foregroundStyle(t.fg)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.hair2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }
}

/// Mini per-day stacked bar chart. Reads `byDay` from each provider's
/// `ProviderTotals` and renders the trailing 7 days for `past7d`, 30 days
/// for `past30d`/`allTime`, or just today for `today` (degenerate single
/// bar).
private struct MiniSpendChart: View {
    @Environment(\.tahoe) private var t
    var byProvider: [UsageRecord.Provider: ProviderTotals]
    var window: UsageHistorySnapshot.Window

    private struct DayBar { let date: Date; let c: Double; let x: Double; let g: Double; var total: Double { c + x + g } }

    private var bars: [DayBar] {
        let now = Calendar.current.startOfDay(for: Date())
        let days: Int = {
            switch window {
            case .today: return 1
            case .past7d: return 7
            case .past30d, .allTime: return 30
            }
        }()
        return (0..<days).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) ?? now
            return DayBar(
                date: date,
                c: doubleFrom(byProvider[.claude]?.byDay[date]?.costUSD ?? 0),
                x: doubleFrom(byProvider[.codex]?.byDay[date]?.costUSD ?? 0),
                g: doubleFrom(byProvider[.gemini]?.byDay[date]?.costUSD ?? 0)
            )
        }
    }

    var body: some View {
        let bars = self.bars
        let maxV: Double = max(bars.map { $0.total }.max() ?? 0, 0.01)
        HStack(alignment: .bottom, spacing: bars.count > 14 ? 2 : 6) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, d in
                let h = d.total / maxV * 70
                VStack(spacing: 4) {
                    if d.total == 0 {
                        Rectangle().fill(t.hair2).frame(height: 2)
                    } else {
                        VStack(spacing: 0) {
                            Rectangle().fill(grad(.gemini)).frame(height: max(0, d.g / d.total * h))
                            Rectangle().fill(grad(.codex)).frame(height: max(0, d.x / d.total * h))
                            Rectangle().fill(grad(.claude)).frame(height: max(0, d.c / d.total * h))
                        }
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    if bars.count <= 14 {
                        Text(dayLabel(for: d.date))
                            .font(TahoeFont.body(9))
                            .foregroundStyle(t.fg4)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 80)
    }

    private func dayLabel(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return String(fmt.string(from: date).prefix(1))
    }

    private func doubleFrom(_ d: Decimal) -> Double {
        NSDecimalNumber(decimal: d).doubleValue
    }

    private func grad(_ p: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: [p.glow.color, p.base.color], startPoint: .top, endPoint: .bottom)
    }
}
