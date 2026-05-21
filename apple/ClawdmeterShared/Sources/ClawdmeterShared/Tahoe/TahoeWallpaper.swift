#if canImport(SwiftUI)
import SwiftUI

/// JSX `WallpaperLayer` + `WallpaperOrbs` — the layered radial+linear
/// gradient backdrop that sits behind every glass surface so the Liquid Glass
/// has something interesting to refract.
public struct TahoeWallpaperView: View {
    @Environment(\.tahoe) private var t

    public init() {}

    public var body: some View {
        ZStack {
            wallpaperBase
            if !t.wallpaper.isMuted {
                wallpaperOrbs
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Base wallpaper

    @ViewBuilder
    private var wallpaperBase: some View {
        switch t.wallpaper {
        case .aurora:    AuroraWallpaper(dark: t.dark)
        case .dawn:      DawnWallpaper(dark: t.dark)
        case .graphite:  GraphiteWallpaper(dark: t.dark)
        case .code:      CodeWallpaper(dark: t.dark)
        case .studio:    StudioWallpaper(dark: t.dark)
        }
    }

    @ViewBuilder
    private var wallpaperOrbs: some View {
        Canvas { ctx, size in
            // Orb A — accent glow, top-left-ish.
            let orbA = Path(ellipseIn: CGRect(
                x: size.width * 0.22 - size.width * 0.26,
                y: size.height * 0.20 - size.height * 0.22,
                width: size.width * 0.52, height: size.height * 0.44))
            ctx.fill(orbA, with: .radialGradient(
                Gradient(stops: [
                    .init(color: t.accentGlowC.opacity(t.dark ? 0.45 : 0.50), location: 0),
                    .init(color: t.accentGlowC.opacity(0), location: 1),
                ]),
                center: CGPoint(x: size.width * 0.22, y: size.height * 0.20),
                startRadius: 0, endRadius: max(size.width, size.height) * 0.3))

            // Orb B — pink/violet glow, bottom-right.
            let pink = OKLCH(l: 0.78, c: 0.16, h: 320).color
            let orbB = Path(ellipseIn: CGRect(
                x: size.width * 0.86 - size.width * 0.30,
                y: size.height * 0.78 - size.height * 0.24,
                width: size.width * 0.60, height: size.height * 0.48))
            ctx.fill(orbB, with: .radialGradient(
                Gradient(stops: [
                    .init(color: pink.opacity(t.dark ? 0.30 : 0.40), location: 0),
                    .init(color: pink.opacity(0), location: 1),
                ]),
                center: CGPoint(x: size.width * 0.86, y: size.height * 0.78),
                startRadius: 0, endRadius: max(size.width, size.height) * 0.34))
        }
    }
}

// MARK: - Per-wallpaper backdrops (port of `wallpaperCSS`)

private struct AuroraWallpaper: View {
    let dark: Bool
    var body: some View {
        ZStack {
            (dark ? Color(.sRGB, red: 6.0/255, green: 8.0/255, blue: 13.0/255)
                  : Color(.sRGB, red: 244.0/255, green: 247.0/255, blue: 251.0/255))
            // 3 stacked radial gradients via Canvas (matches JSX layering)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    radial(color: dark ? OKLCH(l: 0.32, c: 0.10, h: 250).color
                                       : OKLCH(l: 0.94, c: 0.06, h: 220).color,
                           opacity: dark ? 0.55 : 0.55,
                           cx: w * 0.18, cy: h * 0.12, r: max(w, h) * 0.55)
                    radial(color: dark ? OKLCH(l: 0.30, c: 0.09, h: 200).color
                                       : OKLCH(l: 0.96, c: 0.05, h: 60).color,
                           opacity: dark ? 0.50 : 0.50,
                           cx: w * 0.88, cy: h * 0.18, r: max(w, h) * 0.50)
                    radial(color: dark ? OKLCH(l: 0.28, c: 0.11, h: 320).color
                                       : OKLCH(l: 0.95, c: 0.06, h: 320).color,
                           opacity: dark ? 0.55 : 0.50,
                           cx: w * 0.50, cy: h * 0.95, r: max(w, h) * 0.60)
                }
            }
        }
    }
}

