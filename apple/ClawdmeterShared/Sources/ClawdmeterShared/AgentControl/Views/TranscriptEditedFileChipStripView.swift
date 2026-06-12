#if canImport(SwiftUI)
import SwiftUI

/// Compact file chip for inline edit rows in the Code tab chat body.
/// Shows a language-aware icon + basename inside a rounded pill.
public struct TranscriptEditedFileChip: View {
    public let filePath: String

    public init(filePath: String) {
        self.filePath = filePath
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: TranscriptEditedFileIcon.symbol(for: filePath))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TranscriptEditedFileIcon.tint(for: filePath))
                .frame(width: 14, height: 14)
            Text(basename)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Color.secondary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var basename: String {
        let last = (filePath as NSString).lastPathComponent
        return last.isEmpty ? filePath : last
    }
}

/// Green/red `+N -M` pair shown beside every edit row in the chat body.
/// Always renders both halves — a zero deletion count shows as `-0`.
public struct EditDiffDeltaCounts: View {
    public let additions: Int
    public let deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)")
                .foregroundStyle(Self.additionsColor)
            Text("-\(deletions)")
                .foregroundStyle(Self.deletionsColor)
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
    }

    public static let additionsColor = Color(
        red: 0x52 / 255.0, green: 0xC4 / 255.0, blue: 0x1A / 255.0
    )
    public static let deletionsColor = Color(
        red: 0xE6 / 255.0, green: 0x4B / 255.0, blue: 0x4B / 255.0
    )
}

public enum TranscriptEditedFileIcon {
    public static func symbol(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown": return "doc.richtext"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        default: return "doc.text"
        }
    }

    public static func tint(for path: String) -> Color {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return Color(red: 0xF0 / 255.0, green: 0x59 / 255.0, blue: 0x2B / 255.0)
        case "ts", "tsx": return Color(red: 0x31 / 255.0, green: 0x78 / 255.0, blue: 0xC6 / 255.0)
        case "py": return Color(red: 0x37 / 255.0, green: 0x7C / 255.0, blue: 0xA8 / 255.0)
        default: return .secondary
        }
    }
}

public enum TranscriptEditedFileFormatting {
    /// `+2 -0` label for turn-summary chips and accessibility strings.
    public static func deltaLabel(additions: Int, deletions: Int) -> String {
        "+\(additions) -\(deletions)"
    }
}
#endif
