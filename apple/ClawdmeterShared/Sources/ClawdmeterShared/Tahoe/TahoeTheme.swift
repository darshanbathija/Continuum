#if canImport(SwiftUI)
import SwiftUI

/// Central observable theme state for the Tahoe 26 redesign. Mirrors the JSX
/// `ThemeProvider` in `project/theme.jsx`: appearance × surface × accent ×
/// wallpaper × glassIntensity × providerFocus, all persisted via @AppStorage
/// and exposed as derived tokens (fg, fg2, hairline, pageBg, glassBlur, …).
///
/// Inject one instance at the App scene root and read it via the
/// `\.tahoeTheme` Environment key.
@MainActor
@Observable
public final class TahoeThemeStore {
    public var appearance: TahoeAppearance {
        didSet { Self.persist(\.appearance, appearance.rawValue) }
    }
    public var surface: TahoeSurface {
        didSet { Self.persist(\.surface, surface.rawValue) }
    }
    public var accent: TahoeAccent {
        didSet { Self.persist(\.accent, accent.rawValue) }
    }
    public var wallpaper: TahoeWallpaper {
        didSet { Self.persist(\.wallpaper, wallpaper.rawValue) }
    }
    public var glassIntensity: Int {
        didSet { Self.persist(\.glassIntensity, glassIntensity) }
    }
    public var providerFocus: TahoeProvider {
        didSet { Self.persist(\.providerFocus, providerFocus.rawValue) }
    }

    public init(
        appearance: TahoeAppearance = .dark,
        surface: TahoeSurface = .translucent,
        accent: TahoeAccent = .halo,
        wallpaper: TahoeWallpaper = .graphite,
        glassIntensity: Int = 95,
        providerFocus: TahoeProvider = .claude
    ) {
        self.appearance = appearance
        self.surface = surface
        self.accent = accent
        self.wallpaper = wallpaper
        self.glassIntensity = glassIntensity
        self.providerFocus = providerFocus
    }

    /// Load from UserDefaults; falls back to JSX TWEAK_DEFAULTS.
    public static func loaded() -> TahoeThemeStore {
        let d = UserDefaults.standard
        return TahoeThemeStore(
            appearance:     TahoeAppearance(rawValue: d.string(forKey: Self.key(\.appearance)) ?? "") ?? .dark,
            surface:        TahoeSurface(rawValue: d.string(forKey: Self.key(\.surface)) ?? "") ?? .translucent,
            accent:         TahoeAccent(rawValue: d.string(forKey: Self.key(\.accent)) ?? "") ?? .halo,
            wallpaper:      TahoeWallpaper(rawValue: d.string(forKey: Self.key(\.wallpaper)) ?? "") ?? .graphite,
            glassIntensity: d.object(forKey: Self.key(\.glassIntensity)) as? Int ?? 95,
            providerFocus:  TahoeProvider(rawValue: d.string(forKey: Self.key(\.providerFocus)) ?? "") ?? .claude
        )
    }

    private static func key<V>(_ kp: KeyPath<TahoeThemeStore, V>) -> String {
        switch kp {
        case \.appearance:     return "tahoe.appearance"
        case \.surface:        return "tahoe.surface"
        case \.accent:         return "tahoe.accent"
        case \.wallpaper:      return "tahoe.wallpaper"
        case \.glassIntensity: return "tahoe.glassIntensity"
        case \.providerFocus:  return "tahoe.providerFocus"
        default:               return "tahoe.unknown"
        }
    }

    private static func persist<V>(_ kp: KeyPath<TahoeThemeStore, V>, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key(kp))
    }

    /// Reset every persisted theme property back to its JSX default. Used
    /// by the Settings header "Reset to defaults" ghost button.
    public func resetToDefaults() {
        appearance = .dark
        surface = .translucent
        accent = .halo
        wallpaper = .graphite
        glassIntensity = 95
        providerFocus = .claude
    }
}

/// A snapshot of derived tokens computed from `TahoeThemeStore`. Views read
/// these via `@Environment(\.tahoeTokens)` — they're a value type so SwiftUI
/// diffs them cleanly per render pass.
public struct TahoeTokens: Equatable, Sendable {
    public var dark: Bool
    public var translucent: Bool
    public var muted: Bool

