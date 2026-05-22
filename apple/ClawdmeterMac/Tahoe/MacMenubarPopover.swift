import SwiftUI
import Combine
import ClawdmeterShared

/// Replacement for `PopoverView`. Provider segmented + stacked meters.
/// Ports `mac-dashboard.jsx::MacMenubarPopover`.
///
/// v0.12 button-wiring pass: the "Open dashboard" and "Sync iPhone"
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

    private let enabled: [TahoeProvider] = [.claude, .codex, .gemini]

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
        geminiModel: AppModel
    ) {
        self.data = .demo  // fallback never used when liveSource is wired
        self._selected = State(initialValue: initialProvider)
        self.onOpenDashboard = onOpenDashboard
        self.onSyncIPhone = onSyncIPhone
        self.liveSource = MenuBarLiveSource(
            claude: claudeModel, codex: codexModel, gemini: geminiModel
        )
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
            gemini: liveRow(model: models.gemini, provider: .gemini)
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
            }
        }()
        guard let usage = model.usage else {
            // Honest "Connecting…" state — zero gauges, hints empty,
            // `hasWeekly` from the real config (false for gemini).
            return TahoeLiveRow(
                sessionPercent: 0,
                weeklyPercent: 0,
                sessionResetIn: "—",
                weeklyResetIn: "—",
                modelName: modelName,
                autoReviveOn: model.autoReviver.isEnabled,
                autoReviveAgo: "—",
                hasWeekly: model.config.hasWeeklyWindow
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
            autoReviveOn:   model.autoReviver.isEnabled,
            autoReviveAgo:  "—",
            hasWeekly:      model.config.hasWeeklyWindow,
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
        let row = activeData.row(for: selected)
        // v0.22.8: drop the outer `TahoeGlass(radius: 18, tone: .panel)`
        // wrapper. NSPopover already draws its own translucent bubble
        // around the contentViewController, so stacking a second glass
        // panel inside produced the doubled-border look the user
        // flagged (designed vs. actual container mismatch). Now the
        // NSPopover bubble IS the container.
        VStack(alignment: .leading, spacing: 0) {
            // Provider segmented control
            HStack(spacing: 3) {
                ForEach(enabled) { p in
                    providerTab(p)
                }
            }
            .padding(3)
            .background {
                Capsule(style: .continuous).fill(t.glassTintHi)
            }
            .padding(.bottom, 12)

            // 5h + Weekly meters
            VStack(spacing: 12) {
                TahoeMenuBarMeter(label: "5h session", percent: row.sessionPercent, hint: "resets in \(row.sessionResetIn)", provider: selected, stale: row.stale)
                if row.hasWeekly {
                    TahoeMenuBarMeter(label: "Weekly", percent: row.weeklyPercent, hint: "resets in \(row.weeklyResetIn)", provider: selected, stale: row.stale)
                }
            }
            .padding(.horizontal, 4)

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
                        Text("Sync iPhone")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 360)
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
        let active = p == selected
        Button {
            guard p != selected else { return }
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { selected = p }
        } label: {
            HStack(spacing: 6) {
                TahoeProviderGlyph(provider: p, size: 18)
                Text(p.displayName)
            }
            .font(TahoeFont.body(12, weight: active ? .bold : .semibold))
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
            .animation(nil, value: selected)
        }
        .buttonStyle(.plain)
    }
}

/// Status-item label as it appears in the macOS menu bar.
/// Ports the JSX `menu-bar items` row format: `[glyph] {percent}%` per provider.
public struct MenuBarItemView: View {
    @Environment(\.tahoe) private var t
    public var provider: TahoeProvider
    public var percent: Double
    public var onClick: () -> Void

    public init(provider: TahoeProvider, percent: Double, onClick: @escaping () -> Void) {
        self.provider = provider; self.percent = percent; self.onClick = onClick
    }

    public var body: some View {
        Button(action: onClick) {
            HStack(spacing: 5) {
                TahoeProviderGlyph(provider: provider, size: 14)
                Text("\(Int(percent))%")
                    .font(TahoeFont.mono(11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(t.fg)
            }
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 6).padding(.vertical, 2)
        }
        .buttonStyle(.plain)
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
    init(claude: AppModel, codex: AppModel, gemini: AppModel) {
        self.models = Models(claude: claude, codex: codex, gemini: gemini)
        // Forward each provider's objectWillChange to our own. The
        // popover view subscribes to MenuBarLiveSource (this) rather
        // than the three AppModels directly, because @ObservedObject
        // needs a single observable to track. The forwarders fan-in
        // updates to a single edge.
        for model in [claude, codex, gemini] {
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
