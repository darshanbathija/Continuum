import SwiftUI
import Combine
import ClawdmeterShared

/// Replacement for `PopoverView`. Provider segmented + stacked meters.
/// Ports `mac-dashboard.jsx::MacMenubarPopover`.
///
/// v0.12 button-wiring pass: the "Open dashboard" and "Pair with iPhone"
/// ghost buttons in the footer now invoke caller-provided callbacks
/// (`onOpenDashboard`, `onSyncIPhone`). `ProviderStatusController`
/// wires them to `AppDelegate.showDashboard()` and a popover hosting
/// `PairingQRPopoverContent` respectively. Defaults are `{}` so the
/// view remains preview-friendly.
///
/// v0.22.4 (audit): the previous wiring passed a value-typed
/// `TahoeLiveBindings` snapshot in. NSPopover hosts the SwiftUI
/// content via an NSHostingController that captures the struct ONCE
/// at construction time, so the popover never picked up subsequent
/// poller updates — meters showed whatever the AppModels had when
/// the user first clicked any status item (often `.demo`, since the
/// item is built eagerly at app launch before pollers complete).
/// The fix: take per-provider AppModels as `@ObservedObject` so the
/// SwiftUI dependency tracker fires `body` on every `usage` change.
/// Live `TahoeLiveBindings` is rebuilt in-body from current model
/// state.
public struct MacMenubarPopover: View {
    @Environment(\.tahoe) private var t
    @State private var selected: TahoeProvider
    /// Demo fallback used by Previews + the convenience init that
    /// doesn't take live AppModels. The live init below overrides
    /// this with a fresh `liveData` computed in-body.
    public var data: TahoeLiveBindings
    var onOpenDashboard: () -> Void
    var onSyncIPhone: () -> Void
    /// v0.22.4: when non-nil, observe the live per-provider models so
    /// meters reflect the latest poll instead of the snapshot captured
    /// at status-item creation time. The observable wrapper carries
    /// the three AppModels together (SwiftUI needs them as a single
    /// observable for `body` to re-fire correctly on any of their
    /// `@Published.usage` changes).
    @ObservedObject private var liveSource: MenuBarLiveSource
    /// v(audit): optional controller-owned selection driver. The shared
    /// NSPopover is reused across status items, so without this the tab
    /// stays on whatever `initialProvider` seeded `selected` at first
    /// build. When non-nil, the controller re-targets the active tab on
    /// each open and `body` reconciles `selected` to it. Nil for preview /
    /// legacy paths (seed-once behavior preserved).
    @ObservedObject private var selectionDriver: MenuBarPopoverSelection
    /// v0.22.30: optional UsageHistoryStore so the OpenCode tab can
    /// render its dollar-cost tile (`$X today / $Y this week` per A2).
    /// When nil (preview path or when opencode isn't wired) the
    /// OpenCode tab still appears but shows "$—.——".
    ///
    /// C2 — was `@ObservedObject` pre-C2; the store is now `@Observable`
    /// and SwiftUI tracks reads via `withObservationTracking` so the
    /// wrapper drops away.
    private var usageHistoryStore: UsageHistoryStore

    @State private var enabledProviderIDs = ProviderEnablement.enabledProviderIDs(for: .menuBar)

    private let allProviders = TahoeProvider.allCases.filter {
        ProviderRegistry.descriptor(id: $0.rawValue)?.capabilities.contains(.menuBar) ?? false
    }

    private var enabledProviders: [TahoeProvider] {
        allProviders.filter { enabledProviderIDs.contains(ProviderRegistry.rootProviderID(for: $0.rawValue)) }
    }

    private var selectedProvider: TahoeProvider {
        enabledProviders.contains(selected) ? selected : (enabledProviders.first ?? selected)
    }

