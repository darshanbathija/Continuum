#if canImport(SwiftUI)
import SwiftUI

/// Rounded-square tile rendering the provider brand mark — **monochrome** for
/// every provider (the dot carries the color, not the glyph). No halo, no glow:
/// Quiet Black rations color to dots/edges/meter fills.
public struct TahoeProviderGlyph: View {
    public var provider: TahoeProvider
    public var size: CGFloat

    public init(provider: TahoeProvider, size: CGFloat = 22) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        let imageRadius = size * 0.24
        ZStack {
            RoundedRectangle(cornerRadius: imageRadius, style: .continuous)
                .fill(ContinuumTokens.surface2)
            Image(provider.logoAssetName, bundle: .module)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(ContinuumTokens.fg)
                .frame(width: size * 0.74, height: size * 0.74)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: imageRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: imageRadius, style: .continuous)
                .strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5)
        }
    }
}

/// A 6px provider dot — the canonical rationed color signal. Always travels
/// with a glyph/label/number per DESIGN.md (never color alone).
public struct ProviderDot: View {
    public var provider: TahoeProvider
    public var size: CGFloat
    public var live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(_ provider: TahoeProvider, size: CGFloat = 6, live: Bool = false) {
        self.provider = provider
        self.size = size
        self.live = live
    }

    public var body: some View {
        Circle()
            .fill(live ? ContinuumTokens.live : provider.dot)
            .frame(width: size, height: size)
            .opacity(live && pulse ? 0.5 : 1)
            .onAppear {
                guard live, let anim = ContinuumMotion.heartbeat(reduceMotion: reduceMotion) else { return }
                withAnimation(anim) { pulse = true }
            }
    }
}

/// A 3px provider edge — a column-top or row-leading identity stripe.
public struct ProviderEdge: View {
    public var provider: TahoeProvider
    public var axis: Axis
    public var thickness: CGFloat

    public init(_ provider: TahoeProvider, axis: Axis = .horizontal, thickness: CGFloat = 3) {
        self.provider = provider
        self.axis = axis
        self.thickness = thickness
    }

    public var body: some View {
        Rectangle()
            .fill(provider.dot)
            .frame(width: axis == .vertical ? thickness : nil,
                   height: axis == .horizontal ? thickness : nil)
    }
}

/// Small rounded-square tile with a single letter, tinted per-repo. Repo
/// identity (not provider/state color) — kept subtle for scannability.
public struct TahoeProjectGlyph: View {
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
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(ContinuumTokens.surface3)
            .frame(width: size, height: size)
            .overlay {
                Text(letter)
                    .font(ContinuumFont.display(size * 0.5, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(ContinuumTokens.fg2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5)
            }
    }
}
#endif
