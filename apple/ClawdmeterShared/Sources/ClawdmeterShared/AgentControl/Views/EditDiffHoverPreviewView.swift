#if canImport(SwiftUI)
import SwiftUI

#if os(macOS)
/// Non-disruptive hover peek for an inline edit row. Shows a capped diff
/// preview beside the row without toggling the disclosure — unlike the
/// v0.29.3 hover-to-expand behavior that flashed open while scrolling.
struct EditDiffHoverPreviewView: View {
    let preview: String
    let filePath: String
    let additions: Int
    let deletions: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TranscriptEditedFileChip(filePath: filePath)
                EditDiffDeltaCounts(additions: additions, deletions: deletions)
            }
            EditDiffPreviewPane(preview: preview, lineLimit: 18)
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.98),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}
#endif
#endif
