#if canImport(SwiftUI)
import SwiftUI

/// Monogram tile for a user-configured custom provider — follows the
/// `TahoeProviderGlyph` recipe (surface2 fill, hairline stroke).
public struct CustomProviderGlyph: View {
    public var label: String
    public var size: CGFloat

    public init(label: String, size: CGFloat = 22) {
        self.label = label
        self.size = size
    }

    private var monogram: String {
        let trimmed = label.filter { $0.isLetter || $0.isNumber }
        if let first = trimmed.first {
            return String(first).uppercased()
        }
        return ""
    }

    public var body: some View {
        let imageRadius = size * 0.24
        ZStack {
            RoundedRectangle(cornerRadius: imageRadius, style: .continuous)
                .fill(ContinuumTokens.surface2)
            if monogram.isEmpty {
                Image(systemName: "server.rack")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(ContinuumTokens.fg2)
            } else {
                Text(monogram)
                    .font(ContinuumFont.display(size * 0.46, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(ContinuumTokens.fg)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: imageRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: imageRadius, style: .continuous)
                .strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5)
        }
    }
}

/// Deterministic accent hue for a custom provider id — avoids built-in
/// provider hues so dots stay visually distinct in broadcast rows.
public enum CustomProviderAccent {
    /// Reserved hues that do not overlap TahoeProvider.base hues (45, 155,
    /// 255, 260, 295).
    private static let reservedHues: [Double] = [10, 20, 75, 90, 120, 180, 210, 330, 350, 15]

    public static func dot(for providerId: String) -> Color {
        dotOKLCH(for: providerId).color
    }

    public static func dotOKLCH(for providerId: String) -> OKLCH {
        let hash = providerId.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) }
        let hue = reservedHues[abs(hash) % reservedHues.count]
        return OKLCH(l: 0.58, c: 0.16, h: hue)
    }
}

public struct CustomProviderDot: View {
    public var providerId: String
    public var size: CGFloat

    public init(_ providerId: String, size: CGFloat = 6) {
        self.providerId = providerId
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(CustomProviderAccent.dot(for: providerId))
            .frame(width: size, height: size)
    }
}

/// Switcher that renders either a built-in or custom provider glyph.
public struct AnyProviderGlyph: View {
    public var choice: ProviderChoice
    public var catalog: ModelCatalog
    public var size: CGFloat

    public init(choice: ProviderChoice, catalog: ModelCatalog, size: CGFloat = 22) {
        self.choice = choice
        self.catalog = catalog
        self.size = size
    }

    public var body: some View {
        switch choice {
        case .builtin(let vendor):
            TahoeProviderGlyph(provider: vendor.tahoeProvider, size: size)
        case .custom(let providerId):
            CustomProviderGlyph(
                label: choice.displayName(in: catalog),
                size: size
            )
            .accessibilityLabel(choice.displayName(in: catalog))
            .accessibilityIdentifier("provider.glyph.custom.\(providerId)")
        case .opencodePartner(let partnerId):
            OpenCodeProviderLogoView(
                providerId: partnerId,
                fallbackLabel: choice.displayName(in: catalog),
                size: size
            )
            .accessibilityLabel(choice.displayName(in: catalog))
            .accessibilityIdentifier("provider.glyph.opencode-partner.\(partnerId)")
        }
    }
}
#endif
