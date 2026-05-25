import SwiftUI
import ClawdmeterShared

/// Mac Settings — drives the global TahoeThemeStore so flipping a switch
/// here repaints every other surface. Ports `mac-settings.jsx`.
///
/// v0.12 button-wiring pass: the Auto-revive toggle now writes to the
/// per-provider `AppModel.setAutoReviveEnabled(_:)` for every provider
/// that supports the feature. Mirror-to-iPhone and Notify-at-90% remain
/// local state with hint copy explaining they're not yet wired (no
/// daemon endpoints exist for those today). Reset-to-defaults wired to
/// `TahoeThemeStore.resetToDefaults()`.
public struct MacSettingsView: View {
    @Environment(\.tahoe) private var t
    @Bindable public var theme: TahoeThemeStore

    @ObservedObject var claudeModel: AppModel
    @ObservedObject var codexModel: AppModel
    @ObservedObject var geminiModel: AppModel
    /// v0.22.9: runtime threaded in so the consolidated settings page
    /// can embed PairingSettingsView (needs AppRuntime for the daemon
    /// + pairing token shape). Optional so Previews don't have to
    /// stand up a full runtime.
    var runtime: AppRuntime?

    /// Source of truth for the auto-revive toggle. Reads the real state
    /// off whichever provider supports it (Claude is the canonical one
    /// today). Setter fans out to every provider that supports auto-revive.
    @SceneStorage("clawdmeter.mac.settings.selectedSection") private var selectedSectionRaw: String = SettingsSection.visual.rawValue

    // v0.22.9: dropped to `internal` because the `runtime` parameter
    // exposes `AppRuntime`, which lives in the Mac target (not the
    // shared library) and is itself `internal`. The Settings page is
    // only constructed from `MacRootView` inside the same target, so
    // the access change has no external impact.
    init(
        theme: TahoeThemeStore,
        claudeModel: AppModel,
        codexModel: AppModel,
        geminiModel: AppModel,
        runtime: AppRuntime? = nil
    ) {
        self.theme = theme
        self.claudeModel = claudeModel
        self.codexModel = codexModel
        self.geminiModel = geminiModel
        self.runtime = runtime
    }

    /// Composite auto-revive state. True when any provider that supports
    /// auto-revive currently has it enabled. Setter writes to every
    /// supporting provider so the toggle is "all or nothing" — matches the
    /// per-provider auto-revive card on MacUsageView's hero column.
    private var autoReviveBinding: Binding<Bool> {
        Binding(
            get: {
                let providers = [claudeModel, codexModel, geminiModel]
                    .filter { $0.config.supportsAutoRevive }
                guard !providers.isEmpty else { return false }
                return providers.contains { $0.autoReviver.isEnabled }
            },
            set: { newValue in
                for model in [claudeModel, codexModel, geminiModel]
                    where model.config.supportsAutoRevive {
                    model.setAutoReviveEnabled(newValue)
                }
            }
        )
    }

    public var body: some View {
        VStack(spacing: 18) {
            SettingsHeader(onReset: { theme.resetToDefaults() })

            HStack(alignment: .top, spacing: 18) {
                SettingsSidebar(
                    selection: selectedSection,
                    onSelect: { selectedSectionRaw = $0.rawValue }
                )
                .frame(width: 220)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsSectionHeader(section: selectedSection)
                        selectedSectionContent
                    }
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 6).padding(.bottom, 20).padding(.top, 20)
    }

