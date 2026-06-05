#if canImport(SwiftUI)
import SwiftUI

// MARK: - Continuum design system — "Quiet Black Workbench"
//
// Single source of truth for the redesign (see DESIGN.md). Dark-only (v1):
// every value is a static constant — no per-instance state, no appearance
// toggle, no glass/wallpaper knobs. SwiftUI views read these via the
// `@Environment(\.theme)` / `@Environment(\.tahoe)` facade (which forwards to
// these constants); widgets, AppKit renderers, and other non-environment
// contexts read `ContinuumTokens` directly.
//
// This replaces the palettes previously scattered across TahoeTokens (glass),
// SessionsV2Theme (terra-cotta + traffic-light semantics), and ClawdmeterTheme
// (firmware). Those layers now forward here and are deleted at the end of the
// migration.

/// The Quiet Black Workbench token palette. All hex values are verbatim from
/// DESIGN.md. Greyscale by default; color is rationed to provider meter fills,
/// provider dots/edges/chart segments, and semantic state.
public enum ContinuumTokens {

    // MARK: Neutrals (dark) — elevation is value + hairline, never shadow.
    public static let bg       = hex(0x050507) // app interior / page
    public static let surface1 = hex(0x0D0E11) // primary panels, sidebars, cards
    public static let surface2 = hex(0x131418) // raised: composer, active row, controls
    public static let surface3 = hex(0x1A1B1F) // popover, menu, active control
    public static let modal    = hex(0x202126) // highest: modal / detached window

    // MARK: Hairlines & focus
    public static let hairline2 = white(0.05)  // faint internal rules
    public static let hairline  = white(0.085) // structural seams (0.5px)
    public static let focus     = white(0.20)  // keyboard focus ring (1px)

    // MARK: Foreground stack — the data is the only thing that glows.
    public static let fg  = white(0.94) // primary text, live numbers, meter highlight
    public static let fg2 = white(0.62) // secondary text, axis labels
    public static let fg3 = white(0.40) // etched labels, tertiary
    public static let fg4 = white(0.26) // disabled / quiet metadata

    // MARK: Interaction states (barely-there)
    public static let hover     = white(0.04)
    public static let pressed   = white(0.065)
    public static let selection = white(0.075)

    // MARK: Primary button — the brand accent is neutral, so the primary
    // action is a light button, not a chromatic one.
    public static let primaryFill = white(0.92)
    public static let primaryText = hex(0x0A0A0C)

    // MARK: Semantic state — thin signals only (dot, hairline, text, cap).
    public static let live   = hex(0x3CC07A) // running / live-now (the only pulsing element)
    public static let warn   = hex(0xD6A23B) // approaching cap (>= 80%)
    public static let error  = hex(0xE5534B) // over cap / failed / stop
    public static let paused = hex(0x8A8A8A) // paused / idle (neutral grey)

    // MARK: Rail meter (the signature component) — treatment "T2".
    public static let railTrack      = modal            // #202126
    public static let railTrackInset = white(0.05)      // inset 0 0 0 0.5px
    public static let railLitEdge    = white(0.18)      // inset 0 1px 0
    /// Warn threshold the limit tick sits at (and where the fill begins to cap).
    public static let warnTickFraction: Double = 0.80
    /// Warn fill (>=80% portion) — DESIGN.md meter-fills table.
    public static let warnFill:  [Color] = [hex(0xE2B45C), hex(0xC98A2E)]
    /// Error fill (over 100%) — DESIGN.md meter-fills table.
    public static let errorFill: [Color] = [hex(0xEC6A62), hex(0xD2433B)]

    /// The big `%` number adopts warn/error past the thresholds; the fill
    /// before the tick never recolors.
    public static func metricColor(percent: Double) -> Color {
        if percent > 100 { return error }
        if percent >= warnTickFraction * 100 { return warn }
        return fg
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
        case .opencode: return ContinuumTokens.hex(0x9B8CC4) // proposed muted slate-violet
        case .cursor:   return ContinuumTokens.hex(0xB8BDC4) // proposed light graphite
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
        case .opencode: return [ContinuumTokens.hex(0xAFA2D6), ContinuumTokens.hex(0x7E6FB0)]
        case .cursor:   return [ContinuumTokens.hex(0xC6CBD2), ContinuumTokens.hex(0x9AA0A8)]
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
