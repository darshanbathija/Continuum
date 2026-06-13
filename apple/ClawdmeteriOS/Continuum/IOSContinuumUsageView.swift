import SwiftUI
import ClawdmeterShared

/// Continuum Mobile Usage — live provider hero + spend analytics from paired Mac.
public struct IOSContinuumUsageView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var usageModel: UsageModel
    @ObservedObject var agentClient: AgentControlClient
    var onOpenSettings: () -> Void

    @State private var provider: TahoeProvider = .claude
    @State private var window: UsageHistorySnapshot.Window = .past7d
    @State private var refreshing = false
    @State private var autoRevive: [TahoeProvider: Bool] = [:]

    public init(
        usageModel: UsageModel,
        agentClient: AgentControlClient,
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.usageModel = usageModel
        self.agentClient = agentClient
        self.onOpenSettings = onOpenSettings
    }

    private var live: TahoeLiveBindings { usageModel.tahoeLive }

    public var body: some View {
        let visible = visibleProviders
        let active = visible.contains(provider) ? provider : (visible.first ?? provider)
        let row = live.row(for: active)

        ScrollView {
            VStack(spacing: 0) {
                header
                if visible.isEmpty {
                    emptyProviders
                } else {
                    providerTabs(visible: visible, active: active)
                        .padding(.top, 12)
                    heroCard(provider: active, row: row)
                        .padding(.top, 14)
                    autoReviveCard(provider: active, row: row)
                        .padding(.top, 12)
                    analyticsSection(activeProvider: active)
                        .padding(.top, 18)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable {
            await refresh()
        }
        .task {
            await refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                ContinuumScreenHeader(title: "Usage")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                ContinuumEtchedLabel(text: "Today")
                Text(todaySpendLabel)
                    .font(ContinuumFont.mono(15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.fg)
            }
            Button(action: ContinuumAnalytics.wrapButton("usage_settings", onOpenSettings)) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .frame(width: 38, height: 38)
                    .background(theme.surface2)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }

    private var todaySpendLabel: String {
        guard let snapshot = usageModel.analyticsSnapshot else { return "—" }
        let total = visibleProviders.reduce(0.0) { $0 + providerCost(snapshot, $1, .today) }
        return formatUSD(total)
    }

    private var emptyProviders: some View {
        ContinuumSurface(level: .one, padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No providers enabled")
                    .font(ContinuumFont.body(16, weight: .semibold))
                    .foregroundStyle(theme.fg)
                Text("Enable providers in Settings after pairing with your Mac.")
                    .font(ContinuumFont.body(13))
                    .foregroundStyle(theme.fg3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 20)
    }

    private func providerTabs(visible: [TahoeProvider], active: TahoeProvider) -> some View {
        HStack(spacing: 6) {
            ForEach(visible) { p in
                let on = p == active
                Button(action: { provider = p }) {
                    VStack(spacing: 5) {
                        TahoeProviderGlyph(provider: p, size: 21)
                        Text(p.displayName)
                            .font(ContinuumFont.body(10.5, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? theme.fg : theme.fg3)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(on ? p.dot.opacity(0.14) : theme.surface1)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(on ? p.dot.opacity(0.38) : theme.hairline, lineWidth: 0.5)
                    }
                    .opacity(on ? 1 : 0.55)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func heroCard(provider: TahoeProvider, row: TahoeLiveRow) -> some View {
        let metricColor = theme.metricColor(percent: row.sessionPercent)
        let todayUSD = todayCost(for: provider)
        let hasQuota = row.sessionResetIn != "\u{2014}"
        return ContinuumSurface(level: .one, padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    ContinuumEtchedLabel(text: "Session")
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        if hasQuota {
                            Text("\(Int(row.sessionPercent))")
                                .font(ContinuumFont.display(42, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(metricColor)
                            Text("%")
                                .font(ContinuumFont.display(21, weight: .bold))
                                .foregroundStyle(theme.fg3)
                        } else {
                            Text("\u{2014}")
                                .font(ContinuumFont.display(42, weight: .bold))
                                .foregroundStyle(theme.fg3)
                        }
                    }
                }
                TahoeRailMeter(percent: row.sessionPercent, provider: provider, height: 10)
                HStack {
                    if row.hasWeekly {
                        Text("weekly \(Int(max(0, row.weeklyPercent)))%")
                    }
                    Spacer()
                    Text("resets \(row.sessionResetIn)")
                }
                .font(ContinuumFont.mono(11))
                .foregroundStyle(theme.fg3)
                if let todayUSD {
                    HStack(spacing: 6) {
                        Text("today")
                            .foregroundStyle(theme.fg3)
                        Text(formatUSD(todayUSD))
                            .foregroundStyle(theme.fg)
                    }
                    .font(ContinuumFont.mono(12, weight: .semibold))
                }
            }
        }
    }

    private func autoReviveCard(provider: TahoeProvider, row: TahoeLiveRow) -> some View {
        ContinuumSurface(level: .one, padding: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(provider.dot.opacity(0.18))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(provider.dot)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep 5h timer ticking")
                        .font(ContinuumFont.body(14, weight: .semibold))
                        .foregroundStyle(theme.fg)
                    Text(autoReviveSubtitle(provider: provider, row: row))
                        .font(ContinuumFont.body(11.5))
                        .foregroundStyle(theme.fg3)
                }
                Spacer()
                if provider == .opencode || provider == .grok {
                    Text("Unavailable")
                        .font(ContinuumFont.body(11, weight: .semibold))
                        .foregroundStyle(theme.fg3)
                } else {
                    Toggle("", isOn: Binding(
                        get: { autoRevive[provider] ?? false },
                        set: { newValue in
                            autoRevive[provider] = newValue
                            Task { @MainActor in
                                await agentClient.setAutoRevive(
                                    provider: agentKind(for: provider),
                                    enabled: newValue
                                )
                            }
                        }
                    ))
                    .labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private func analyticsSection(activeProvider: TahoeProvider) -> some View {
        if let snapshot = usageModel.analyticsSnapshot {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ContinuumEtchedLabel(text: "Spend")
                    Spacer()
                    periodPicker
                }
                ContinuumSurface(level: .one, padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(formatUSD(totalCost(in: snapshot, window: window)))
                            .font(ContinuumFont.display(42, weight: .heavy))
                            .monospacedDigit()
                            .foregroundStyle(theme.fg)
                        Text("\(snapshot.sessionCount) session\(snapshot.sessionCount == 1 ? "" : "s") · \(window.shortLabel)")
                            .font(ContinuumFont.body(13, weight: .semibold))
                            .foregroundStyle(theme.fg3)
                        AnalyticsTotalsGrid(snapshot: snapshot, isLoading: refreshing)
                    }
                }
                ContinuumEtchedLabel(text: "Spend over time")
                ContinuumSurface(level: .one, padding: 14) {
                    ContinuumSpendChart(byProvider: snapshot.byProvider, window: window)
                }
                let repos = mergedByRepo(snapshot, window: window)
                if !repos.isEmpty {
                    ContinuumEtchedLabel(text: "By repo")
                    ContinuumSurface(level: .one, padding: 14) {
                        VStack(spacing: 10) {
                            ForEach(Array(repos.enumerated()), id: \.offset) { _, r in
                                repoSpendRow(r, maxTotal: repos.map(\.total).max() ?? 1)
                            }
                        }
                    }
                }
            }
        } else {
            ContinuumSurface(level: .one, padding: 18) {
                VStack(spacing: 8) {
                    if refreshing {
                        ProgressView()
                    }
                    Text(refreshing ? "Loading analytics…" : "No analytics yet")
                        .font(ContinuumFont.body(14, weight: .semibold))
                        .foregroundStyle(theme.fg2)
                    Text("Run a session on your Mac to see spend breakdowns here.")
                        .font(ContinuumFont.body(12))
                        .foregroundStyle(theme.fg3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { w in
                let active = w == window
                Button { window = w } label: {
                    Text(w == .today ? "Today" : w == .past7d ? "7d" : w == .past30d ? "30d" : "All")
                        .font(ContinuumFont.body(12, weight: .semibold))
                        .foregroundStyle(active ? theme.fg : theme.fg3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.segmentActiveFill)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func repoSpendRow(_ r: MergedRepoRow, maxTotal: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.label)
                    .font(ContinuumFont.body(13, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                Spacer()
                Text(formatUSD(r.total))
                    .font(ContinuumFont.mono(12))
                    .foregroundStyle(theme.fg2)
            }
            GeometryReader { geo in
                let width = r.total / maxTotal
                HStack(spacing: 0) {
                    segmentBar(.claude, r.claude, r.total, geo.size.width * width)
                    segmentBar(.codex, r.codex, r.total, geo.size.width * width)
                    segmentBar(.gemini, r.gemini, r.total, geo.size.width * width)
                    segmentBar(.opencode, r.opencode, r.total, geo.size.width * width)
                    segmentBar(.cursor, r.cursor, r.total, geo.size.width * width)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    @ViewBuilder
    private func segmentBar(_ p: TahoeProvider, _ amount: Double, _ total: Double, _ maxW: CGFloat) -> some View {
        if total > 0, amount > 0 {
            Rectangle()
                .fill(ProviderFill.gradient(for: p))
                .frame(width: maxW * (amount / total))
        }
    }

    // MARK: - Data

    private var visibleProviders: [TahoeProvider] {
        let all = TahoeProvider.allCases.filter {
            ProviderRegistry.descriptor(id: $0.rawValue)?.capabilities.contains(.mobileMirror) ?? false
        }
        if let ids = usageModel.enabledProviderIDs ?? usageModel.analyticsSnapshot?.enabledProviderIDs {
            let enabled = Set(ids.map { ProviderRegistry.rootProviderID(for: $0) })
            let filtered = all.filter { enabled.contains(ProviderRegistry.rootProviderID(for: $0.rawValue)) }
            if !filtered.isEmpty { return filtered }
        }
        return all.isEmpty ? [.claude, .codex, .gemini, .cursor] : all
    }

    private func todayCost(for provider: TahoeProvider) -> Double? {
        guard let snapshot = usageModel.analyticsSnapshot else { return nil }
        let cost = doubleFrom(snapshot.totals(for: mapProvider(provider)).today.totals.costUSD)
        guard cost > 0 else { return nil }
        return cost
    }

    @MainActor
    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        await usageModel.refreshMirroredData()
        await agentClient.refreshAll()
        syncAutoReviveFromLive()
    }

    private func syncAutoReviveFromLive() {
        for p in visibleProviders {
            autoRevive[p] = live.row(for: p).autoReviveOn
        }
    }

    private func autoReviveSubtitle(provider: TahoeProvider, row: TahoeLiveRow) -> String {
        if provider == .opencode || provider == .grok {
            return "Auto-revive unavailable for \(provider.displayName)"
        }
        return "Auto-revive · " + ((autoRevive[provider] ?? false) ? "on" : "off")
    }

    private func agentKind(for p: TahoeProvider) -> AgentKind {
        switch p {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .opencode, .openrouter: return .opencode
        case .cursor: return .cursor
        case .grok: return .grok
        }
    }

    private func formatUSD(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    private func doubleFrom(_ dec: Decimal) -> Double {
        NSDecimalNumber(decimal: dec).doubleValue
    }

    private func mapProvider(_ p: TahoeProvider) -> UsageRecord.Provider {
        switch p {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .opencode, .openrouter: return .opencode
        case .cursor: return .cursor
        case .grok: return .grok
        }
    }

    private func providerCost(_ s: UsageHistorySnapshot, _ p: TahoeProvider, _ w: UsageHistorySnapshot.Window) -> Double {
        doubleFrom(s.totals(for: mapProvider(p)).window(w).totals.costUSD)
    }

    private func totalCost(in s: UsageHistorySnapshot, window: UsageHistorySnapshot.Window) -> Double {
        visibleProviders.reduce(0) { $0 + providerCost(s, $1, window) }
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

    private func mergedByRepo(_ snapshot: UsageHistorySnapshot, window: UsageHistorySnapshot.Window) -> [MergedRepoRow] {
        var bag: [String: (c: Double, x: Double, g: Double, o: Double, u: Double, k: Double)] = [:]
        for prov in visibleProviders.map(mapProvider) {
            let rows = snapshot.totals(for: prov).window(window).byRepo
            for row in rows {
                let key = row.repo
                let cost = doubleFrom(row.totals.costUSD)
                var current = bag[key] ?? (0, 0, 0, 0, 0, 0)
                switch prov {
                case .claude: current.c += cost
                case .codex: current.x += cost
                case .gemini: current.g += cost
                case .opencode: current.o += cost
                case .cursor: current.u += cost
                case .grok: current.k += cost
                }
                bag[key] = current
            }
        }
        return bag.map { key, v in
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
}

private extension UsageHistorySnapshot.Window {
    var shortLabel: String {
        switch self {
        case .today: return "today"
        case .past7d: return "7d"
        case .past30d: return "30d"
        case .allTime: return "all"
        }
    }
}

/// Stacked daily spend bars — Continuum flat styling (parity with design SpendChart).
private struct ContinuumSpendChart: View {
    @Environment(\.theme) private var theme
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
                        Rectangle().fill(theme.hair2).frame(height: 2)
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
                            .font(ContinuumFont.body(9))
                            .foregroundStyle(theme.fg4)
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
