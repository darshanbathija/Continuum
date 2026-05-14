import SwiftUI
import ClawdmeterShared

/// One-page main window. Both providers side-by-side, with current-session and
/// weekly-window meters plus reset countdowns. Opens when the user launches
/// Clawdmeter from /Applications, Spotlight, or the Dock.
///
/// The menu bar items remain for quick access from anywhere; this window is
/// the "the whole picture in one place" view.
struct DashboardView: View {
    @ObservedObject var claudeModel: AppModel
    @ObservedObject var codexModel: AppModel
    @ObservedObject var usageHistoryStore: UsageHistoryStore

    @AppStorage(AppTheme.storageKey) private var themeRaw: String = AppTheme.system.rawValue

    /// Per-provider "show in the menu bar" preferences. Read by `AppDelegate`
    /// to add or remove `NSStatusItem`s. Both default-on so first-launch
    /// behaviour matches what the docs promise.
    @AppStorage("clawdmeter.claude.menuBarShown") private var claudeMenuBarShown: Bool = true
    @AppStorage("clawdmeter.codex.menuBarShown") private var codexMenuBarShown: Bool = true

    private var theme: AppTheme {
        AppTheme(rawValue: themeRaw) ?? .system
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                HStack(spacing: 0) {
                    ProviderColumn(model: claudeModel)
                    Divider()
                    ProviderColumn(model: codexModel)
                }

                Divider()

                if #available(macOS 13, *) {
                    AnalyticsView(store: usageHistoryStore)
                }