    private var selectedSection: SettingsSection {
        SettingsSection(rawValue: selectedSectionRaw) ?? .visual
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .visual:
            visualSettings
        case .providers:
            providerSettings
        case .devices:
            deviceSettings
        case .diagnostics:
            diagnosticsSettings
        }
    }

    @ViewBuilder
    private var visualSettings: some View {
        SettingsCard(title: "Appearance",
                     sub: "How the app looks. Independent of your system setting.") {
            SettingsRow(label: "Theme", hint: "Light for daytime, Dark for late-night sessions.") {
                SwatchToggle(
                    value: theme.appearance == .dark ? "dark" : "light",
                    options: [
                        .init(key: "light", label: "Light", swatch: AnyView(ThemeSwatch(dark: false))),
                        .init(key: "dark",  label: "Dark",  swatch: AnyView(ThemeSwatch(dark: true))),
                    ]
                ) { theme.appearance = $0 == "dark" ? .dark : .light }
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Surface",
                        hint: "Translucent layers refract the wallpaper through every panel. Solid is calmer and faster on older Macs.") {
                SwatchToggle(
                    value: theme.surface == .translucent ? "translucent" : "solid",
                    options: [
                        .init(key: "solid",        label: "Solid",       swatch: AnyView(SurfaceSwatch(glass: false))),
                        .init(key: "translucent",  label: "Translucent", swatch: AnyView(SurfaceSwatch(glass: true))),
                    ]
                ) { theme.surface = $0 == "translucent" ? .translucent : .solid }
            }
        }

        SettingsCard(title: "Background",
                     sub: "Tints the wallpaper that sits behind every glass panel.") {
            SettingsRow(label: "Vibrance",
                        hint: "Colorful gives you the aurora-tinted hero look. Muted strips out the hue for a focus-mode feel.") {
                SwatchToggle(
                    value: theme.wallpaper.isMuted ? "muted" : "colorful",
                    options: [
                        .init(key: "colorful", label: "Colorful", swatch: AnyView(WallSwatch(name: .aurora))),
                        .init(key: "muted",    label: "Muted",    swatch: AnyView(WallSwatch(name: .graphite))),
                    ]
                ) { theme.wallpaper = $0 == "muted" ? .graphite : .aurora }
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Accent", hint: "Used on the primary button, active tab, and the iPhone Live ring.") {
                AccentPicker(value: $theme.accent)
            }
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        // Providers card. All providers use the same row shape so
        // their visual rhythm matches: glyph + title + one-line status +
        // single trailing control (button or toggle).
        SettingsCard(title: "Providers",
                     sub: "External agent runtimes Clawdmeter can drive.") {
            VStack(alignment: .leading, spacing: 14) {
                ClaudeCLIProviderRow()
                TahoeHair()
                OpencodeProviderRow()
                TahoeHair()
                CodexSDKProviderRow()
                TahoeHair()
                AntigravitySDKProviderRow()
                TahoeHair()
                CursorSDKProviderRow()
            }
        }
    }

    @ViewBuilder
    private var deviceSettings: some View {
        SettingsCard(title: "Quota & sync",
                     sub: "Behavior that affects the menu-bar agent and the paired iPhone.") {
            SettingsRow(label: "Auto-revive 5h timer",
                        hint: "Sends a no-op every ~4 hours so you don't lose your rolling session window. Applies to every provider that supports it.") {
                TahoeToggleView(on: autoReviveBinding)
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Mirror to iPhone",
                        hint: "Live gauges sync through the pairing service when a phone is paired. No separate toggle exists yet.") {
                SettingsUnavailableBadge()
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Notify at 90%",
                        hint: "Notification routing is not implemented in this settings surface yet.") {
                SettingsUnavailableBadge()
            }
        }

        SettingsCard(title: "Live Activities",
                     sub: "Real-time iPhone Lock Screen + Dynamic Island state for each running session.") {
            LiveActivitySetupView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let runtime {
            SettingsCard(title: "Pairing",
                         sub: "Pair an iPhone over Tailscale so the iPhone app + widgets see live quota + sessions.") {
                PairingSettingsView(runtime: runtime)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSettings: some View {
        SettingsCard(title: "Diagnostics",
                     sub: "Diagnose data sources, copy debug bundles, force refresh, and explore the on-disk cache.") {
            DiagnosticsSettingsView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsUnavailableBadge: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        Text("Unavailable")
            .font(TahoeFont.body(11, weight: .bold))
            .foregroundStyle(t.fg3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background { Capsule().fill(t.glassTintHi) }
            .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case visual
    case providers
    case devices
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visual: return "Visual"
        case .providers: return "Providers"
        case .devices: return "Devices"
        case .diagnostics: return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .visual:
            return "Theme, glass surface, wallpaper, and accent color."
        case .providers:
            return "External agent runtimes and native SDK modes."
        case .devices:
            return "Quota behavior, iPhone mirroring, Live Activities, and pairing."
        case .diagnostics:
            return "Debug bundles, source checks, cache tools, and wire inspection."
        }
    }

    var icon: String {
        switch self {
        case .visual: return "sparkles"
        case .providers: return "terminal"
        case .devices: return "link"
        case .diagnostics: return "gear"
        }
    }
}

private struct SettingsSidebar: View {
    @Environment(\.tahoe) private var t
    var selection: SettingsSection
    var onSelect: (SettingsSection) -> Void

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            VStack(alignment: .leading, spacing: 6) {
                Text("GROUPS")
                    .font(TahoeFont.body(10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(t.fg4)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: section == selection,
                        onSelect: { onSelect(section) }
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
        }
    }
}

private struct SettingsSidebarRow: View {
    @Environment(\.tahoe) private var t
    var section: SettingsSection
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                TahoeIcon(section.icon, size: 13, weight: .semibold)
                    .foregroundStyle(isSelected ? t.accent : t.fg3)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(isSelected ? t.fg : t.fg2)
                        .lineLimit(1)
                    Text(section.subtitle)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? t.accentAlpha(t.dark ? 0.16 : 0.09) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? t.accentAlpha(0.55) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsSectionHeader: View {
    @Environment(\.tahoe) private var t
    var section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TahoeIcon(section.icon, size: 13, weight: .semibold)
                    .foregroundStyle(t.accent)
                Text(section.title)
                    .font(TahoeFont.body(18, weight: .bold))
                    .foregroundStyle(t.fg)
            }
            Text(section.subtitle)
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

// MARK: - Header

private struct SettingsHeader: View {
    @Environment(\.tahoe) private var t
    var onReset: () -> Void
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(TahoeFont.body(28, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(t.fg)
                Text("Tweak the look of the app and how it talks to your devices.")
                    .font(TahoeFont.body(13))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
            TahoeGhostButton(size: .s, action: onReset) {
                HStack(spacing: 5) {
                    TahoeIcon("refresh", size: 10)
                    Text("Reset to defaults")
                }
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}

// MARK: - Card / row

private struct SettingsCard<Content: View>: View {
    @Environment(\.tahoe) private var t
    var title: String
    var sub: String?
    @ViewBuilder var content: Content

    var body: some View {
        TahoeGlass(radius: 20, tone: .panel) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(t.fg3)
                    if let sub {
                        Text(sub).font(TahoeFont.body(12.5)).foregroundStyle(t.fg3)
                    }
                }
                .padding(.bottom, 18)
                content
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsRow<Control: View>: View {
    @Environment(\.tahoe) private var t
    var label: String
    var hint: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(TahoeFont.body(14, weight: .semibold)).foregroundStyle(t.fg)
                if let hint {
                    Text(hint)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .frame(maxWidth: 460, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

// MARK: - SwatchToggle

private struct SwatchToggle: View {
    @Environment(\.tahoe) private var t
    struct Option { var key: String; var label: String; var swatch: AnyView }
    var value: String
    var options: [Option]
    var onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.key) { opt in
                let on = opt.key == value
                Button { onChange(opt.key) } label: {
                    VStack(spacing: 6) {
                        opt.swatch
                            .frame(width: 92, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(t.hairline, lineWidth: 0.5)
                            }
                        Text(opt.label)
                            .font(TahoeFont.body(12, weight: on ? .bold : .semibold))
                            .foregroundStyle(on ? t.accent : t.fg2)
                    }
                    .padding(6)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? t.accentAlpha(t.dark ? 0.16 : 0.08) : .clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(on ? t.accentAlpha(0.7) : t.hairline, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ThemeSwatch: View {
    var dark: Bool
    var body: some View {
        ZStack {
            (dark ? LinearGradient(colors: [
                Color(.sRGB, red: 10.0/255, green: 12.0/255, blue: 18.0/255),
                Color(.sRGB, red: 4.0/255,  green: 5.0/255,  blue: 10.0/255),
            ], startPoint: .top, endPoint: .bottom)
              : LinearGradient(colors: [
                Color(.sRGB, red: 244.0/255, green: 247.0/255, blue: 251.0/255),
                Color(.sRGB, red: 230.0/255, green: 235.0/255, blue: 243.0/255),
            ], startPoint: .top, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.10) : Color.white.opacity(0.85))
                    .frame(height: 14)
                Capsule().fill(dark ? Color.white.opacity(0.55) : Color(.sRGB, white: 15.0/255, opacity: 0.55))
                    .frame(width: 36, height: 4)
                Capsule().fill((dark ? Color.white.opacity(0.55) : Color(.sRGB, white: 15.0/255, opacity: 0.55)).opacity(0.5))
                    .frame(width: 56, height: 4)
                Spacer(minLength: 0)
            }
            .padding(8)
        }
    }
}

private struct SurfaceSwatch: View {
    @Environment(\.tahoe) private var t
    var glass: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: [
                t.dark ? Color(.sRGB, red: 10.0/255, green: 12.0/255, blue: 18.0/255)
                       : Color(.sRGB, red: 238.0/255, green: 242.0/255, blue: 248.0/255),
                t.dark ? Color(.sRGB, red: 4.0/255, green: 5.0/255, blue: 10.0/255)
                       : Color(.sRGB, red: 221.0/255, green: 227.0/255, blue: 236.0/255),
            ], startPoint: .top, endPoint: .bottom)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(glass ? AnyShapeStyle(.regularMaterial)
                            : AnyShapeStyle(t.surfaceSolid))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(glass ? Color.white.opacity(0.4) : t.hairline, lineWidth: 0.5)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }
}

private struct WallSwatch: View {
    @Environment(\.tahoe) private var t
    var name: TahoeWallpaper

    var body: some View {
        // Quick inline gradient swatch based on the wallpaper kind (lightweight stand-in for TahoeWallpaperView).
        switch name {
        case .aurora:
            ZStack {
                LinearGradient(colors: [
                    t.dark ? Color(.sRGB, red: 6.0/255, green: 8.0/255, blue: 13.0/255)
                           : Color(.sRGB, red: 244.0/255, green: 247.0/255, blue: 251.0/255),
                    t.dark ? Color(.sRGB, red: 4.0/255, green: 3.0/255, blue: 10.0/255)
                           : Color(.sRGB, red: 238.0/255, green: 242.0/255, blue: 248.0/255),
                ], startPoint: .top, endPoint: .bottom)
                Ellipse().fill(OKLCH(l: 0.78, c: 0.16, h: 220).color.opacity(t.dark ? 0.45 : 0.55))
                    .frame(width: 60, height: 50).offset(x: -22, y: -14).blur(radius: 14)
                Ellipse().fill(OKLCH(l: 0.78, c: 0.16, h: 320).color.opacity(t.dark ? 0.35 : 0.45))
                    .frame(width: 50, height: 40).offset(x: 26, y: 16).blur(radius: 14)
            }
        case .graphite:
            LinearGradient(colors: [
                t.dark ? Color(.sRGB, white: 31.0/255) : Color.white,
                t.dark ? Color(.sRGB, white: 8.0/255)  : Color(.sRGB, white: 214.0/255),
            ], startPoint: .top, endPoint: .bottom)
        default:
            (t.dark ? Color.black : Color.white)
        }
    }
}

// MARK: - AccentPicker

private struct AccentPicker: View {
    @Environment(\.tahoe) private var t
    @Binding var value: TahoeAccent

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TahoeAccent.allCases) { a in
                let on = a == value
                Button { value = a } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(LinearGradient(colors: [a.glow.color, a.base.color, a.deep.color],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 32, height: 32)
                            .overlay {
                                Circle().stroke(on ? Color.white.opacity(0.001) : a.base.color(opacity: 0.5), lineWidth: 0.5)
                            }
                            .background {
                                if on {
                                    Circle()
                                        .stroke(t.dark ? Color.black : Color.white, lineWidth: 2)
                                        .padding(-2)
                                    Circle()
                                        .stroke(a.base.color, lineWidth: 2)
                                        .padding(-4)
                                }
                            }
                            .shadow(color: a.base.color(opacity: 0.5), radius: on ? 8 : 0, x: 0, y: 4)
                        Text(a.displayName)
                            .font(TahoeFont.body(11, weight: on ? .bold : .medium))
                            .foregroundStyle(on ? t.fg : t.fg3)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Providers (PR #31 chunk 2)

/// Settings → Providers → OpenCode row.
///
/// Collapsed UX: one toggle, one button.
///   - Off (binary missing OR no API key) → "Activate" button. Clicking it
///     re-probes for the binary, then opens the OpenRouter API key sheet
///     so the user can paste a key. The toggle moves on once a key lands.
///   - On (binary present AND ≥1 provider configured) → toggle ON plus an
///     "Edit API key" button that re-opens the same sheet. Flipping the
///     toggle off removes every configured provider via
///     OpencodeAuthFile.removeProvider — equivalent to a global sign-out.
///
/// Power-user affordances (sign in with browser / diagnostic / OAuth
/// providers) are reachable via OpencodeAPIKeySheet's provider picker
/// or via the upstream `opencode` CLI. They no longer need top-level
/// chrome in Settings.
private struct OpencodeProviderRow: View {
    @Environment(\.tahoe) private var t
    @State private var authStatus: [String: String]? = nil
    @State private var hasBinary: Bool = false
    @State private var apiKeySheet: Bool = false
    @State private var activating: Bool = false

    private var isOn: Bool {
        hasBinary && !(authStatus?.isEmpty ?? true)
    }

    /// One-line status. Keeps the row compact: signed-in surfaces the
    /// provider name, off-state explains what Activate does.
    private var detailLine: String {
        if isOn {
            let provider = authStatus?.keys.sorted().first ?? "provider"
            return "Signed in via \(displayName(for: provider)). Click Edit API key to swap."
        }
        if !hasBinary {
            return "OpenCode CLI not detected. Click Activate to detect it (install via opencode.ai if missing) and paste an OpenRouter key."
        }
        return "Paste an OpenRouter (or other) API key to enable OpenCode-backed sessions."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TahoeProviderGlyph(provider: .opencode, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenCode")
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text(detailLine)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailingControl
        }
        .task { await refreshState() }
        .sheet(isPresented: $apiKeySheet) {
            OpencodeAPIKeySheet {
                Task { await refreshState() }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isOn {
            VStack(alignment: .trailing, spacing: 8) {
                TahoeToggleView(on: Binding(
                    get: { true },
                    set: { newValue in
                        if !newValue { Task { await signOutAll() } }
                    }
                ))
                Button("Edit API key") { apiKeySheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            Button(activating ? "Activating…" : "Activate") {
                Task { await activate() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(activating)
        }
    }

    // MARK: - Actions

    /// Activate path: ensure the binary is detected, then surface the API
    /// key sheet. Binary missing isn't a hard stop — the sheet still lets
    /// the user paste a key, and OpencodeProcessManager.ensureRunning()
    /// re-probes on the first session spawn.
    private func activate() async {
        activating = true
        await OpencodeProcessManager.shared.reprobe()
        await refreshState()
        activating = false
        apiKeySheet = true
    }

    /// Toggle-off → remove every configured provider so the row collapses
    /// back to the Activate state. Auth file is the source of truth; the
    /// in-memory authStatus is refreshed afterwards.
    private func signOutAll() async {
        let providers = await OpencodeAuthFile.shared.providerIds()
        for id in providers {
            try? await OpencodeAuthFile.shared.removeProvider(providerId: id)
        }
        await OpencodeProcessManager.shared.reprobe()
        await refreshState()
    }

    private func refreshState() async {
        hasBinary = OpencodeProcessManager.shared.binaryPath != nil
        await OpencodeProcessManager.shared.refreshAuthStatus()
        authStatus = OpencodeProcessManager.shared.authStatus
        hasBinary = OpencodeProcessManager.shared.binaryPath != nil
    }

    /// Map opencode's internal provider id to the OpencodeAPIKeySheet
    /// display label so the status string reads "OpenRouter" not
    /// "openrouter".
    private func displayName(for providerId: String) -> String {
        OpencodeAPIKeySheet.Provider(rawValue: providerId)?.displayName
            ?? providerId
    }
}

// MARK: - Codex SDK row

/// Same row shape as OpencodeProviderRow / ClaudeCLIProviderRow: glyph +
/// title + one-line status + trailing TahoeToggleView. Replaces the old
/// standalone "Codex SDK" SettingsCard that had a duplicate header,
/// `@openai/codex-sdk` paragraph, Status grid, install path, and Wipe /
/// Open install folder buttons — none of which a customer can act on.
///
/// Toggle ON calls `CodexSDKManager.shared.enableSDKMode()` which lazily
/// provisions the sidecar (~25 MB npm install on first run). Toggle OFF
/// calls `disableSDKMode()` which keeps the install on disk so re-enable
/// is instant. `lastProvisioningError` is read on appear to surface a
/// stale failure from a previous launch.
private struct CodexSDKProviderRow: View {
    @Environment(\.tahoe) private var t
    @AppStorage("clawdmeter.codex.sdkMode") private var sdkModeEnabled: Bool = false
    @State private var isProvisioning: Bool = false
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                TahoeProviderGlyph(provider: .codex, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex SDK")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(statusLine)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                TahoeToggleView(on: Binding(
                    get: { sdkModeEnabled },
                    set: { handleToggle($0) }
                ))
                .opacity(isProvisioning ? 0.4 : 1)
                .allowsHitTesting(!isProvisioning)
            }
            if isProvisioning { progressChip }
            if let lastError, !lastError.isEmpty { errorChip(lastError) }
        }
        .onAppear { refreshErrorIfIdle() }
    }

    private var statusLine: String {
        if isProvisioning { return "Setting up…" }
        return sdkModeEnabled
            ? "Live events on. Token usage streams in real time."
            : "Off. Token usage updates a couple of seconds behind the CLI."
    }

    private var progressChip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Setting up (first run installs ~25 MB)…")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
        }
    }

    private func errorChip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(TahoeFont.body(12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func handleToggle(_ newValue: Bool) {
        if newValue {
            isProvisioning = true
            lastError = nil
            Task { @MainActor in
                let result = await CodexSDKManager.shared.enableSDKMode()
                isProvisioning = false
                switch result {
                case .success:
                    sdkModeEnabled = true
                case .failure(let err):
                    sdkModeEnabled = false
                    lastError = err.errorDescription ?? "Couldn't turn on live events."
                }
            }
        } else {
            CodexSDKManager.shared.disableSDKMode()
            sdkModeEnabled = false
            lastError = nil
        }
    }

    private func refreshErrorIfIdle() {
        guard !isProvisioning else { return }
        lastError = CodexSDKManager.shared.lastProvisioningError
    }
}

// MARK: - Antigravity SDK row

/// Same row shape as the other provider rows. Replaces the old
/// standalone "Antigravity SDK" SettingsCard that had duplicate header,
/// "What changes when SDK mode is on" bullet list, "What stays the same"
/// bullet list, and a StatusPill showing the literal UserDefaults
/// backing key — none of which a customer can act on.
private struct AntigravitySDKProviderRow: View {
    @Environment(\.tahoe) private var t
    @AppStorage("clawdmeter.antigravity.sdkMode") private var sdkModeEnabled: Bool = false
    @State private var isProvisioning: Bool = false
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                TahoeProviderGlyph(provider: .gemini, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Antigravity SDK")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(statusLine)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                TahoeToggleView(on: Binding(
                    get: { sdkModeEnabled },
                    set: { newValue in Task { await applyToggle(newValue) } }
                ))
                .opacity(isProvisioning ? 0.4 : 1)
                .allowsHitTesting(!isProvisioning)
            }
            if isProvisioning { progressChip }
            if let lastError, !lastError.isEmpty { errorChip(lastError) }
        }
        .onAppear { refreshErrorIfIdle() }
    }

    private var statusLine: String {
        if isProvisioning { return "Setting up…" }
        return sdkModeEnabled
            ? "Live events on. Token usage streams in real time."
            : "Off. Plan view reads the cached brain instead."
    }

    private var progressChip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Setting up (first run takes about 15 seconds)…")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
        }
    }

    private func errorChip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(TahoeFont.body(12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyToggle(_ newValue: Bool) async {
        guard !isProvisioning else { return }
        if newValue {
            isProvisioning = true
            defer { isProvisioning = false }
            let result = await AntigravitySidecarManager.shared.enableSDKMode()
            switch result {
            case .success:
                lastError = nil
            case .failure(let err):
                lastError = err.errorDescription ?? "Couldn't turn on live events."
            }
        } else {
            AntigravitySidecarManager.shared.disableSDKMode()
            lastError = nil
        }
        refreshErrorIfIdle()
    }

    private func refreshErrorIfIdle() {
        guard !isProvisioning else { return }
        lastError = AntigravitySidecarManager.shared.lastProvisioningError
    }
}

// MARK: - Cursor SDK provider row

private struct CursorSDKProviderRow: View {
    @Environment(\.tahoe) private var t
    @State private var state: CursorModelProbeState?
    @State private var hasKeychainToken: Bool = false
    @State private var isRefreshing: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TahoeProviderGlyph(provider: .cursor, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Cursor SDK")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    statePill
                }
                Text(detailLine)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if let binaryPath = state?.binaryPath {
                    Text("Binary: \(binaryPath)")
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            actionButton
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var statePill: some View {
        let (label, color): (String, Color) = {
            if isRefreshing || state == nil { return ("Checking…", t.fg4) }
            guard let state else { return ("Checking…", t.fg4) }
            if state.binaryPath == nil { return ("Not installed", Color.orange) }
            if state.authenticated || hasKeychainToken { return ("Ready", Color.green) }
            return ("Sign-in pending", Color.yellow)
        }()
        Text(label)
            .font(TahoeFont.body(10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background { Capsule().fill(color.opacity(0.15)) }
            .overlay { Capsule().stroke(color.opacity(0.35), lineWidth: 0.5) }
    }

    private var detailLine: String {
        guard let state else { return "Probing cursor-agent auth and model access…" }
        if state.binaryPath == nil {
            return "Cursor Agent CLI not found. Install cursor-agent so Clawdmeter can start and resume Cursor-backed sessions."
        }
        if state.authenticated || hasKeychainToken {
            let count = max(0, state.models.count)
            return count > 1
                ? "Signed in via cursor-agent. \(count) account models are available in the picker."
                : "Signed in via cursor-agent. Model access will be discovered when Cursor reports account models."
        }
        return state.reason ?? "Run `cursor-agent login` to connect Cursor auth."
    }

    @ViewBuilder
    private var actionButton: some View {
        if isRefreshing {
            ProgressView().controlSize(.small)
        } else if state?.binaryPath == nil {
            Button {
                if let url = URL(string: "https://docs.cursor.com/en/cli") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Install docs")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
        } else if state?.authenticated == true || hasKeychainToken {
            Button {
                Task { await refresh(force: true) }
            } label: {
                Text("Refresh")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                openTerminalRunningCursorLogin()
            } label: {
                Text("Sign in")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
            .help("Open Terminal and run `cursor-agent login`.")
        }
    }

    private func refresh(force: Bool = false) async {
        isRefreshing = true
        if force {
            await CursorModelProbe.shared.invalidate()
        }
        let nextState = await CursorModelProbe.shared.currentState()
        let token = await Task.detached(priority: .utility) {
            CursorTokenProvider().hasToken
        }.value
        state = nextState
        hasKeychainToken = token
        isRefreshing = false
    }

    private func openTerminalRunningCursorLogin() {
        let command = state?.binaryPath ?? "cursor-agent"
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped) login"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        _ = appleScript?.executeAndReturnError(&error)
    }
}

// MARK: - Claude Code CLI provider row (v0.22.23)

/// Mirrors `OpencodeProviderRow`'s shape — install + auth status for the
/// Claude Code CLI. Uses the same real-home binary resolver as session
/// spawning and combines it with the Claude Code Keychain token. This keeps
/// Release builds from mislabeling ~/.local/bin/claude as missing just
/// because NSHomeDirectory() points at the app sandbox.
private struct ClaudeCLIProviderRow: View {
    @Environment(\.tahoe) private var t
    @State private var probe: ProbeState = .pending
    @State private var version: String?
    @State private var binaryPath: String?
    @State private var hasUsedClaude: Bool = false
    @State private var hasKeychainToken: Bool = false

    enum ProbeState: Equatable {
        case pending
        case notInstalled
        case authenticatedNoCLI
        case installedNeedsLogin
        case ready
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TahoeProviderGlyph(provider: .claude, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Claude Code")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    statePill
                }
                Text(detailLine)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if let binaryPath, probe == .ready || probe == .installedNeedsLogin {
                    Text("Binary: \(binaryPath)\(version.map { "  ·  \($0)" } ?? "")")
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg2)
                }
            }
            Spacer()
            actionButton
        }
        .task { await refreshProbe() }
    }

    @ViewBuilder
    private var statePill: some View {
        let (label, color): (String, Color) = {
            switch probe {
            case .pending:           return ("Checking…", t.fg4)
            case .notInstalled:      return ("Not installed", Color.orange)
            case .authenticatedNoCLI: return ("Auth found", Color.yellow)
            case .installedNeedsLogin: return ("Sign-in pending", Color.yellow)
            case .ready:             return ("Ready", Color.green)
            }
        }()
        Text(label)
            .font(TahoeFont.body(10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background { Capsule().fill(color.opacity(0.15)) }
            .overlay { Capsule().stroke(color.opacity(0.35), lineWidth: 0.5) }
    }

    private var detailLine: String {
        switch probe {
        case .pending:
            return "Probing the `claude` binary, Claude Code Keychain token, and activity history…"
        case .notInstalled:
            return "Claude Code CLI is not installed. Use the button to open Terminal, install the CLI with npm or Homebrew, and run `claude /login`."
        case .authenticatedNoCLI:
            return "Claude Code auth is present, but the `claude` CLI binary is not on the standard paths. Use the button to install or expose the CLI and refresh auth."
        case .installedNeedsLogin:
            return "CLI installed, but no Claude Code keychain token was found. Run `claude /login` once to finish OAuth."
        case .ready:
            return hasKeychainToken
                ? "Installed and authenticated via Claude Code Keychain. Clawdmeter spawns sessions with the `claude` CLI."
                : "Installed with local Claude project activity. Clawdmeter can spawn sessions with the `claude` CLI."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch probe {
        case .pending:
            EmptyView()
        case .notInstalled, .authenticatedNoCLI:
            Button {
                openTerminalForClaudeAuth(installIfMissing: true)
                scheduleAuthReprobe()
            } label: {
                Text("Auth via CLI")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
            .help("Open Terminal to install Claude Code if needed, then run `claude /login`.")
        case .installedNeedsLogin:
            Button {
                openTerminalForClaudeAuth(installIfMissing: false)
                scheduleAuthReprobe()
            } label: {
                Text("Sign in")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
            .help("Open Terminal and run `claude /login` so the OAuth flow can complete.")
        case .ready:
            Button {
                let url = URL(fileURLWithPath: ClawdmeterRealHome.path())
                    .appendingPathComponent(".claude", isDirectory: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text("Open ~/.claude")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// Probe is cheap — single file existence + one `claude --version`
    /// invocation. Run off the main actor to avoid janking the
    /// Settings tab on first appear.
    private func refreshProbe() async {
        let detected = await Task.detached(priority: .userInitiated) {
            ClaudeCLIProbe.run()
        }.value
        self.binaryPath = detected.binaryPath
        self.version = detected.version
        self.hasUsedClaude = detected.hasActivity
        self.hasKeychainToken = detected.hasKeychainToken
        if detected.binaryPath == nil && detected.hasKeychainToken {
            self.probe = .authenticatedNoCLI
        } else if detected.binaryPath == nil {
            self.probe = .notInstalled
        } else if detected.hasKeychainToken || detected.hasActivity {
            self.probe = .ready
        } else {
            self.probe = .installedNeedsLogin
        }
    }

    private func scheduleAuthReprobe() {
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await refreshProbe()
        }
    }

    /// AppleScript a Terminal window that runs `claude` so the user
    /// can complete the OAuth handshake inline. No-op if the script
    /// fails (e.g. Terminal denied, sandbox restriction); the help
    /// tooltip on the button explains the manual path.
    private func openTerminalForClaudeAuth(installIfMissing: Bool) {
        let command = claudeAuthCommand(installIfMissing: installIfMissing)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        _ = appleScript?.executeAndReturnError(&error)
    }

    private func claudeAuthCommand(installIfMissing: Bool) -> String {
        if !installIfMissing, let binaryPath {
            return "\(shellQuoted(binaryPath)) /login"
        }
        let installSteps = """
        if command -v claude >/dev/null 2>&1; then
          claude /login
        elif command -v npm >/dev/null 2>&1; then
          npm i -g @anthropic-ai/claude-code && claude /login
        elif command -v brew >/dev/null 2>&1; then
          brew install anthropic/claude/claude && claude /login
        else
          echo "Install npm or Homebrew, then run: npm i -g @anthropic-ai/claude-code && claude /login"
        fi
        """
        return "/bin/zsh -lc \(shellQuoted(installSteps))"
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Static probe helper that walks the standard install locations,
/// runs `--version`, and counts `~/.claude/projects/` children. Kept
/// out of the View struct so it can be called off the main actor
/// without touching SwiftUI state. The "has activity" signal proxies
/// for sign-in status without needing Keychain access.
private enum ClaudeCLIProbe {
    struct Result {
        let binaryPath: String?
        let version: String?
        let hasActivity: Bool
        let hasKeychainToken: Bool
    }

    nonisolated static func run() -> Result {
        let path = locateBinary()
        let version: String? = path.flatMap { runVersion(binary: $0) }
        let activity = projectsDirHasEntries()
        let token = KeychainTokenProvider().hasToken
        return Result(binaryPath: path, version: version, hasActivity: activity, hasKeychainToken: token)
    }

    private nonisolated static func locateBinary() -> String? {
        ShellRunner.locateBinary("claude")
    }

    private nonisolated static func runVersion(binary: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let raw = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        } catch {
            return nil
        }
    }

    private nonisolated static func projectsDirHasEntries() -> Bool {
        let url = URL(fileURLWithPath: ClawdmeterRealHome.path())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return !kids.isEmpty
    }
}
