import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Sessions v2 design tokens — single source of truth for colors,
/// typography, spacing, corner radius, and animation timing. T34 from
/// the design review.
///
/// Goals:
/// - Replace the repeated `Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)`
///   literal that's duplicated across SessionWorkspaceView (5 sites),
///   SessionActivityStrip, iOSSessionsView, etc.
/// - Give every chip / dial / banner / strip the same vocabulary.
/// - Provide a single place to update the design system after v2 ships.
public enum SessionsV2Theme {

    // MARK: - Color tokens

    public enum Tokens {
        /// Terra-cotta brand accent (#D97757). Matches existing Clawdmeter
        /// brand language. Used for selected pill state, primary buttons,
        /// session attention indicator, agent-state pulse for Claude.
        public static let accentRGB: (red: Double, green: Double, blue: Double) = (
            red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0
        )
        /// Codex accent (#5C9DFF — Apple system blue tone). Used on the
        /// provider-split bar for Codex segments. Conductor's screenshot
        /// uses a similar tone on its Codex group.
        public static let codexBlueRGB: (red: Double, green: Double, blue: Double) = (
            red: 0x5C / 255.0, green: 0x9D / 255.0, blue: 0xFF / 255.0
        )
    }

    // MARK: - Spacing scale

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: - Corner radius scale

    public enum Radius {
        /// Chips + segmented control segments (ModePicker, ModelPicker, EffortDial).
        public static let chip: CGFloat = 6
        /// Buttons (Start, Approve, Merge).
        public static let button: CGFloat = 8
        /// Cards + lift surfaces (cost banner, plan card, A/B compare).
        public static let card: CGFloat = 10
        /// Sheet / modal corners.
        public static let sheet: CGFloat = 12
    }

    // MARK: - Animation tokens

    public enum AnimationDuration {
        /// Effectively disabled — used when Reduce Motion is on.
        public static let instant: Double = 0.001
        /// Quick state changes (chip selection, hover).
        public static let fast: Double = 0.15
        /// Standard chip swap, control-strip transition.
        public static let normal: Double = 0.25
        /// Slower transitions (sheet present/dismiss).
        public static let slow: Double = 0.35
    }

    // MARK: - Typography (SF Pro)

    /// Display size — used on the new-session-sheet title, complications
    /// hero numerals. 34pt bold.
    public static let displayFontSize: CGFloat = 34
    /// Section title size. 22pt semibold.
    public static let titleFontSize: CGFloat = 22
    /// Headline / section header. 17pt semibold.
    public static let headlineFontSize: CGFloat = 17
    /// Body text. 17pt regular.
    public static let bodyFontSize: CGFloat = 17
    /// Caption. 13pt regular.
    public static let captionFontSize: CGFloat = 13

    // MARK: - Pulse / fade indicator timing

    /// Pulsing terra-cotta `✻` for Claude — established in SessionActivityStrip.
    public static let claudePulseDuration: Double = 0.9
    /// Fading "Thinking" for Codex — established in SessionActivityStrip.
    public static let codexFadeDuration: Double = 1.0

    // MARK: - SwiftUI Color shortcuts

    #if canImport(SwiftUI)
    /// Terra-cotta brand accent.
    public static let accent: Color = Color(
        red: Tokens.accentRGB.red,
        green: Tokens.accentRGB.green,
        blue: Tokens.accentRGB.blue
    )
    /// Codex provider color.
    public static let codexBlue: Color = Color(
        red: Tokens.codexBlueRGB.red,
        green: Tokens.codexBlueRGB.green,
        blue: Tokens.codexBlueRGB.blue
    )
    public static let backgroundPrimary: Color = .black
    public static let surfaceElev0: Color = Color(white: 0.04)   // #0A0A0A
    public static let surfaceElev1: Color = Color(white: 0.08)   // #141414
    public static let textPrimary: Color = .white
    public static let textSecondary: Color = .white.opacity(0.7)
    public static let textTertiary: Color = .white.opacity(0.5)
    public static let warn: Color = .yellow   // soft-warn cost banner
    public static let danger: Color = .red    // autopilot banner, destructive
    public static let success: Color = .green
    #endif

    // MARK: - Reduce-Motion respect helper

    #if canImport(SwiftUI)
    /// Returns a spring animation tuned for chip swaps. When Reduce Motion
    /// is on (accessibility setting), the duration collapses to `instant`
    /// so animations become near-zero opacity changes.
    public static func chipSwapAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: AnimationDuration.instant)
            : .spring(response: AnimationDuration.normal, dampingFraction: 0.7)
    }

    /// Returns the slide-up animation for the cost banner / autopilot banner.
    public static func bannerSlideUp(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: AnimationDuration.instant)
            : .spring(response: AnimationDuration.slow, dampingFraction: 0.75)
    }

    /// Per-agent pulse animation. Used by SessionActivityStrip and Watch
    /// complications. When Reduce Motion is on, returns nil so the caller
    /// can render a static glyph.
    public static func pulseAnimation(for agent: AgentKind, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        let dur = agent == .claude ? claudePulseDuration : codexFadeDuration
        return .easeInOut(duration: dur).repeatForever(autoreverses: true)
    }
    #endif
}
