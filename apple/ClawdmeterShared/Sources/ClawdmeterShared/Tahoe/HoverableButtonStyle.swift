#if canImport(SwiftUI)
import SwiftUI

// Interactive feedback for ghost / icon / chip buttons that otherwise read as
// static chrome. Many sidebar + titlebar controls only carried a press-scale
// (PressableButtonStyle) or `.plain`, so hovering them changed nothing but the
// cursor — they didn't feel clickable. This adds the missing two states from
// DESIGN.md ("Standard transitions: 120–160ms ease for hover, selection … and
// control changes"): a barely-there `hover` fill on pointer-over and a brighter
// `pressed` fill + subtle scale on mouse-down, plus the link (pointing-hand)
// cursor so the control reads as interactive. Mirrors the `TahoeDashTab`
// precedent (hover fill + `.pointerStyle(.link)`).

/// A ButtonStyle that paints `tahoe.hover` / `tahoe.pressed` token fills and
/// shows the pointing-hand cursor on hover. Use in place of
/// `PressableButtonStyle` on ghost / icon / chip buttons that need to read as
/// clickable. `cornerRadius` should match the label's own background shape
/// (e.g. 4 row · 6 icon · 10 spawn · ≥height/2 for a capsule chip).
public struct HoverableButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var pressedScale: CGFloat
    /// Draw the highlight *over* the label instead of behind it. Needed when the
    /// label already paints an opaque background (e.g. a `surface-2` capsule),
    /// where a behind-fill would be hidden.
    public var overlay: Bool

    public init(cornerRadius: CGFloat = ContinuumTokens.Radius.card,
                pressedScale: CGFloat = 0.97,
                overlay: Bool = false) {
        self.cornerRadius = cornerRadius
        self.pressedScale = pressedScale
        self.overlay = overlay
    }

    public func makeBody(configuration: Configuration) -> some View {
        // ButtonStyle is not a View, so `@Environment` / `@State` (the hover
        // flag) have to live in this label-context child — same pattern as
        // PressableButtonStyle's Reduce-Motion read.
        HoverableBody(configuration: configuration,
                      cornerRadius: cornerRadius,
                      pressedScale: pressedScale,
                      overlay: overlay)
    }

    private struct HoverableBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let pressedScale: CGFloat
        let overlay: Bool
        @Environment(\.tahoe) private var t
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        private var highlight: Color {
            if configuration.isPressed { return t.pressed }
            if isHovered { return t.hover }
            return .clear
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .background { if !overlay { shape.fill(highlight) } }
                .overlay { if overlay { shape.fill(highlight) } }
                .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? pressedScale : 1.0))
                .animation(.easeOut(duration: reduceMotion ? 0.0 : 0.12), value: isHovered)
                .animation(.easeOut(duration: reduceMotion ? 0.0 : 0.12), value: configuration.isPressed)
                #if os(macOS)
                .pointerStyle(.link)
                #endif
                #if !os(watchOS)
                .onHover { isHovered = $0 }
                #endif
        }
    }
}

#if !os(watchOS)
private struct HoverHighlightModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            // Overlay (not behind): Menu labels often sit on an opaque-ish
            // accent/hairline fill where a behind-highlight wouldn't show. A 4%
            // white wash on top is visible everywhere and never obscures the
            // glyph.
            .overlay { if isHovered { shape.fill(t.hover) } }
            .contentShape(shape)
            .animation(.easeOut(duration: reduceMotion ? 0.0 : 0.12), value: isHovered)
            #if os(macOS)
            .pointerStyle(.link)
            #endif
            .onHover { isHovered = $0 }
    }
}
#endif

public extension View {
    /// Hover-only interactive feedback (`tahoe.hover` wash + pointing-hand
    /// cursor) for controls that can't take a ButtonStyle — notably `Menu`
    /// labels. The menu opening is itself the press feedback. `cornerRadius`
    /// should match the label's background shape.
    func hoverHighlight(cornerRadius: CGFloat = ContinuumTokens.Radius.card) -> some View {
        #if os(watchOS)
        return self
        #else
        return modifier(HoverHighlightModifier(cornerRadius: cornerRadius))
        #endif
    }
}
#endif
