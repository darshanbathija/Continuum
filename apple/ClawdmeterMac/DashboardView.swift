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
    @ObservedObject var geminiModel: AppModel
    @ObservedObject var usageHistoryStore: UsageHistoryStore
    @ObservedObject var sessionsModel: SessionsModel

    @AppStorage(AppTheme.storageKey) private var themeRaw: String = AppTheme.system.rawValue

    /// Per-provider "show in the menu bar" preferences. Read by `AppDelegate`
    /// to add or remove `NSStatusItem`s. Both default-on so first-launch
    /// behaviour matches what the docs promise.
    @AppStorage("clawdmeter.claude.menuBarShown") private var claudeMenuBarShown: Bool = true
    @AppStorage("clawdmeter.codex.menuBarShown") private var codexMenuBarShown: Bool = true
    @AppStorage("clawdmeter.gemini.menuBarShown") private var geminiMenuBarShown: Bool = true

    /// Sessions feature toggle (T18 feature flag). Default true — the
    /// SwiftUI-side check; AppRuntime also gates daemon startup on it.
    @AppStorage("clawdmeter.sessions.enabled") private var sessionsEnabled: Bool = true

    /// Top-level tab selection. Sessions tab is hidden when the feature
    /// flag is off (existing Usage view fills the whole window).
    @State private var selectedTab: DashboardTab = .usage

    /// Drives the "Sync with iPhone" popover in the header. The popover
    /// renders the pairing QR + Copy URL CTA — the two things users need
    /// to pair an iPhone — without burying them in Settings → Sessions.
    @State private var showPairingPopover: Bool = false

    private var theme: AppTheme {
        AppTheme(rawValue: themeRaw) ?? .system
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            Divider()
            tabContent
        }
        // Min size keeps the window usable when the user shrinks it; the
        // default size (set on the Window scene) opens large enough for the
        // analytics row to be visible without scrolling.
        .frame(minWidth: 820, minHeight: 580)
        .background(backgroundColor)
        .preferredColorScheme(theme.colorScheme)
    }

    // MARK: - Tab strip + content

    enum DashboardTab: String, CaseIterable {
        case chat = "Chat"
        case usage = "Usage"
        case sessions = "Code"
    }

    /// 3-col / 2-col / 1-col responsive layout per D10. Breakpoints mirror
    /// the Sessions tab's <1100pt collapse pattern.
    @ViewBuilder
    private func providerColumns(width: CGFloat) -> some View {
        if width >= 1200 {
            HStack(spacing: 0) {
                ProviderColumn(model: claudeModel)
                Divider()
                ProviderColumn(model: codexModel)
                Divider()
                ProviderColumn(model: geminiModel)
            }
        } else if width >= 800 {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ProviderColumn(model: claudeModel)
                    Divider()
                    ProviderColumn(model: codexModel)
                }
                Divider()
                ProviderColumn(model: geminiModel)
            }
        } else {
            VStack(spacing: 0) {
                ProviderColumn(model: claudeModel)
                Divider()
                ProviderColumn(model: codexModel)
                Divider()
                ProviderColumn(model: geminiModel)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? primaryText : secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == tab
                                ? AnyShapeStyle(terraCotta.opacity(0.12))
                                : AnyShapeStyle(Color.clear)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
    }

    private var visibleTabs: [DashboardTab] {
        sessionsEnabled ? DashboardTab.allCases : [.usage]
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .chat:
            if #available(macOS 14, *) {
                ChatWorkspaceView(model: sessionsModel)
            } else {
                Text("Chat tab requires macOS 14+")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .usage:
            ScrollView {
                VStack(spacing: 0) {
                    // 3-col responsive layout per D10: ≥1200pt = 3 cols
                    // side-by-side, 800-1200pt = 2 cols (Claude+Codex top,
                    // Gemini below), <800pt = single-column vertical.
                    // Mirrors the Sessions tab's existing collapse pattern.
                    GeometryReader { proxy in
                        providerColumns(width: proxy.size.width)
                    }
                    .frame(minHeight: 460)
                    Divider()
                    if #available(macOS 13, *) {
                        AnalyticsView(store: usageHistoryStore)
                    }
                }
            }
        case .sessions:
            SessionsView(model: sessionsModel)
        }
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

    // MARK: - Header (title + menu bar toggles + theme pill)

    private var header: some View {
        HStack(spacing: 18) {
            Text("Clawdmeter")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(primaryText)

            Spacer()

            // Menu bar toggles — promoted from the bottom of the window
            // so they sit alongside the theme selector at the top.
            HStack(spacing: 14) {
                Text("Menu bar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondaryText)

                Toggle("Claude", isOn: $claudeMenuBarShown)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(primaryText)

                Toggle("Codex", isOn: $codexMenuBarShown)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(primaryText)

                Toggle("Gemini", isOn: $geminiMenuBarShown)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(primaryText)
            }

            syncWithiPhoneButton

            ThemePill(themeRaw: $themeRaw, scheme: effectiveScheme)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    /// Front-and-center pairing CTA: QR + Copy URL in a popover so users
    /// don't have to dig through Settings → Sessions to bring an iPhone
    /// online. The Settings pane keeps the destructive controls
    /// (regenerate / revoke); this one is the happy-path entry point.
    @ViewBuilder
    private var syncWithiPhoneButton: some View {
        if let runtime = AppDelegate.runtime {
            Button {
                showPairingPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Sync with iPhone")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(terraCotta)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPairingPopover, arrowEdge: .bottom) {
                PairingQRPopoverContent(runtime: runtime)
            }
        }
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.config.displayName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(primaryText)
                    // D8: when the provider's auth file isn't detected
                    // (e.g. ~/.gemini/oauth_creds.json missing) surface
                    // a "Not detected" subtitle so the column reads as
                    // honest "no data" instead of a perpetually-spinning
                    // "Connecting…" state. Today only Gemini has the
                    // file-presence proxy; Claude/Codex's tokens live in
                    // Keychain / auth.json and detection there happens
                    // by `model.usage == nil && !needsReauth` for >60s.
                    if let subtitle = providerSubtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                    }
                }
                Spacer()
            }

            // D4: stale-token banner shown inline (not just in Settings)
            // when the model surfaced `.unauthenticatedNeedsReauth` from
            // its poller. Includes a one-click copy-command button for
            // the provider-specific re-login flow.
            if model.needsReauth {
                staleTokenBanner
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

            // Weekly limits — only render when the provider exposes a real
            // weekly bucket upstream (Claude/Codex). Gemini's cloudcode-pa
            // returns a single refreshTime per model, so a 0% "Weekly limits"
            // card here would invent a window that doesn't exist. iOS
            // GeminiSection already drops its WeeklyCard for the same reason.
            if model.config.hasWeeklyWindow {
                Divider().background(dividerColor)

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
            }

            Divider().background(dividerColor)

            // Advanced — auto-revive controls. Always expanded in the
            // dashboard (the popover collapses it to keep the menu bar
            // surface compact; here we have the room).
            advancedSection

            Divider().background(dividerColor)

            // Last updated + refresh. D7: when the source returned a cached
            // snapshot with `.unknown` status (parse-miss / 5xx fallback),
            // surface "Stale · updated Xh ago" so the user knows the
            // numbers above are last-known-good, not live.
            HStack(spacing: 8) {
                if let updatedAt = model.usage?.updatedAt {
                    let stale = model.usage?.status == .unknown
                    HStack(spacing: 5) {
                        if stale {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.orange)
                                .accessibilityLabel("Data is stale")
                        }
                        (Text(stale ? "Stale · updated " : "Last updated ")
                         + Text(updatedAt, style: .relative)
                         + Text(" ago"))
                            .font(.system(size: 12))
                            .foregroundStyle(stale ? Color.orange.opacity(0.85) : secondaryText)
                            .monospacedDigit()
                    }
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
        // Auto-revive toggle gated on the provider's own capability flag
        // (see ProviderConfig.supportsAutoRevive). Eliminates the previous
        // `id == "claude"` hardcode (per E3 #3 / Codex P1(6)).
        let autoReviveSupported = model.config.supportsAutoRevive

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

    /// D8: subtitle shown under the provider name when the local auth
    /// material isn't detected. Returns nil when the provider is in a
    /// normal state. Currently only Gemini exposes a file-presence
    /// proxy (`~/.gemini/oauth_creds.json`); Claude/Codex's tokens live
    /// in Keychain / `~/.codex/auth.json` and we can't cheaply detect
    /// "not configured" vs "configured but offline" for them.
    private var providerSubtitle: String? {
        guard model.config.id == "gemini" else { return nil }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/oauth_creds.json")
        let exists = FileManager.default.fileExists(atPath: path)
        return exists ? nil : "Not detected · install gemini CLI"
    }

    /// D4: provider-specific re-login command, used by the stale-token
    /// banner's "Copy command" button. Returns nil when the provider
    /// doesn't have a known re-auth incantation.
    private var reAuthCommand: String? {
        switch model.config.id {
        case "claude": return "claude auth login"
        case "codex":  return "codex auth login"
        case "gemini": return "gemini auth login"
        default:       return nil
        }
    }

    /// D4: inline banner shown above the session/weekly cards when the
    /// model's poller surfaced `.unauthenticatedNeedsReauth`. Mirrors the
    /// banner already in ProvidersSettingsView but lands where the user
    /// actually looks first (the provider column on the dashboard).
    @ViewBuilder
    private var staleTokenBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Token expired")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryText)
                if let cmd = reAuthCommand {
                    Text("Run `\(cmd)` in a terminal, then click Refresh below.")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy command") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(cmd, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("Reconnect this provider — see Settings → Providers.")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.5)
        )
    }

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
        // The Codex asset is a black silhouette on a transparent canvas;
        // rendering it directly makes the glyph disappear on the dark Mac
        // dashboard background. Mark it template so SwiftUI tints it with
        // the surrounding foreground style (which adapts to color scheme).
        // Claude's burst stays full-color.
        let templated = (assetName == "CodexLogo")
        let img: NSImage = {
            if templated, let copy = nsImage.copy() as? NSImage {
                copy.isTemplate = true
                return copy
            }
            return nsImage
        }()
        Image(nsImage: img)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.primary)
    } else {
        Rectangle()
            .fill(.secondary.opacity(0.2))
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
