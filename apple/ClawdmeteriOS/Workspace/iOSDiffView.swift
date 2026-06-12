import SwiftUI
import ClawdmeterShared

/// iOS git diff viewer — file list with `+/-` line counts, tap a file to
/// see syntax-highlighted hunks. Sessions v2 Phase 4 / T15.
///
/// Wire: `GET /sessions/:id/diff` returns `[GitDiffFile]`. Truncated file
/// rows lazy-fetch full hunks through `GET /sessions/:id/diff/:path`.
struct iOSDiffView: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    @State private var files: [GitDiffFile] = []
    @State private var isLoading: Bool = true
    @State private var applyingPath: String?
    @State private var discardTarget: GitDiffFile?
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
                emptyState
            } else {
                fileList
            }
        }
        .navigationTitle("Diff")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .confirmationDialog(
            "Discard this file's local changes?",
            isPresented: Binding(
                get: { discardTarget != nil },
                set: { if !$0 { discardTarget = nil } }
            ),
            presenting: discardTarget
        ) { file in
            Button("Discard \(file.path)", role: .destructive, action: ContinuumAnalytics.wrapButton(
                    "discard_file_path",
                    {
                Task { await apply(.discardFile, to: file) }
            
                    }
                ))
            Button("Cancel", role: .cancel, action: ContinuumAnalytics.wrapButton(
                    "cancel",
                    {
 discardTarget = nil 
                    }
                ))
        } message: { file in
            Text("This is destructive. Untracked files move to Trash; tracked changes are restored from HEAD.")
        }
    }

    @ViewBuilder
    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(files) { file in
                    NavigationLink {
                        iOSDiffFileView(session: session, client: client, initialFile: file)
                    } label: {
                        TahoeGlass(radius: 6, tone: .chip, solid: t.dark ? true : nil) {
                            HStack(alignment: .top, spacing: 11) {
                                statusGlyph(file.status)
                                    .frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.path)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .font(TahoeFont.mono(12))
                                        .foregroundStyle(t.fg)
                                    HStack(spacing: 8) {
                                        Text("+\(file.additions)")
                                            .foregroundStyle(.green)
                                        Text("-\(file.deletions)")
                                            .foregroundStyle(.red)
                                        if let changeState = file.changeState {
                                            changeStatePill(changeState)
                                        }
                                        if file.truncated {
                                            Text("truncated")
                                                .foregroundStyle(t.fg4)
                                        }
                                    }
                                    .font(TahoeFont.mono(10.5, weight: .semibold))
                                }
                                Spacer()
                                TahoeIcon("chevR", size: 13)
                                    .foregroundStyle(t.fg4)
                                    .padding(.top, 3)
                            }
                            .padding(12)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        diffActionButtons(for: file)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await apply(.stageFile, to: file) }
                        } label: {
                            Label("Stage", systemImage: "plus.square")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive, action: ContinuumAnalytics.wrapButton(
                                "diff_revert_hunk",
                                {
                            discardTarget = file
                        
                                }
                            )) {
                            Label("Discard", systemImage: "trash")
                        }
                        if file.changeState == "staged" || file.changeState == "mixed" {
                            Button {
                                Task { await apply(.unstageFile, to: file) }
                            } label: {
                                Label("Unstage", systemImage: "minus.square")
                            }
                            .tint(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(rowAccessibilityLabel(file))
                    .accessibilityHint("Double-tap to view the hunks.")
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func diffActionButtons(for file: GitDiffFile) -> some View {
        Button(action: ContinuumAnalytics.wrapButton("diff_stage_file", { Task { await apply(.stageFile, to: file) } })) {
            Label("Stage file", systemImage: "plus.square")
        }
        if file.changeState == "staged" || file.changeState == "mixed" {
            Button(action: ContinuumAnalytics.wrapButton("diff_unstage_file", { Task { await apply(.unstageFile, to: file) } })) {
                Label("Unstage file", systemImage: "minus.square")
            }
        }
        Button(role: .destructive, action: ContinuumAnalytics.wrapButton("diff_discard_file", { discardTarget = file })) {
            Label("Discard file", systemImage: "trash")
        }
    }

    private func changeStatePill(_ state: String) -> some View {
        Text(state.capitalized)
            .font(TahoeFont.body(9.5, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(t.glassTintHi, in: Capsule())
            .foregroundStyle(t.fg4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            TahoeIcon("diff", size: 24)
                .foregroundStyle(t.fg4)
            Text("No local diff")
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("The worktree has no visible changes yet.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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

    @MainActor
    private func apply(_ action: GitDiffActionKind, to file: GitDiffFile) async {
        applyingPath = file.path
        defer {
            applyingPath = nil
            discardTarget = nil
        }
        if let response = await client.applyDiffAction(sessionId: session.id, path: file.path, action: action),
           response.ok {
            files = response.files
            errorMessage = nil
        } else {
            errorMessage = client.lastError ?? "The Mac could not apply this diff action."
        }
    }
}

/// File-level diff view with per-hunk paginated rendering for large diffs.
struct iOSDiffFileView: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    @ObservedObject var client: AgentControlClient
    let initialFile: GitDiffFile

    @State private var loadedFile: GitDiffFile?
    @State private var isLoading = false
    @State private var isApplying = false
    @State private var discardPresented = false
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
                    LazyVStack(alignment: .leading, spacing: 10) {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: ContinuumAnalytics.wrapButton("diff_stage_file", { Task { await apply(.stageFile) } })) {
                        Label("Stage file", systemImage: "plus.square")
                    }
                    Button(action: ContinuumAnalytics.wrapButton("diff_unstage_file", { Task { await apply(.unstageFile) } })) {
                        Label("Unstage file", systemImage: "minus.square")
                    }
                    Button(role: .destructive, action: ContinuumAnalytics.wrapButton("diff_discard_file", { discardPresented = true })) {
                        Label("Discard file", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: isApplying ? "clock.arrow.circlepath" : "ellipsis.circle")
                }
                .disabled(isApplying)
            }
        }
        .task(id: initialFile.path) {
            if initialFile.truncated || initialFile.hunks.isEmpty {
                await loadFullFile()
            }
        }
        .confirmationDialog("Discard file changes?", isPresented: $discardPresented) {
            Button("Discard", role: .destructive, action: ContinuumAnalytics.wrapButton("diff_confirm_discard", { Task { await apply(.discardFile) } }))
            Button("Cancel", role: .cancel, action: ContinuumAnalytics.wrapButton("diff_discard_cancel", {}))
        } message: {
            Text("This is destructive. Untracked files move to Trash; tracked changes are restored from HEAD.")
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

    @MainActor
    private func apply(_ action: GitDiffActionKind) async {
        isApplying = true
        defer { isApplying = false }
        if let response = await client.applyDiffAction(sessionId: session.id, path: file.path, action: action),
           response.ok {
            if let refreshed = response.files.first(where: { $0.path == file.path }) {
                loadedFile = refreshed
                if refreshed.truncated || refreshed.hunks.isEmpty {
                    await loadFullFile()
                }
            } else {
                loadedFile = GitDiffFile(
                    path: file.path,
                    status: file.status,
                    additions: 0,
                    deletions: 0,
                    hunks: [],
                    truncated: false,
                    changeState: nil
                )
            }
            errorMessage = nil
        } else {
            errorMessage = client.lastError ?? "The Mac could not apply this diff action."
        }
    }

    @ViewBuilder
    private func hunkView(_ hunk: GitDiffHunk) -> some View {
        TahoeGlass(radius: 6, tone: .chip, solid: t.dark ? true : nil) {
            VStack(alignment: .leading, spacing: 1) {
                Text(hunk.header)
                    .font(TahoeFont.mono(11, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .padding(.bottom, 3)
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(lineColor(line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(lineBg(line.kind), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(10)
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
        #if DEBUG
        if let fixture = codeTabVerificationDiff(sessionId: sessionId) {
            return fixture
        }
        #endif
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
