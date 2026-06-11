#if canImport(SwiftUI)
import SwiftUI

// MARK: - Continuum design system — "Quiet Black Workbench"
//
// Single source of truth for the redesign (see DESIGN.md). Dark-first with a
// calibrated light variant; dark remains the default. SwiftUI views read
// tokens via `@Environment(\.theme)` / `@Environment(\.tahoe)` (derived from
// `ContinuumPalette` + `TahoeThemeStore.appearance`). Widgets and other
// non-environment contexts read the static dark `ContinuumTokens` aliases.
//
// This replaces the palettes previously scattered across TahoeTokens (glass),
// SessionsV2Theme (terra-cotta + traffic-light semantics), and ClawdmeterTheme
// (firmware). Those layers now forward here and are deleted at the end of the
// migration.

/// A resolved neutral + semantic palette for one appearance mode.
public struct ContinuumPalette: Equatable, Sendable {
    public var bg: Color
    public var surface1: Color
    public var surface2: Color
    public var surface3: Color
    public var modal: Color

    public var hairline2: Color
    public var hairline: Color
    public var focus: Color

    public var fg: Color
    public var fg2: Color
    public var fg3: Color
    public var fg4: Color

    public var hover: Color
    public var pressed: Color
    public var selection: Color

    public var primaryFill: Color
    public var primaryText: Color

    /// Active segmented-control / titlebar tab fill.
    public var segmentActiveFill: Color

    public var live: Color
    public var warn: Color
    public var error: Color
    public var paused: Color

    public var railTrack: Color
    public var railTrackInset: Color
    public var railLitEdge: Color

    public func metricColor(percent: Double) -> Color {
        if percent > 100 { return error }
        if percent >= ContinuumTokens.warnTickFraction * 100 { return warn }
        return fg
    }
}

/// The Quiet Black Workbench token palette. Dark values are verbatim from
/// DESIGN.md; the light variant inverts the neutral stack while keeping semantic
/// + provider colors rationed the same way. Greyscale by default; color is
/// rationed to provider meter fills, provider dots/edges/chart segments, and
/// semantic state.
public enum ContinuumTokens {

    // MARK: Palettes

    public static let darkPalette = ContinuumPalette(
        bg: hex(0x050507),
        surface1: hex(0x0D0E11),
        surface2: hex(0x131418),
        surface3: hex(0x1A1B1F),
        modal: hex(0x202126),
        hairline2: white(0.05),
        hairline: white(0.085),
        focus: white(0.20),
        fg: white(0.94),
        fg2: white(0.62),
        fg3: white(0.40),
        fg4: white(0.26),
        hover: white(0.04),
        pressed: white(0.065),
        selection: white(0.075),
        primaryFill: white(0.92),
        primaryText: hex(0x0A0A0C),
        segmentActiveFill: white(0.10),
        live: hex(0x3CC07A),
        warn: hex(0xD6A23B),
        error: hex(0xE5534B),
        paused: hex(0x8A8A8A),
        railTrack: hex(0x202126),
        railTrackInset: white(0.05),
        railLitEdge: white(0.18)
    )

    /// "Quiet White Workbench" — cool off-white instrument palette. Semantic +
    /// provider colors stay identical; neutrals invert with black hairlines.
    public static let lightPalette = ContinuumPalette(
        bg: hex(0xF4F6FA),
        surface1: hex(0xFFFFFF),
        surface2: hex(0xF3F4F7),
        surface3: hex(0xECEEF2),
        modal: hex(0xE4E6EB),
        hairline2: ink(0.06),
        hairline: ink(0.10),
        focus: ink(0.20),
        fg: ink(0.95),
        fg2: ink(0.66),
        fg3: ink(0.46),
        fg4: ink(0.26),
        hover: ink(0.04),
        pressed: ink(0.065),
        selection: ink(0.075),
        primaryFill: hex(0x0A0A0C),
        primaryText: white(0.98),
        segmentActiveFill: hex(0xFFFFFF),
        live: hex(0x3CC07A),
        warn: hex(0xD6A23B),
        error: hex(0xE5534B),
        paused: hex(0x8A8A8A),
        railTrack: hex(0xE4E6EB),
        railTrackInset: ink(0.05),
        railLitEdge: ink(0.12)
    )