                menuBarTogglesRow
            }
        }
        // Min size keeps the window usable when the user shrinks it; the
        // default size (set on the Window scene) opens large enough for the
        // analytics row to be visible without scrolling.
        .frame(minWidth: 820, minHeight: 580)
        .background(backgroundColor)
        .preferredColorScheme(theme.colorScheme)
    }

    // MARK: - Menu bar toggles

    private var menuBarTogglesRow: some View {
        HStack(spacing: 24) {
            Text("Menu bar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryText)

            Toggle("Claude", isOn: $claudeMenuBarShown)
                .toggleStyle(.checkbox)
                .foregroundStyle(primaryText)

            Toggle("Codex", isOn: $codexMenuBarShown)
                .toggleStyle(.checkbox)
                .foregroundStyle(primaryText)

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(footerBackground)
    }

    // MARK: - Header (title + theme pill)

    private var header: some View {
        HStack {
            Text("Clawdmeter")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(primaryText)

            Spacer()

            ThemePill(themeRaw: $themeRaw, scheme: effectiveScheme)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
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
}

// MARK: - One provider's column (gauge + countdowns + advanced)

private struct ProviderColumn: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    /// Auto-revive preference is namespaced per provider so Claude and Codex
    /// each remember their own toggle independently.
    @AppStorage private var autoReviveEnabled: Bool
    /// Advanced section collapse state, also per-provider so each column
    /// remembers independently.
    @AppStorage private var advancedExpanded: Bool

    init(model: AppModel) {
        self._model = ObservedObject(initialValue: model)
        self._autoReviveEnabled = AppStorage(
            wrappedValue: false,
            "\(model.config.storageKeyPrefix).autoRevive"
        )
        self._advancedExpanded = AppStorage(
            wrappedValue: false,
            "\(model.config.storageKeyPrefix).advancedExpanded"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Provider title + logo
            HStack(spacing: 10) {
                providerBadge(assetName: model.config.logoAssetName, size: 32)
                Text(model.config.displayName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(primaryText)
                Spacer()
            }

            // Current session
            VStack(alignment: .leading, spacing: 12) {
                Text("Current session")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(primaryText)

                if model.usage?.status == .notStarted {
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
                } else if let usage = model.usage {
                    ProgressTrack(value: progressValue(usage.sessionPct))
                    HStack {
                        Text("\(usage.sessionPct)% used")
                            .font(.system(size: 14))
                            .foregroundStyle(secondaryText)
                        Spacer()
                        let resetDate = Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch))
                        (Text("Resets ") + Text(resetDate, style: .relative))
                            .font(.system(size: 14))
                            .foregroundStyle(secondaryText)
                            .monospacedDigit()
                    }
                } else {
                    ProgressTrack(value: 0)
                    Text("Connecting…")
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                }
            }

            Divider().background(dividerColor)

            // Weekly limits
            VStack(alignment: .leading, spacing: 12) {
                Text("Weekly limits")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(primaryText)

                Text("All models")
                    .font(.system(size: 13))
                    .foregroundStyle(secondaryText)

                ProgressTrack(value: progressValue(model.usage?.weeklyPct))
                HStack {
                    Text("\(model.usage?.weeklyPct ?? 0)% used")
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                    Spacer()
                    if let usage = model.usage {
                        let weeklyDate = Date(timeIntervalSince1970: TimeInterval(usage.weeklyEpoch))
                        (Text("Resets ") + Text(weeklyDate, style: .relative))
                            .font(.system(size: 14))
                            .foregroundStyle(secondaryText)
                            .monospacedDigit()
                    }
                }
            }

            Divider().background(dividerColor)

            // Advanced — auto-revive controls. Always expanded in the
            // dashboard (the popover collapses it to keep the menu bar
            // surface compact; here we have the room).
            advancedSection

            Divider().background(dividerColor)

            // Last updated + refresh
            HStack {
                if let updatedAt = model.usage?.updatedAt {
                    (Text("Last updated ") + Text(updatedAt, style: .relative) + Text(" ago"))
                        .font(.system(size: 12))
                        .foregroundStyle(secondaryText)
                        .monospacedDigit()
                } else {
                    Text("Connecting…")
                        .font(.system(size: 12))
                        .foregroundStyle(secondaryText)
                }

                Spacer()

                Button(action: { model.forcePoll() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .frame(width: 30, height: 30)
                        .background(buttonFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh \(model.config.displayName)")
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: autoReviveEnabled) { _, newValue in
            model.setAutoReviveEnabled(newValue)
        }
        .onAppear {
            // Mirror persisted state into the model on first appear so the
            // background AutoReviver tick respects the saved toggle.
            model.setAutoReviveEnabled(autoReviveEnabled)
        }
    }

    // MARK: - Advanced section

    @ViewBuilder
    private var advancedSection: some View {
        // Codex's auto-revive isn't implemented (ChatGPT backend uses SSE
        // streaming, not a one-shot completion call). Disable the toggle
        // and explain inline.
        let autoReviveSupported = (model.config.id == "claude")

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
                .contentShape(Rectangle())  // make the whole row clickable, not just the text
            }
            .buttonStyle(.plain)
            .accessibilityLabel(advancedExpanded ? "Collapse advanced" : "Expand advanced")

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 14) {
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
                }
                .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private var autoReviveStatusView: some View {
        if !autoReviveEnabled {
            Text("Off — toggle on to keep the 5h window perpetual.")
        } else if let last = model.autoReviver.lastResult {
            switch last.outcome {
            case .fired:
                Text("Last revived ")
                    + Text(last.at, style: .relative)
                    + Text(" ago · \(model.autoReviver.fireCount) total")
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

    private var reviveModelDisplayName: String {
        // Mirror PopoverView's pretty-print so the two surfaces stay in sync.
        let m = model.config.reviveModel
        if m.contains("haiku") { return "Claude Haiku 4.5" }
        if m.contains("gpt") { return "GPT 5.5 mini" }
        return m
    }

    // MARK: - Helpers

    private func progressValue(_ pct: Int?) -> Double {
        guard let pct else { return 0 }
        return max(0, min(1, Double(pct) / 100))
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }
    private var secondaryText: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.55)
    }
    private var dividerColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.10)
    }
    private var buttonFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white
    }
}

// MARK: - Provider logo badge

@ViewBuilder
private func providerBadge(assetName: String, size: CGFloat) -> some View {
    if let nsImage = NSImage(named: assetName) {
        Image(nsImage: nsImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    } else {
        Rectangle()
            .fill(.secondary.opacity(0.2))
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
