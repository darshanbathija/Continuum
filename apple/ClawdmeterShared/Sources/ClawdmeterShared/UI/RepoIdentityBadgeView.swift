#if canImport(SwiftUI)
import SwiftUI

public struct RepoIdentityBadgeView: View {
    @Environment(\.tahoe) private var t
    public let badge: RepoIdentityBadge
    public let size: CGFloat

    public init(badge: RepoIdentityBadge, size: CGFloat = 22) {
        self.badge = badge
        self.size = size
    }

    public var body: some View {
        let tint = Color.repoIdentityHex(badge.colorHex)
        RoundedRectangle(cornerRadius: max(5, size * 0.28), style: .continuous)
            .fill(tint.opacity(t.dark ? 0.28 : 0.18))
            .overlay(
                RoundedRectangle(cornerRadius: max(5, size * 0.28), style: .continuous)
                    .stroke(tint.opacity(t.dark ? 0.48 : 0.38), lineWidth: 0.7)
            )
            .overlay(
                iconContent(tint: tint)
            )
            .frame(width: size, height: size)
            .accessibilityLabel("Repository \(badge.displayName)")
            .help(badge.remoteSlug.map { "\($0) on \(badge.remoteHost ?? "remote")" } ?? badge.displayName)
    }

    @ViewBuilder
    private func iconContent(tint: Color) -> some View {
        if let raw = badge.iconURL, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    fallbackIcon(tint: tint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous))
        } else {
            fallbackIcon(tint: tint)
        }
    }

    private func fallbackIcon(tint: Color) -> some View {
        Text(badge.emoji ?? badge.symbol)
            .font(TahoeFont.body(max(9, size * 0.42), weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
    }
}

private extension Color {
    static func repoIdentityHex(_ raw: String) -> Color {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard text.count == 6,
              let value = UInt64(text, radix: 16)
        else {
            return .secondary
        }
        let red = Double((value >> 16) & 0xff) / 255.0
        let green = Double((value >> 8) & 0xff) / 255.0
        let blue = Double(value & 0xff) / 255.0
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
#endif