    public static func palette(for appearance: TahoeAppearance) -> ContinuumPalette {
        appearance == .light ? lightPalette : darkPalette
    }

    // MARK: Dark aliases (widgets + non-environment contexts stay dark-first)
    public static let bg       = darkPalette.bg
    public static let surface1 = darkPalette.surface1
    public static let surface2 = darkPalette.surface2
    public static let surface3 = darkPalette.surface3
    public static let modal    = darkPalette.modal

    public static let hairline2 = darkPalette.hairline2
    public static let hairline  = darkPalette.hairline
    public static let focus     = darkPalette.focus

    public static let fg  = darkPalette.fg
    public static let fg2 = darkPalette.fg2
    public static let fg3 = darkPalette.fg3
    public static let fg4 = darkPalette.fg4

    public static let hover     = darkPalette.hover
    public static let pressed   = darkPalette.pressed
    public static let selection = darkPalette.selection

    public static let primaryFill = darkPalette.primaryFill
    public static let primaryText = darkPalette.primaryText

    public static let live   = darkPalette.live
    public static let warn   = darkPalette.warn
    public static let error  = darkPalette.error
    public static let paused = darkPalette.paused

    public static let railTrack      = darkPalette.railTrack
    public static let railTrackInset = darkPalette.railTrackInset
    public static let railLitEdge    = darkPalette.railLitEdge

    // MARK: Rail meter (the signature component) — treatment "T2".
    /// Warn threshold the limit tick sits at (and where the fill begins to cap).
    public static let warnTickFraction: Double = 0.80
    /// Warn fill (>=80% portion) — DESIGN.md meter-fills table.
    public static let warnFill:  [Color] = [hex(0xE2B45C), hex(0xC98A2E)]
    /// Error fill (over 100%) — DESIGN.md meter-fills table.
    public static let errorFill: [Color] = [hex(0xEC6A62), hex(0xD2433B)]

    /// The big `%` number adopts warn/error past the thresholds; the fill
    /// before the tick never recolors. Uses the dark palette for static call sites.
    public static func metricColor(percent: Double) -> Color {
        darkPalette.metricColor(percent: percent)
    }

    // MARK: Radius — tight radii read as engineered.
    public enum Radius {
        public static let row: CGFloat = 4      // sidebar / list rows
        public static let button: CGFloat = 5   // buttons, small controls
        public static let card: CGFloat = 6     // default panels and cards
        public static let modal: CGFloat = 8    // modals, popovers, the Mac window
        public static let rail: CGFloat = 3     // meter track + fill
        public static let pill: CGFloat = 999   // native segmented controls + switches
    }

    // MARK: Spacing — base unit 4, shown.
    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: helpers
    public static func hex(_ v: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255.0,
              green: Double((v >> 8) & 0xFF) / 255.0,
              blue: Double(v & 0xFF) / 255.0,
              opacity: opacity)
    }
    public static func white(_ opacity: Double) -> Color { Color(.sRGB, white: 1, opacity: opacity) }
    /// Ink stack for light mode — rgba(15,17,22, α).
    public static func ink(_ opacity: Double) -> Color { hex(0x0F1116, opacity) }
}

