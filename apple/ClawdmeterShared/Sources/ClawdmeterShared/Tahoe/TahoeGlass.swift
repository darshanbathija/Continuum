#if canImport(SwiftUI)
import SwiftUI

/// Surface elevation "tone" — which Quiet Black surface step a panel sits at.
/// (Names preserved from the old glass system so call sites compile; the glass
/// is gone — these now select a flat surface fill.)
public enum TahoeGlassTone: String, Sendable, CaseIterable {
    case panel   // surface-1 — primary panels, sidebars, cards
    case chip    // surface-2 — raised: composer, active row, controls
    case raised  // surface-2 — raised card
    case floor   // surface-1 — floor-level surface
    case inset   // bg — recessed
}

/// Shadow weight. Quiet Black reserves shadows for genuinely floating surfaces
/// (popovers, modals, the Mac window); inline panels are separated by hairline
/// seams + elevation, never shadow.
///   - `.none`     — no shadow (inline panels — the default).
///   - `.subtle`   — also no shadow now (inline; kept for API compatibility).
///   - `.prominent` — opt-in lift for floating surfaces only.
public enum TahoeGlassShadow: Sendable, Equatable {
    case none
    case subtle
    case prominent
}

/// The workhorse panel primitive. Was the Liquid Glass surface; now a flat
/// Quiet Black panel — a solid surface fill + a 0.5px hairline seam, no blur,
/// no material, no glass tint, no inner highlight. Reworking this one type
/// flattens every panel across the app.
///
/// Usage:
/// ```swift
/// TahoeGlass(tone: .panel) { content }   // surface-1 + hairline, radius 6
/// ```
public struct TahoeGlass<Content: View>: View {
    @Environment(\.theme) private var t

    public var radius: CGFloat
    public var tone: TahoeGlassTone
    public var solidOverride: Bool?
    public var ring: Bool
    public var shadowStyle: TahoeGlassShadow
    public var content: Content

    public init(
        radius: CGFloat = ContinuumTokens.Radius.card,
        tone: TahoeGlassTone = .panel,
        solid: Bool? = nil,
        ring: Bool = true,
        shadow: TahoeGlassShadow = .none,
        @ViewBuilder content: () -> Content
    ) {
        self.radius = radius
        self.tone = tone
        self.solidOverride = solid
        self.ring = ring
        self.shadowStyle = shadow
        self.content = content()
    }

    /// Back-compat init taking `shadow: Bool`. Inline panels get no shadow now;
    /// `true` maps to `.none` (was `.subtle`) so the ~78 historical
    /// `shadow: true` call sites flatten automatically. Floating surfaces opt
    /// in to `.prominent` via the designated init.
    public init(
        radius: CGFloat = ContinuumTokens.Radius.card,
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
            shadow: shadow ? .none : .none,
            content: content
        )
    }

    private var surfaceFill: Color {
        switch tone {
        case .panel, .floor:  return ContinuumTokens.surface1
        case .chip, .raised:  return ContinuumTokens.surface2
        case .inset:          return ContinuumTokens.bg
        }
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(surfaceFill)
                    if ring {
                        // Hairline-as-structure: the 0.5px seam is the divider.
                        shape.strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5)
                    }
                }
            }
            .clipShape(shape)
            .modifier(TahoeShadow(style: shadowStyle))
    }
}

private struct TahoeShadow: ViewModifier {
    let style: TahoeGlassShadow

    func body(content: Content) -> some View {
        switch style {
        case .none, .subtle:
            return AnyView(content)
        case .prominent:
            // Floating surfaces only (popover / modal / window).
            return AnyView(content.shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 12))
        }
    }
}

// MARK: - Pill

/// Capsule wrapper. Neutral surface (no accent fill, no glow). The `accent`
/// flag now means "selected" — a faint `selection` fill + hairline — never a
/// terra-cotta capsule.
public struct TahoePill<Content: View>: View {
    @Environment(\.theme) private var t
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
        content
            .background {
                Capsule(style: .continuous)
                    .fill(accent ? ContinuumTokens.selection : ContinuumTokens.surface2)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(accent ? ContinuumTokens.focus : ContinuumTokens.hairline, lineWidth: 0.5)
            }
    }
}

// MARK: - Buttons

/// Primary action — a LIGHT button (`#fff@92%` on near-black), not a chromatic
/// one. The brand accent is neutral, so the single most important action (Send,
/// Approve & run, Pair) is the brightest control, carried by luminance.
public struct TahoeAccentButton<Label: View>: View {
    @Environment(\.theme) private var t
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
            HStack(spacing: 6) { label }
                .font(ContinuumFont.body(fontSize, weight: .semibold))
                .padding(.horizontal, height * 0.5)
                .frame(height: height)
                .foregroundStyle(ContinuumTokens.primaryText)
                .background {
                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                        .fill(ContinuumTokens.primaryFill)
                }
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }
}

/// Ghost / secondary — transparent + 0.5px hairline + `fg-2`. Hover adds a
/// barely-there fill; active tints the border to `focus`.
public struct TahoeGhostButton<Label: View>: View {
    @Environment(\.theme) private var t
    public enum Size { case s, m, l }
    public var size: Size
    public var active: Bool
    public var action: () -> Void
    public var label: Label
    @State private var isHovered = false

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
            HStack(spacing: 5) { label }
                .font(ContinuumFont.body(fontSize, weight: .medium))
                .padding(.horizontal, height * 0.5)
                .frame(height: height)
                .foregroundStyle(active ? ContinuumTokens.fg : ContinuumTokens.fg2)
                .background {
                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                        .fill(isHovered ? ContinuumTokens.hover : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                        .strokeBorder(active ? ContinuumTokens.focus : ContinuumTokens.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(PressableButtonStyle())
        #if !os(watchOS)
        .onHover { isHovered = $0 }
        #endif
    }
}

// MARK: - Hair (separator)

public struct TahoeHair: View {
    public var vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        if vertical {
            Rectangle().fill(ContinuumTokens.hairline).frame(width: 0.5)
        } else {
            Rectangle().fill(ContinuumTokens.hairline).frame(height: 0.5)
        }
    }
}
#endif
