import SwiftUI
import AppKit
import ClawdmeterShared

struct RepoFilePickerView: View {
    @Environment(\.tahoe) private var t
    let repoRoot: String?
    @ObservedObject var presentationStore: SessionPresentationStore
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var filteredFiles: [RepoFileMatch] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchBackend: RepoFileSearchBackend = .unavailable
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(t.fg3)
                TextField("Open file in repo", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                Text("⌘P")
                    .font(TahoeFont.mono(10))
                    .foregroundStyle(t.fg4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            TahoeHair()

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(searchBackend == .fff ? "Indexing repo with FFF..." : "Indexing repo files...")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else if let error {
                ContentUnavailableView("File picker unavailable", systemImage: "folder.badge.questionmark", description: Text(error))
                    .frame(minHeight: 260)
            } else if filteredFiles.isEmpty {
                ContentUnavailableView("No files found", systemImage: "doc.text.magnifyingglass", description: Text("Try another query."))
                    .frame(minHeight: 260)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(filteredFiles.enumerated()), id: \.element.id) { index, match in
                            Button {
                                open(match)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: icon(for: match.path))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(t.accent)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((match.path as NSString).lastPathComponent)
                                            .font(TahoeFont.body(12.5, weight: .semibold))
                                            .foregroundStyle(t.fg)
                                            .lineLimit(1)
                                        Text(match.subtitle)
                                            .font(TahoeFont.mono(10.5))
                                            .foregroundStyle(t.fg3)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    if match.isRecent {
                                        Text("recent")
                                            .font(TahoeFont.body(10, weight: .bold))
                                            .foregroundStyle(t.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(t.accentAlpha(0.12), in: Capsule(style: .continuous))
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .background(
                                    index == selectedIndex ? t.accentAlpha(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(match.id)
                            .contextMenu {
                                Button("Open", action: ContinuumAnalytics.wrapButton("plan_match_open", { open(match) }))
                                Button("Reveal in Finder", action: ContinuumAnalytics.wrapButton("plan_match_reveal", { reveal(match.path) }))
                                Button("Copy relative path", action: ContinuumAnalytics.wrapButton("plan_match_copy_path", { copy(match.path) }))
                                if let line = match.line {
                                    Button("Copy path with line", action: ContinuumAnalytics.wrapButton("plan_match_copy_path_line", { copy("\(match.path):\(line)") }))
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedIndex) { _, newValue in
                    guard filteredFiles.indices.contains(newValue) else { return }
                    proxy.scrollTo(filteredFiles[newValue].id, anchor: .center)
                }
                }
                .frame(maxHeight: 390)
            }
        }
        .frame(width: 620)
        .background(ContinuumTokens.surface3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.hairline, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.24), radius: 34, x: 0, y: 20)
        .task(id: repoRoot) { await refreshMatches(resetSelection: true) }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            Task { await refreshMatches(resetSelection: false) }
        }
        .background(KeyMonitor(
            up: { moveSelection(delta: -1) },
            down: { moveSelection(delta: 1) },
            enter: { open(filteredFiles[safe: selectedIndex]) },
            escape: onDismiss
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repo file picker")
    }

    @MainActor
    private func refreshMatches(resetSelection: Bool) async {
        guard let repoRoot, !repoRoot.isEmpty else {
            filteredFiles = []
            error = "No open code session has a repo root."
            searchBackend = .unavailable
            return
        }

        isLoading = true
        error = nil
        let recents = presentationStore.snapshot.recentPathActions
        let result = await RepoFileSearchService.shared.matches(
            query: query,
            repoRoot: repoRoot,
            recents: recents
        )
        filteredFiles = result.matches
        searchBackend = result.backend
        error = result.error
        isLoading = false
        if resetSelection {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, max(0, filteredFiles.count - 1))
        }
    }

    private func open(_ match: RepoFileMatch?) {
        guard let match, let root = repoRoot else { return }
        try? presentationStore.recordPathAction(match.path)
        if let line = match.line {
            try? presentationStore.recordPathAction("\(match.path):\(line)")
        }
        let path = match.path
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        switch presentationStore.snapshot.externalEditorIdentifier ?? "xed" {
        case "finder":
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case "default":
            NSWorkspace.shared.open(url)
        default:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            if let line = match.line {
                process.arguments = ["-l", "\(line)", url.path]
            } else {
                process.arguments = [url.path]
            }
            try? process.run()
        }
        onDismiss()
    }

    private func moveSelection(delta: Int) {
        guard !filteredFiles.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(selectedIndex + delta, 0), filteredFiles.count - 1)
    }

    private func reveal(_ path: String) {
        guard let root = repoRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(path)])
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func icon(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown": return "doc.richtext"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        default: return "doc.text"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

enum SessionExportBundleWriter {
    static func export(
        session: AgentSession,
        transcriptURL: URL?,
        presentation: SessionPresentationSnapshot,
        outputRoot: URL? = nil
    ) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let root = (outputRoot ?? downloads).appendingPathComponent("Clawdmeter Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safeTitle = session.displayLabel
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let dir = root.appendingPathComponent("\(safeTitle)-\(session.id.uuidString.prefix(8))", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: dir.appendingPathComponent("session.json"))
        try encoder.encode(ExportPresentationState(sessionId: session.id, presentation: presentation))
            .write(to: dir.appendingPathComponent("presentation-state.json"))

        if let transcriptURL, FileManager.default.fileExists(atPath: transcriptURL.path) {
            try FileManager.default.copyItem(at: transcriptURL, to: dir.appendingPathComponent("transcript.jsonl"))
        }

        if FileManager.default.fileExists(atPath: session.effectiveCwd) {
            let status = run("/usr/bin/git", ["-C", session.effectiveCwd, "status", "--short", "--branch"])
            let files = run("/usr/bin/git", ["-C", session.effectiveCwd, "ls-files", "--cached", "--others", "--exclude-standard"])
            let unstagedDiff = run("/usr/bin/git", ["-C", session.effectiveCwd, "diff", "--no-ext-diff"])
            let stagedDiff = run("/usr/bin/git", ["-C", session.effectiveCwd, "diff", "--cached", "--no-ext-diff"])
            let untracked = run("/usr/bin/git", ["-C", session.effectiveCwd, "ls-files", "--others", "--exclude-standard"])
            try status.write(to: dir.appendingPathComponent("git-status.txt"), atomically: true, encoding: .utf8)
            try files.write(to: dir.appendingPathComponent("sources.txt"), atomically: true, encoding: .utf8)
            try unstagedDiff.write(to: dir.appendingPathComponent("diff-unstaged.patch"), atomically: true, encoding: .utf8)
            try stagedDiff.write(to: dir.appendingPathComponent("diff-staged.patch"), atomically: true, encoding: .utf8)
            try untracked.write(to: dir.appendingPathComponent("untracked-files.txt"), atomically: true, encoding: .utf8)
        }

        let plan = exportPlan(session: session, presentation: presentation)
        try encoder.encode(plan).write(to: dir.appendingPathComponent("plan.json"))
        if let pr = session.prMirrorState {
            try encoder.encode(pr).write(to: dir.appendingPathComponent("pr.json"))
            try encoder.encode(pr.checks).write(to: dir.appendingPathComponent("checks.json"))
        }

        let manifest = ExportManifest(
            exportedAt: Date(),
            sessionId: session.id,
            title: session.displayLabel,
            provider: session.agent.rawValue,
            repo: session.repoDisplayName,
            cwd: session.effectiveCwd,
            files: try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        )
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))

        var notes: [String] = [
            "# Clawdmeter Session Export",
            "",
            "- Session: \(session.displayLabel)",
            "- ID: \(session.id.uuidString)",
            "- Provider: \(session.agent.rawValue)",
            "- Status: \(session.status.rawValue)",
            "- Repo: \(session.repoDisplayName)",
            "- Open path: \(dir.path)",
            "",
            "## Contents",
            "- `manifest.json`: export index and file list",
            "- `session.json`: session metadata",
            "- `presentation-state.json`: session-scoped pins, unread, bookmarks, viewed files, and review state",
            "- `transcript.jsonl`: copied transcript when available",
            "- `plan.json`: approved/pending plan snapshot from available local state",
            "- `diff-unstaged.patch`, `diff-staged.patch`, `git-status.txt`, `untracked-files.txt`, `sources.txt`: git evidence",
            "- `pr.json`, `checks.json`: PR/check mirror state when available",
        ]
        if let pr = session.prMirrorState?.prURL {
            notes.append("- PR: \(pr)")
        }
        try notes.joined(separator: "\n").write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private static func exportPlan(session: AgentSession, presentation: SessionPresentationSnapshot) -> ExportPlan {
        ExportPlan(
            sessionId: session.id,
            status: session.status.rawValue,
            mode: session.mode.rawValue,
            titleOverride: presentation.titleOverrides[session.id],
            bookmarks: presentation.messageBookmarks[session.id]?.sorted() ?? [],
            viewedFiles: presentation.viewedFiles[session.id] ?? [],
            reviewDispositions: presentation.fileReviewDispositions[session.id] ?? [:]
        )
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private struct ExportPlan: Codable {
        var sessionId: UUID
        var status: String
        var mode: String
        var titleOverride: String?
        var bookmarks: [String]
        var viewedFiles: [ViewedFileState]
        var reviewDispositions: [String: FileReviewDisposition]
    }

    private struct ExportManifest: Codable {
        var exportedAt: Date
        var sessionId: UUID
        var title: String
        var provider: String
        var repo: String
        var cwd: String
        var files: [String]
    }

    private struct ExportPresentationState: Codable {
        var sessionId: UUID
        var isPinned: Bool
        var isUnread: Bool
        var titleOverride: String?
        var snoozedUntil: Date?
        var isMuted: Bool
        var colorTag: String?
        var bookmarks: [String]
        var viewedFiles: [ViewedFileState]
        var collapsedDiffHunks: [String]
        var reviewDispositions: [String: FileReviewDisposition]
        var syntaxTheme: CodeSyntaxTheme
        var diffDisplayMode: DiffDisplayMode

        init(sessionId: UUID, presentation: SessionPresentationSnapshot) {
            self.sessionId = sessionId
            self.isPinned = presentation.pinnedSessionIds.contains(sessionId)
            self.isUnread = presentation.unreadSessionIds.contains(sessionId)
            self.titleOverride = presentation.titleOverrides[sessionId]
            self.snoozedUntil = presentation.snoozedUntil[sessionId]
            self.isMuted = presentation.mutedSessionIds.contains(sessionId)
            self.colorTag = presentation.colorTags[sessionId]
            self.bookmarks = presentation.messageBookmarks[sessionId]?.sorted() ?? []
            self.viewedFiles = presentation.viewedFiles[sessionId] ?? []
            self.collapsedDiffHunks = presentation.collapsedDiffHunks[sessionId]?.sorted() ?? []
            self.reviewDispositions = presentation.fileReviewDispositions[sessionId] ?? [:]
            self.syntaxTheme = presentation.syntaxTheme
            self.diffDisplayMode = presentation.diffDisplayMode
        }
    }
}

struct StatusHUDView: View {
    @ObservedObject var runtime: AppRuntime
    @ObservedObject private var registry: AgentSessionRegistry
    @Environment(\.tahoe) private var t

    init(runtime: AppRuntime) {
        self.runtime = runtime
        self._registry = ObservedObject(wrappedValue: runtime.agentSessionRegistry)
    }

    private var sessions: [AgentSession] {
        registry.sessions.filter { $0.archivedAt == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Clawdmeter HUD")
                    .font(TahoeFont.body(18, weight: .bold))
                Spacer()
                Text("\(running.count) running")
                    .font(TahoeFont.mono(11, weight: .bold))
                    .foregroundStyle(running.isEmpty ? t.fg3 : .green)
            }
            HStack(spacing: 10) {
                metric("Active", sessions.count, "bubble.left.and.bubble.right")
                metric("Review", review.count, "checklist")
                metric("Attention", attention.count, "bell.badge")
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sessions.sorted { $0.lastEventAt > $1.lastEventAt }.prefix(8)) { session in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(session.status == .running ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(session.displayLabel)
                            .font(TahoeFont.body(12, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(session.agent.rawValue)
                            .font(TahoeFont.mono(10))
                            .foregroundStyle(t.fg3)
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 360, minHeight: 260, alignment: .topLeading)
        .tahoeTheme(TahoeThemeStore.loaded())
    }

    private var running: [AgentSession] {
        sessions.filter { $0.status == .running }
    }

    private var review: [AgentSession] {
        sessions.filter { $0.prMirrorState != nil || $0.planText != nil || $0.approvedPlanText != nil }
    }

    private var attention: [AgentSession] {
        sessions.filter {
            $0.status == .paused
                || $0.status == .degraded
                || $0.status == .planning
                || $0.prMirrorState?.checksRollup == .failure
        }
    }

    private func metric(_ title: String, _ value: Int, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(t.accent)
            Text("\(value)")
                .font(TahoeFont.body(20, weight: .bold))
            Text(title.uppercased())
                .font(TahoeFont.body(9, weight: .bold))
                .foregroundStyle(t.fg4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
