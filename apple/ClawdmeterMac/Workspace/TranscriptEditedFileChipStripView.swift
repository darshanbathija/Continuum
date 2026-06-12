import SwiftUI
import AppKit
import ClawdmeterShared

/// Horizontal strip of edited-file chips at the bottom of a transcript turn.
/// Hovering a chip with preview data expands an inline diff card beneath it.
struct TranscriptEditedFileChipStripView: View {
    let files: [TranscriptEditedFile]
    let repoRoot: URL?

    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(files.prefix(6)) { file in
                TranscriptEditedFileChipView(file: file, repoRoot: repoRoot)
            }
        }
    }
}

private struct TranscriptEditedFileChipView: View {
    let file: TranscriptEditedFile
    let repoRoot: URL?

    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var showPreview = false
    @State private var hoverTask: Task<Void, Never>?

    private var hasPreview: Bool {
        guard let preview = file.preview else { return false }
        return !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chipLabel
            if showPreview, hasPreview, let preview = file.preview {
                EditDiffHoverPreviewView(
                    preview: preview,
                    isTruncated: file.isPreviewTruncated
                )
                .padding(8)
                .frame(minWidth: 360, maxWidth: 560, alignment: .leading)
                .background(ContinuumTokens.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(t.hairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier("code.turn.edited-file.preview.\(file.id)")
            }
        }
        .zIndex(showPreview ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showPreview)
        .onHover(perform: handleHover)
        .onDisappear {
            hoverTask?.cancel()
            showPreview = false
        }
        .accessibilityIdentifier("code.turn.edited-file.chip.\(file.id)")
    }

    private var chipLabel: some View {
        HStack(spacing: 6) {
            fileIcon
                .frame(width: 14, height: 14)
            Text(file.basename)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
            if file.additions > 0 {
                Text("+\(file.additions)")
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(additionsColor)
                    .monospacedDigit()
            }
            if file.deletions > 0 {
                Text("-\(file.deletions)")
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(deletionsColor)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            (isHovered ? t.hair2.opacity(1.15) : t.hair2),
            in: Capsule(style: .continuous)
        )
        .overlay {
            if isHovered {
                Capsule(style: .continuous)
                    .stroke(t.hairline.opacity(0.9), lineWidth: 0.5)
            }
        }
        .help(chipHelp)
    }

    @ViewBuilder
    private var fileIcon: some View {
        if let url = resolvedFileURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SessionsV2Theme.success)
        }
    }

    private var resolvedFileURL: URL? {
        let trimmed = file.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        return repoRoot?.appendingPathComponent(trimmed)
    }

    private var chipHelp: String {
        if hasPreview {
            return "\(file.filePath)\nHover to preview diff"
        }
        return file.filePath
    }

    private func handleHover(_ inside: Bool) {
        isHovered = inside
        hoverTask?.cancel()
        guard inside, hasPreview else {
            showPreview = false
            return
        }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showPreview = true
            }
        }
    }

    private var additionsColor: Color {
        Color(red: 0x52 / 255.0, green: 0xC4 / 255.0, blue: 0x1A / 255.0)
    }

    private var deletionsColor: Color {
        Color(red: 0xE6 / 255.0, green: 0x4B / 255.0, blue: 0x4B / 255.0)
    }
}
