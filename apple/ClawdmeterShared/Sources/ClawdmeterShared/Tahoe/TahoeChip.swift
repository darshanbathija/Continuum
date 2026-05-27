#if canImport(SwiftUI)
import SwiftUI

/// Generic composer chip — icon + optional label + optional caret. Used in
/// composer chip rows (Mac IDE, iOS Chat). Mirrors JSX `ComposerChip`.
public struct TahoeComposerChip: View {
    @Environment(\.tahoe) private var t
    public var icon: String
    public var label: String?
    public var caret: Bool
    public var tinted: Bool
    public var iconOnly: Bool { label == nil }
    public var action: (() -> Void)?

    public init(icon: String, label: String? = nil, caret: Bool = false, tinted: Bool = false, action: (() -> Void)? = nil) {
        self.icon = icon
        self.label = label
        self.caret = caret
        self.tinted = tinted
        self.action = action
    }

    public var body: some View {
        let fill: Color = tinted
            ? t.accentAlpha(t.dark ? 0.18 : 0.10)
            : (t.dark ? Color(.sRGB, white: 1, opacity: 0.05) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
        let fg: Color = tinted ? t.accent : t.fg2
        Group {
            if let action {
                Button(action: action) { content(fg) }.buttonStyle(.plain)
            } else {
                content(fg)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.hairline, lineWidth: 0.5))
        .frame(height: 26)
    }

    @ViewBuilder
    private func content(_ fg: Color) -> some View {
        HStack(spacing: 5) {
            TahoeIcon(icon, size: 12)
            if let label {
                Text(label)
                    .font(TahoeFont.body(11.5, weight: .medium))
            }
            if caret {
                TahoeIcon("chevD", size: 9).opacity(0.6)
            }
        }
        .foregroundStyle(fg)
        .padding(.horizontal, iconOnly ? 0 : 9)
        .frame(minWidth: iconOnly ? 26 : nil, alignment: .center)
        .frame(maxWidth: iconOnly ? 26 : .infinity, alignment: iconOnly ? .center : .leading)
        .fixedSize(horizontal: !iconOnly, vertical: true)
    }
}

/// Live-status / paired-device chip — accent-tinted capsule with a glowing
/// dot. Used in Sessions titlebar, Dashboard "Sync with iPhone".
public struct TahoeSyncChip: View {
    @Environment(\.tahoe) private var t
    public var icon: String?
    public var text: String

    public init(icon: String? = nil, text: String) {
        self.icon = icon
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let icon {
                TahoeIcon(icon, size: 10)
            } else {
                Circle()
                    .fill(t.accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: t.accent, radius: 4, x: 0, y: 0)
            }
            Text(text)
                .font(TahoeFont.body(11.5, weight: .semibold))
        }
        .foregroundStyle(t.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(t.accentAlpha(0.14))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(t.accentAlpha(0.35), lineWidth: 0.5)
        }
    }
}

/// Top-row tab chip (DashTab in JSX) — active state uses solid white in light,
/// translucent white in dark; inactive is transparent.
public struct TahoeDashTab: View {
    @Environment(\.tahoe) private var t
    public var label: String
    public var active: Bool
    public var help: String?
    public var shortcut: String?
    public var action: () -> Void
    @State private var isHovered = false

    public init(_ label: String, active: Bool, help: String? = nil, shortcut: String? = nil, action: @escaping () -> Void = {}) {
        self.label = label
        self.active = active
        self.help = help
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(TahoeFont.body(12, weight: active ? .bold : .semibold))
                .foregroundStyle(active ? t.fg : t.fg3)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background {
                    if active || isHovered {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active
                                  ? (t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : Color.white)
                                  : t.hair2.opacity(t.dark ? 0.9 : 1.15))
                            .shadow(color: active ? Color.black.opacity(0.10) : .clear, radius: 1, x: 0, y: 1)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(active ? Color.black.opacity(0.08) : (isHovered ? t.hairline : .clear), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityIdentifier("dash.tab.\(label.lowercased())")
        .onHover { isHovered = $0 }
    }

    private var tooltip: String {
        if let shortcut, let help {
            return "\(help) \(shortcut)"
        }
        return help ?? shortcut ?? label
    }
}

/// Tiny round icon button used inside titlebar trays, etc.
public struct TahoeIconBtn: View {
    @Environment(\.tahoe) private var t
    public var icon: String
    public var active: Bool
    public var action: () -> Void

    public init(_ icon: String, active: Bool = false, action: @escaping () -> Void = {}) {
        self.icon = icon
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            TahoeIcon(icon, size: 14)
                .foregroundStyle(active ? t.accent : t.fg2)
                .frame(width: 26, height: 22)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(t.accentAlpha(0.18))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// macOS-style "traffic lights" cluster.
public struct TahoeTrafficLights: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 7) {
            light(color: Color(.sRGB, red: 1, green: 0x5F/255.0, blue: 0x57/255.0))
            light(color: Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0))
            light(color: Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
        }
    }
    @ViewBuilder private func light(color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12)
    }
}
#endif