    public var accentBase: OKLCH
    public var accentDeep: OKLCH
    public var accentGlow: OKLCH

    public var provider: TahoeProvider
    public var providerColor: OKLCH
    public var providerGlow: OKLCH

    // Foreground stack (alpha varies by tier)
    public var fg: Color
    public var fg2: Color
    public var fg3: Color
    public var fg4: Color
    public var fgInv: Color

    // Hairlines & surfaces
    public var hairline: Color
    public var hair2: Color
    public var pageBg: Color
    public var surfaceSolid: Color
    public var surfaceSolid2: Color

    // Glass
    public var glassBlur: Double
    public var glassSaturate: Double  // 0..2 multiplier
    public var glassTint: Color
    public var glassTintHi: Color
    public var glassRing: Color
    public var glassInner: Color

    // Wallpaper
    public var wallpaper: TahoeWallpaper

    @MainActor
    public static func make(from store: TahoeThemeStore) -> TahoeTokens {
        let dark = store.appearance == .dark
        let translucent = store.surface == .translucent
        let muted = store.wallpaper.isMuted
        let intensity = max(0, min(100, Double(store.glassIntensity))) / 100.0
        // Match JSX: blur 8..44, saturate 100 (muted) | 110..210 (lively), tintMul 0.5..1.2
        let blur = 8 + intensity * 36
        let sat: Double = muted ? 1.0 : (1.1 + intensity * 1.0)
        let tintMul = 0.5 + intensity * 0.7

        let fgBase   = dark ? Color(.sRGB, white: 1.0, opacity: 0.96) : Color(.sRGB, white: 15.0/255, opacity: 0.95)
        let fg2Base  = dark ? Color(.sRGB, white: 1.0, opacity: 0.72) : Color(.sRGB, white: 15.0/255, opacity: 0.66)
        let fg3Base  = dark ? Color(.sRGB, white: 1.0, opacity: 0.48) : Color(.sRGB, white: 15.0/255, opacity: 0.46)
        let fg4Base  = dark ? Color(.sRGB, white: 1.0, opacity: 0.28) : Color(.sRGB, white: 15.0/255, opacity: 0.26)
        let fgInv    = dark ? Color(.sRGB, red: 10.0/255, green: 10.0/255, blue: 12.0/255) : Color.white

        let hairline = dark ? Color(.sRGB, white: 1.0, opacity: 0.10) : Color(.sRGB, white: 15.0/255, opacity: 0.10)
        let hair2    = dark ? Color(.sRGB, white: 1.0, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.06)

        let pageBg        = dark ? Color.black : Color(.sRGB, red: 244.0/255, green: 246.0/255, blue: 250.0/255)
        let surfaceSolid  = dark ? Color(.sRGB, red: 13.0/255, green: 14.0/255, blue: 17.0/255) : Color.white
        let surfaceSolid2 = dark ? Color(.sRGB, red: 21.0/255, green: 23.0/255, blue: 27.0/255) : Color(.sRGB, red: 247.0/255, green: 248.0/255, blue: 251.0/255)

        let tintOpacity   = (dark ? 0.06 : 0.45) * tintMul
        let tintHiOpacity = (dark ? 0.10 : 0.55) * tintMul
        let glassTint   = Color(.sRGB, white: 1.0, opacity: tintOpacity)
        let glassTintHi = Color(.sRGB, white: 1.0, opacity: tintHiOpacity)
        let glassRing   = dark ? Color(.sRGB, white: 1.0, opacity: 0.18) : Color(.sRGB, white: 1.0, opacity: 0.7)
        let glassInner  = dark ? Color(.sRGB, white: 1.0, opacity: 0.10) : Color(.sRGB, white: 1.0, opacity: 0.6)

        return TahoeTokens(
            dark: dark, translucent: translucent, muted: muted,
            accentBase: store.accent.base, accentDeep: store.accent.deep, accentGlow: store.accent.glow,
            provider: store.providerFocus,
            providerColor: store.providerFocus.base, providerGlow: store.providerFocus.glow,
            fg: fgBase, fg2: fg2Base, fg3: fg3Base, fg4: fg4Base, fgInv: fgInv,
            hairline: hairline, hair2: hair2,
            pageBg: pageBg, surfaceSolid: surfaceSolid, surfaceSolid2: surfaceSolid2,
            glassBlur: blur, glassSaturate: sat,
            glassTint: glassTint, glassTintHi: glassTintHi,
            glassRing: glassRing, glassInner: glassInner,
            wallpaper: store.wallpaper
        )
    }

