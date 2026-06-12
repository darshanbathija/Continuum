#if canImport(SwiftUI)
import SwiftUI

/// Renders a technology-stack logo beside a file path in the Code tab
/// transcript. Falls back to a muted file glyph when no stack is known.
public struct TechStackIconView: View {
    public let path: String
    public var size: CGFloat

    public init(path: String, size: CGFloat = 14) {
        self.path = path
        self.size = size
    }

    public var body: some View {
        if let asset = TechStackIconCatalog.assetName(forPath: path) {
            Image(asset, bundle: .module)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityLabel(stackAccessibilityLabel)
        } else {
            Image(systemName: "doc")
                .font(.system(size: size * 0.78, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityLabel("File")
        }
    }

    private var stackAccessibilityLabel: String {
        if let slug = TechStackIconCatalog.slug(for: path) {
            return slug.replacingOccurrences(of: "dot", with: ".")
        }
        return "File"
    }
}
#endif
