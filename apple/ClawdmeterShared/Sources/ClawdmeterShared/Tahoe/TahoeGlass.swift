#if canImport(SwiftUI)
import SwiftUI

/// Glass surface "tone" — five surface elevations that the JSX `Glass`
/// component supports.
public enum TahoeGlassTone: String, Sendable, CaseIterable {
    case panel   // standard surface
    case chip    // higher tint for chips/pills
    case raised  // raised card
    case floor   // floor-level surface (same as panel for tint)
    case inset   // recessed (dark fill in dark mode, ~clear in light)
}

/// The workhorse Liquid Glass primitive. Ports `glass.jsx::Glass`.
///
/// Usage:
/// ```swift
/// TahoeGlass(radius: 18, tone: .panel) {
///     // content
/// }
/// .frame(width: 248)
/// ```
public struct TahoeGlass<Content: View>: View {
    @Environment(\.tahoe) private var t

    public var radius: CGFloat
    public var tone: TahoeGlassTone
    public var solidOverride: Bool?
    public var ring: Bool
    public var shadow: Bool
    public var content: Content

    public init(
        radius: CGFloat = 18,
        tone: TahoeGlassTone = .panel,
        solid: Bool? = nil,
        ring: Bool = true,
        shadow: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.radius = radius
        self.tone = tone
        self.solidOverride = solid
        self.ring = ring
        self.shadow = shadow
        self.content = content()
    }

    private var isSolid: Bool { solidOverride ?? !t.translucent }

    private var solidFill: Color {
        switch tone {
        case .panel, .raised, .floor: return t.surfaceSolid
        case .chip:                   return t.surfaceSolid2
        case .inset:                  return t.dark ? Color(.sRGB, red: 6.0/255, green: 7.0/255, blue: 10.0/255)
                                                    : Color(.sRGB, red: 238.0/255, green: 240.0/255, blue: 244.0/255)
        }
    }

    private var glassTint: Color {
        switch tone {
        case .panel, .floor:           return t.glassTint
        case .chip, .raised:           return t.glassTintHi
        case .inset:                   return t.dark ? Color(.sRGB, white: 0, opacity: 0.32)
                                                     : Color(.sRGB, white: 0, opacity: 0.04)
        }
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    if isSolid {
                        shape.fill(solidFill)
                    } else {
                        // Tahoe 26 / iOS 26: native Liquid Glass.
                        // `.glassEffect(_:in:isEnabled:)` ships in the macOS 26 / iOS 26
                        // SDK and gives us the real refraction + specular pass that the
                        // JSX `backdrop-filter: blur(...) saturate(...)` simulates.
                        // Older OSes fall back to `.regularMaterial`, which renders the
                        // closest in-tree approximation.
                        if #available(macOS 26.0, iOS 26.0, watchOS 26.0, *) {
                            shape.fill(.clear)
                                .glassEffect(.regular, in: shape)
                        } else {
                            shape.fill(.regularMaterial)
                        }
                        shape.fill(glassTint)
                    }
                    if ring {
                        shape.stroke(t.glassRing, lineWidth: 0.5)
                    }
                    if !isSolid {
                        // Inner highlight (JSX `glassInner` + bottom shadow)
                        shape.strokeBorder(
                            LinearGradient(colors: [
                                t.glassInner,
                                Color.clear,
                                t.dark ? Color(.sRGB, white: 0, opacity: 0.4) : Color(.sRGB, white: 1, opacity: 0.3)
                            ], startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75
                        )
                    }
                }
            }
            .clipShape(shape)
            .modifier(TahoeShadow(isSolid: isSolid, shadow: shadow))
    }
}

private struct TahoeShadow: ViewModifier {
    @Environment(\.tahoe) private var t
    let isSolid: Bool
    let shadow: Bool

