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
        // PR #31 chunk 2: Providers card surfaces install + auth state for adapters that run external CLIs.
        SettingsCard(title: "Providers",
                     sub: "External agent runtimes Clawdmeter can drive. Listed providers must be installed and signed in to spawn sessions.") {
            VStack(alignment: .leading, spacing: 14) {
                // v0.22.23: explicit Claude Code CLI row at the top
                // since Claude is the headline provider. Shows
                // install status + a "Has been used" proxy for the
                // sign-in state (the real OAuth token lives in
                // macOS Keychain and isn't readable without entitlement,
                // so we infer auth from `~/.claude/projects/` having
                // any entries).
                ClaudeCLIProviderRow()
                TahoeHair()
                OpencodeProviderRow()
            }
        }

        SettingsCard(title: "Codex SDK",
                     sub: "Observation mode toggle + diagnostics for the Codex provider.") {
            CodexSDKSettingsView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        SettingsCard(title: "Antigravity SDK",
                     sub: "Antigravity 2 native runtime — bundled IPC bridge + plan-mode hand-off.") {
            AntigravitySDKSettingsView()
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// OpenCode provider row — install + auth status surfaced from
/// OpencodeProcessManager.shared. Re-runs `opencode auth list` on
/// appear so signed-in providers reflect within ~50ms of the user
/// switching to the Settings tab. The "Open docs" affordance points
/// at opencode.ai/docs/auth which covers both first-time install and
/// the per-provider `opencode auth login` flow.
/// Settings → Providers → OpenCode row. v0.23.0 rewrite — adds the
/// embedded-terminal setup sheet so users can install / sign in / sign
/// out / run diagnostics without ever dropping to a Terminal.
///
/// State machine (CQ3):
///
///   ┌─[bundle-missing]──────────┐  fallback only — DMG tampered
///   │ orange "Reinstall app"    │
///   └───────────────────────────┘
///                │
///                ▼
///   ┌─[activated, no auth]──────┐  binary discovered, no providers
///   │ yellow "Sign in required" │
///   │ button: Sign in           │── launches OpencodeSetupSheet
///   └───────────────────────────┘    in `.signIn` mode
///                │
///                │ sheet exits with code 0 → reprobe (O5)
///                ▼
///   ┌─[activated + signed in]───┐
///   │ green "Signed in"         │
///   │ per-provider info rows    │
///   │ button: Add provider      │── launches sheet `.addProvider`
///   │ button: Sign out          │── launches sheet `.signOut` (O6 global)
///   │ button: Diagnostic        │── launches sheet `.diagnostic`
///   └───────────────────────────┘
private struct OpencodeProviderRow: View {
    @Environment(\.tahoe) private var t
    @State private var managerState: OpencodeProcessManager.State = .stopped
    @State private var authStatus: [String: String]? = nil
    @State private var setupCommand: OpencodeSetupSheet.Command?
    @State private var activating: Bool = false

    private var hasBinary: Bool {
        OpencodeProcessManager.shared.binaryPath != nil
    }

    private var isAuthed: Bool {
        guard let s = authStatus else { return false }
        return !s.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TahoeProviderGlyph(provider: .opencode, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("OpenCode")
                            .font(TahoeFont.body(14, weight: .semibold))
                            .foregroundStyle(t.fg)
                        statePill
                    }
                    Text(detailLine)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let authStatus, !authStatus.isEmpty {
                        Text(authLine(authStatus))
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(t.fg2)
                    }
                }
                Spacer(minLength: 12)
                actionButtons
            }
            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "https://opencode.ai/docs/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Open docs")
                        .font(TahoeFont.body(11, weight: .semibold))
                        .foregroundStyle(t.fg4)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .task {
            await refreshState()
        }
        .sheet(item: $setupCommand) { command in
            if let tmux = AppDelegate.runtime?.tmuxClient {
                OpencodeSetupSheet(tmuxClient: tmux, command: command) {
                    // onCompletion: triggered when child exits 0.
                    Task { await refreshState() }
                }
            } else {
                Text("tmux not available — relaunch Clawdmeter.")
                    .padding()
            }
        }
    }

    /// Primary action area on the right side of the row. Renders
    /// different buttons depending on the state machine in the
    /// header comment.
    @ViewBuilder
    private var actionButtons: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !hasBinary {
                Button("Activate") {
                    activating = true
                    Task {
                        await OpencodeProcessManager.shared.reprobe()
                        await refreshState()
                        activating = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(activating)
            } else if !isAuthed {
                Button("Sign in") { setupCommand = .signIn }
                    .buttonStyle(.borderedProminent)
            } else {
                Menu {
                    Button("Add another provider") { setupCommand = .addProvider }
                    Button("Diagnostic") { setupCommand = .diagnostic }
                    Divider()
                    Button("Sign out of OpenCode", role: .destructive) {
                        setupCommand = .signOut
                    }
                } label: {
                    Text("Manage")
                        .font(TahoeFont.body(12, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
            }
        }
    }

    private func refreshState() async {
        managerState = OpencodeProcessManager.shared.state
        authStatus = OpencodeProcessManager.shared.authStatus
        await OpencodeProcessManager.shared.refreshAuthStatus()
        authStatus = OpencodeProcessManager.shared.authStatus
        managerState = OpencodeProcessManager.shared.state
    }

    /// Compact pill rendering whichever state the manager is in.
    @ViewBuilder
    private var statePill: some View {
        let (label, color): (String, Color) = {
            switch managerState {
            case .notInstalled:
                return ("Not installed", Color.orange)
            case .stopped:
                return ("Idle", t.fg4)
            case .starting:
                return ("Starting…", Color.blue)
            case .running:
                return ("Running", Color.green)
            case .failed:
                return ("Failed", Color.red)
            }
        }()
        Text(label)
            .font(TahoeFont.body(10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background {
                Capsule().fill(color.opacity(0.15))
            }
            .overlay {
                Capsule().stroke(color.opacity(0.35), lineWidth: 0.5)
            }
    }

    /// Human-readable status detail. Uses the manager's binaryPath +
    /// lastError when available so the user sees exactly what
    /// happened.
    private var detailLine: String {
        switch managerState {
        case .notInstalled:
            return "Not installed. Run `brew install opencode` (or download from opencode.ai) to enable OpenCode-backed sessions."
        case .stopped:
            if let path = OpencodeProcessManager.shared.binaryPath {
                return "Installed at \(path). Starts on demand when you spawn an OpenCode session."
            }
            return "Starts on demand when you spawn an OpenCode session."
        case .starting:
            return "Spinning up the shared `opencode serve` process…"
        case .running(let port):
            let path = OpencodeProcessManager.shared.binaryPath ?? "<discovered>"
            return "Running on 127.0.0.1:\(port) — shared process for every OpenCode session.  Binary: \(path)"
        case .failed(let detail):
            return "Failed: \(detail)"
        }
    }

    /// Joined "provider: model" lines from `opencode auth list`. Empty
    /// dict surfaces as "No providers signed in" so the user knows
    /// what's missing.
    private func authLine(_ status: [String: String]) -> String {
        let pairs = status
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: " · ")
        return "Signed in: \(pairs)"
    }
}

// MARK: - Claude Code CLI provider row (v0.22.23)

/// Mirrors `OpencodeProviderRow`'s shape — install + auth status for the
/// Claude Code CLI. Authentication isn't directly observable (Claude
/// stores OAuth tokens in macOS Keychain, which requires user-prompted
/// entitlement to read), so we use `~/.claude/projects/` having any
/// entries as a proxy for "Claude has been signed in + used at least
/// once on this machine". A user who just installed but hasn't run
/// `claude` yet sees a "Signed in?" pending state with a "Sign in"
/// button that launches Terminal to run `claude` (which kicks off
/// the OAuth flow).
private struct ClaudeCLIProviderRow: View {
    @Environment(\.tahoe) private var t
    @State private var probe: ProbeState = .pending
    @State private var version: String?
    @State private var binaryPath: String?
    @State private var hasUsedClaude: Bool = false

    enum ProbeState: Equatable {
        case pending
        case notInstalled
        case installedNoActivity   // binary present but ~/.claude/projects/ empty
        case installedActive       // binary present + has activity (probably signed in)
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
                if let binaryPath, probe == .installedActive || probe == .installedNoActivity {
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
            case .installedNoActivity: return ("Sign-in pending", Color.yellow)
            case .installedActive:   return ("Ready", Color.green)
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
            return "Probing the `claude` binary + activity history…"
        case .notInstalled:
            return "Not installed. `npm i -g @anthropic-ai/claude-code` or `brew install anthropic/claude/claude` to enable Claude-backed sessions."
        case .installedNoActivity:
            return "Installed, but no project activity in ~/.claude/projects/ yet — run `claude` once in a terminal to sign in via OAuth."
        case .installedActive:
            return "Installed and signed in. Clawdmeter spawns Claude sessions via the `claude` CLI."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch probe {
        case .pending:
            EmptyView()
        case .notInstalled:
            Button {
                if let url = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Install docs")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
        case .installedNoActivity:
            Button {
                openTerminalRunningClaude()
            } label: {
                Text("Sign in")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
            .help("Open Terminal and run `claude` so the OAuth flow can complete.")
        case .installedActive:
            Button {
                let url = URL(fileURLWithPath: NSHomeDirectory())
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
        if detected.binaryPath == nil {
            self.probe = .notInstalled
        } else if detected.hasActivity {
            self.probe = .installedActive
        } else {
            self.probe = .installedNoActivity
        }
    }

    /// AppleScript a Terminal window that runs `claude` so the user
    /// can complete the OAuth handshake inline. No-op if the script
    /// fails (e.g. Terminal denied, sandbox restriction); the help
    /// tooltip on the button explains the manual path.
    private func openTerminalRunningClaude() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        _ = appleScript?.executeAndReturnError(&error)
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
    }

    nonisolated static func run() -> Result {
        let path = locateBinary()
        let version: String? = path.flatMap { runVersion(binary: $0) }
        let activity = projectsDirHasEntries()
        return Result(binaryPath: path, version: version, hasActivity: activity)
    }

    private nonisolated static func locateBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.npm-global/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude",
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
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
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return !kids.isEmpty
    }
}
