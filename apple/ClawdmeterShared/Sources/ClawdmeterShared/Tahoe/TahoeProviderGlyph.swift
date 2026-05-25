#if canImport(SwiftUI)
import SwiftUI

/// Rounded-square tile rendering the actual provider brand mark, with a
/// brand-tinted outer halo. Ports JSX `ProviderGlyph`.
///
/// Dark mode treatment: tile is dark `#1a1b1f`, and Claude/Codex marks are
/// rendered monochrome white (their native colors don't read on dark);
/// Antigravity keeps its gradient color since it's the brand's defining
/// feature.
public struct TahoeProviderGlyph: View {
    @Environment(\.tahoe) private var t
    public var provider: TahoeProvider
    public var size: CGFloat

    public init(provider: TahoeProvider, size: CGFloat = 22) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        let isFocused = provider == t.provider
        let haloOpacity = isFocused ? 0.65 : 0.40
        let haloRadius = size * (isFocused ? 0.48 : 0.36)
        let tileColor = t.dark ? Color(.sRGB, red: 26.0/255, green: 27.0/255, blue: 31.0/255) : Color.white
        let monochromize = t.dark && provider.monochromeInDark
        let imageRadius = size * 0.24

        ZStack {
            RoundedRectangle(cornerRadius: imageRadius, style: .continuous)
                .fill(tileColor)
            Rectangle()
                .fill(Color.clear)
                .overlay {
                    providerImage(monochromize: monochromize)
                        .frame(width: size * 0.78, height: size * 0.78)
                }
                .frame(width: size * 0.78, height: size * 0.78)
                .clipped()
        }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: imageRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: imageRadius, style: .continuous)
                    .stroke(t.dark ? Color(.sRGB, white: 1, opacity: 0.10)
                                   : Color(.sRGB, white: 0, opacity: 0.08),
                            lineWidth: 0.5)
            }
            .shadow(color: t.dark ? Color.black.opacity(0.45) : Color.black.opacity(0.12),
                    radius: 2, x: 0, y: 1)
            .shadow(color: provider.halo.color(opacity: haloOpacity),
                    radius: haloRadius, x: 0, y: 0)
    }

    @ViewBuilder
    private func providerImage(monochromize: Bool) -> some View {
        if monochromize {
            Image(provider.logoAssetName, bundle: .module)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
        } else {
            Image(provider.logoAssetName, bundle: .module)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }
}

/// Small rounded-square tile with a single letter, tinted per-repo. Used in
/// the repo lists (sidebar + iOS).
public struct TahoeProjectGlyph: View {
    @Environment(\.tahoe) private var t
    public var name: String
    public var tint: OKLCH
    public var size: CGFloat

    public init(name: String, tint: OKLCH, size: CGFloat = 22) {
        self.name = name
        self.tint = tint
        self.size = size
    }

    private var letter: String {
        let trimmed = name.filter { $0.isLetter || $0.isNumber }
        return String(trimmed.first ?? "?").uppercased()
    }

    public var body: some View {
        let bumped = OKLCH(l: min(tint.l + 0.10, 1.0), c: tint.c, h: tint.h).color
        let base = tint.color
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [bumped, base],
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Text(letter)
                    .font(TahoeFont.rounded(size * 0.5, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(tint.color(opacity: 0.55), lineWidth: 0.5)
            }
    }
}
#endif
