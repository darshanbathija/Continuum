#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

#if canImport(SwiftUI)

/// Snappy press feedback for any `Button` — the single press primitive for the
/// Code tab. Scales the label to 0.97 on press-down with a 120ms ease (DESIGN.md
/// interaction band) so a click is visibly *acknowledged* instead of feeling
/// dead. Replaces the bare `.buttonStyle(.plain)` scattered across the workbench.
///
/// Reduce Motion collapses the scale to identity (the press still registers, just
/// without the squish). Haptics are opt-in and OFF by default — Mac users don't
/// expect a Force-Touch buzz on every click; reserve it for a few high-signal
/// confirmations.
public struct PressableButtonStyle: ButtonStyle {
    public var pressedScale: CGFloat
    public var haptics: Bool

    public init(pressedScale: CGFloat = 0.97, haptics: Bool = false) {
        self.pressedScale = pressedScale
        self.haptics = haptics
    }

    public func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, pressedScale: pressedScale, haptics: haptics)
    }

    // ButtonStyle is not a View, so `@Environment` can't be read directly in the
    // style; the Reduce-Motion read lives in this label-context child view.
    private struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        let pressedScale: CGFloat
        let haptics: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? pressedScale : 1.0))
                .animation(SessionsV2Theme.pressAnimation(reduceMotion: reduceMotion),
                           value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    guard haptics, pressed else { return }
                    #if canImport(AppKit)
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    #endif
                }
        }
    }
}

public extension View {
    /// Apply the standard Code-tab press feedback to a `Button`. Swap in for
    /// `.buttonStyle(.plain)` on any tappable that should feel alive.
    func pressable(scale: CGFloat = 0.97, haptics: Bool = false) -> some View {
        buttonStyle(PressableButtonStyle(pressedScale: scale, haptics: haptics))
    }
}

#endif
