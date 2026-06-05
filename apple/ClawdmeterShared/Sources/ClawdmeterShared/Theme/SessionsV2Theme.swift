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
        public static let chip: CGFloat = ContinuumTokens.Radius.card   // 6
        /// Buttons (Start, Approve, Merge).
        public static let button: CGFloat = ContinuumTokens.Radius.button // 5
        /// Cards + lift surfaces (cost banner, plan card, A/B compare).
        public static let card: CGFloat = ContinuumTokens.Radius.card   // 6
        /// Sheet / modal corners.
        public static let sheet: CGFloat = ContinuumTokens.Radius.modal // 8
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
        /// DESIGN.md interaction band — button / tab press + hover (120ms).
        public static let interaction: Double = 0.12
        /// DESIGN.md segmented-control selection slide (160ms).
        public static let segmented: Double = 0.16
        /// DESIGN.md composer accent-rim breathing pulse (1.8s).
        public static let composerPulse: Double = 1.8
        /// DESIGN.md spinner / shimmer-sweep cadence (0.9s).
        public static let spinner: Double = 0.9
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
    // Quiet Black Workbench: all of SessionsV2Theme's colors now forward to the
    // unified `ContinuumTokens`. `accent` survives only as the Claude provider
    // dot (rationed); `codexBlue` is Codex graphite; semantics map to the
    // DESIGN.md live/warn/error palette.
    /// Claude provider dot (#D97757) — terra-cotta, rationed to provider signal.
    public static let accent: Color = TahoeProvider.claude.dot
    /// Codex provider dot (#8A9099 graphite).
    public static let codexBlue: Color = TahoeProvider.codex.dot
    public static let backgroundPrimary: Color = ContinuumTokens.bg
    public static let surfaceElev0: Color = ContinuumTokens.surface1
    public static let surfaceElev1: Color = ContinuumTokens.surface2
    public static let textPrimary: Color = ContinuumTokens.fg
    public static let textSecondary: Color = ContinuumTokens.fg2
    public static let textTertiary: Color = ContinuumTokens.fg3
    /// Approaching-cap amber (#D6A23B) — soft-warn cost banner, pending CI,
    /// paused state.
    public static let warn: Color = ContinuumTokens.warn
    /// Over-cap red (#E5534B) — autopilot banner, destructive actions, failed.
    public static let danger: Color = ContinuumTokens.error
    /// Live green (#3CC07A) — live dots, successful checks, enabled switches.
    public static let success: Color = ContinuumTokens.live
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

    /// Standard disclosure / expand-collapse animation. Used by
    /// collapsible sidebar sections, the controls-strip toggle, and
    /// any `withAnimation` that flips a `@State` boolean. Replaces the
    /// ad-hoc `easeInOut(duration: 0.18)` calls scattered across v2
    /// surfaces. Honors Reduce Motion.
    public static func disclosureToggle(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: AnimationDuration.instant)
            : .easeInOut(duration: AnimationDuration.fast)
    }

    /// Press-state animation for buttons / chips — snappy (Conductor feel),
    /// 120ms ease-out. Collapses to instant under Reduce Motion.
    public static func pressAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: AnimationDuration.instant)
            : .easeOut(duration: AnimationDuration.interaction)
    }

    /// Segmented-control selection slide (matched-geometry fill) — 160ms ease.
    public static func segmentedSelection(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: AnimationDuration.instant)
            : .easeOut(duration: AnimationDuration.segmented)
    }

    /// Switch-thumb / toggle slide. DESIGN.md curve cubic-bezier(0.3,0.7,0.4,1)
    /// at 150ms. Collapses to instant under Reduce Motion.
    public static func switchThumb(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: AnimationDuration.instant)
            : .timingCurve(0.3, 0.7, 0.4, 1, duration: 0.15)
    }

    /// Composer accent-rim breathing pulse. Per DESIGN.md the rim breathes at
    /// 1.8s ease-in-out while a turn runs; under Reduce Motion this returns nil
    /// so the caller renders a STATIC rim (no infinite loop) — matches the
    /// `pulseAnimation(for:reduceMotion:)` nil contract.
    public static func composerRimPulse(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: AnimationDuration.composerPulse)
            .repeatForever(autoreverses: true)
    }
    #endif
}
