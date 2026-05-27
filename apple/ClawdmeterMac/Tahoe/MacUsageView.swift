import SwiftUI
import ClawdmeterShared

/// Mac Usage dashboard — three provider columns + analytics row.
/// Ports `mac-dashboard.jsx`. Accepts a `TahoeLiveBindings` value (defaults
/// to the demo fixture); the Mac app injects real AppRuntime-derived data
/// via `MacRootView.body`.
///
/// v0.12 button-wiring pass: ProviderColumn's auto-revive toggle now
/// writes to `AppModel.setAutoReviveEnabled(_:)`. MenuBarCheckbox now
/// writes its per-provider visibility preference to `UserDefaults` so the
/// AppDelegate observer hides/shows the matching status item.
public struct MacUsageView: View {
    @Environment(\.tahoe) private var t
    public var data: TahoeLiveBindings
    /// Optional per-provider models — when nil (SwiftUI Previews) the
    /// auto-revive toggle remains local @State only.
    var claudeModel: AppModel?
    var codexModel: AppModel?
    var geminiModel: AppModel?
    /// PR #31 chunk 3 (A2): the live usage store the OpenCode dollar
    /// row reads from. Optional so Previews work without a runtime.
    var usageHistoryStore: UsageHistoryStore?

    public init(
        data: TahoeLiveBindings = .demo,
        claudeModel: AppModel? = nil,
        codexModel: AppModel? = nil,
        geminiModel: AppModel? = nil,
        usageHistoryStore: UsageHistoryStore? = nil
    ) {
        self.data = data
        self.claudeModel = claudeModel
        self.codexModel = codexModel
        self.geminiModel = geminiModel
        self.usageHistoryStore = usageHistoryStore
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ProviderColumn(provider: .claude, row: data.claude, model: claudeModel)
                    ProviderColumn(provider: .codex,  row: data.codex,  model: codexModel)
                    ProviderColumn(provider: .gemini, row: data.gemini, model: geminiModel)
                    ProviderColumn(provider: .cursor, row: data.cursor, model: nil)
                }
                .padding(.horizontal, 6).padding(.bottom, 14)

                // PR #31 chunk 3 (A2): OpenCode dollar-cost row.
                // Renders as a single full-width strip beneath the 3
                // provider columns because OpenCode doesn't have a 5h
                // rolling quota — only dollar totals. The dedicated
                // column avoids cramping the existing 3-column layout
                // at the 1280pt min window width.
                OpencodeDollarRow(usageHistory: usageHistoryStore)
                    .padding(.horizontal, 6).padding(.bottom, 18)

                TahoeHair()

                AnalyticsRow(usageHistoryStore: usageHistoryStore)
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
    var row: TahoeLiveRow
    var model: AppModel?

    @State private var menuBar: Bool = true
    @State private var autoRevive: Bool = true

