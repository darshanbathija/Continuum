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

/// Shadow weight on a `TahoeGlass` surface. A3 split the historical
/// single boolean into three explicit levels:
///   - `.none`     — no shadow (e.g. `inset` surfaces, status pills inline
///                   with surrounding chrome)
///   - `.subtle`   — radius 10, default for all glass surfaces. Reads as
///                   "soft elevation" without the offscreen-blur cost of
///                   the historical radius-20 shadow.
///   - `.prominent` — radius 20, opt-in for surfaces that genuinely need
///                    a heavier lift (modal cards, important CTAs).
///
/// Why the change: pre-A3, every `TahoeGlass(shadow: true)` rendered a
/// `shadow(radius: 20)` — 78 sites stacked across the Mac UI. Each shadow
/// is an offscreen blur pass in Core Animation; the cost compounds when
/// the user resizes the window or scrolls between tabs. Trimming the
/// default to radius 10 + reserving 20 for opt-in cuts per-frame work
/// without losing visual hierarchy where it actually matters.
public enum TahoeGlassShadow: Sendable, Equatable {
    case none
    case subtle
    case prominent
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
    public var shadowStyle: TahoeGlassShadow
    public var content: Content

    /// Designated init — accepts a `TahoeGlassShadow` enum.
    ///
    /// Default `.subtle` (radius 10) replaces the historical `radius: 20`
    /// per A3: 78 call sites stacked the old radius and offscreen-rendered
    /// 78 expensive blurs per frame. The trimmed default reads "soft
    /// elevation"; pass `.prominent` for surfaces that actually need the
    /// heavier lift (heavy modal CTAs, popovers).
    public init(
        radius: CGFloat = 18,
        tone: TahoeGlassTone = .panel,
        solid: Bool? = nil,
        ring: Bool = true,
        shadow: TahoeGlassShadow = .subtle,
        @ViewBuilder content: () -> Content
    ) {
        self.radius = radius
        self.tone = tone
        self.solidOverride = solid
        self.ring = ring
        self.shadowStyle = shadow
        self.content = content()
    }

    /// Back-compat init taking `shadow: Bool` as the original boolean.
    /// Maps `true` → `.subtle` (trimmed radius) and `false` → `.none`.
    /// Lets the 78 call sites that pass `shadow: true` upgrade to the
    /// new trimmed default without API churn. Sites that want the old
    /// heavy shadow opt in to `.prominent` via the designated init.
    public init(
        radius: CGFloat = 18,
        tone: TahoeGlassTone = .panel,
        solid: Bool? = nil,
        ring: Bool = true,
        shadow: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            radius: radius,
            tone: tone,
            solid: solid,
            ring: ring,
            shadow: shadow ? .subtle : .none,
            content: content
        )
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
            .modifier(TahoeShadow(isSolid: isSolid, style: shadowStyle))
    }
}

private struct TahoeShadow: ViewModifier {
    @Environment(\.tahoe) private var t
    let isSolid: Bool
    let style: TahoeGlassShadow

    private var radius: CGFloat {
        switch style {
        case .none:      return 0
        case .subtle:    return 10  // A3: down from 20
        case .prominent: return 20  // explicit opt-in
        }
    }

    private var yOffset: CGFloat {
        switch style {
        case .none:      return 0
        case .subtle:    return 5   // proportional to radius
        case .prominent: return 10
        }
    }

    func body(content: Content) -> some View {
        if style == .none { return AnyView(content) }
        return AnyView(
            content
                .shadow(
                    color: t.dark ? Color.black.opacity(isSolid ? 0.40 : 0.45)
                                  : Color(.sRGB, red: 15.0/255, green: 17.0/255, blue: 22.0/255, opacity: isSolid ? 0.08 : 0.10),
                    radius: radius, x: 0, y: yOffset
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
        .buttonStyle(PressableButtonStyle())
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
        .buttonStyle(PressableButtonStyle())
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
