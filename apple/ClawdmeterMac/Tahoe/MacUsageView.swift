import SwiftUI
import ClawdmeterShared

/// Mac Usage dashboard — live provider columns + analytics row.
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
    var cursorModel: AppModel?
    var grokModel: AppModel?
    var opencodeModel: AppModel?
    /// PR #31 chunk 3 (A2): the live usage store the OpenCode dollar
    /// row reads from. Optional so Previews work without a runtime.
    var usageHistoryStore: UsageHistoryStore?
    /// Multi-account: one extra gauge column per secondary account
    /// (Settings → Providers → Add account). Empty in Previews.
    var secondaryColumns: [SecondaryTahoeColumn] = []
    /// Wire v30: loopback client for host-run-minute analytics.
    var agentClient: AgentControlClient?
    @State private var hostRunMinutes: HostRunMinutesResponse?
    /// v0.29.32: spend/token analytics read other apps' data, so they're gated
    /// behind an explicit "Get access from your Mac" tap. Mirrors the persisted
    /// flag; flipped locally so the view swaps in the charts on grant.
    @State private var usageAccessGranted = ProviderEnablement.usageDataAccessGranted
    @State private var enabledProviderIDs = ProviderEnablement.enabledProviderIDs()

    public init(
        data: TahoeLiveBindings = .demo,
        claudeModel: AppModel? = nil,
        codexModel: AppModel? = nil,
        geminiModel: AppModel? = nil,
        cursorModel: AppModel? = nil,
        grokModel: AppModel? = nil,
        opencodeModel: AppModel? = nil,
        usageHistoryStore: UsageHistoryStore? = nil,
        secondaryColumns: [SecondaryTahoeColumn] = [],
        agentClient: AgentControlClient? = nil
    ) {
        self.data = data
        self.claudeModel = claudeModel
        self.codexModel = codexModel
        self.geminiModel = geminiModel
        self.cursorModel = cursorModel
        self.grokModel = grokModel
        self.opencodeModel = opencodeModel
        self.usageHistoryStore = usageHistoryStore
        self.secondaryColumns = secondaryColumns
        self.agentClient = agentClient
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if liveColumns.isEmpty {
                    noProvidersCTA
                        .padding(.horizontal, 6).padding(.bottom, 14)
                } else {
                    usageGaugeGrid
                }

                if usageAccessGranted {
                    if ProviderRegistry.isVisible(id: "opencode", capability: .historicalUsage) {
                        // PR #31 chunk 3 (A2): OpenCode dollar-cost row.
                        // Renders as a single full-width strip beneath the live
                        // provider columns because OpenCode doesn't have a 5h
                        // rolling quota — only dollar totals.
                        OpencodeDollarRow(usageHistory: usageHistoryStore)
                            .padding(.horizontal, 6).padding(.bottom, 18)
                    }
                    if ProviderRegistry.isVisible(id: "grok", capability: .historicalUsage) {
                        GrokUsageRow(usageHistory: usageHistoryStore)
                            .padding(.horizontal, 6).padding(.bottom, 18)
                    }

                    TahoeHair()

                    if let hostRunMinutes {
                        HostRunMinutesSection(
                            response: hostRunMinutes,
                            hostNames: Dictionary(
                                uniqueKeysWithValues: (agentClient?.executionHosts ?? []).map { ($0.id, $0.displayName) }
                            )
                        )
                        .padding(.horizontal, 6).padding(.bottom, 18)
                    }

                    AnalyticsRow(usageHistoryStore: usageHistoryStore)
                        .padding(.top, 14)

                    // Token volume (not dollars): flat ranked leaderboard across
                    // all models. Surfaces models regardless of price.
                    TokensByModelSection(usageHistoryStore: usageHistoryStore)
                        .padding(.horizontal, 6).padding(.top, 18)
                } else {
                    // v0.29.32: gate the analytics (which reads other apps'
                    // data) behind an explicit grant. The live provider columns
                    // above need no file access, so they stay visible.
                    usageAccessCTA
                        .padding(.horizontal, 6).padding(.top, 8)
                }
            }
            .padding(.vertical, 6)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderEnablement.changedNotification)) { _ in
            enabledProviderIDs = ProviderEnablement.enabledProviderIDs()
        }
        .task {
            await refreshHostRunMinutes()
        }
    }

    @MainActor
    private func refreshHostRunMinutes() async {
        guard let client = agentClient, client.supportsExecutionHosts else { return }
        hostRunMinutes = await client.refreshHostRunMinutes()
    }

    private struct LiveColumn: Identifiable {
        let provider: TahoeProvider
        let row: TahoeLiveRow
        let model: AppModel?
        var id: TahoeProvider { provider }
    }

    private enum UsageGaugeItem: Identifiable {
        case primary(LiveColumn)
        case secondary(SecondaryTahoeColumn)

        var id: String {
            switch self {
            case .primary(let column):
                return "primary-\(column.provider.rawValue)"
            case .secondary(let column):
                return "secondary-\(column.wireId)"
            }
        }
    }

    /// Row widths for the live usage gauge grid. Five cards share one row so a
    /// lone secondary account doesn't stretch across the dashboard; six split 3+3.
    static func usageGaugeRowSizes(for count: Int) -> [Int] {
        switch count {
        case 0: return []
        case 1...5: return [count]
        case 6: return [3, 3]
        default:
            var rows: [Int] = []
            var remaining = count
            while remaining > 0 {
                if remaining == 7 {
                    rows += [3, 4]
                    remaining = 0
                } else if remaining == 8 {
                    rows += [4, 4]
                    remaining = 0
                } else {
                    let size = min(3, remaining)
                    rows.append(size)
                    remaining -= size
                }
            }
            return rows
        }
    }

    private var usageGaugeItems: [UsageGaugeItem] {
        liveColumns.map { .primary($0) }
            + enabledSecondaryColumns.map { .secondary($0) }
    }

    @ViewBuilder
    private var usageGaugeGrid: some View {
        let items = usageGaugeItems
        let rowSizes = Self.usageGaugeRowSizes(for: items.count)
        VStack(spacing: 14) {
            ForEach(Array(chunked(items, rowSizes: rowSizes).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    ForEach(row) { item in
                        Group {
                            switch item {
                            case .primary(let column):
                                ProviderColumn(provider: column.provider, row: column.row, model: column.model)
                            case .secondary(let column):
                                SecondaryProviderColumn(column: column)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 14)
    }

    private func chunked(_ items: [UsageGaugeItem], rowSizes: [Int]) -> [[UsageGaugeItem]] {
        var rows: [[UsageGaugeItem]] = []
        var index = items.startIndex
        for size in rowSizes {
            guard index < items.endIndex else { break }
            let end = items.index(index, offsetBy: size, limitedBy: items.endIndex) ?? items.endIndex
            rows.append(Array(items[index..<end]))
            index = end
        }
        return rows
    }

    private var enabledSecondaryColumns: [SecondaryTahoeColumn] {
        secondaryColumns.filter {
            enabledProviderIDs.contains(ProviderRegistry.rootProviderID(for: $0.provider.rawValue))
        }
    }

    private var liveColumns: [LiveColumn] {
        [
            LiveColumn(provider: .claude, row: data.claude, model: claudeModel),
            LiveColumn(provider: .codex, row: data.codex, model: codexModel),
            LiveColumn(provider: .gemini, row: data.gemini, model: geminiModel),
            LiveColumn(provider: .cursor, row: data.cursor, model: cursorModel),
            LiveColumn(provider: .grok, row: data.grok, model: grokModel),
            LiveColumn(provider: .opencode, row: data.opencode, model: opencodeModel),
        ].filter { enabledProviderIDs.contains(ProviderRegistry.rootProviderID(for: $0.provider.rawValue)) }
    }

    private var noProvidersCTA: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(t.fg3)
                Text("Enable a provider in Settings")
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("Usage appears after at least one provider is turned on.")
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    /// "Get access from your Mac" — shown until the user grants Usage data
    /// access. Tapping sets the flag and kicks the first analytics load (which
    /// is the moment the cross-app-data prompt appears, with user intent).
    private var usageAccessCTA: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(t.fg3)
                Text("Get access from your Mac")
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("Spend + token analytics read usage data written by \(enabledAnalyticsProviderText) on this Mac. Grant access to see your usage here — macOS will ask once.")
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
                Button {
                    ProviderEnablement.usageDataAccessGranted = true
                    usageAccessGranted = true
                    usageHistoryStore?.forceRefresh()
                } label: {
                    Text("Grant access")
                        .font(TahoeFont.body(12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(t.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private var enabledAnalyticsProviderText: String {
        let names = ProviderRegistry.enabledProviders(for: .historicalUsage).map(\.displayName)
        guard !names.isEmpty else { return "enabled providers" }
        if names.count == 1 { return names[0] }
        return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
    }
}

// MARK: - Tokens by model (ranked leaderboard)

private struct TokensByModelSection: View {
    var usageHistoryStore: UsageHistoryStore?
    // v0.29.31: time selector matching the dollar charts. Defaults to "all"
    // so the landing view preserves the prior all-time numbers; the toggle
    // narrows to today/7d/30d/90d via the windowed `byDayByModel` rollup.
    @State private var range: String = "all"

    var body: some View {
        let byModel: [String: TokenTotals] = {
            guard let snapshot = usageHistoryStore?.snapshot else { return [:] }
            return TokensByModelLeaderboard.tokensByModel(
                snapshot: snapshot.filteredToEnabledProviders(),
                range: range
            )
        }()
        let entries = TokensByModelLeaderboard.rankedEntries(from: byModel)
        TokensByModelLeaderboardView(entries: entries, range: range) {
            TokensByModelRangeSelector(value: $range)
        }
    }
}

// MARK: - Provider column

/// "resets in 12m" / "usage limit" — shared between the primary and
/// secondary gauge columns so the em-dash sentinel comparison lives in
/// exactly one place.
private func quotaSublabel(for row: TahoeLiveRow) -> String {
    row.sessionResetIn == "\u{2014}" ? "usage limit" : "resets in \(row.sessionResetIn)"
}

/// The "Weekly · all models" meter block — shared between the primary
/// and secondary gauge columns (they must not drift).
private struct WeeklyMeterRow: View {
    @Environment(\.tahoe) private var t
    let row: TahoeLiveRow
    let provider: TahoeProvider
    var barHeight: CGFloat = 6

    var body: some View {
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
            TahoePillBar(percent: row.weeklyPercent, provider: provider, height: barHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Multi-account gauge column. Same instrument shape as ProviderColumn
/// with an account-tagged header plus a per-instance menu-bar toggle.
private struct SecondaryProviderColumn: View {
    @Environment(\.tahoe) private var t
    let column: SecondaryTahoeColumn
    @ObservedObject var model: AppModel
    @State private var menuBar: Bool = true

    init(column: SecondaryTahoeColumn) {
        self.column = column
        _model = ObservedObject(wrappedValue: column.model)
    }

    private var row: TahoeLiveRow {
        AppRuntime.makeTahoeRow(model: model, provider: column.provider)
    }

    private var menuBarPrefKey: String {
        ProviderStatusController.prefKey(forWireId: column.wireId)
    }

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    TahoeProviderGlyph(provider: column.provider, size: 28)
                    HStack(spacing: 6) {
                        Text(column.provider.displayName)
                            .font(TahoeFont.body(16, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(t.fg)
                        Text(column.accountName)
                            .font(TahoeFont.mono(11, weight: .medium))
                            .foregroundStyle(t.fg2)
                    }
                    Spacer()
                    MenuBarCheckbox(on: $menuBar)
                }
                TahoeQuotaBar(provider: column.provider, percent: row.sessionPercent, size: 220,
                              label: "session",
                              sublabel: quotaSublabel(for: row))
                .padding(.top, 28)
                .padding(.bottom, 28)
                if row.hasWeekly {
                    WeeklyMeterRow(row: row, provider: column.provider)
                }
                Spacer(minLength: 12)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("usage.secondary.\(column.wireId)")
        .onAppear {
            menuBar = UserDefaults.standard.object(forKey: menuBarPrefKey) as? Bool ?? true
            model.forcePoll()
        }
        .onChange(of: menuBar) { _, v in
            UserDefaults.standard.set(v, forKey: menuBarPrefKey)
        }
    }
}

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
            case .openrouter: return "openrouter"
            case .cursor: return "cursor"
            case .grok: return "grok"
            }
        }()
        return "clawdmeter.\(id).menuBarShown"
    }

    /// Opt-in providers (Cursor / OpenCode) default their standalone menu-bar
    /// gauge OFF — mirror AppDelegate.applyVisibilityFromPrefs so the checkbox's
    /// shown-default matches the gauge's. Otherwise the box reads "checked"
    /// while the gauge is hidden, and the first toggle writes a value that
    /// already equals the applied state → it no-ops ("toggle does nothing").
    private var menuBarDefaultShown: Bool {
        switch provider {
        case .cursor, .opencode, .openrouter: return false
        default: return true
        }
    }

    private var quotaLabel: String {
        switch provider {
        case .grok: return "credits used"
        case .cursor: return "billing period"
        case .opencode: return "5 hour"
        default: return "session"
        }
    }

    private var quotaSublabelText: String {
        quotaSublabel(for: row)
    }

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
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
                TahoeQuotaBar(provider: provider, percent: row.sessionPercent, size: 220,
                              label: quotaLabel, sublabel: quotaSublabelText)
                .padding(.top, 28)
                .padding(.bottom, (provider == .cursor || provider == .opencode) ? 18 : 28)

                if provider == .cursor, let quota = row.cursorQuota {
                    CursorMonthlyMeters(quota: quota, fallbackTotalPct: Int(row.sessionPercent))
                        .padding(.bottom, row.hasWeekly ? 18 : 0)
                }

                // Only render the monthly meter when the window was actually
                // fetched (monthlyPct != nil) — never a fabricated number.
                if provider == .opencode, let quota = row.opencodeGoQuota, let monthlyPct = quota.monthlyPct {
                    OpenCodeGoMonthlyMeter(monthlyPct: monthlyPct, resetMins: quota.monthlyResetMins)
                        .padding(.bottom, row.hasWeekly ? 18 : 0)
                }

                // Weekly row — hidden when provider has no weekly window.
                if row.hasWeekly {
                    WeeklyMeterRow(row: row, provider: provider)
                }

                Spacer(minLength: 12)

                if row.supportsAutoRevive {
                    // Auto-revive card
                    TahoeGlass(radius: 6, tone: .chip) {
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
            menuBar = UserDefaults.standard.object(forKey: menuBarPrefKey) as? Bool ?? menuBarDefaultShown
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

private struct OpenCodeGoMonthlyMeter: View {
    @Environment(\.tahoe) private var t
    var monthlyPct: Int
    var resetMins: Int

    var body: some View {
        let value = min(100, max(0, monthlyPct))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Monthly")
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Spacer()
                Text("\(value)%")
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
            }
            TahoePillBar(percent: Double(value), provider: .opencode, height: 5)
            if resetMins > 0 {
                Text("resets in \(TahoeFmt.resetIn(minutes: resetMins))")
                    .font(TahoeFont.body(10))
                    .foregroundStyle(t.fg4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CursorMonthlyMeters: View {
    @Environment(\.tahoe) private var t
    var quota: UsageData.CursorQuota
    var fallbackTotalPct: Int

    var body: some View {
        VStack(spacing: 9) {
            meter(label: "Auto", pct: quota.autoPct)
            meter(label: "API", pct: quota.apiPct)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meter(label: String, pct: Int?) -> some View {
        let value = min(100, max(0, pct ?? fallbackTotalPct))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label)
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Spacer()
                Text("\(value)%")
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
            }
            TahoePillBar(percent: Double(value), provider: .cursor, height: 5)
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
            .contentShape(Capsule())
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
            return AnalyticsRangeAdapter.rangeData(snapshot: snapshot.filteredToEnabledProviders(), range: range)
        }
        return TahoeDemo.ranges[range] ?? TahoeDemo.ranges["7d"]!
    }

    var body: some View {
        // Bind the range adapter once per body pass — `data` is an uncached
        // computed getter and SwiftUI does NOT cache computed-property reads
        // within a body, so reading it inline (6× below) re-ran the full
        // AnalyticsRangeAdapter aggregation on every render.
        let data = self.data
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("ANALYTICS")
                    .font(TahoeFont.body(11.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                TahoeHair(vertical: true).frame(height: 14)
                Legend()
                Spacer()
                TokensByModelRangeSelector(value: $range)
            }
            .padding(.horizontal, 14)

            HStack(alignment: .top, spacing: 14) {
                TahoeGlass(radius: 8, tone: .panel) {
                    VStack(alignment: .leading, spacing: 0) {
                        ChartHeader(title: "Spend over time", range: data.label, total: data.total)
                        SpendChart(series: data.series, ticks: data.ticks)
                    }
                    .padding(18)
                }
                .frame(maxWidth: .infinity)
                .frame(idealHeight: 280)

                TahoeGlass(radius: 8, tone: .panel) {
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

            if ProviderRegistry.isVisible(id: "grok", capability: .historicalUsage),
               let snapshot = usageHistoryStore?.snapshot?.filteredToEnabledProviders(),
               let grokActivity = GrokAnalyticsActivity(snapshot: snapshot, range: range) {
                GrokAnalyticsActivityStrip(activity: grokActivity)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 14)
    }
}

private enum UsageAnalyticsProvider {
    static var order: [UsageRecord.Provider] {
        UsageRecord.Provider.analyticsDisplayOrder.filter {
            ProviderRegistry.isVisible(id: $0.rawValue, capability: .historicalUsage)
        }
    }

    static var stackOrder: [UsageRecord.Provider] {
        Array(order.reversed())
    }

    static func tahoeProvider(_ provider: UsageRecord.Provider) -> TahoeProvider {
        TahoeProvider(analyticsProvider: provider)
    }

    static func label(_ provider: UsageRecord.Provider) -> String {
        tahoeProvider(provider).displayName
    }

    static func value(_ provider: UsageRecord.Provider, in point: TahoeDemo.SpendPoint) -> Double {
        switch provider {
        case .claude:   return point.c
        case .codex:    return point.x
        case .gemini:   return point.g
        case .opencode: return point.o
        case .cursor:   return point.r
        case .grok:     return point.k
        }
    }

    static func value(_ provider: UsageRecord.Provider, in repo: TahoeDemo.SpendRepo) -> Double {
        switch provider {
        case .claude:   return repo.c
        case .codex:    return repo.x
        case .gemini:   return repo.g
        case .opencode: return repo.o
        case .cursor:   return repo.r
        case .grok:     return repo.k
        }
    }

    static func total(_ point: TahoeDemo.SpendPoint) -> Double {
        order.reduce(0) { $0 + value($1, in: point) }
    }

    static func total(_ repo: TahoeDemo.SpendRepo) -> Double {
        order.reduce(0) { $0 + value($1, in: repo) }
    }
}

private struct GrokAnalyticsActivity: Equatable {
    var build: TokenTotals
    var composer: TokenTotals
    var other: TokenTotals

    var totalTokens: Int {
        build.totalTokens + composer.totalTokens + other.totalTokens
    }

    var requestCount: Int {
        build.requestCount + composer.requestCount + other.requestCount
    }

    init?(snapshot: UsageHistorySnapshot, range: String) {
        var build = TokenTotals.zero
        var composer = TokenTotals.zero
        var other = TokenTotals.zero
        for (model, totals) in AnalyticsRangeAdapter.tokensByModel(snapshot: snapshot, range: range) where Self.isGrokModel(model) {
            switch Self.bucket(model) {
            case .build: build += totals
            case .composer: composer += totals
            case .other: other += totals
            }
        }
        guard build.totalTokens + composer.totalTokens + other.totalTokens > 0
            || build.requestCount + composer.requestCount + other.requestCount > 0
        else { return nil }
        self.build = build
        self.composer = composer
        self.other = other
    }

    private enum Bucket {
        case build
        case composer
        case other
    }

    private static func isGrokModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("grok") || m.hasPrefix("xai/") || m.contains("/grok")
    }

    private static func bucket(_ model: String) -> Bucket {
        let m = model.lowercased()
        if m.contains("composer-2.5") || m.contains("grok-composer") { return .composer }
        if m.contains("grok-build") { return .build }
        return .other
    }
}

private struct GrokAnalyticsActivityStrip: View {
    @Environment(\.tahoe) private var t
    let activity: GrokAnalyticsActivity

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ProviderDot(.grok, size: 7)
                    Text("Grok activity")
                        .font(TahoeFont.body(12.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Spacer()
                    metric(label: "Tokens", value: Self.formatTokens(activity.totalTokens), subvalue: Self.formatRequests(activity.requestCount))
                }
                HStack(spacing: 8) {
                    modelPill("Grok Build", totals: activity.build)
                    modelPill("Composer 2.5", totals: activity.composer)
                    if activity.other.totalTokens > 0 || activity.other.requestCount > 0 {
                        modelPill("Other Grok", totals: activity.other)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func modelPill(_ name: String, totals: TokenTotals) -> some View {
        if totals.totalTokens > 0 || totals.requestCount > 0 {
            HStack(spacing: 6) {
                Text(name)
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text(Self.formatTokens(totals.totalTokens))
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(t.glassTintHi, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func metric(label: String, value: String, subvalue: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label.uppercased())
                .font(TahoeFont.body(9.5, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(t.fg4)
            Text(value)
                .font(TahoeFont.rounded(16, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(t.fg)
            Text(subvalue)
                .font(TahoeFont.mono(9.5))
                .foregroundStyle(t.fg3)
        }
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM tok", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK tok", Double(n) / 1_000) }
        return "\(n) tok"
    }

    private static func formatRequests(_ n: Int) -> String {
        "\(n) request\(n == 1 ? "" : "s")"
    }
}

private struct Legend: View {
    @Environment(\.tahoe) private var t
    var body: some View {
        HStack(spacing: 14) {
            ForEach(UsageAnalyticsProvider.order, id: \.self) { provider in
                let p = UsageAnalyticsProvider.tahoeProvider(provider)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(ProviderFill.gradient(for: p))
                        .frame(width: 9, height: 9)
                    Text(p.displayName)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg2)
                }
            }
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
        let rawMax = series.map { UsageAnalyticsProvider.total($0) }.max() ?? 1
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
        let total = UsageAnalyticsProvider.total(d)
        let h = total > 0 ? total / max * chartHeight : 0
        return VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                if total > 0 {
                    ForEach(UsageAnalyticsProvider.stackOrder, id: \.self) { provider in
                        let value = UsageAnalyticsProvider.value(provider, in: d)
                        if value > 0 {
                            Rectangle()
                                .fill(grad(UsageAnalyticsProvider.tahoeProvider(provider)))
                                .frame(height: value / total * h)
                        }
                    }
                }
            }
            .frame(width: w)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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

    private func grad(_ p: TahoeProvider) -> LinearGradient {
        ProviderFill.gradient(for: p)
    }
}

private struct RepoList: View {
    @Environment(\.tahoe) private var t
    var repos: [TahoeDemo.SpendRepo]
    var body: some View {
        let maxTotal = repos.map { UsageAnalyticsProvider.total($0) }.max() ?? 1
        VStack(spacing: 12) {
            ForEach(Array(repos.enumerated()), id: \.offset) { _, r in
                let total = UsageAnalyticsProvider.total(r)
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
                                ForEach(UsageAnalyticsProvider.order, id: \.self) { provider in
                                    let value = UsageAnalyticsProvider.value(provider, in: r)
                                    if value > 0 {
                                        Rectangle()
                                            .fill(grad(UsageAnalyticsProvider.tahoeProvider(provider)))
                                            .frame(width: geo.size.width * width * (value / total))
                                    }
                                }
                            }
                            Spacer()
                        }
                    }
                    .frame(height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
        }
        .padding(.top, 14)
    }

    private func grad(_ p: TahoeProvider) -> LinearGradient {
        ProviderFill.gradient(for: p)
    }
}

// MARK: - OpencodeDollarRow (PR #31 chunk 3, A2)

/// OpenCode usage row — dollar-cost gauge variant per A2.
/// Renders as a single full-width strip beneath the live provider columns.
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
        TahoeGlass(radius: 8, tone: .panel) {
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

private struct GrokUsageRow: View {
    @Environment(\.tahoe) private var t
    let usageHistory: UsageHistoryStore

    init(usageHistory: UsageHistoryStore?) {
        self.usageHistory = usageHistory ?? UsageHistoryStore()
    }

    private var providerTotals: ProviderTotals {
        usageHistory.snapshot?.grok ?? .empty
    }

    var body: some View {
        let today = providerTotals.today.totals
        let week = providerTotals.past7d.totals
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    TahoeProviderGlyph(provider: .grok, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grok")
                            .font(TahoeFont.body(15, weight: .bold))
                            .foregroundStyle(t.fg)
                        Text("Grok Build + Composer 2.5 analytics")
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                    }
                    Spacer()
                    if today.totalTokens == 0 && week.totalTokens == 0 && today.requestCount == 0 && week.requestCount == 0 {
                        Text("No captured activity")
                            .font(TahoeFont.body(12.5, weight: .semibold))
                            .foregroundStyle(t.fg3)
                    }
                    if today.totalTokens > 0 || today.requestCount > 0 {
                        metric(label: "Today", value: Self.formatTokens(today.totalTokens), subvalue: Self.formatRequests(today.requestCount))
                    }
                    if week.totalTokens > 0 || week.requestCount > 0 {
                        metric(label: "Past 7d", value: Self.formatTokens(week.totalTokens), subvalue: Self.formatRequests(week.requestCount))
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func metric(label: String, value: String, subvalue: String) -> some View {
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
            Text(subvalue)
                .font(TahoeFont.mono(10.5))
                .foregroundStyle(t.fg3)
        }
        .padding(.leading, 18)
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM tok", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK tok", Double(n) / 1_000) }
        return "\(n) tok"
    }

    private static func formatRequests(_ n: Int) -> String {
        "\(n) request\(n == 1 ? "" : "s")"
    }

}

// MARK: - Hover tooltip for SpendChart bars (v0.22.24)

/// Compact provider breakdown shown above the hovered bar in
/// `SpendChart`. User reported "there's no way for me to see the codex
/// token spend — when I hover over this, show me the specific break
/// up." Renders one row per provider with dollar amounts +
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
            ForEach(UsageAnalyticsProvider.order, id: \.self) { provider in
                row(provider)
            }
            TahoeHair().padding(.vertical, 2)
            HStack {
                Text("Total")
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer(minLength: 10)
                Text(Self.format(UsageAnalyticsProvider.total(point)))
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
    private func row(_ provider: UsageRecord.Provider) -> some View {
        let tahoeProvider = UsageAnalyticsProvider.tahoeProvider(provider)
        let label = UsageAnalyticsProvider.label(provider)
        let value = UsageAnalyticsProvider.value(provider, in: point)
        HStack(spacing: 6) {
            Circle()
                .fill(tahoeProvider.dot)
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
