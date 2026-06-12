#if canImport(SwiftUI)
import SwiftUI

public struct TranscriptEditedFileDetail: Identifiable, Hashable, Sendable {
    public let file: TranscriptEditedFile
    public let stats: EditStats
    public let editDiff: EditDiff?
    public let resultBody: String?

    public var id: String { file.filePath }

    public init(
        file: TranscriptEditedFile,
        stats: EditStats,
        editDiff: EditDiff? = nil,
        resultBody: String? = nil
    ) {
        self.file = file
        self.stats = stats
        self.editDiff = editDiff
        self.resultBody = resultBody
    }
}

public enum TranscriptEditedFileChipStripModel {
    public static let defaultVisibleCount = 4

    public struct OverflowSummary: Equatable, Sendable {
        public let hiddenCount: Int
        public let additions: Int
        public let deletions: Int
    }

    public static func overflowSummary(
        for files: [TranscriptEditedFile],
        visibleCount: Int = defaultVisibleCount
    ) -> OverflowSummary? {
        guard files.count > visibleCount else { return nil }
        let hidden = files.dropFirst(visibleCount)
        return OverflowSummary(
            hiddenCount: hidden.count,
            additions: hidden.reduce(0) { $0 + $1.additions },
            deletions: hidden.reduce(0) { $0 + $1.deletions }
        )
    }

    public static func systemImage(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown": return "doc.richtext"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "html", "htm": return "safari"
        case "sh", "bash", "zsh": return "terminal"
        default: return "doc.text"
        }
    }

    public static func iconTint(for path: String) -> Color {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return Color.orange
        default: return Color.secondary
        }
    }
}

/// End-of-turn chip strip for edited files. Shows the first few files with
/// per-file +N/-M stats, then a `+N more` overflow chip that expands to
/// reveal every edited file and its inline diff preview.
public struct TranscriptEditedFileChipStripView: View {
    public let files: [TranscriptEditedFile]
    public let details: [TranscriptEditedFileDetail]
    public let visibleCount: Int
    public let density: TranscriptDensity

    @State private var showAllFiles = false

    public init(
        turn: TranscriptTurn,
        visibleCount: Int = TranscriptEditedFileChipStripModel.defaultVisibleCount,
        density: TranscriptDensity = .balanced
    ) {
        self.files = turn.editedFiles
        self.details = turn.editFileDetails()
        self.visibleCount = visibleCount
        self.density = density
    }

    public init(
        files: [TranscriptEditedFile],
        details: [TranscriptEditedFileDetail],
        visibleCount: Int = TranscriptEditedFileChipStripModel.defaultVisibleCount,
        density: TranscriptDensity = .balanced
    ) {
        self.files = files
        self.details = details
        self.visibleCount = visibleCount
        self.density = density
    }

    public var body: some View {
        if files.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                chipRow
                if showAllFiles {
                    expandedDiffList
                }
            }
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(files.prefix(visibleCount))) { file in
                    fileChip(file)
                }
                if let overflow = TranscriptEditedFileChipStripModel.overflowSummary(
                    for: files,
                    visibleCount: visibleCount
                ) {
                    Button {
                        showAllFiles.toggle()
                    } label: {
                        moreChip(overflow)
                    }
                    .buttonStyle(.plain)
                    .help(showAllFiles ? "Hide edited files" : "Show all edited files")
                    .accessibilityIdentifier("code.turn.edited-files.more")
                }
            }
        }
    }

    private var expandedDiffList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(details) { detail in
                EditDiffRow(
                    stats: detail.stats,
                    editDiff: detail.editDiff,
                    resultBody: detail.resultBody,
                    density: density
                )
            }
        }
        .padding(.top, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func fileChip(_ file: TranscriptEditedFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: TranscriptEditedFileChipStripModel.systemImage(for: file.filePath))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(TranscriptEditedFileChipStripModel.iconTint(for: file.filePath))
            Text(file.basename)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            deltaStats(additions: file.additions, deletions: file.deletions)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .help(file.filePath)
        .accessibilityLabel(fileChipAccessibilityLabel(file))
    }

    private func moreChip(_ overflow: TranscriptEditedFileChipStripModel.OverflowSummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: showAllFiles ? "chevron.down" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("+\(overflow.hiddenCount) more")
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            deltaStats(additions: overflow.additions, deletions: overflow.deletions)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityLabel("Show \(overflow.hiddenCount) more edited files, \(overflow.additions) additions, \(overflow.deletions) deletions")
    }

    @ViewBuilder
    private func deltaStats(additions: Int, deletions: Int) -> some View {
        if additions > 0 {
            Text("+\(additions)")
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(Self.additionsTint)
                .monospacedDigit()
        }
        if deletions > 0 {
            Text("-\(deletions)")
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(Self.deletionsTint)
                .monospacedDigit()
        }
    }

    private var chipBackground: Color {
        #if os(iOS)
        Color(.secondarySystemBackground)
        #else
        Color.secondary.opacity(0.10)
        #endif
    }

    private func fileChipAccessibilityLabel(_ file: TranscriptEditedFile) -> String {
        var parts = [file.basename]
        if file.additions > 0 { parts.append("\(file.additions) additions") }
        if file.deletions > 0 { parts.append("\(file.deletions) deletions") }
        return parts.joined(separator: ", ")
    }

    private static let additionsTint = Color(red: 0x52 / 255.0, green: 0xC4 / 255.0, blue: 0x1A / 255.0)
    private static let deletionsTint = Color(red: 0xE6 / 255.0, green: 0x4B / 255.0, blue: 0x4B / 255.0)
}
#endif
