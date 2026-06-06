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
    @ObservedObject var usageModel: UsageModel
    @ObservedObject var agentClient: AgentControlClient
    @State private var window: UsageHistorySnapshot.Window = .past7d
    @State private var refreshing: Bool = false

    /// v0.14.0 (plan v2.1 D1): optional Live gauges header. When set,
    /// renders the per-provider live quota gauges above the analytics
    /// scroll, folding the retired standalone Live tab into Analytics.
    /// Nil-passing keeps the view backward-compatible.
    private let liveHeader: AnyView?
    private let onPairWithDesktop: () -> Void

    public init(usageModel: UsageModel, agentClient: AgentControlClient, onPairWithDesktop: @escaping () -> Void = {}) {
        self.usageModel = usageModel
        self.agentClient = agentClient
        self.liveHeader = nil
        self.onPairWithDesktop = onPairWithDesktop
    }

    public init<Header: View>(
        usageModel: UsageModel,
        agentClient: AgentControlClient,
        @ViewBuilder liveHeader: () -> Header,
        onPairWithDesktop: @escaping () -> Void = {}
    ) {
        self.usageModel = usageModel
        self.agentClient = agentClient
        self.liveHeader = AnyView(liveHeader())
        self.onPairWithDesktop = onPairWithDesktop
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
                IOSDesktopPairingCTA(client: agentClient, onPair: onPairWithDesktop)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)

                // Period segmented
                TahoeGlass(radius: 6, tone: .chip) {
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

                if let snapshot = usageModel.analyticsSnapshot {
                    let totalUSD = totalCost(in: snapshot, window: window)
                    let claudeUSD = providerCost(snapshot, .claude, window)
                    let codexUSD = providerCost(snapshot, .codex, window)
                    let geminiUSD = providerCost(snapshot, .gemini, window)
                    let opencodeUSD = providerCost(snapshot, .opencode, window)
                    let grokUSD = providerCost(snapshot, .grok, window)

                    // Total card
                    TahoeGlass(radius: 8, tone: .raised) {
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
                                providerStat(.opencode, formatUSD(opencodeUSD))
                                providerStat(.grok, formatUSD(grokUSD))
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

                            TahoeGlass(radius: 8, tone: .raised) {
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
                                                    Rectangle().fill(grad(.opencode)).frame(width: geo.size.width * width * (r.total == 0 ? 0 : (r.opencode / r.total)))
                                                    Rectangle().fill(grad(.cursor)).frame(width: geo.size.width * width * (r.total == 0 ? 0 : (r.cursor / r.total)))
                                                    Rectangle().fill(grad(.grok)).frame(width: geo.size.width * width * (r.total == 0 ? 0 : (r.grok / r.total)))
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

                    // Tokens by model (parity with Mac Usage tab). Token
                    // volume, not dollars — follows the page window selector.
                    IOSTokensByModelSection(snapshot: snapshot, window: window)
                        .padding(.horizontal, 16).padding(.bottom, 30)
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
        await usageModel.refreshMirroredData()
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
            + providerCost(s, .opencode, window)
            + providerCost(s, .cursor, window)
            + providerCost(s, .grok, window)
    }

    private func mapProvider(_ p: TahoeProvider) -> UsageRecord.Provider {
        switch p {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode  // PR #31
        case .cursor: return .cursor
        case .grok: return .grok
        }
    }

    private struct MergedRepoRow {
        let label: String
        let claude: Double
        let codex: Double
        let gemini: Double
        let opencode: Double
        let cursor: Double
        let grok: Double
        var total: Double { claude + codex + gemini + opencode + cursor + grok }
    }

    private func mergedByRepo(_ s: UsageHistorySnapshot, window: UsageHistorySnapshot.Window) -> [MergedRepoRow] {
        var bag: [String: (c: Double, x: Double, g: Double, o: Double, u: Double, k: Double)] = [:]
        for prov in [UsageRecord.Provider.claude, .codex, .gemini, .opencode, .cursor, .grok] {
            let rows = s.totals(for: prov).window(window).byRepo
            for row in rows {
                let key = row.repo  // RepoKey is a typealias for String
                let cost = doubleFrom(row.totals.costUSD)
                var current = bag[key] ?? (0, 0, 0, 0, 0, 0)
                switch prov {
                case .claude: current.c += cost
                case .codex:  current.x += cost
                case .gemini: current.g += cost
                case .opencode: current.o += cost
                case .cursor: current.u += cost
                case .grok: current.k += cost
                }
                bag[key] = current
            }
        }
        return bag.map { (key, v) in
            MergedRepoRow(
                label: displayName(forRepo: key),
                claude: v.c,
                codex: v.x,
                gemini: v.g,
                opencode: v.o,
                cursor: v.u,
                grok: v.k
            )
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
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.hair2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
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

    private struct DayBar {
        let date: Date
        let c: Double
        let x: Double
        let g: Double
        let o: Double
        let u: Double
        let k: Double
        var total: Double { c + x + g + o + u + k }
    }

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
                g: doubleFrom(byProvider[.gemini]?.byDay[date]?.costUSD ?? 0),
                o: doubleFrom(byProvider[.opencode]?.byDay[date]?.costUSD ?? 0),
                u: doubleFrom(byProvider[.cursor]?.byDay[date]?.costUSD ?? 0),
                k: doubleFrom(byProvider[.grok]?.byDay[date]?.costUSD ?? 0)
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
                            Rectangle().fill(grad(.grok)).frame(height: max(0, d.k / d.total * h))
                            Rectangle().fill(grad(.cursor)).frame(height: max(0, d.u / d.total * h))
                            Rectangle().fill(grad(.opencode)).frame(height: max(0, d.o / d.total * h))
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

// MARK: - Tokens by model (parity with Mac MacUsageView.TokensByModelSection)

/// iOS port of the Mac "Tokens by model" section: groups the windowed
/// per-model token volume by provider family and renders a per-family +
/// per-model breakdown. Token volume (not dollars), so unpriced models
/// (Grok, free OpenRouter, …) are included. Driven by the page-level window
/// selector via the shared `UsageHistorySnapshot.tokensByModel(in:)`.
private struct IOSTokensByModelSection: View {
    @Environment(\.tahoe) private var t
    var snapshot: UsageHistorySnapshot
    var window: UsageHistorySnapshot.Window

    private struct Family: Identifiable {
        let id: String
        let total: TokenTotals
        let models: [(name: String, totals: TokenTotals)]
        /// Largest single-model volume in the family — model bars scale to it.
        var maxModel: Int { models.map(\.totals.totalTokens).max() ?? 0 }
    }

    /// Map a raw model name to a provider family for grouping. Matches the Mac
    /// `TokensByModelSection.family(for:)` so both platforms bucket identically.
    static func family(for model: String) -> String {
        let m = model.lowercased()
        if m.hasPrefix("claude") || m == "opus" || m == "sonnet" || m == "haiku" { return "Claude" }
        if m.hasPrefix("gpt") || m.hasPrefix("chatgpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.contains("codex") { return "OpenAI" }
        if m.hasPrefix("gemini") || m.hasPrefix("gemma") { return "Gemini" }
        if m.hasPrefix("grok") || m.hasPrefix("xai/") { return "Grok" }
        return "Other"
    }

    private func families(from byModel: [String: TokenTotals]) -> [Family] {
        guard !byModel.isEmpty else { return [] }
        var grouped: [String: [(String, TokenTotals)]] = [:]
        for (model, totals) in byModel where totals.totalTokens > 0 {
            grouped[Self.family(for: model), default: []].append((model, totals))
        }
        return grouped.map { (fam, models) -> Family in
            var sum = TokenTotals.zero
            for (_, tot) in models { sum += tot }
            let sorted = models.sorted { $0.1.totalTokens > $1.1.totalTokens }
                .map { (name: $0.0, totals: $0.1) }
            return Family(id: fam, total: sum, models: sorted)
        }
        .sorted { $0.total.totalTokens > $1.total.totalTokens }
    }

    /// Family accent — reuse the provider lanes where they exist so the bars
    /// key the same colors as the dollar charts above.
    private func familyColor(_ family: String) -> Color {
        switch family {
        case "Claude": return TahoeProvider.claude.glow.color
        case "OpenAI": return TahoeProvider.codex.glow.color
        case "Gemini": return TahoeProvider.gemini.glow.color
        case "Grok":   return TahoeProvider.grok.glow.color
        default:        return t.fg3                                      // "Other"
        }
    }

    var body: some View {
        let fams = families(from: snapshot.tokensByModel(in: window))
        if !fams.isEmpty {
            let grand = fams.reduce(0) { $0 + $1.total.totalTokens }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("TOKENS BY MODEL")
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(t.fg3)
                    Spacer()
                    Text("\(Self.fmt(grand)) tokens")
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                }
                .padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 8)

                TahoeGlass(radius: 8, tone: .raised) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(fams) { fam in
                            familyBlock(fam, grandTotal: grand)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    @ViewBuilder
    private func familyBlock(_ fam: Family, grandTotal: Int) -> some View {
        let color = familyColor(fam.id)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(fam.id)
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text(grandTotal > 0 ? "\(Int((Double(fam.total.totalTokens) / Double(grandTotal) * 100).rounded()))%" : "")
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg4)
                Spacer()
                Text(Self.fmt(fam.total.totalTokens) + " tokens")
                    .font(TahoeFont.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(t.fg)
            }
            // Family share of the grand total — full-width bar.
            IOSProportionBar(fraction: grandTotal > 0 ? Double(fam.total.totalTokens) / Double(grandTotal) : 0,
                             color: color, height: 5)
            ForEach(fam.models, id: \.name) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(m.name)
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(t.fg2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.fmt(m.totals.totalTokens))
                            .font(TahoeFont.mono(11))
                            .monospacedDigit()
                            .foregroundStyle(t.fg)
                    }
                    // Bar scaled to the family's largest model.
                    IOSProportionBar(fraction: fam.maxModel > 0 ? Double(m.totals.totalTokens) / Double(fam.maxModel) : 0,
                                     color: color, height: 5)
                    Text("in \(Self.fmt(m.totals.inputTokens)) · out \(Self.fmt(m.totals.outputTokens)) · cache \(Self.fmt(m.totals.cacheReadTokens + m.totals.cacheCreationTokens))")
                        .font(TahoeFont.body(9.5))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1)
                }
                .padding(.leading, 2)
            }
        }
    }

    /// Compact token count: 1.2K / 3.4M / 5.6B.
    static func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
}

/// Thin horizontal proportion bar (0…1) for the iOS tokens-by-model section.
/// iOS twin of the Mac `ProportionBar` (private to MacUsageView).
private struct IOSProportionBar: View {
    @Environment(\.tahoe) private var t
    var fraction: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.5)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
    }
}