    /// Preview / demo init — no live AppModels; uses the static
    /// `data` snapshot.
    public init(
        data: TahoeLiveBindings = .demo,
        initialProvider: TahoeProvider = .claude,
        onOpenDashboard: @escaping () -> Void = {},
        onSyncIPhone: @escaping () -> Void = {}
    ) {
        self.data = data
        self._selected = State(initialValue: initialProvider)
        self.onOpenDashboard = onOpenDashboard
        self.onSyncIPhone = onSyncIPhone
        self.liveSource = MenuBarLiveSource()  // no live models
        self.usageHistoryStore = UsageHistoryStore()
        // Self-owned driver never bumps `epoch`, so the preview path keeps
        // the original seed-once selection behavior.
        self.selectionDriver = MenuBarPopoverSelection(initial: initialProvider)
    }

    /// Production init — wires live per-provider AppModels so meters
    /// refresh on every poll. Used by `ProviderStatusController` in
    /// AppDelegate.
    public init(
        initialProvider: TahoeProvider,
        onOpenDashboard: @escaping () -> Void,
        onSyncIPhone: @escaping () -> Void,
        claudeModel: AppModel,
        codexModel: AppModel,
        geminiModel: AppModel,
        // Optional so the existing call site compiles before it's wired;
        // when non-nil the cursor tab renders live usage instead of a stale
        // hardcoded literal.
        cursorModel: AppModel? = nil,
        grokModel: AppModel? = nil,
        // Optional controller-owned driver to re-target the active tab on
        // each open (see MenuBarPopoverSelection). Nil → self-owned driver,
        // preserving the original seed-once selection behavior.
        selectionDriver: MenuBarPopoverSelection? = nil,
        usageHistoryStore: UsageHistoryStore
    ) {
        self.data = .demo  // fallback never used when liveSource is wired
        self._selected = State(initialValue: initialProvider)
        self.onOpenDashboard = onOpenDashboard
        self.onSyncIPhone = onSyncIPhone
        self.liveSource = MenuBarLiveSource(
            claude: claudeModel, codex: codexModel, gemini: geminiModel, cursor: cursorModel, grok: grokModel
        )
        self.selectionDriver = selectionDriver ?? MenuBarPopoverSelection(initial: initialProvider)
        self.usageHistoryStore = usageHistoryStore
    }

    /// Rebuild bindings from live AppModel state on every render. The
    /// computed property reads each model's `usage` via the
    /// `liveSource` wrapper, which makes SwiftUI re-render this view
    /// when any of those `@Published` values change.
    private var liveData: TahoeLiveBindings {
        guard let models = liveSource.models else { return data }
        return TahoeLiveBindings(
            claude: liveRow(model: models.claude, provider: .claude),
            codex:  liveRow(model: models.codex,  provider: .codex),
            gemini: liveRow(model: models.gemini, provider: .gemini),
            // Bug fix: the cursor tab was hardcoded to a stale 0%/"-" literal,
            // so it never reflected cursorModel.usage. Build it from the live
            // model like every other provider; fall back to the honest
            // "Connecting…" row when the cursor model isn't wired yet.
            cursor: models.cursor.map { liveRow(model: $0, provider: .cursor) }
                ?? TahoeLiveRow(
                    sessionPercent: 0,
                    weeklyPercent: 0,
                    sessionResetIn: "-",
                    weeklyResetIn: "",
                    modelName: "Cursor Auto",
                    autoReviveOn: false,
                    supportsAutoRevive: false,
                    hasWeekly: false,
                    cursorQuota: nil,
                    stale: true
                ),
            grok: models.grok.map { liveRow(model: $0, provider: .grok) }
                ?? TahoeLiveRow(
                    sessionPercent: 0,
                    weeklyPercent: -1,
                    sessionResetIn: "—",
                    weeklyResetIn: "",
                    modelName: "Grok",
                    autoReviveOn: false,
                    supportsAutoRevive: false,
                    hasWeekly: false,
                    stale: true
                )
        )
    }

