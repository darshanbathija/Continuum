#if canImport(SwiftUI)
import SwiftUI

/// Rounded pill showing a file's technology-stack logo and basename —
/// matches the Cursor agent transcript file chips (`🟠 AppModel.swift`).
public struct FilePathChip: View {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    private var basename: String {
        (path as NSString).lastPathComponent
    }

    public var body: some View {
        HStack(spacing: 5) {
            TechStackIconView(path: path, size: 12)
            Text(basename)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.14), in: Capsule(style: .continuous))
        .accessibilityLabel(basename)
    }
}
#endif