    /// Convenience accent color helpers.
    public var accent: Color      { accentBase.color }
    public var accentDeepC: Color { accentDeep.color }
    public var accentGlowC: Color { accentGlow.color }

    /// `oklchAlpha(accent, a)` in JSX.
    public func accentAlpha(_ a: Double) -> Color { accentBase.color(opacity: a) }
}

// MARK: - Environment plumbing

private struct TahoeThemeStoreKey: EnvironmentKey {
    @MainActor static var defaultValue: TahoeThemeStore? = nil
}

private struct TahoeTokensKey: EnvironmentKey {
    // Plain-value default to avoid main-actor isolation crossing in the
    // protocol conformance. Real values are injected via `.tahoeTheme(_)`.
    static let defaultValue: TahoeTokens = TahoeTokens(
        dark: true, translucent: true, muted: true,
        accentBase: OKLCH(l: 0.78, c: 0.16, h: 220),
        accentDeep: OKLCH(l: 0.55, c: 0.20, h: 250),
        accentGlow: OKLCH(l: 0.88, c: 0.13, h: 205),
        provider: .claude,
        providerColor: OKLCH(l: 0.72, c: 0.13, h: 45),
        providerGlow: OKLCH(l: 0.83, c: 0.10, h: 50),
        fg: Color(.sRGB, white: 1, opacity: 0.96),
        fg2: Color(.sRGB, white: 1, opacity: 0.72),
        fg3: Color(.sRGB, white: 1, opacity: 0.48),
        fg4: Color(.sRGB, white: 1, opacity: 0.28),
        fgInv: Color(.sRGB, red: 10.0/255, green: 10.0/255, blue: 12.0/255),
        hairline: Color(.sRGB, white: 1, opacity: 0.10),
        hair2: Color(.sRGB, white: 1, opacity: 0.06),
        pageBg: .black,
        surfaceSolid: Color(.sRGB, red: 13.0/255, green: 14.0/255, blue: 17.0/255),
        surfaceSolid2: Color(.sRGB, red: 21.0/255, green: 23.0/255, blue: 27.0/255),
        glassBlur: 42, glassSaturate: 1.0,
        glassTint: Color(.sRGB, white: 1, opacity: 0.06),
        glassTintHi: Color(.sRGB, white: 1, opacity: 0.10),
        glassRing: Color(.sRGB, white: 1, opacity: 0.18),
        glassInner: Color(.sRGB, white: 1, opacity: 0.10),
        wallpaper: .graphite
    )
}

extension EnvironmentValues {
    public var tahoeTheme: TahoeThemeStore? {
        get { self[TahoeThemeStoreKey.self] }
        set { self[TahoeThemeStoreKey.self] = newValue }
    }

    public var tahoe: TahoeTokens {
        get { self[TahoeTokensKey.self] }
        set { self[TahoeTokensKey.self] = newValue }
    }
}

/// A View-modifier that injects both the store and the derived tokens, and
/// applies `preferredColorScheme` for the Tahoe appearance choice. Use at
/// the root of every Mac window / iOS Scene.
public struct TahoeThemeApplied: ViewModifier {
    public var store: TahoeThemeStore

    public init(store: TahoeThemeStore) { self.store = store }

    public func body(content: Content) -> some View {
        let tokens = TahoeTokens.make(from: store)
        content
            .environment(\.tahoeTheme, store)
            .environment(\.tahoe, tokens)
            .preferredColorScheme(store.appearance == .dark ? .dark : .light)
    }
}

extension View {
    public func tahoeTheme(_ store: TahoeThemeStore) -> some View {
        modifier(TahoeThemeApplied(store: store))
    }
}
#endif
