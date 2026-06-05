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
        // DARK-ONLY (Quiet Black Workbench): the appearance / surface /
        // wallpaper / glassIntensity knobs are dead — every value now reads
        // from `ContinuumTokens`, the single source of truth. Glass is gone, so
        // the glass* fields collapse to flat values (tint/inner → clear,
        // blur → 0). `accent*` keeps the Claude terra-cotta OKLCH so legacy
        // `t.accent` sites resolve to the Claude provider dot; those sites are
        // rationed away per-surface during the migration.
        TahoeTokens(
            dark: true, translucent: false, muted: true,
            accentBase: TahoeProvider.claude.base,
            accentDeep: TahoeProvider.claude.deep,
            accentGlow: TahoeProvider.claude.glow,
            provider: store.providerFocus,
            providerColor: store.providerFocus.base,
            providerGlow: store.providerFocus.glow,
            fg: ContinuumTokens.fg, fg2: ContinuumTokens.fg2,
            fg3: ContinuumTokens.fg3, fg4: ContinuumTokens.fg4,
            fgInv: ContinuumTokens.primaryText,
            hairline: ContinuumTokens.hairline, hair2: ContinuumTokens.hairline2,
            pageBg: ContinuumTokens.bg,
            surfaceSolid: ContinuumTokens.surface1,
            surfaceSolid2: ContinuumTokens.surface2,
            glassBlur: 0, glassSaturate: 1,
            glassTint: Color.clear, glassTintHi: Color.clear,
            glassRing: ContinuumTokens.hairline, glassInner: Color.clear,
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
        dark: true, translucent: false, muted: true,
        accentBase: TahoeProvider.claude.base,
        accentDeep: TahoeProvider.claude.deep,
        accentGlow: TahoeProvider.claude.glow,
        provider: .claude,
        providerColor: TahoeProvider.claude.base,
        providerGlow: TahoeProvider.claude.glow,
        fg: ContinuumTokens.fg, fg2: ContinuumTokens.fg2,
        fg3: ContinuumTokens.fg3, fg4: ContinuumTokens.fg4,
        fgInv: ContinuumTokens.primaryText,
        hairline: ContinuumTokens.hairline, hair2: ContinuumTokens.hairline2,
        pageBg: ContinuumTokens.bg,
        surfaceSolid: ContinuumTokens.surface1,
        surfaceSolid2: ContinuumTokens.surface2,
        glassBlur: 0, glassSaturate: 1.0,
        glassTint: Color.clear, glassTintHi: Color.clear,
        glassRing: ContinuumTokens.hairline, glassInner: Color.clear,
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

    /// Canonical Continuum accessor. Forwards to the same token bag as
    /// `\.tahoe` (kept as a deprecated alias during the migration). New code
    /// reads `@Environment(\.theme) var t`.
    public var theme: TahoeTokens {
        get { self[TahoeTokensKey.self] }
        set { self[TahoeTokensKey.self] = newValue }
    }
}

/// Continuum token convenience accessors on the `\.theme` / `\.tahoe` facade —
/// the new Quiet Black tokens that the legacy `TahoeTokens` struct didn't
/// carry. These forward to `ContinuumTokens` so every view reaches the full
/// palette through `t`.
extension TahoeTokens {
    public var bg: Color { ContinuumTokens.bg }
    public var surface1: Color { ContinuumTokens.surface1 }
    public var surface2: Color { ContinuumTokens.surface2 }
    public var surface3: Color { ContinuumTokens.surface3 }
    public var modal: Color { ContinuumTokens.modal }
    public var hairlineToken: Color { ContinuumTokens.hairline }
    public var hover: Color { ContinuumTokens.hover }
    public var pressed: Color { ContinuumTokens.pressed }
    public var selection: Color { ContinuumTokens.selection }
    public var focus: Color { ContinuumTokens.focus }
    public var primaryFill: Color { ContinuumTokens.primaryFill }
    public var primaryText: Color { ContinuumTokens.primaryText }
    public var live: Color { ContinuumTokens.live }
    public var warn: Color { ContinuumTokens.warn }
    public var error: Color { ContinuumTokens.error }
    public var paused: Color { ContinuumTokens.paused }
    /// Provider dot color (rationed color signal).
    public func providerDot(_ provider: TahoeProvider) -> Color { provider.dot }
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
            // Dark-only v1 (Quiet Black Workbench) — the appearance toggle is gone.
            .preferredColorScheme(.dark)
    }
}

extension View {
    public func tahoeTheme(_ store: TahoeThemeStore) -> some View {
        modifier(TahoeThemeApplied(store: store))
    }
}
#endif
