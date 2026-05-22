import SwiftUI
import ClawdmeterShared

/// iOS git diff viewer — file list with `+/-` line counts, tap a file to
/// see syntax-highlighted hunks. Sessions v2 Phase 4 / T15.
///
/// Wire: `GET /sessions/:id/diff` returns `[GitDiffFile]`. Truncated file
/// rows lazy-fetch full hunks through `GET /sessions/:id/diff/:path`.
struct iOSDiffView: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    @State private var files: [GitDiffFile] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Could not load diff", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else if files.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "doc.text")
            } else {
                fileList
            }
        }
        .navigationTitle("Diff")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    @ViewBuilder
    private var fileList: some View {
        List(files) { file in
            NavigationLink {
                iOSDiffFileView(session: session, client: client, initialFile: file)
            } label: {
                HStack {
                    statusGlyph(file.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .font(.callout.monospaced())
                        HStack(spacing: 6) {
                            Text("+\(file.additions)")
                                .foregroundStyle(.green)
                            Text("-\(file.deletions)")
                                .foregroundStyle(.red)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
                .frame(minHeight: 44)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rowAccessibilityLabel(file))
            .accessibilityHint("Double-tap to view the hunks.")
        }
        .listStyle(.plain)
    }

    private func rowAccessibilityLabel(_ file: GitDiffFile) -> String {
        let kind: String
        switch file.status {
        case "A": kind = "Added"
        case "D": kind = "Deleted"
        case "M": kind = "Modified"
        case "R": kind = "Renamed"
        default:  kind = "Changed"
        }
        return "\(kind) \(file.path). \(file.additions) lines added, \(file.deletions) lines removed."
    }

    private func statusGlyph(_ s: String) -> some View {
        let glyph: String
        let color: Color
        switch s {
        case "A": glyph = "plus"; color = .green
        case "D": glyph = "minus"; color = .red
        case "M": glyph = "pencil"; color = SessionsV2Theme.accent
        case "R": glyph = "arrow.right"; color = SessionsV2Theme.codexBlue
        default:  glyph = "doc"; color = .secondary
        }
        return Image(systemName: glyph)
            .foregroundStyle(color)
            .font(.caption)
            .frame(width: 14, alignment: .center)
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        let fetched = await client.fetchDiff(sessionId: session.id)
        if let fetched {
            self.files = fetched
            self.isLoading = false
        } else {
            self.errorMessage = client.lastError ?? "Repo may be in rebase/merge state — finish on Mac"
            self.isLoading = false
        }
    }
}

/// File-level diff view with per-hunk paginated rendering for large diffs.
struct iOSDiffFileView: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient
    let initialFile: GitDiffFile

    @State private var loadedFile: GitDiffFile?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var file: GitDiffFile { loadedFile ?? initialFile }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading hunks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Could not load hunks", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else if file.hunks.isEmpty {
                ContentUnavailableView {
                    Label("No hunks", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("The file may only have mode changes or the diff is no longer current.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                            hunkView(hunk)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(file.path)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: initialFile.path) {
            if initialFile.truncated || initialFile.hunks.isEmpty {
                await loadFullFile()
            }
        }
    }

    @MainActor
    private func loadFullFile() async {
        isLoading = true
        errorMessage = nil
        if let fetched = await client.fetchDiffFile(sessionId: session.id, path: initialFile.path) {
            loadedFile = fetched
        } else {
            errorMessage = client.lastError ?? "The Mac did not return this file's hunks."
        }
        isLoading = false
    }

    @ViewBuilder
    private func hunkView(_ hunk: GitDiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(SessionsV2Theme.codexBlue)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(lineColor(line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(lineBg(line.kind))
            }
        }
    }

    private func lineColor(_ kind: GitDiffHunk.Line.Kind) -> Color {
        switch kind {
        case .context:  return .primary
        case .addition: return .green
        case .deletion: return .red
        }
    }

    private func lineBg(_ kind: GitDiffHunk.Line.Kind) -> Color {
        switch kind {
        case .context:  return .clear
        case .addition: return Color.green.opacity(0.1)
        case .deletion: return Color.red.opacity(0.1)
        }
    }
}

extension AgentControlClient {
    /// Fetch the live `git diff HEAD` from the daemon for this session.
    @MainActor
    public func fetchDiff(sessionId: UUID) async -> [GitDiffFile]? {
        guard let host, let token else { return nil }
        guard let url = URL(string: "http://\(Self.urlHostLiteral(host)):\(httpPort)/sessions/\(sessionId.uuidString)/diff") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return try JSONDecoder().decode([GitDiffFile].self, from: data)
        } catch {
            return nil
        }
    }

}