// MARK: - Type roles
//
// Apple system fonts only. The machine/human handoff is the typographic
// signature: any glyph that is a measurement or a machine string is SF Mono;
// prose, labels, and headings stay proportional.
public enum ContinuumFont {
    /// Display / big metrics / titles — SF Pro Rounded.
    public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    /// UI body / labels / nav — SF Pro Text (the human voice).
    public static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// Data numerals & every machine string — SF Mono.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Etched label — SF Mono, uppercase, ~10.5px, +0.09em tracking, fg-3.
    /// (Apply `.tracking(...)`/`.textCase(.uppercase)`/`.foregroundStyle(fg3)`
    /// at the call site; this just yields the font.)
    public static func etched(_ size: CGFloat = 10.5) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

// MARK: - Motion — mechanical instrument physics.
public enum ContinuumMotion {
    /// Effectively disabled — used when Reduce Motion is on.
    public static let instant: Double = 0.001
    /// Meter / value settle — a short galvanometer settle (~140ms).
    public static func settle(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: instant)
                     : .spring(response: 0.14, dampingFraction: 0.86)
    }
    /// Standard transition (hover, selection, tab, control) — 120–160ms ease.
    public static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: instant) : .easeOut(duration: 0.14)
    }
    /// Segmented-control selection slide — 160ms ease.
    public static func segmented(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: instant) : .easeOut(duration: 0.16)
    }
    /// Switch-thumb slide — cubic-bezier(0.3,0.7,0.4,1) @150ms.
    public static func switchThumb(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: instant) : .timingCurve(0.3, 0.7, 0.4, 1, duration: 0.15)
    }
    /// The `live` dot heartbeat — 1Hz, opacity 0.5→1. The only pulsing element.
    /// Returns nil under Reduce Motion so the caller renders a static dot.
    public static func heartbeat(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
    }
}

// MARK: - Provider identity (rationed color)
//
// Color travels with a glyph + label + number. The provider color appears only
// as a 6px dot, a 3px edge, a chart segment, or the meter fill — never a
// provider-colored button/header/background.
public extension TahoeProvider {
    /// 6px dot / 3px edge / chart-legend swatch color.
    var dot: Color {
        switch self {
        case .claude:   return ContinuumTokens.hex(0xD97757) // terra-cotta (heritage warmth)
        case .codex:    return ContinuumTokens.hex(0x8A9099) // graphite
        case .gemini:   return ContinuumTokens.hex(0x5C9DFF) // Antigravity cool blue
        case .opencode: return ContinuumTokens.hex(0x9B87D4) // muted violet (OpenCode's brand hue)
        case .cursor:   return ContinuumTokens.hex(0x7FA8B5) // cool steel (Cursor's mono identity)
        case .grok:     return ContinuumTokens.hex(0x6BD19E) // cool green
        }
    }

    /// Meter-fill gradient endpoints (treatment T2: muted glow→base), applied
    /// leading→trailing. Same gradient used by the rail, charts, and any
    /// provider-colored segment so color stays consistent everywhere.
    var meterFill: [Color] {
        switch self {
        case .claude:   return [ContinuumTokens.hex(0xE68A66), ContinuumTokens.hex(0xC9603F)]
        case .codex:    return [ContinuumTokens.hex(0x9AA3AD), ContinuumTokens.hex(0x6E7681)]
        case .gemini:   return [ContinuumTokens.hex(0x79ADFF), ContinuumTokens.hex(0x4A86E8)]
        case .opencode: return [ContinuumTokens.hex(0xB2A4E2), ContinuumTokens.hex(0x7C6CB6)] // muted violet
        case .cursor:   return [ContinuumTokens.hex(0x9BBFC9), ContinuumTokens.hex(0x5E8893)] // cool steel
        case .grok:     return [ContinuumTokens.hex(0x8EDFB8), ContinuumTokens.hex(0x4C9F77)] // cool green
        }
    }
}

/// Canonical provider/state fill — the one place rail + chart + segment fills
/// are produced, so the gradient is identical across every surface.
public enum ProviderFill {
    /// Leading→trailing T2 gradient for a provider's meter / chart segment.
    public static func gradient(for provider: TahoeProvider) -> LinearGradient {
        LinearGradient(colors: provider.meterFill, startPoint: .leading, endPoint: .trailing)
    }
    /// Warn cap gradient (>= 80%).
    public static let warn = LinearGradient(colors: ContinuumTokens.warnFill, startPoint: .leading, endPoint: .trailing)
    /// Error cap gradient (over 100%).
    public static let error = LinearGradient(colors: ContinuumTokens.errorFill, startPoint: .leading, endPoint: .trailing)
}
#endif