    /// Build a single TahoeLiveRow from an AppModel's current usage.
    /// Mirrors `MacTahoeAdapter.tahoeLive` for the same provider —
    /// duplicated here (rather than calling the adapter) to avoid
    /// re-reading SessionsModel / agentSessionRegistry which the
    /// popover doesn't care about.
    ///
    /// v0.22.8: when `model.usage` is nil (poller hasn't completed,
    /// or the user isn't authed for this provider yet) we used to fall
    /// back to `.demo(provider)` — which dishonestly shows the canned
    /// `TahoeDemo.liveData` numbers (89% / 61% for Antigravity, etc.).
    /// That made unauthed Antigravity look like it had real data. The
    /// honest fallback is an empty row with `hasWeekly` driven by the
    /// real per-provider config, so gemini's weekly meter stays hidden
    /// even before the first poll.
    private func liveRow(model: AppModel, provider: TahoeProvider) -> TahoeLiveRow {
        let modelName: String = {
            switch provider {
            case .claude: return "Sonnet 4.5"
            case .codex:  return "gpt-5"
            case .gemini: return "antigravity-pro"
            case .opencode: return "via opencode"
            case .openrouter: return "via OpenRouter"
            case .cursor: return "Cursor Auto"
            case .grok: return "Grok"
            }
        }()
        guard let usage = model.usage else {
            // Honest "Connecting…" state — zero gauges, hints empty,
            // `hasWeekly` from the real config (false for gemini).
            return TahoeLiveRow(
                sessionPercent: 0,
                weeklyPercent: model.config.hasWeeklyWindow ? 0 : -1,
                sessionResetIn: "—",
                weeklyResetIn: model.config.hasWeeklyWindow ? "—" : "",
                modelName: modelName,
                autoReviveOn: model.config.supportsAutoRevive ? model.autoReviver.isEnabled : false,
                autoReviveAgo: "—",
                supportsAutoRevive: model.config.supportsAutoRevive,
                hasWeekly: model.config.hasWeeklyWindow,
                cursorQuota: nil,
                stale: true
            )
        }
        let sessionResetIn = TahoeFmt.resetIn(minutes: usage.sessionResetMins)
        let weeklyResetIn  = TahoeFmt.resetIn(minutes: usage.weeklyResetMins)
        return TahoeLiveRow(
            sessionPercent: Double(usage.sessionPct),
            weeklyPercent:  Double(usage.weeklyPct),
            sessionResetIn: sessionResetIn,
            weeklyResetIn:  weeklyResetIn,
            modelName:      modelName,
            autoReviveOn:   model.config.supportsAutoRevive ? model.autoReviver.isEnabled : false,
            autoReviveAgo:  "—",
            supportsAutoRevive: model.config.supportsAutoRevive,
            hasWeekly:      model.config.hasWeeklyWindow,
            cursorQuota:    usage.cursorQuota,
            // v0.22.18: surface the source's fallback/cached state.
            // CodexSource sets status = .unknown when it had to read
            // the JSONL rate_limits block instead of hitting the wham
            // endpoint; AntigravitySource sets it when serving a
            // cached fallback after a 5xx / network blip. The popover
            // renders a "Stale" pill so the user knows the numbers
            // may not reflect what each provider's desktop app shows.
            stale: usage.status == .unknown
        )
    }