    func body(content: Content) -> some View {
        if !shadow { return AnyView(content) }
        return AnyView(
            content
                .shadow(
                    color: t.dark ? Color.black.opacity(isSolid ? 0.40 : 0.45)
                                  : Color(.sRGB, red: 15.0/255, green: 17.0/255, blue: 22.0/255, opacity: isSolid ? 0.08 : 0.10),
                    radius: 20, x: 0, y: 10
                )
        )
    }
}

// MARK: - Pill

/// Glass capsule — radius 999 wrapper around `TahoeGlass`. Matches JSX `Pill`.
public struct TahoePill<Content: View>: View {
    @Environment(\.tahoe) private var t
    public var tone: TahoeGlassTone
    public var accent: Bool
    public var solid: Bool?
    public var content: Content

    public init(
        tone: TahoeGlassTone = .chip,
        accent: Bool = false,
        solid: Bool? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.tone = tone
        self.accent = accent
        self.solid = solid
        self.content = content()
    }

    public var body: some View {
        if accent {
            content
                .background {
                    Capsule(style: .continuous).fill(t.accent)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(t.accentDeepC, lineWidth: 0.5)
                }
                .foregroundStyle(.white)
                .shadow(color: t.accentAlpha(0.35), radius: 9, x: 0, y: 6)
        } else {
            TahoeGlass(radius: 999, tone: tone, solid: solid) { content }
        }
    }
}

// MARK: - Buttons

/// Quieter primary capsule (gradient accent → accentDeep). JSX `AccentButton`.
public struct TahoeAccentButton<Label: View>: View {
    @Environment(\.tahoe) private var t
    public enum Size { case s, m, l }
    public var size: Size
    public var disabled: Bool
    public var action: () -> Void
    public var label: Label

    public init(size: Size = .m, disabled: Bool = false, action: @escaping () -> Void = {}, @ViewBuilder label: () -> Label) {
        self.size = size; self.disabled = disabled; self.action = action; self.label = label()
    }

    private var height: CGFloat {
        switch size { case .s: return 28; case .m: return 32; case .l: return 38 }
    }
    private var fontSize: CGFloat {
        switch size { case .s: return 12; case .m: return 13; case .l: return 14 }
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label
            }
            .font(TahoeFont.body(fontSize, weight: .semibold))
            .padding(.horizontal, height * 0.5)
            .frame(height: height)
            .foregroundStyle(.white)
            .background {
                Capsule(style: .continuous)
                    .fill(LinearGradient(
                        colors: [t.accent, t.accentDeepC],
                        startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(t.accentDeepC, lineWidth: 0.5)
            }
            .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
    }
}

/// Ghost button — glass capsule, no fill. Active state uses accent tint.
public struct TahoeGhostButton<Label: View>: View {
    @Environment(\.tahoe) private var t
    public enum Size { case s, m, l }
    public var size: Size
    public var active: Bool
    public var action: () -> Void
    public var label: Label

    public init(size: Size = .m, active: Bool = false, action: @escaping () -> Void = {}, @ViewBuilder label: () -> Label) {
        self.size = size; self.active = active; self.action = action; self.label = label()
    }

    private var height: CGFloat {
        switch size { case .s: return 26; case .m: return 30; case .l: return 36 }
    }
    private var fontSize: CGFloat {
        switch size { case .s: return 12; case .m: return 12.5; case .l: return 13 }
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                label
            }
            .font(TahoeFont.body(fontSize, weight: .medium))
            .padding(.horizontal, height * 0.5)
            .frame(height: height)
            .foregroundStyle(active ? t.accent : t.fg)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? t.accentAlpha(t.dark ? 0.15 : 0.10) : Color.clear)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(active ? t.accent : t.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hair (separator)

public struct TahoeHair: View {
    @Environment(\.tahoe) private var t
    public var vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        if vertical {
            Rectangle().fill(t.hairline).frame(width: 0.5)
        } else {
            Rectangle().fill(t.hairline).frame(height: 0.5)
        }
    }
}
#endif