private struct DawnWallpaper: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: [
                dark ? Color(.sRGB, red: 7.0/255,  green: 7.0/255,  blue: 14.0/255)
                     : Color(.sRGB, red: 254.0/255, green: 246.0/255, blue: 238.0/255),
                dark ? Color(.sRGB, red: 14.0/255, green: 10.0/255, blue: 8.0/255)
                     : Color(.sRGB, red: 246.0/255, green: 239.0/255, blue: 232.0/255),
            ], startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    radial(color: dark ? OKLCH(l: 0.30, c: 0.10, h: 35).color
                                       : OKLCH(l: 0.92, c: 0.10, h: 35).color,
                           opacity: 0.55, cx: w * 0.50, cy: h, r: max(w, h) * 0.7)
                    radial(color: dark ? OKLCH(l: 0.24, c: 0.07, h: 280).color
                                       : OKLCH(l: 0.94, c: 0.07, h: 280).color,
                           opacity: 0.55, cx: w * 0.30, cy: h * 0.27, r: max(w, h) * 0.6)
                }
            }
        }
    }
}

private struct GraphiteWallpaper: View {
    let dark: Bool
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                (dark ? Color(.sRGB, red: 8.0/255, green: 8.0/255, blue: 8.0/255)
                      : Color(.sRGB, red: 214.0/255, green: 214.0/255, blue: 214.0/255))
                radial(color: dark ? Color(.sRGB, white: 31.0/255, opacity: 1.0)
                                   : Color.white,
                       opacity: 1.0,
                       cx: w * 0.50, cy: 0, r: max(w, h) * 0.7)
            }
        }
    }
}

private struct CodeWallpaper: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: [
                dark ? Color(.sRGB, red: 14.0/255, green: 17.0/255, blue: 22.0/255)
                     : Color(.sRGB, red: 251.0/255, green: 252.0/255, blue: 254.0/255),
                dark ? Color(.sRGB, red: 6.0/255,  green: 8.0/255,  blue: 11.0/255)
                     : Color(.sRGB, red: 238.0/255, green: 242.0/255, blue: 247.0/255),
            ], startPoint: .top, endPoint: .bottom)
            // Striped editor backdrop (22px stripes, very subtle)
            Canvas { ctx, size in
                let stripeColor = dark ? Color(.sRGB, white: 1.0, opacity: 0.012)
                                       : Color(.sRGB, white: 0.0, opacity: 0.025)
                var y: CGFloat = 22
                while y < size.height {
                    let rect = Path(CGRect(x: 0, y: y, width: size.width, height: 1))
                    ctx.fill(rect, with: .color(stripeColor))
                    y += 23
                }
            }
        }
    }
}

private struct StudioWallpaper: View {
    let dark: Bool
    var body: some View {
        LinearGradient(colors: [
            dark ? Color(.sRGB, red: 26.0/255, green: 26.0/255, blue: 31.0/255)
                 : Color(.sRGB, red: 242.0/255, green: 242.0/255, blue: 245.0/255),
            dark ? Color(.sRGB, red: 10.0/255, green: 10.0/255, blue: 13.0/255)
                 : Color(.sRGB, red: 228.0/255, green: 228.0/255, blue: 234.0/255),
        ], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Helpers

@ViewBuilder
private func radial(color: Color, opacity: Double, cx: CGFloat, cy: CGFloat, r: CGFloat) -> some View {
    GeometryReader { geo in
        Canvas { ctx, size in
            let path = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.fill(path, with: .radialGradient(
                Gradient(stops: [
                    .init(color: color.opacity(opacity), location: 0),
                    .init(color: color.opacity(0), location: 1),
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: 0, endRadius: r))
            _ = size
        }
    }
}
#endif
