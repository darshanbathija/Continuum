#if canImport(SwiftUI)
import SwiftUI

/// Design tokens ported from the firmware `CLAUDE.md` aesthetic spec:
/// Anthropic dark theme — true black background, terra-cotta accent, Tiempos serif
/// display + Styrene sans body. AOD-aware variants per plan AOD spec.
public enum ClawdmeterTheme {

    // MARK: - Colors

    public enum Colors {
        /// True black for AMOLED-friendly backgrounds.
        public static let background = Color(red: 0.0, green: 0.0, blue: 0.0)

        /// Anthropic terra-cotta accent #d97757.
        public static let accent = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)

        /// Warmer red-line variant #e07a5f.
        public static let accentRedLine = Color(red: 0xE0 / 255.0, green: 0x7A / 255.0, blue: 0x5F / 255.0)

        /// Primary white for numerals (21:1 contrast on background).
        public static let primaryText = Color.white

        /// Secondary text (white at 60% opacity).
        public static let secondaryText = Color.white.opacity(0.6)

        /// Tertiary (white at 40%).
        public static let tertiaryText = Color.white.opacity(0.4)

        /// Status colors meeting WCAG AA on black.
        public static let statusOK = Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0)
        public static let statusWarning = Color(red: 0xE0 / 255.0, green: 0x7A / 255.0, blue: 0x5F / 255.0)
        public static let statusError = Color(red: 0xDC / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0)

        /// Stale-data dim variant of accent (50% brightness).
        public static let accentStale = Color(red: 0x6C / 255.0, green: 0x3B / 255.0, blue: 0x2B / 255.0)

        /// Mood→color mapping (mirrors firmware's idle/active/red-line state).
        public static func accent(for mood: UsageData.Mood) -> Color {
            switch mood {
            case .idle: return accent.opacity(0.6)
            case .active: return accent
            case .redLine: return accentRedLine
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
        /// Display serif (Tiempos-style). Falls back to system-rounded if not bundled.
        public static func display(size: CGFloat, weight: Font.Weight = .bold) -> Font {
            Font.custom("Tiempos", size: size, relativeTo: .largeTitle)
                .weight(weight)
        }

        /// Sans serif body (Styrene-style). Falls back to system if not bundled.
        public static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.custom("Styrene", size: size, relativeTo: .body)
                .weight(weight)
        }

        /// Tabular mono for countdowns and numerical streams.
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
