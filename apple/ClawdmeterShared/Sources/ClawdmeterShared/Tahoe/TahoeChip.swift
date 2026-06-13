#if canImport(SwiftUI)
import SwiftUI

/// Composer chip — icon + optional label + optional caret. 24px high, 6px
/// radius, `surface-2` fill, hairline border, `fg-2`. "Tinted" now means a
/// neutral selected state (`selection` fill + `fg`), never a terra-cotta tint.
public struct TahoeComposerChip: View {
    @Environment(\.theme) private var t
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
        let fill: Color = tinted ? t.selection : t.surface2
        let fg: Color = tinted ? t.fg : t.fg2
        Group {
            if let action {
                let chipName = label.map {
                    "composer_chip_" + $0.lowercased().replacingOccurrences(of: " ", with: "_")
                } ?? "composer_chip_\(icon)"
                Button(action: ContinuumAnalytics.wrapButton(chipName, action)) { content(fg) }.buttonStyle(.plain)
            } else {
                content(fg)
            }
        }
        .background(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.card, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.card, style: .continuous).strokeBorder(t.hairline, lineWidth: 0.5))
        .frame(height: 24)
    }

    @ViewBuilder
    private func content(_ fg: Color) -> some View {
        HStack(spacing: 5) {
            TahoeIcon(icon, size: 12)
            if let label {
                Text(label).font(ContinuumFont.body(11.5, weight: .medium))
            }
            if caret {
                TahoeIcon("chevD", size: 9).opacity(0.6)
            }
        }
        .foregroundStyle(fg)
        .padding(.horizontal, iconOnly ? 0 : 9)
        .frame(minWidth: iconOnly ? 24 : nil, alignment: .center)
        .frame(maxWidth: iconOnly ? 24 : .infinity, alignment: iconOnly ? .center : .leading)
        .fixedSize(horizontal: !iconOnly, vertical: true)
    }
}

/// Paired-device / live-status chip — neutral `surface-2` capsule + hairline +
/// a small `live` dot (1Hz heartbeat). No accent fill, no glow. Used in the
/// Sessions titlebar + Dashboard "Sync with iPhone".
public struct TahoeSyncChip: View {
    @Environment(\.theme) private var t
    public var icon: String?
    public var text: String

    public init(icon: String? = nil, text: String) {
        self.icon = icon
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let icon {
                TahoeIcon(icon, size: 10).foregroundStyle(t.fg2)
            } else {
                Circle().fill(t.live).frame(width: 6, height: 6)
            }
            Text(text)
                .font(ContinuumFont.body(11.5, weight: .semibold))
                .foregroundStyle(t.fg2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background { Capsule(style: .continuous).fill(t.surface2) }
        .overlay { Capsule(style: .continuous).strokeBorder(t.hairline, lineWidth: 0.5) }
    }
}

/// Top-row tab chip. Active = segment fill, 5px radius, weight 700;
/// inactive `fg-3`; hover a barely-there fill.
public struct TahoeDashTab: View {
    @Environment(\.theme) private var t
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
        Button(action: ContinuumAnalytics.wrapButton("dash_tab_\(label.lowercased())", action)) {
            Text(label)
                .font(ContinuumFont.body(12, weight: active ? .bold : .semibold))
                .foregroundStyle(active ? t.fg : t.fg3)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background {
                    if active || isHovered {
                        RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                            .fill(active ? t.segmentActiveFill : t.hover)
                    }
                }
        }
        .buttonStyle(.plain)
        // It's a clickable nav tab — show the link (pointing-hand) cursor
        // on hover so it reads as interactive, not as static label text.
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .help(tooltip)
        .accessibilityIdentifier("dash.tab.\(label.lowercased())")
        #if !os(watchOS)
        .onHover { isHovered = $0 }
        #endif
    }

    private var tooltip: String {
        let base = help ?? label
        if let shortcut { return "\(base) \(shortcut)" }
        return base
    }
}

/// Tiny icon button used inside titlebar trays, etc. Square, 5px radius; active
/// uses a neutral `selection` fill (not accent).
public struct TahoeIconBtn: View {
    @Environment(\.theme) private var t
    public var icon: String
    public var active: Bool
    public var action: () -> Void

    public init(_ icon: String, active: Bool = false, action: @escaping () -> Void = {}) {
        self.icon = icon
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: ContinuumAnalytics.wrapButton("icon_btn_\(icon)", action)) {
            TahoeIcon(icon, size: 14)
                .foregroundStyle(active ? t.fg : t.fg2)
                .frame(width: 26, height: 22)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                            .fill(t.selection)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// macOS "traffic lights" cluster — DESIGN.md hexes, 12px.
public struct TahoeTrafficLights: View {
    @Environment(\.theme) private var t
    public init() {}
    public var body: some View {
        HStack(spacing: 7) {
            light(color: t.error)
            light(color: t.warn)
            light(color: t.live)
        }
    }
    @ViewBuilder private func light(color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12)
    }
}
#endif