    /// UserDefaults key that AppDelegate's MenuBarController observes to
    /// hide/show this provider's status item. Mirrors
    /// `ProviderStatusController.prefKey(_:)` in AppDelegate.swift.
    private var menuBarPrefKey: String {
        let id: String = {
            switch provider {
            case .claude: return "claude"
            case .codex:  return "codex"
            case .gemini: return "gemini"
            case .opencode: return "opencode"  // PR #31
            case .cursor: return "cursor"
            }
        }()
        return "clawdmeter.\(id).menuBarShown"
    }

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    TahoeProviderGlyph(provider: provider, size: 28)
                    // v0.22.9: dropped the per-model subtitle
                    // (`Sonnet 4.5 / gpt-5 / antigravity-pro`). Brand-
                    // only label is cleaner — the model is exposed in
                    // the chat composer's model picker chip anyway.
                    Text(provider.displayName)
                        .font(TahoeFont.body(16, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(t.fg)
                    Spacer()
                    MenuBarCheckbox(on: $menuBar)
                }

                // QuotaBar
                TahoeQuotaBar(provider: provider, percent: row.sessionPercent, size: 260,
                              label: "session", sublabel: "resets in \(row.sessionResetIn)")
                .padding(.vertical, 28)

                // Weekly row — hidden when provider has no weekly window.
                if row.hasWeekly {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Weekly · all models")
                                .font(TahoeFont.body(11.5))
                                .foregroundStyle(t.fg2)
                            Spacer()
                            Text("\(Int(row.weeklyPercent))% · \(row.weeklyResetIn)")
                                .font(TahoeFont.mono(11.5))
                                .foregroundStyle(t.fg3)
                        }
                        TahoePillBar(percent: row.weeklyPercent, provider: provider, height: 6)
                    }
                }

                Spacer(minLength: 12)

                if row.supportsAutoRevive {
                    // Auto-revive card
                    TahoeGlass(radius: 12, tone: .chip) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Keep 5h timer ticking")
                                    .font(TahoeFont.body(12, weight: .semibold))
                                    .foregroundStyle(t.fg)
                                Text("Auto-revive · " + (autoRevive ? "last fired \(row.autoReviveAgo)" : "off"))
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
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)
        }
        .onAppear {
            autoRevive = row.autoReviveOn
            menuBar = UserDefaults.standard.object(forKey: menuBarPrefKey) as? Bool ?? true
        }
        .onChange(of: row.autoReviveOn) { _, v in autoRevive = v }
        .onChange(of: autoRevive) { _, v in
            // Only persist when the user flipped the toggle, not when we're
            // syncing from row.autoReviveOn on first appear (the values
            // would already match in that case).
            guard let model, v != row.autoReviveOn else { return }
            model.setAutoReviveEnabled(v)
        }
        .onChange(of: menuBar) { _, v in
            UserDefaults.standard.set(v, forKey: menuBarPrefKey)
            // The AppDelegate has a UserDefaults observer that picks this
            // up and calls `setVisible(_:)` on the matching status item.
            // No notification needed.
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
    /// v0.22.8: real analytics — drive the chart + repo list from
    /// `UsageHistoryStore.snapshot` via `AnalyticsRangeAdapter` instead
    /// of the canned `TahoeDemo.ranges` dictionary. Optional so Preview
    /// callsites that don't wire a store fall back to demo data.
    var usageHistoryStore: UsageHistoryStore?

    private var data: TahoeDemo.RangeData {
        // Build from the live snapshot when available, otherwise fall
        // back to the canned demo so Previews still render.
        if let snapshot = usageHistoryStore?.snapshot {
            return AnalyticsRangeAdapter.rangeData(snapshot: snapshot, range: range)
        }
        return TahoeDemo.ranges[range] ?? TahoeDemo.ranges["7d"]!
    }

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
                    // v0.29.4: match the SpendChart's bar gradient
                    // (`halo → glow`) instead of the previous
                    // `glow → base`. The old recipe rendered Codex as
                    // a dark gray chip even though the chart bars use
                    // OpenAI's bright blue — users couldn't tell which
                    // legend entry mapped to which bar color. Halo is
                    // the same hue family per provider so the chip now
                    // visually keys the bar above it.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient(colors: [p.halo.color, p.glow.color],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 9, height: 9)
                        .shadow(color: p.halo.color(opacity: 0.6), radius: 3, x: 0, y: 0)
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
        // v0.22.17: "24h" replaced with "Today" to match ccusage's
        // daily-bucket model. The previous "past 24h" view split today's
        // total across 6 equally-weighted four-hour buckets — pure
        // smoke-and-mirrors, since UsageHistoryLoader stores data at
        // day-resolution. "Today" tells the truth: a single day's spend.
        ("today","Today"),("7d","7d"),("30d","30d"),("90d","90d"),("all","All time"),
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

    // v0.22.24: track which bar is hovered for the tooltip overlay.
    // -1 means no hover (we don't use Int? because compiler complains
    // about ambiguity inside the GeometryReader closure).
    @State private var hoverIndex: Int = -1

    var body: some View {
        // v0.22.24: round to a "nice" Y-axis max instead of `rawMax * 1.08`
        // (which produced labels like $876 / $584 / $292). Tick stride
        // is in {1, 2, 2.5, 5} × 10^n so each gridline lands on a clean
        // dollar number (e.g. $0 / $250 / $500 / $750 with stride 250).
        let rawMax = series.map { $0.c + $0.x + $0.g + $0.o }.max() ?? 1
        let (maxTotal, stride) = Self.niceAxisMax(rawMax: rawMax, ticks: lines)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                // Y axis labels — each is `(lines - 1 - i) * stride` so
                // labels are exactly integer multiples of `stride`, not
                // arbitrary `rawMax * fraction` values.
                VStack(alignment: .trailing) {
                    ForEach(0..<lines, id: \.self) { i in
                        let v = stride * Double(lines - 1 - i)
                        Text(Self.formatAxisLabel(v))
                            .font(TahoeFont.mono(10))
                            .foregroundStyle(t.fg4)
                        if i < lines - 1 { Spacer() }
                    }
                }
                .frame(width: 36, height: chartHeight, alignment: .topTrailing)

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
                            ForEach(Array(series.enumerated()), id: \.offset) { idx, d in
                                stackedBar(d: d, max: maxTotal, w: barW, isHover: idx == hoverIndex)
                                    .frame(maxWidth: .infinity)
                                    // v0.22.24: per-bar hover for the
                                    // breakdown tooltip. macOS-only —
                                    // `.onHover` is no-op on iOS where
                                    // there's no mouse, but this view
                                    // ships Mac-only.
                                    .onHover { hovering in
                                        hoverIndex = hovering ? idx : (hoverIndex == idx ? -1 : hoverIndex)
                                    }
                            }
                        }
                    }
                    .frame(height: chartHeight)

                    // v0.22.24: hover tooltip overlay anchored just
                    // above the hovered bar. Lives inside the ZStack so
                    // it overlays the gridlines + bars without
                    // affecting layout. Uses .allowsHitTesting(false)
                    // so the tooltip itself doesn't steal hover events
                    // from underlying bars when it overlaps.
                    if hoverIndex >= 0 && hoverIndex < series.count {
                        GeometryReader { geo in
                            let barCount = max(series.count, 1)
                            let slot = geo.size.width / CGFloat(barCount)
                            let cx = slot * (CGFloat(hoverIndex) + 0.5)
                            HoverBreakdown(
                                day: ticks.indices.contains(hoverIndex) ? ticks[hoverIndex] : "",
                                point: series[hoverIndex]
                            )
                            .fixedSize()
                            .position(x: cx, y: 22)
                            .allowsHitTesting(false)
                        }
                        .frame(height: chartHeight)
                    }
                }
            }

            // X labels
            HStack {
                Spacer().frame(width: 44)
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

    private func stackedBar(d: TahoeDemo.SpendPoint, max: Double, w: CGFloat, isHover: Bool) -> some View {
        let total = d.c + d.x + d.g + d.o
        let h = total > 0 ? total / max * chartHeight : 0
        return VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                if total > 0 {
                    Rectangle().fill(grad(.opencode)).frame(height: d.o / total * h)
                    Rectangle().fill(grad(.gemini)).frame(height: d.g / total * h)
                    Rectangle().fill(grad(.codex)).frame(height: d.x / total * h)
                    Rectangle().fill(grad(.claude)).frame(height: d.c / total * h)
                }
            }
            .frame(width: w)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            // v0.22.24: brighten the bar slightly when hovered so user
            // gets a visual confirmation of which bar the tooltip
            // describes.
            .shadow(color: TahoeProvider.claude.base.color(opacity: isHover ? 0.42 : 0.18), radius: isHover ? 11 : 7, x: 0, y: 0)
            .overlay {
                if isHover {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(t.fg.opacity(0.35), lineWidth: 1)
                        .frame(width: w)
                }
            }
        }
    }

    /// v0.22.24: pick a "nice" Y-axis maximum so labels land on round
    /// dollar amounts (250, 500, 750, 1000...). Algorithm: pick a
    /// per-tick stride from the {1, 2, 2.5, 5} × 10^n family that's
    /// the smallest stride for which `(ticks-1) * stride >= rawMax`.
    /// Returns the chosen max and the per-tick stride.
    static func niceAxisMax(rawMax: Double, ticks: Int) -> (max: Double, stride: Double) {
        let segments = max(1, ticks - 1)
        guard rawMax > 0 else { return (Double(segments), 1) }
        // Rough step that would fit rawMax exactly into `segments`,
        // then round up to a nicer number.
        let rough = rawMax / Double(segments)
        let exp = floor(log10(rough))
        let pow10 = pow(10, exp)
        let mantissa = rough / pow10
        let niceMantissa: Double
        if mantissa <= 1 { niceMantissa = 1 }
        else if mantissa <= 2 { niceMantissa = 2 }
        else if mantissa <= 2.5 { niceMantissa = 2.5 }
        else if mantissa <= 5 { niceMantissa = 5 }
        else { niceMantissa = 10 }
        let stride = niceMantissa * pow10
        return (stride * Double(segments), stride)
    }

    /// v0.22.24: y-axis labels use compact dollar formatting. Numbers
    /// ≥ 1000 collapse to "$1.2K" / "$2K" / "$10K" to fit the 36pt
    /// y-axis column; smaller values show full dollar amount.
    static func formatAxisLabel(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v >= 1000 {
            let kv = v / 1000.0
            if kv == kv.rounded() {
                return String(format: "$%dK", Int(kv))
            }
            return String(format: "$%.1fK", kv)
        }
        if v < 10 { return String(format: "$%.1f", v) }
        return String(format: "$%d", Int(v))
    }

    /// v0.22.17: switched from `[glow, base]` to `[halo, glow]` to
    /// match the popover pill bar's brightening fix (v0.22.16) —
    /// Codex's intentionally-desaturated brand palette was rendering
    /// the stacked-bar Codex slice as a near-black sliver against
    /// the dark chart bg. Halo is each provider's bright accent
    /// (Codex's OpenAI cool blue, etc.) so all four show now.
    private func grad(_ p: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: [p.halo.color, p.glow.color], startPoint: .top, endPoint: .bottom)
    }
}

