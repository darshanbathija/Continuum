#if canImport(SwiftUI)
import SwiftUI

// Tahoe 26 / iOS 26 design tokens — ports the JSX `ACCENTS` and `PROVIDERS`
// constants from the Claude Design handoff (`project/theme.jsx`). Every value
// here corresponds 1:1 to a constant in the JSX so the verifier can compare
// surfaces against the source of truth.

public enum TahoeAccent: String, CaseIterable, Sendable, Codable, Identifiable {
    case halo, ember, bloom, spring
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .halo:   return "Halo"
        case .ember:  return "Ember"
        case .bloom:  return "Bloom"
        case .spring: return "Spring"
        }
    }

    /// JSX `ACCENTS[k].base`.
    public var base: OKLCH {
        switch self {
        case .halo:   return OKLCH(l: 0.78, c: 0.16, h: 220)
        case .ember:  return OKLCH(l: 0.72, c: 0.16, h: 40)
        case .bloom:  return OKLCH(l: 0.74, c: 0.18, h: 320)
        case .spring: return OKLCH(l: 0.78, c: 0.16, h: 155)
        }
    }

    /// JSX `ACCENTS[k].deep`.
    public var deep: OKLCH {
        switch self {
        case .halo:   return OKLCH(l: 0.55, c: 0.20, h: 250)
        case .ember:  return OKLCH(l: 0.55, c: 0.18, h: 30)
        case .bloom:  return OKLCH(l: 0.55, c: 0.22, h: 320)
        case .spring: return OKLCH(l: 0.58, c: 0.18, h: 155)
        }
    }

    /// JSX `ACCENTS[k].glow`.
    public var glow: OKLCH {
        switch self {
        case .halo:   return OKLCH(l: 0.88, c: 0.13, h: 205)
        case .ember:  return OKLCH(l: 0.82, c: 0.14, h: 50)
        case .bloom:  return OKLCH(l: 0.84, c: 0.15, h: 320)
        case .spring: return OKLCH(l: 0.88, c: 0.14, h: 145)
        }
    }
}

public enum TahoeProvider: String, CaseIterable, Sendable, Codable, Identifiable {
    case claude, codex, gemini
    /// OpenCode — added PR #31 (v0.20.0). 4th lane in every provider
    /// switcher. Brand color is OpenCode violet (#6B5DD3) to disambiguate
    /// from Codex blue + Antigravity violet-blue.
    case opencode
    /// OpenRouter BYOK — routes through opencode serve with provider-scoped
    /// model slugs (`anthropic/claude-sonnet-4.6`). Distinct from OpenCode Go.
    case openrouter
    /// Cursor Agent CLI / SDK lane. The real model catalog is account-scoped,
    /// so Tahoe labels it by provider rather than by a fixed model.
    case cursor
    /// xAI Grok / Grok Build lane. Grok does not expose a verified quota API
    /// yet, but it is a first-class chat and analytics provider.
    case grok
    public var id: String { rawValue }

    /// User-visible name. Note: internal key for the third provider stays
    /// `gemini` to match existing call sites (UsageHistoryStore, parsers,
    /// LiveActivity coordinators), but the user-facing name is "Antigravity".
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Antigravity"
        case .opencode: return "OpenCode"
        case .openrouter: return "OpenRouter"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        }
    }

    public var base: OKLCH {
        switch self {
        case .claude: return OKLCH(l: 0.72, c: 0.13, h: 45)
        case .codex:  return OKLCH(l: 0.30, c: 0.01, h: 260)
        case .gemini: return OKLCH(l: 0.62, c: 0.20, h: 255)
        // OpenCode violet — h≈285 is in the purple-pink region, more
        // saturated than Antigravity's blue-violet to keep them
        // visually distinct in the per-provider segmented control.
        case .opencode: return OKLCH(l: 0.55, c: 0.18, h: 295)
        case .openrouter: return OKLCH(l: 0.58, c: 0.18, h: 265)
        case .cursor: return OKLCH(l: 0.34, c: 0.02, h: 260)
        case .grok: return OKLCH(l: 0.50, c: 0.12, h: 155)
        }
    }

    public var glow: OKLCH {
        switch self {
        case .claude: return OKLCH(l: 0.83, c: 0.10, h: 50)
        case .codex:  return OKLCH(l: 0.55, c: 0.02, h: 260)
        case .gemini: return OKLCH(l: 0.78, c: 0.18, h: 250)
        case .opencode: return OKLCH(l: 0.75, c: 0.16, h: 295)
        case .openrouter: return OKLCH(l: 0.76, c: 0.16, h: 265)
        case .cursor: return OKLCH(l: 0.72, c: 0.02, h: 260)
        case .grok: return OKLCH(l: 0.78, c: 0.13, h: 155)
        }
    }

    public var deep: OKLCH {
        switch self {
        case .claude: return OKLCH(l: 0.48, c: 0.14, h: 35)
        case .codex:  return OKLCH(l: 0.12, c: 0.01, h: 260)
        case .gemini: return OKLCH(l: 0.45, c: 0.22, h: 265)
        case .opencode: return OKLCH(l: 0.38, c: 0.20, h: 295)
        case .openrouter: return OKLCH(l: 0.42, c: 0.20, h: 265)
        case .cursor: return OKLCH(l: 0.18, c: 0.02, h: 260)
        case .grok: return OKLCH(l: 0.34, c: 0.15, h: 165)
        }
    }

    /// Outer-glow halo color — Claude warm orange, Codex OpenAI cool blue,
    /// Antigravity vivid violet, OpenCode magenta-violet.
    public var halo: OKLCH {
        switch self {
        case .claude: return OKLCH(l: 0.78, c: 0.16, h: 50)
        case .codex:  return OKLCH(l: 0.70, c: 0.16, h: 235)
        case .gemini: return OKLCH(l: 0.72, c: 0.22, h: 285)
        case .opencode: return OKLCH(l: 0.72, c: 0.20, h: 305)
        case .openrouter: return OKLCH(l: 0.72, c: 0.20, h: 265)
        case .cursor: return OKLCH(l: 0.76, c: 0.03, h: 260)
        case .grok: return OKLCH(l: 0.76, c: 0.16, h: 155)
        }
    }

    /// Filename of the brand logo asset bundled in the Tahoe.xcassets.
    public var logoAssetName: String {
        switch self {
        case .claude: return "tahoe-claude-mark"
        case .codex:  return "tahoe-codex-mark"
        case .gemini: return "tahoe-antigravity-mark"
        // PR #31: bundled asset added separately; until art lands,
        // TahoeProviderGlyph falls back to AgentKindUI.assetName which
        // points at "OpencodeLogo". Naming kept consistent for the
        // future Tahoe-art swap.
        case .opencode: return "tahoe-opencode-mark"
        case .openrouter: return "tahoe-openrouter-mark"
        case .cursor: return "tahoe-cursor-mark"
        case .grok: return "tahoe-grok-mark"
        }
    }

    /// True for marks whose native colors don't read against dark tiles —
    /// these get a brightness(0) invert(1) treatment in dark mode.
    public var monochromeInDark: Bool {
        switch self {
        case .claude, .codex: return true
        case .gemini:         return false
        case .opencode:       return true
        case .openrouter:     return true
        case .cursor:         return true
        case .grok:           return true
        }
    }
}

