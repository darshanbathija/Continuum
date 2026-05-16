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
        Button {
            Task { await open(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: entry.filename))
                    .font(.title3)
                    .foregroundStyle(SessionsV2Theme.accent)
                    .frame(width: 32)
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
                if downloading == entry.path {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(downloading != nil)
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
}

extension AgentControlClient {
    enum ArtifactError: LocalizedError {
        case notPaired
        case badStatus(Int)
        case ioError(String)
        var errorDescription: String? {
            switch self {
            case .notPaired: return "Not paired to a Mac"
            case .badStatus(let code): return "Daemon returned HTTP \(code)"
            case .ioError(let msg): return msg
            }
        }
    }

    /// Fetch artifact bytes via GET /sessions/:id/artifact?path=… and
    /// write them to a tempdir for QLPreviewController. Caches under
    /// the file's basename so reopening the same artifact is fast.
    @MainActor
    func downloadArtifact(sessionId: UUID, remotePath: String) async throws -> URL {
        guard let host, let token else { throw ArtifactError.notPaired }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = httpPort
        comps.path = "/sessions/\(sessionId.uuidString)/artifact"
        comps.queryItems = [URLQueryItem(name: "path", value: remotePath)]
        guard let url = comps.url else { throw ArtifactError.ioError("bad URL") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ArtifactError.badStatus(http.statusCode)
        }
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-artifacts/\(sessionId.uuidString)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let basename = (remotePath as NSString).lastPathComponent
        let localURL = cacheDir.appendingPathComponent(basename)
        try data.write(to: localURL, options: .atomic)
        return localURL
    }
}
