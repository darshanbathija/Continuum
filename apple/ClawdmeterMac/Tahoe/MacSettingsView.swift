import SwiftUI
import ClawdmeterShared

/// Mac Settings — drives the global TahoeThemeStore so flipping a switch
/// here repaints every other surface. Ports `mac-settings.jsx`.
public struct MacSettingsView: View {
    @Environment(\.tahoe) private var t
    @Bindable public var theme: TahoeThemeStore

    @State private var autoRevive: Bool = true
    @State private var mirrorToiPhone: Bool = true
    @State private var notifyAt90: Bool = true

    public init(theme: TahoeThemeStore) { self.theme = theme }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsHeader()

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

                SettingsCard(title: "Quota & sync",
                             sub: "Behavior that affects the menu-bar agent and the paired iPhone.") {
                    SettingsRow(label: "Auto-revive 5h timer",
                                hint: "Sends a no-op every ~4 hours so you don't lose your rolling session window. Skip if you'd rather see a true reading.") {
                        TahoeToggleView(on: $autoRevive)
                    }
                    TahoeHair().padding(.vertical, 14)
                    SettingsRow(label: "Mirror to iPhone",
                                hint: "Push live gauges to a paired iPhone so you can glance at quota from the Lock Screen.") {
                        TahoeToggleView(on: $mirrorToiPhone)
                    }
                    TahoeHair().padding(.vertical, 14)
                    SettingsRow(label: "Notify at 90%",
                                hint: "Send a system notification when any session passes 90% of its rolling window.") {
                        TahoeToggleView(on: $notifyAt90)
                    }
                }
            }
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6).padding(.bottom, 20).padding(.top, 20)
        }
    }
}

// MARK: - Header

private struct SettingsHeader: View {
    @Environment(\.tahoe) private var t
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
            TahoeGhostButton(size: .s) {
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
