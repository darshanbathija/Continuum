import SwiftUI
import QuickLookThumbnailing
import ClawdmeterShared

/// Single attachment pill rendered above the composer input row.
/// Shows a thumbnail (rendered async via QLThumbnailGenerator) + filename
/// + size + an X to remove. Image attachments get a larger image-shaped
/// pill; non-images get a generic doc icon.
struct AttachmentChip: View {

    let attachment: ComposerStore.Attachment
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            iconOrThumbnail
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(humanSize)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 180, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressableButtonStyle())
            .help("Remove attachment")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .task { await loadThumbnail() }
    }

    @ViewBuilder
    private var iconOrThumbnail: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else if attachment.isImage {
            Image(systemName: "photo")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "doc")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    private var humanSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file)
    }

    @MainActor
    private func loadThumbnail() async {
        let request = QLThumbnailGenerator.Request(
            fileAt: attachment.sourceURL,
            size: CGSize(width: 48, height: 48),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                Task { @MainActor in
                    if let rep {
                        self.thumbnail = rep.nsImage
                    }
                    cont.resume()
                }
            }
        }
    }
}