    public var body: some View {
        let activeData = liveData
        let activeProvider = selectedProvider
        let row = activeData.row(for: activeProvider)
        // v0.22.8: drop the outer `TahoeGlass(radius: 8, tone: .panel)`
        // wrapper. NSPopover already draws its own translucent bubble
        // around the contentViewController, so stacking a second glass
        // panel inside produced the doubled-border look the user
        // flagged (designed vs. actual container mismatch). Now the
        // NSPopover bubble IS the container.
        VStack(alignment: .leading, spacing: 0) {
            // Provider segmented control
            HStack(spacing: 3) {
                ForEach(enabledProviders) { p in
                    providerTab(p)
                }
            }
            .padding(3)
            .background {
                Capsule(style: .continuous).fill(t.glassTintHi)
            }
            .padding(.bottom, 12)

            // v0.22.30: OpenCode renders a dollar-cost variant per A2
            // (pay-as-you-go through underlying provider; no rolling
            // 5h window or weekly quota). Other providers keep the
            // percent meter shape.
            if activeProvider == .opencode {
                VStack(spacing: 12) {
                    OpencodeDollarTile(
                        label: "Today",
                        value: usageHistoryStore.opencodeTodayCostUSD
                    )
                    OpencodeDollarTile(
                        label: "This week",
                        value: usageHistoryStore.opencodeWeekCostUSD
                    )
                }
                .padding(.horizontal, 4)
            } else if activeProvider == .grok {
                GrokHistorySummary(
                    row: row,
                    hasLimit: liveSource.models?.grok?.usage != nil,
                    snapshot: usageHistoryStore.snapshot
                )
            } else if activeProvider == .cursor {
                CursorMonthlyMenuBarMeters(row: row)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 12) {
                    TahoeMenuBarMeter(label: "5h session", percent: row.sessionPercent, hint: "resets in \(row.sessionResetIn)", provider: activeProvider, stale: row.stale)
                    if row.hasWeekly {
                        TahoeMenuBarMeter(label: "Weekly", percent: row.weeklyPercent, hint: "resets in \(row.weeklyResetIn)", provider: activeProvider, stale: row.stale)
                    }
                }
                .padding(.horizontal, 4)
            }

            // JSX `<Hair style={{ margin: '12px 0 10px' }} />` (mac-dashboard.jsx:646)
            // — asymmetric: 12pt above, 10pt below.
            TahoeHair().padding(.top, 12).padding(.bottom, 10)

            HStack(spacing: 6) {
                TahoeGhostButton(size: .s, action: onOpenDashboard) {
                    HStack(spacing: 4) {
                        TahoeIcon("grid", size: 10)
                        Text("Open dashboard")
                    }
                }
                .frame(maxWidth: .infinity)

                TahoeGhostButton(size: .s, action: onSyncIPhone) {
                    HStack(spacing: 4) {
                        TahoeIcon("qr", size: 10)
                        Text("Pair with iPhone")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 388)
        // Re-target the active tab when the controller requests a provider
        // on popover open. Keys off `epoch` (not `requested`) so clicking
        // the same provider's status item still reactivates the tab; a
        // self-owned driver never bumps `epoch`, so the preview / legacy
        // paths keep seed-once behavior.
        .onChange(of: selectionDriver.epoch) { _, _ in
            let requested = enabledProviders.contains(selectionDriver.requested)
                ? selectionDriver.requested
                : (enabledProviders.first ?? selectionDriver.requested)
            guard selected != requested else { return }
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { selected = requested }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderEnablement.changedNotification)) { _ in
            enabledProviderIDs = ProviderEnablement.enabledProviderIDs(for: .menuBar)
            if !enabledProviders.contains(selected), let first = enabledProviders.first {
                selected = first
            }
        }
    }

    /// v0.22.8: extracted into its own builder so the per-button state
    /// (the `active` capsule + shadow) doesn't drag the entire HStack
    /// re-render path. Adds three explicit fixes for the "needs many
    /// clicks" gripe:
    ///   1. `.contentShape(Capsule())` makes the entire capsule
    ///      hittable — the previous HStack had hit-test fall-through
    ///      between the glyph and label on first click.
    ///   2. Selection update wrapped in a `Transaction { disablesAnimations
    ///      = true }` so the active-capsule swap is instant. The default
    ///      SwiftUI animation made the segmented switch feel laggy even
    ///      when SwiftUI had already received the click.
    ///   3. `.animation(nil, value: selected)` on the background so the
    ///      capsule snap is uniform across re-renders.
    @ViewBuilder
    private func providerTab(_ p: TahoeProvider) -> some View {
        let active = p == selectedProvider
        Button {
            guard p != selectedProvider else { return }
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { selected = p }
        } label: {
            HStack(spacing: 4) {
                TahoeProviderGlyph(provider: p, size: 16)
                Text(p.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .layoutPriority(1)
            }
            .font(TahoeFont.body(11, weight: active ? .bold : .semibold))
            .foregroundStyle(active ? t.fg : t.fg3)
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Capsule(style: .continuous))
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                        .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
                }
            }
            .animation(nil, value: selectedProvider)
        }
        .buttonStyle(.plain)
    }
}

