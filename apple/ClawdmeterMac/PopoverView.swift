import SwiftUI
import ClawdmeterShared

/// Popover modeled after Claude's iOS Usage page, with:
///   - close button (left), "Usage" title, 3-way theme pill (right)
///   - "Current session" + progress bar + percentage + live countdown
///   - "Weekly limits" + "All models" + progress bar + percentage + absolute reset
///   - "Last updated: …" + refresh button (bottom)
struct PopoverView: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppTheme.storageKey) private var themeRaw: String = AppTheme.system.rawValue
    @State private var advancedExpanded: Bool = false

    /// Auto-revive preference is namespaced per provider (each model has its own toggle).
    private var autoReviveStorageKey: String {
        "\(model.config.storageKeyPrefix).autoRevive"
    }
    @AppStorage private var autoReviveEnabled: Bool

    init(model: AppModel) {
        self.model = model
        self._autoReviveEnabled = AppStorage(wrappedValue: false, "\(model.config.storageKeyPrefix).autoRevive")
    }

    private var theme: AppTheme {
        AppTheme(rawValue: themeRaw) ?? .system
    }

    var body: some View {
        // Body is fully deterministic — no `Date()`, no `TimelineView`, no
        // non-deterministic value anywhere in this view hierarchy. Live
        // timestamps use `Text(_:style: .relative)`, which schedules its own
        // internal updates without invalidating the view graph.
        //
        // Why this matters on Tahoe: anything that makes SwiftUI re-evaluate
        // this body — a 1Hz @Published clock on AppModel, a TimelineView, even
        // a bare `Date()` inline — cascades through `MenuBarExtra { content }`
        // into `AppDelegate.scenesDidChange → makeMainMenu`, which schedules
        // another body evaluation, looping at 100% CPU. Confirmed across four
        // separate sampler runs.
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    currentSessionSection
                    Divider().background(dividerColor)
                    weeklyLimitsSection
                    Divider().background(dividerColor)
                    advancedSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            footer
        }
        // Width is fixed; height is intrinsic — the popover's
        // NSHostingController has `sizingOptions = [.preferredContentSize]`,
        // so it re-sizes to whatever this VStack reports. Earlier hand-tuned
        // heights either cut Advanced off (480) or cut top/bottom (560/640).
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(backgroundColor)
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: autoReviveEnabled) { _, newValue in
            model.setAutoReviveEnabled(newValue)
        }
        .onAppear {
            // Sync persisted state into the model on first appear.
            model.setAutoReviveEnabled(autoReviveEnabled)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Usage")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(primaryText)
                Spacer()
                ThemePill(themeRaw: $themeRaw, scheme: effectiveScheme)
            }

            Button(action: {
                NotificationCenter.default.post(
                    name: AppDelegate.showDashboardNotification, object: nil
                )
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Open dashboard")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryText)
                }
                .foregroundStyle(primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(dashboardButtonFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(dashboardButtonBorder, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Open the Clawdmeter dashboard window")
            .accessibilityLabel("Open dashboard")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var dashboardButtonFill: Color {
        effectiveScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.white
    }
    private var dashboardButtonBorder: Color {
        effectiveScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.10)
    }

    // MARK: - Footer ("Last updated" + refresh)

    @ViewBuilder
    private var footer: some View {
        HStack {
            // `Text(_:style: .relative)` self-updates via SwiftUI's internal
            // timer machinery — no view-body re-render, so it doesn't trip the
            // MenuBarExtra scene reconciliation loop.
            HStack(spacing: 0) {
                Text("Last updated ")
                if let updatedAt = model.usage?.updatedAt {
                    Text(updatedAt, style: .relative) + Text(" ago")
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(secondaryText)

            Spacer()

            Button(action: { model.forcePoll() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .frame(width: 30, height: 30)
                    .background(refreshButtonFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh now")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(footerBackground)
    }

    private func circleButton(systemImage: String) -> some View {
        ZStack {
            Circle().fill(circleButtonFill)
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryText)
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Sections

    @ViewBuilder
    private var currentSessionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Current session")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(primaryText)

            if model.usage?.status == .notStarted {
                // No active 5h window — render an empty track, no countdown.
                ProgressTrack(value: 0)
                HStack {
                    Text("Not started")
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                    Spacer()
                    Text("Starts on next use")
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                }
            } else {
                ProgressTrack(value: progressValue(model.usage?.sessionPct))
                HStack {
                    Text("\(model.usage?.sessionPct ?? 0)% used")
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                    Spacer()
                    if let usage = model.usage {
                        let resetDate = Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch))
                        HStack(spacing: 0) {
                            Text("Resets ")
                            Text(resetDate, style: .relative)
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                        .monospacedDigit()
                    } else {
                        Text("—")
                            .font(.system(size: 14))
                            .foregroundStyle(secondaryText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { withAnimation(.snappy) { advancedExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryText)
                    Text("Advanced")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(advancedExpanded ? "Collapse advanced" : "Expand advanced")

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    // Codex auto-revive isn't implemented in V1 — the ChatGPT
                    // backend's `/conversation` endpoint takes a streaming SSE
                    // protocol with parent_message_id chaining, which is more
                    // surface area than a "Hi" ping deserves. Disable for
                    // Codex; only Claude's Anthropic Messages endpoint is
                    // simple enough to be a one-shot 1-token call.
                    // Gated on ProviderConfig.supportsAutoRevive (E3 #3 /
                    // Codex P1(6) refactor — eliminates `id == "claude"`
                    // hardcode).
                    let autoReviveSupported = model.config.supportsAutoRevive

                    Toggle(isOn: $autoReviveEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep 5h timer ticking")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(autoReviveSupported ? primaryText : secondaryText)
                            if autoReviveSupported {
                                Text("When the 5-hour window ends, send a 1-token 'Hi' to \(reviveModelDisplayName) so a new window starts immediately.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Not yet supported for Codex — the ChatGPT backend needs a streaming protocol we haven't wired up.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!autoReviveSupported)

                    if autoReviveSupported {
                        HStack(spacing: 8) {
                            autoReviveStatusView
                                .font(.system(size: 11))
                                .foregroundStyle(secondaryText)
                                .monospacedDigit()

                            Spacer()

                            Button("Revive now") { model.reviveNow() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!autoReviveEnabled)
                        }
                    }

                    // (The "Show Codex in menu bar" toggle was removed: its
                    // backing `MenuBarExtra(isInserted:)` triggers a SwiftUI
                    // KVO loop on macOS Tahoe — see ClawdmeterMacApp.body.)
                }
                .padding(.leading, 18)
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var weeklyLimitsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weekly limits")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(primaryText)

            Text("All models")
                .font(.system(size: 15))
                .foregroundStyle(primaryText)
                .padding(.top, 4)

            ProgressTrack(value: progressValue(model.usage?.weeklyPct))

            HStack {
                Text("\(model.usage?.weeklyPct ?? 0)% used")
                    .font(.system(size: 14))
                    .foregroundStyle(secondaryText)
                Spacer()
                // Weekly reset is days out — show the absolute date+time.
                // This is a derived constant from `usage.weeklyEpoch`, so it's
                // deterministic across body re-evaluations.
                Text(weeklyResetLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(secondaryText)
            }
        }
    }

    // MARK: - Computed labels

    /// Weekly reset is formatted as an absolute timestamp — the value depends
    /// only on `usage.weeklyEpoch`, which is itself stable until the next poll
    /// after the reset boundary. No "now" needed, so the body stays
    /// deterministic. Uses a weekday-only format because the weekly window is
    /// always within a week.
    private var weeklyResetLabel: String {
        guard let usage = model.usage else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(usage.weeklyEpoch))
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEE h:mm a"
        return "Resets \(formatter.string(from: date))"
    }

    private var reviveModelDisplayName: String {
        // "claude-haiku-4-5" → "Claude Haiku 4.5"
        let m = model.config.reviveModel
        if m.contains("haiku") { return "Claude Haiku 4.5" }
        if m.contains("gpt") { return "GPT 5.5 mini" }
        return m
    }

    /// "Last revived…" / "Armed…" / error status. Uses `Text(_:style: .relative)`
    /// for the elapsed-since-last-revive portion, which self-updates without
    /// re-running the view body.
    @ViewBuilder
    private var autoReviveStatusView: some View {
        if !autoReviveEnabled {
            Text("Off — toggle on to keep the 5h window perpetual.")
        } else if let last = model.autoReviver.lastResult {
            switch last.outcome {
            case .fired:
                Text("Last revived ") +
                Text(last.at, style: .relative) +
                Text(" ago · \(model.autoReviver.fireCount) total")
            case .throttled:
                Text("Throttled ") + Text(last.at, style: .relative) + Text(" ago")
            case .noToken:
                Text("Skipped (no token) ") + Text(last.at, style: .relative) + Text(" ago")
            case .httpError(let code):
                Text("API error \(code) ") + Text(last.at, style: .relative) + Text(" ago")
            case .networkError:
                Text("Network error ") + Text(last.at, style: .relative) + Text(" ago")
            case .disabled:
                Text("Disabled")
            }
        } else {
            Text("Armed. Will fire when the next 5h window ends.")
        }
    }

    private func progressValue(_ pct: Int?) -> Double {
        guard let pct else { return 0 }
        return max(0, min(1, Double(pct) / 100))
    }

    // MARK: - Theme-aware colors

    @Environment(\.colorScheme) private var systemColorScheme

    private var effectiveScheme: ColorScheme {
        theme.colorScheme ?? systemColorScheme
    }

    private var backgroundColor: Color {
        effectiveScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.96, green: 0.96, blue: 0.96)
    }

    private var footerBackground: Color {
        // Subtle elevation from the main background.
        effectiveScheme == .dark
            ? Color(red: 0.07, green: 0.07, blue: 0.07)
            : Color(red: 0.92, green: 0.92, blue: 0.92)
    }

    private var primaryText: Color {
        effectiveScheme == .dark ? .white : .black
    }

    private var secondaryText: Color {
        effectiveScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.55)
    }

    private var dividerColor: Color {
        effectiveScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.10)
    }

    private var circleButtonFill: Color {
        effectiveScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white
    }

    private var refreshButtonFill: Color {
        effectiveScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white
    }
}

// MARK: - 3-way theme pill (system / light / dark) — replaces the `i` button

struct ThemePill: View {
    @Binding var themeRaw: String
    let scheme: ColorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTheme.allCases) { t in
                button(for: t)
            }
        }
        .padding(3)
        .background(containerFill)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
    }

    private func button(for theme: AppTheme) -> some View {
        let isSelected = themeRaw == theme.rawValue
        return Button(action: { themeRaw = theme.rawValue }) {
            Image(systemName: icon(for: theme))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? selectedFG : unselectedFG)
                .frame(width: 30, height: 24)
                .background(isSelected ? selectedFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? selectedBorder : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.displayName) appearance")
    }

    private func icon(for theme: AppTheme) -> String {
        switch theme {
        case .system: return "display"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    // Theme-aware colors
    private var containerFill: Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
    private var borderColor: Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
    private var selectedFill: Color {
        scheme == .dark ? Color.white.opacity(0.18) : Color.white
    }
    private var selectedBorder: Color {
        scheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.10)
    }
    private var selectedFG: Color {
        scheme == .dark ? .white : .black
    }
    private var unselectedFG: Color {
        scheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)
    }
}

// MARK: - Progress bar matching Claude iOS Usage page

struct ProgressTrack: View {
    let value: Double  // 0...1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule().fill(fillColor).frame(width: max(8, geo.size.width * value))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private var fillColor: Color {
        Color(red: 0x36 / 255.0, green: 0x7C / 255.0, blue: 0xF0 / 255.0)
    }
}
