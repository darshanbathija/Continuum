#if canImport(SwiftUI)
import SwiftUI

/// Design tokens ported from the firmware `CLAUDE.md` aesthetic spec:
/// Anthropic dark theme — true black background, terra-cotta accent, Tiempos serif
/// display + Styrene sans body. AOD-aware variants per plan AOD spec.
public enum ClawdmeterTheme {

    // MARK: - Colors

    public enum Colors {
        // Quiet Black Workbench: forward to the unified `ContinuumTokens`.
        /// App interior base (#050507).
        public static let background = ContinuumTokens.bg

        /// Claude provider dot (#D97757) — the heritage terra-cotta, rationed.
        public static let accent = TahoeProvider.claude.dot

        /// Over-cap / red-line state — error red (#E5534B).
        public static let accentRedLine = ContinuumTokens.error

        /// Primary text / live numerals.
        public static let primaryText = ContinuumTokens.fg

        /// Secondary text.
        public static let secondaryText = ContinuumTokens.fg2

        /// Tertiary.
        public static let tertiaryText = ContinuumTokens.fg3

        /// Semantic state — live / warn / error.
        public static let statusOK = ContinuumTokens.live
        public static let statusWarning = ContinuumTokens.warn
        public static let statusError = ContinuumTokens.error

        /// Stale / idle dim variant.
        public static let accentStale = ContinuumTokens.fg4

        /// Mood→color mapping (mirrors firmware's idle/active/red-line state).
        public static func accent(for mood: UsageData.Mood) -> Color {
            switch mood {
            case .idle: return ContinuumTokens.paused
            case .active: return TahoeProvider.claude.dot
            case .redLine: return ContinuumTokens.error
            }
        }

        /// AOD variant of a color (per plan AOD style spec: 50% brightness, no fills).
        public static func aod(_ color: Color) -> Color {
            color.opacity(0.5)
        }
    }

    // MARK: - Typography

    /// Custom fonts loaded from the firmware aesthetic. App targets must bundle
    /// the OTF files and reference them as `UIAppFonts` (Info.plist).
    ///
    /// The firmware uses pre-compiled LVGL bitmaps; on Apple platforms we use
    /// the same family names so the visual identity carries over.
    public enum Typography {
        /// Display / big metrics — SF Pro Rounded (was Tiempos serif). Rounded
        /// terminals echo the meter and warm the panel without color.
        public static func display(size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        /// UI body — SF Pro Text (was Styrene). The human voice.
        public static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }

        /// Tabular mono for countdowns and numerical streams — SF Mono.
        public static func mono(size: CGFloat, weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    // MARK: - Layout

    public enum Layout {
        /// Standard margin inside the rounded display corners on watch.
        public static let watchMargin: CGFloat = 8
        /// iPhone widget padding.
        public static let widgetPadding: CGFloat = 12
        /// Mac popover overall width per plan D2 (one-composition).
        public static let macPopoverSize = CGSize(width: 320, height: 320)
        /// Mac popover gauge area height per plan D2.
        public static let macPopoverGaugeHeight: CGFloat = 200
        /// Mac popover sparkline area height per plan D2.
        public static let macPopoverSparklineHeight: CGFloat = 80
        /// Mac popover status row height per plan D2.
        public static let macPopoverStatusHeight: CGFloat = 40
        /// Watch app Pin button per plan accessibility spec.
        public static let watchPinButtonSize = CGSize(width: 60, height: 44)
        /// Touch target minimums (iPhone HIG and watch).
        public static let iPhoneTouchMin: CGFloat = 44
        public static let watchTouchMin: CGFloat = 30
    }

    // MARK: - Motion

    public enum Motion {
        /// Entrance animation: ring drawing from 12 o'clock per plan onboarding spec.
        public static let entranceDuration: TimeInterval = 0.6
        /// Active-mood pulse cadence (1 Hz, 5% opacity oscillation).
        public static let activePulseHz: Double = 1.0
        /// Red-line pulse cadence (0.5 Hz, more pronounced).
        public static let redLinePulseHz: Double = 0.5
    }
}
#endif