/// v0.22.30: OpenCode dollar tile for the popover. Pay-as-you-go
/// usage rendered as `$X.XX` per A2, no percent meter or "resets in"
/// line. Mirrors the visual shape of TahoeMenuBarMeter so the popover
/// height stays consistent when the user switches between Codex (5h
/// + Weekly) and OpenCode (Today + This week) tabs.
private struct OpencodeDollarTile: View {
    @Environment(\.tahoe) private var t
    var label: String
    var value: Decimal

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(TahoeFont.body(13, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("OpenCode usage")
                    .font(TahoeFont.mono(11))
                    .foregroundStyle(t.fg3)
            }
            Spacer(minLength: 12)
            Text(Self.format(value))
                .font(TahoeFont.rounded(20, weight: .heavy))
                .tracking(-0.4)
                .monospacedDigit()
                .foregroundStyle(t.fg)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(t.glassTintHi.opacity(0.6))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        }
    }

    // Perf: the popover body re-runs on every SSE append (UsageHistoryStore
    // is @Observable), and two tiles call `format` per pass — so configure
    // the currency formatter once instead of allocating one per render.
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()

    private static func format(_ v: Decimal) -> String {
        formatter.string(from: v as NSDecimalNumber) ?? "$0.00"
    }
}

private struct GrokHistorySummary: View {
    @Environment(\.tahoe) private var t
    var row: TahoeLiveRow
    var hasLimit: Bool
    var snapshot: UsageHistorySnapshot?

    private var providerTotals: ProviderTotals {
        snapshot?.grok ?? .empty
    }

    private var hasTokenActivity: Bool {
        providerTotals.today.totals.totalTokens > 0
            || providerTotals.past7d.totals.totalTokens > 0
            || providerTotals.today.totals.requestCount > 0
            || providerTotals.past7d.totals.requestCount > 0
    }

    var body: some View {
        VStack(spacing: 12) {
            if hasLimit {
                TahoeMenuBarMeter(
                    label: "Credits used",
                    percent: row.sessionPercent,
                    hint: row.sessionResetIn == "—" ? "Grok usage limit" : "resets in \(row.sessionResetIn)",
                    provider: .grok,
                    stale: row.stale
                )
            } else {
                emptyLimitTile
            }

            if hasTokenActivity {
                tokenTile(label: "Today", totals: providerTotals.today.totals)
            }
        }
        .padding(.horizontal, 4)
    }

