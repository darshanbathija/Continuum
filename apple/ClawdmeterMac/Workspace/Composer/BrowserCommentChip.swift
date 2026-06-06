import SwiftUI
import ClawdmeterShared

struct BrowserCommentChip: View {
    let comment: BrowserCommentContext
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "safari")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SessionsV2Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(comment.chipLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let url = comment.urlString {
                    Text(url)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressableButtonStyle())
            .help("Remove browser comment")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .help(comment.standardMarkdown())
    }
}
