import SwiftUI
import QuickLook
import ClawdmeterShared

/// Sessions v2 — iOS artifacts pane (TODOS.md v2.0.1 carryover). Lists
/// every file the agent wrote (PDF, image, doc, spreadsheet) inside the
/// session worktree, downloads bytes from the Mac daemon on tap, and
/// previews via QLPreviewController.
struct iOSArtifactsPane: View {
    @ObservedObject var client: AgentControlClient
    let session: AgentSession
    @ObservedObject var chatStore: iOSChatStore

    @State private var previewURL: URL?
    @State private var downloading: String?
    @State private var error: String?

    var body: some View {
        Group {
            if chatStore.snapshot.artifactEntries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(chatStore.snapshot.artifactEntries) { entry in
                        row(for: entry)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .quickLookPreview($previewURL)
        .alert("Could not load artifact", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No artifacts yet")
                .foregroundStyle(.secondary)
            Text("When the agent writes a PDF, image, or spreadsheet, it'll appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for entry: ArtifactEntry) -> some View {
        let isDownloading = downloading == entry.path
        return Button {
            Task { await open(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: entry.filename))
                    .font(.title3)
                    .foregroundStyle(SessionsV2Theme.accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.filename)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if isDownloading {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading != nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.filename)
        .accessibilityValue(isDownloading ? "Downloading" : entry.path)
        .accessibilityHint("Double-tap to preview.")
    }

    private func icon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "csv", "xlsx": return "tablecells"
        case "docx": return "doc"
        case "pptx": return "rectangle.stack"
        case "md", "txt", "log": return "doc.text"
        case "json": return "curlybraces"
        case "html": return "globe"
        default: return "doc"
        }
    }

    private func open(_ entry: ArtifactEntry) async {
        guard downloading == nil else { return }
        // P2-iOS-7 (refined after Codex review): refuse any artifact path
        // that contains a `..` traversal segment. ArtifactEntry.path
        // is documented as storing absolute paths (it comes from the
        // agent's `Write` tool input via SessionChatStore.ChatItemBuilder),
        // so rejecting `/`-prefixed paths broke every real download.
        // Daemon-side sandbox validation is the actual defense.
        guard Self.isSafeArtifactPath(entry.path) else {
            self.error = "Refusing to fetch unsafe artifact path: \(entry.path)"
            return
        }
        downloading = entry.path
        defer { downloading = nil }
        do {
            let localURL = try await client.downloadArtifact(
                sessionId: session.id, remotePath: entry.path
            )
            previewURL = localURL
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// v0.7.7: delegated to PathValidator. The shape (reject empty +
    /// traversal, allow absolute) is identical to the previous inline
    /// implementation; pulling it into the shared helper consolidates
    /// the three near-clone validators that used to live across this
    /// file + AgentControlServer.
    static func isSafeArtifactPath(_ path: String) -> Bool {
        PathValidator.isSafeArtifactPath(path)
    }
}