public extension TahoeProvider {
    init(analyticsProvider provider: UsageRecord.Provider) {
        switch provider {
        case .claude:   self = .claude
        case .codex:    self = .codex
        case .gemini:   self = .gemini
        case .opencode: self = .opencode
        case .cursor:   self = .cursor
        case .grok:     self = .grok
        }
    }
}

public enum TahoeWallpaper: String, CaseIterable, Sendable, Codable, Identifiable {
    case aurora, dawn, graphite, code, studio
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aurora:   return "Aurora — accent-tinted blobs"
        case .dawn:     return "Dawn — warm dusk"
        case .graphite: return "Graphite — neutral fade"
        case .code:     return "Code — striped editor"
        case .studio:   return "Studio — flat"
        }
    }

    /// JSX `isMuted` — wallpapers that should NOT pump saturation through
    /// the glass filter (avoids the teal-sheen artifact).
    public var isMuted: Bool {
        switch self {
        case .graphite, .studio, .code: return true
        case .aurora, .dawn:            return false
        }
    }
}

public enum TahoeAppearance: String, CaseIterable, Sendable, Codable, Identifiable {
    case light, dark
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dark:  return "Quiet Black"
        case .light: return "Quiet White"
        }
    }

    public var settingsLabel: String {
        switch self {
        case .dark:  return "Quiet Black · Dark"
        case .light: return "Quiet White · Light"
        }
    }
}

public enum TahoeSurface: String, CaseIterable, Sendable, Codable, Identifiable {
    case solid, translucent
    public var id: String { rawValue }
}

// MARK: - OKLCH → sRGB

/// A perceptual OKLCH color. Stored as raw triple; converted to SwiftUI
/// `Color` lazily so we can also derive an alpha variant.
public struct OKLCH: Sendable, Hashable {
    public var l: Double
    public var c: Double
    public var h: Double  // degrees

    public init(l: Double, c: Double, h: Double) {
        self.l = l; self.c = c; self.h = h
    }

    public func color(opacity: Double = 1) -> Color {
        let (r, g, b) = OKLCH.toSRGB(l: l, c: c, h: h)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Convenience for sites that want a Color directly.
    public var color: Color { color(opacity: 1) }

    /// OKLCH → sRGB (Ottosson 2020). Returns sRGB in [0, 1].
    public static func toSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        // 1. OKLCH → OKLAB
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let b = c * sin(hr)

        // 2. OKLAB → linear sRGB
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_

        let r =  4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3

        // 3. Linear sRGB → sRGB (gamma)
        func gamma(_ x: Double) -> Double {
            let v = max(0, min(1, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
        }
        return (gamma(r), gamma(g), gamma(bl))
    }
}

/// Tight radius scale (Quiet Black Workbench) — engineered, not bubbly. A hard
/// break from the old 10/18/26 glass radii. Maps onto DESIGN.md's
/// row 4 / button 5 / card 6 / modal 8.
public enum TahoeRadius {
    public static let s: CGFloat = 5   // buttons / small controls (was 10)
    public static let m: CGFloat = 6   // cards / panels (was 18)
    public static let l: CGFloat = 8   // modals / popovers (was 26)
}

public enum TahoeFont {
    public static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
#endif
