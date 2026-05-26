import SwiftUI
import AppKit
import Quartz
import QuickLookThumbnailing
import ClawdmeterShared

/// G10 / Artifacts tab. Tracks every `Write` tool_call with a non-source-code
/// extension (.pdf, .xlsx, .docx, .pptx, .png, .svg, …). Renders thumbnails
/// via QuickLook. Click → full QuickLook overlay.
///
/// Filtering by extension matches the Codex-desktop behavior: source code
/// already lives in the diff pane. Generated docs / images / spreadsheets
/// deserve their own surface.
struct ArtifactsPane: View {
    let session: AgentSession
    // A5 — bind to the per-transcript slice. ArtifactsPane only ever
    // read `snapshot.updateCounter` + `snapshot.artifactEntries`, both
    // of which live on the messages slice. Composer token deltas and
    // permission-prompt flips no longer invalidate this pane.
    @ObservedObject var messagesSlice: ChatMessagesSlice
    @State private var previewURL: URL?
    /// Verified-on-disk artifact set. The existence check used to run
    /// synchronously inside `collect()` on every render; with many
    /// artifacts and a slow FS (network mount, heavy disk load) this
    /// hitched. The check now runs off-main via Task.detached and the
    /// result lands here. The view re-runs the check when
    /// `messagesSlice.artifactEntries` changes.
    @State private var verifiedArtifacts: [Artifact] = []
    @State private var lastVerifiedCounter: UInt64 = 0

    init(session: AgentSession, chatStore: SessionChatStore) {
        self.session = session
        _messagesSlice = ObservedObject(wrappedValue: chatStore.messagesSlice)
    }

    var body: some View {
        let artifacts = verifiedArtifacts
        return ZStack {
            ScrollView {
                if artifacts.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 110), spacing: 10)
                    ], spacing: 10) {
                        ForEach(artifacts) { artifact in
                            artifactCard(artifact)
                        }
                    }
                    .padding(12)
                }
            }
            if let url = previewURL {
                QuickLookOverlay(url: url, onClose: { previewURL = nil })
                    .transition(.opacity)
            }
        }
        .onAppear { refreshVerified() }
        .onChange(of: messagesSlice.updateCounter) { _, _ in
            refreshVerified()
        }
    }

    /// Resolve relative paths, stat each one off-main, and publish the
    /// verified list back. Skips re-running for the same updateCounter
    /// so tab switches don't trigger redundant stat() calls.
    private func refreshVerified() {
        let counter = messagesSlice.updateCounter
        guard counter != lastVerifiedCounter else { return }
        lastVerifiedCounter = counter
        let entries = messagesSlice.artifactEntries
        let repoCwd = session.effectiveCwd
        Task.detached(priority: .userInitiated) {
            var out: [Artifact] = []
            var seen: Set<String> = []
            for entry in entries {
                let absolute: String = entry.path.hasPrefix("/")
                    ? entry.path
                    : (repoCwd as NSString).appendingPathComponent(entry.path)
                guard !seen.contains(absolute) else { continue }
                seen.insert(absolute)
                guard FileManager.default.fileExists(atPath: absolute) else { continue }
                out.append(Artifact(
                    path: absolute,
                    url: URL(fileURLWithPath: absolute)
                ))
            }
            await MainActor.run {
                self.verifiedArtifacts = out
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("No artifacts yet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("When the agent writes a PDF, image, or spreadsheet, it'll appear here.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func artifactCard(_ artifact: Artifact) -> some View {
        Button(action: {
            previewURL = artifact.url
        }) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.10))
                    QuickLookThumbnail(url: artifact.url)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(height: 90)
                Text(artifact.filename)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(6)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    struct Artifact: Identifiable {
        let id = UUID()
        let path: String
        let url: URL
        var filename: String { url.lastPathComponent }
    }

    // The artifact-extension allowlist + the per-render `collect()` helper
    // both lived here previously. After T9 the source of truth is
    // `StagingParser.artifactExtensions`; after hardening, the verified
    // existence list is computed off-main via `refreshVerified()` above
    // and stored in `@State verifiedArtifacts` so the view body does
    // zero per-render filesystem work.
}

// MARK: - QuickLook thumbnail (NSViewRepresentable)

private struct QuickLookThumbnail: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSWorkspace.shared.icon(forFile: url.path)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 180, height: 180),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                nsView.image = rep.nsImage
            }
        }
    }
}

// MARK: - QuickLook full-preview overlay

private struct QuickLookOverlay: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(spacing: 0) {
                HStack {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)
                }
                .padding(10)
                QuickLookPreview(url: url)
                    .frame(minWidth: 400, minHeight: 320)
            }
            .padding(8)
            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            .padding(40)
        }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
}