    private var emptyLimitTile: some View {
        HStack(spacing: 12) {
                TahoeProviderGlyph(provider: .grok, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Grok usage limit captured")
                        .font(TahoeFont.body(13, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("Grok credits unavailable")
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg3)
                }
                Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(t.glassTintHi.opacity(0.6))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func tokenTile(label: String, totals: TokenTotals) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(TahoeFont.body(13, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("\(totals.requestCount) request\(totals.requestCount == 1 ? "" : "s")")
                    .font(TahoeFont.mono(11))
                    .foregroundStyle(t.fg3)
            }
            Spacer(minLength: 12)
            Text(Self.formatTokens(totals.totalTokens))
                .font(TahoeFont.rounded(20, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(t.fg)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(t.glassTintHi.opacity(0.6))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        }
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM tok", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK tok", Double(n) / 1_000) }
        return "\(n) tok"
    }

}

private struct CursorMonthlyMenuBarMeters: View {
    @Environment(\.tahoe) private var t
    var row: TahoeLiveRow

    var body: some View {
        VStack(spacing: 12) {
            cursorMeter(label: "Monthly total", pct: row.cursorQuota?.totalPct ?? Int(row.sessionPercent))
            cursorMeter(label: "Auto", pct: row.cursorQuota?.autoPct)
            cursorMeter(label: "API", pct: row.cursorQuota?.apiPct)
        }
    }

    private func cursorMeter(label: String, pct: Int?) -> some View {
        let value = pct ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg2)
                if row.stale {
                    Text("STALE")
                        .font(TahoeFont.body(8.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color(.sRGB, red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color(.sRGB, red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0, opacity: 0.14))
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(Color(.sRGB, red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0, opacity: 0.40), lineWidth: 0.5)
                        }
                }
                Spacer()
                Text(pct.map { "\($0)%" } ?? "--")
                    .font(TahoeFont.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(t.fg2)
            }
            TahoePillBar(percent: Double(value), provider: .cursor, height: 6)
                .opacity(pct == nil ? 0.35 : 1)
            Text("resets in \(row.sessionResetIn)")
                .font(TahoeFont.mono(10))
                .foregroundStyle(t.fg3)
                .padding(.top, 2)
        }
    }
}

// MARK: - Menu-bar live source (v0.22.4)

/// Per-AppModel observable wrapper that re-fires `objectWillChange`
/// whenever any of the three providers' `usage` updates. The popover
/// `@ObservedObject`s this so its `body` re-renders on every poll —
/// fixing the stale-snapshot bug where the popover showed whatever
/// data the AppModels had at `ensureStatusItem()` time (often `.demo`
/// before pollers completed).
///
/// Wraps three optional refs because the Preview / demo init path
/// doesn't have real models. When `models` is nil, the popover uses
/// the static `data` snapshot it was constructed with.
@MainActor
final class MenuBarLiveSource: ObservableObject {
    struct Models {
        let claude: AppModel
        let codex: AppModel
        let gemini: AppModel
        // Optional: the production call site passes the real cursorModel when
        // available; nil keeps the demo/legacy path compiling and falls back
        // to the honest "Connecting…" row.
        let cursor: AppModel?
        let grok: AppModel?
    }

    let models: Models?
    private var cancellables: Set<AnyCancellable> = []

    /// Preview / demo init: no live models, no subscriptions.
    init() {
        self.models = nil
    }

    /// Production init: subscribes to each model's `objectWillChange`
    /// and re-emits via our own publisher so the popover's
    /// `@ObservedObject` dependency tracker fires on every poll.
    init(claude: AppModel, codex: AppModel, gemini: AppModel, cursor: AppModel? = nil, grok: AppModel? = nil) {
        self.models = Models(claude: claude, codex: codex, gemini: gemini, cursor: cursor, grok: grok)
        // Forward each provider's objectWillChange to our own. The
        // popover view subscribes to MenuBarLiveSource (this) rather
        // than the three AppModels directly, because @ObservedObject
        // needs a single observable to track. The forwarders fan-in
        // updates to a single edge.
        for model in [claude, codex, gemini, cursor, grok].compactMap({ $0 }) {
            model.objectWillChange
                .sink { [weak self] _ in
                    // Hop one runloop tick: AppModel's @Published
                    // properties fire objectWillChange BEFORE their
                    // value is set, so reading on the same tick
                    // would observe the old value.
                    Task { @MainActor in
                        self?.objectWillChange.send()
                    }
                }
                .store(in: &cancellables)
        }
    }
}

// MARK: - Menu-bar popover selection driver

/// Lets the controller re-target the popover's active tab on each open.
/// The NSPopover + NSHostingController is built once per status item and
/// reused, so the popover's `@State selected` is seeded once at init and
/// never reactivates when a different provider's status item is clicked.
/// The controller bumps `requested` (+ `epoch` so re-clicking the same
/// provider still fires) in its toggle handler; the popover observes this
/// and reconciles `selected` via `.onChange`. Optional on the view so the
/// preview / legacy call sites keep the original seed-once behavior.
@MainActor
public final class MenuBarPopoverSelection: ObservableObject {
    @Published public var requested: TahoeProvider
    /// Bumped alongside `requested` so re-selecting the already-requested
    /// provider still publishes a distinct change the view can observe.
    @Published public var epoch: Int = 0

    public init(initial: TahoeProvider) {
        self.requested = initial
    }

    public func request(_ provider: TahoeProvider) {
        requested = provider
        epoch &+= 1
    }
}