private struct RepoList: View {
    @Environment(\.tahoe) private var t
    var repos: [TahoeDemo.SpendRepo]
    var body: some View {
        // v0.22.8: include opencode in the maxTotal so the relative
        // bar widths normalize across all four providers.
        let maxTotal = repos.map { $0.c + $0.x + $0.g + $0.o }.max() ?? 1
        VStack(spacing: 12) {
            ForEach(Array(repos.enumerated()), id: \.offset) { _, r in
                let total = r.c + r.x + r.g + r.o
                let width = maxTotal > 0 ? total / maxTotal : 0
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
                            if total > 0 {
                                Rectangle().fill(grad(.claude)).frame(width: geo.size.width * width * (r.c / total))
                                Rectangle().fill(grad(.codex)).frame(width: geo.size.width * width * (r.x / total))
                                Rectangle().fill(grad(.gemini)).frame(width: geo.size.width * width * (r.g / total))
                                Rectangle().fill(grad(.opencode)).frame(width: geo.size.width * width * (r.o / total))
                            }
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

    /// v0.22.17: switched from `[glow, base]` to `[halo, glow]` to
    /// match the popover pill bar's brightening fix (v0.22.16) —
    /// Codex's intentionally-desaturated brand palette was rendering
    /// the stacked-bar Codex slice as a near-black sliver against
    /// the dark chart bg. Halo is each provider's bright accent
    /// (Codex's OpenAI cool blue, etc.) so all four show now.
    private func grad(_ p: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: [p.halo.color, p.glow.color], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - OpencodeDollarRow (PR #31 chunk 3, A2)

/// OpenCode usage row — dollar-cost gauge variant per A2.
/// Renders as a single full-width strip beneath the 3 provider columns.
/// Shows `$X today` + `$Y this week` (no rolling 5h quota — OpenCode
/// is pay-as-you-go through whichever underlying provider the user
/// signed in with).
private struct OpencodeDollarRow: View {
    @Environment(\.tahoe) private var t
    // C2 — was `@ObservedObject var usageHistory: UsageHistoryStore`
    // pre-C2. Now `@Observable`, so a plain stored reference is
    // sufficient — SwiftUI's `withObservationTracking` registers
    // dependencies on whichever fields the body actually reads
    // (`opencodeTodayCostUSD` / `opencodeWeekCostUSD`).
    let usageHistory: UsageHistoryStore

    init(usageHistory: UsageHistoryStore?) {
        // Bind to whichever store the parent injected; for Previews
        // a fresh store is fine — opencodeLive* default to empty
        // arrays so the row shows "$0.00".
        self.usageHistory = usageHistory ?? UsageHistoryStore()
    }

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            HStack(spacing: 18) {
                TahoeProviderGlyph(provider: .opencode, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenCode")
                        .font(TahoeFont.body(15, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("Pay-as-you-go via your authenticated provider")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                }
                Spacer()
                metric(label: "Today", value: format(usageHistory.opencodeTodayCostUSD))
                metric(label: "This week", value: format(usageHistory.opencodeWeekCostUSD))
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(label.uppercased())
                .font(TahoeFont.body(10, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(t.fg4)
            Text(value)
                .font(TahoeFont.rounded(22, weight: .heavy))
                .monospacedDigit()
                .tracking(-0.4)
                .foregroundStyle(t.fg)
        }
        .padding(.leading, 18)
    }

    /// Currency formatter for the dollar gauge. Mac users see USD by
    /// default — locale formatting matches what AnalyticsTotalsGrid
    /// uses elsewhere in the app.
    private func format(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "$0.00"
    }
}

// MARK: - Hover tooltip for SpendChart bars (v0.22.24)

/// Compact provider breakdown shown above the hovered bar in
/// `SpendChart`. User reported "there's no way for me to see the codex
/// token spend — when I hover over this, show me the specific break
/// up." Renders four rows (one per provider) with dollar amounts +
/// total, color-coded by the provider glyph that matches the bar
/// segments below.
private struct HoverBreakdown: View {
    @Environment(\.tahoe) private var t
    var day: String
    var point: TahoeDemo.SpendPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !day.isEmpty {
                Text(day)
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
            }
            row(.claude, "Claude", point.c)
            row(.codex, "Codex", point.x)
            row(.gemini, "Antigravity", point.g)
            row(.opencode, "OpenCode", point.o)
            TahoeHair().padding(.vertical, 2)
            HStack {
                Text("Total")
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer(minLength: 10)
                Text(Self.format(point.c + point.x + point.g + point.o))
                    .font(TahoeFont.mono(11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(t.fg)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(t.glassTintHi)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    private func row(_ provider: TahoeProvider, _ label: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(provider.halo.color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg2)
            Spacer(minLength: 10)
            Text(Self.format(value))
                .font(TahoeFont.mono(10.5))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? t.fg : t.fg4)
        }
    }

    private static func format(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 1 { return String(format: "$%.3f", v) }
        if v < 10 { return String(format: "$%.2f", v) }
        if v < 1000 { return String(format: "$%.2f", v) }
        if v < 10_000 { return String(format: "$%.0f", v) }
        return String(format: "$%.1fK", v / 1000.0)
    }
}
