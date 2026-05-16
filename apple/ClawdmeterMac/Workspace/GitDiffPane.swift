import SwiftUI
import AppKit
import OSLog

private let diffLogger = Logger(subsystem: "com.clawdmeter.mac", category: "GitDiffPane")

// MARK: - Model

/// Single-file unified-diff representation.
struct GitDiffFile: Identifiable, Hashable {
    let id = UUID()
    let path: String         // post-image path (a/foo/bar.swift → foo/bar.swift)
    let isNewFile: Bool
    let isDeleted: Bool
    let oldPath: String?     // pre-image path for renames; nil otherwise
    let hunks: [GitDiffHunk]
    /// The verbatim diff text for THIS file (headers + all hunks). Lets us
    /// pipe a per-file patch into `git apply --cached`.
    let rawPatch: String
}

struct GitDiffHunk: Identifiable, Hashable {
    let id = UUID()
    /// `@@ -L1,N1 +L2,N2 @@ context` line text.
    let header: String
    /// Lines including the prefix char (` `, `+`, `-`).
    let lines: [String]
    /// Self-contained patch for this hunk — file headers + this hunk only.
    /// Pipe-able into `git apply --cached`.
    let rawPatch: String

    var addedCount: Int { lines.filter { $0.first == "+" }.count }
    var removedCount: Int { lines.filter { $0.first == "-" }.count }
}

@MainActor
final class GitDiffStore: ObservableObject {
    @Published private(set) var files: [GitDiffFile] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?

    let repoCwd: String
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var refreshTask: Task<Void, Never>?

    init(repoCwd: String) {
        self.repoCwd = repoCwd
    }

    deinit {
        watcher?.cancel()
        if watchedFD != -1 { close(watchedFD) }
    }

    func start() {
        refresh()
        installIndexWatch()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        if watchedFD != -1 { close(watchedFD); watchedFD = -1 }
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Re-run `git diff HEAD`. Coalesces overlapping refreshes (vnode events
    /// can come in bursts — multiple edits within the same 100ms window
    /// shouldn't re-spawn git N times).
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            await self.runDiff()
        }
    }

    private func runDiff() async {
        guard let git = ShellRunner.locateBinary("git") else {
            lastError = "git not found"
            return
        }
        isLoading = true
        defer { isLoading = false }
        // T14 signpost: git-diff shell + parse cycle.
        let signpostID = OSSignpostID(log: chatPerfLog)
        os_signpost(.begin, log: chatPerfLog, name: "git-diff-run",
                    signpostID: signpostID,
                    "repo=%{public}@", repoCwd)
        defer {
            os_signpost(.end, log: chatPerfLog, name: "git-diff-run",
                        signpostID: signpostID,
                        "files=%d", files.count)
        }
        do {
            // Combine staged + unstaged diff. `HEAD` covers both because the
            // index gets normalized into the comparison.
            let result = try await ShellRunner.shared.run(
                executable: git,
                arguments: ["-C", repoCwd, "diff", "--unified=3", "HEAD"],
                timeout: 10
            )
            if result.exitStatus != 0 && !result.stdoutString.isEmpty == false {
                lastError = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                files = []
                return
            }
            // T11 codex tension #7d: parse off main. `parse(unified:)`
            // walks a potentially huge string (5,000-line diffs hit the
            // 10s timeout previously). Run on a detached task to keep
            // the @MainActor responsive; commit the result back here.
            let stdout = result.stdoutString
            let parsed = await Task.detached(priority: .userInitiated) {
                GitDiffStore.parse(unified: stdout)
            }.value
            self.files = parsed
            self.lastError = nil
            self.lastRefresh = Date()
        } catch {
            lastError = (error as? ShellRunner.ShellError).map(humanize) ?? "\(error)"
            files = []
        }
    }

    private func humanize(_ err: ShellRunner.ShellError) -> String {
        switch err {
        case .executableNotFound(let p): return "missing: \(p)"
        case .spawnFailed(let u):        return "spawn failed: \(u)"
        case .nonZeroExit(let s, let e): return "git exit \(s): \(e.prefix(120))"
        case .timedOut(let t):           return "git timed out after \(Int(t))s"
        }
    }

    // MARK: - Actions (stage / revert / commit)

    func stage(_ hunk: GitDiffHunk) async {
        await applyPatch(hunk.rawPatch, cached: true, reverse: false, label: "stage hunk")
    }

    func revert(_ hunk: GitDiffHunk) async {
        // Reverse-apply to the working tree. Removes the change without
        // affecting the index. (Caller can re-stage if they change their
        // mind — `git checkout` would be more dangerous.)
        await applyPatch(hunk.rawPatch, cached: false, reverse: true, label: "revert hunk")
    }

    func stageFile(_ file: GitDiffFile) async {
        await applyPatch(file.rawPatch, cached: true, reverse: false, label: "stage file")
    }

    private func applyPatch(_ patch: String, cached: Bool, reverse: Bool, label: String) async {
        guard let git = ShellRunner.locateBinary("git") else {
            lastError = "git not found"
            return
        }
        // Write the patch to a temp file. `git apply` reads from stdin too,
        // but Process+Pipe stdin requires extra plumbing — temp file is
        // simpler and the patch is tiny.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-patch-\(UUID().uuidString).diff")
        do {
            try patch.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            lastError = "couldn't write temp patch: \(error)"
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        var args = ["-C", repoCwd, "apply"]
        if cached { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append(tmp.path)
        do {
            let result = try await ShellRunner.shared.run(
                executable: git, arguments: args, timeout: 10
            )
            if result.exitStatus != 0 {
                lastError = "\(label) failed: \(result.stderrString.prefix(200))"
                diffLogger.error("\(label, privacy: .public) failed: \(result.stderrString, privacy: .public)")
            } else {
                refresh()
            }
        } catch {
            lastError = "\(label) failed: \(error)"
        }
    }

    func commit(message: String) async -> Bool {
        guard let git = ShellRunner.locateBinary("git") else {
            lastError = "git not found"
            return false
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { lastError = "commit message empty"; return false }
        do {
            let result = try await ShellRunner.shared.run(
                executable: git,
                arguments: ["-C", repoCwd, "commit", "-m", trimmed],
                timeout: 15
            )
            if result.exitStatus != 0 {
                lastError = "commit failed: \(result.stderrString.prefix(200))"
                return false
            }
            refresh()
            return true
        } catch {
            lastError = "commit failed: \(error)"
            return false
        }
    }

    // MARK: - File-change watch

    private func installIndexWatch() {
        // Watch .git/index (changes on every stage / unstage) and HEAD (commits).
        // A single watcher on the .git directory is the simplest reliable
        // signal — anything that changes index, HEAD, or refs lands there.
        let dotGit = (repoCwd as NSString).appendingPathComponent(".git")
        let fd = open(dotGit, O_EVTONLY)
        guard fd >= 0 else {
            diffLogger.warning("Can't open \(dotGit, privacy: .public) for watch")
            return
        }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .link],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.refresh()
        }
        source.setCancelHandler { [weak self] in
            if let self, self.watchedFD != -1 {
                close(self.watchedFD); self.watchedFD = -1
            }
        }
        source.resume()
        self.watcher = source
    }

    // MARK: - Unified diff parser

    nonisolated static func parse(unified: String) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        var lines = unified.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        while !lines.isEmpty {
            guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("diff --git ") })
            else { break }
            let trailing = lines.firstIndex(from: headerIdx + 1,
                                            where: { $0.hasPrefix("diff --git ") })
                ?? lines.endIndex
            let fileSlice = Array(lines[headerIdx..<trailing])
            if let file = parseFile(fileSlice) {
                files.append(file)
            }
            lines = Array(lines[trailing..<lines.endIndex])
        }
        return files
    }

    private nonisolated static func parseFile(_ lines: [String]) -> GitDiffFile? {
        guard let first = lines.first, first.hasPrefix("diff --git ") else { return nil }
        // Header parse: "diff --git a/path b/path"
        let header = first.dropFirst("diff --git ".count)
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        var postPath: String = ""
        if let bPart = parts.last, bPart.hasPrefix("b/") {
            postPath = String(bPart.dropFirst(2))
        }
        var oldPath: String? = nil
        var isNew = false
        var isDel = false
        for line in lines.prefix(10) {
            if line.hasPrefix("new file mode") { isNew = true }
            if line.hasPrefix("deleted file mode") { isDel = true }
            if line.hasPrefix("rename from ") {
                oldPath = String(line.dropFirst("rename from ".count))
            }
            if line.hasPrefix("--- a/") {
                // already captured in oldPath via rename, but use as fallback
                if oldPath == nil {
                    oldPath = String(line.dropFirst("--- a/".count))
                }
            }
        }

        // Extract header block (everything before the first @@).
        let firstHunkIdx = lines.firstIndex(where: { $0.hasPrefix("@@ ") })
        let headerBlock = firstHunkIdx.map { Array(lines[0..<$0]) } ?? lines
        let headerText = headerBlock.joined(separator: "\n") + "\n"

        // Parse hunks.
        var hunks: [GitDiffHunk] = []
        if let firstHunkIdx {
            var i = firstHunkIdx
            while i < lines.count {
                guard lines[i].hasPrefix("@@ ") else { i += 1; continue }
                let hunkHeader = lines[i]
                var j = i + 1
                while j < lines.count, !lines[j].hasPrefix("@@ ") {
                    j += 1
                }
                let body = Array(lines[(i + 1)..<j])
                let hunkText = ([hunkHeader] + body).joined(separator: "\n") + "\n"
                let patch = headerText + hunkText
                hunks.append(GitDiffHunk(header: hunkHeader, lines: body, rawPatch: patch))
                i = j
            }
        }

        let rawPatch = lines.joined(separator: "\n") + "\n"
        return GitDiffFile(
            path: postPath,
            isNewFile: isNew,
            isDeleted: isDel,
            oldPath: oldPath,
            hunks: hunks,
            rawPatch: rawPatch
        )
    }
}

private extension Array where Element == String {
    /// Like `firstIndex(where:)` but starting from a given offset.
    func firstIndex(from start: Int, where predicate: (String) -> Bool) -> Int? {
        guard start < self.endIndex else { return nil }
        for i in start..<self.endIndex {
            if predicate(self[i]) { return i }
        }
        return nil
    }
}

// MARK: - View

struct GitDiffPane: View {
    @StateObject private var store: GitDiffStore
    @State private var expandedFiles: Set<UUID> = []
    @State private var showingCommitSheet = false
    @State private var commitMessage = ""
    @State private var isCommitting = false

    @Environment(\.colorScheme) private var colorScheme

    init(repoCwd: String) {
        _store = StateObject(wrappedValue: GitDiffStore(repoCwd: repoCwd))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .sheet(isPresented: $showingCommitSheet) { commitSheet }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Diff")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if store.isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let last = store.lastRefresh {
                Text(last, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh diff")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let err = store.lastError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.files.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                Text("Working tree clean")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(store.files) { file in
                        fileSection(file)
                    }
                }
                .padding(8)
            }
        }
    }

    private func fileSection(_ file: GitDiffFile) -> some View {
        let isExpanded = expandedFiles.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if isExpanded { expandedFiles.remove(file.id) }
                else { expandedFiles.insert(file.id) }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: fileBadgeIcon(file))
                        .font(.system(size: 10))
                        .foregroundStyle(fileBadgeTint(file))
                    Text(file.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("+\(file.hunks.reduce(0) { $0 + $1.addedCount })")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                    Text("-\(file.hunks.reduce(0) { $0 + $1.removedCount })")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red)
                    Button("Stage") {
                        Task { await store.stageFile(file) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .help("Stage all hunks in this file")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(file.hunks) { hunk in
                    hunkView(file: file, hunk: hunk)
                }
            }
        }
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func fileBadgeIcon(_ file: GitDiffFile) -> String {
        if file.isNewFile { return "plus.square" }
        if file.isDeleted { return "minus.square" }
        if file.oldPath != nil, file.oldPath != file.path { return "arrow.right.square" }
        return "pencil"
    }

    private func fileBadgeTint(_ file: GitDiffFile) -> Color {
        if file.isNewFile { return .green }
        if file.isDeleted { return .red }
        if file.oldPath != nil, file.oldPath != file.path { return .blue }
        return .orange
    }

    private func hunkView(file: GitDiffFile, hunk: GitDiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(hunk.header)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                Spacer()
                Button("Stage") { Task { await store.stage(hunk) } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                Button("Revert") { Task { await store.revert(hunk) } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.06))

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                hunkLineView(line)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private func hunkLineView(_ line: String) -> some View {
        let prefix = line.first
        let bg: Color
        let fg: Color
        switch prefix {
        case "+":
            bg = Color.green.opacity(0.18)
            fg = colorScheme == .dark ? .green : Color(red: 0.0, green: 0.4, blue: 0.0)
        case "-":
            bg = Color.red.opacity(0.18)
            fg = colorScheme == .dark ? .red : Color(red: 0.6, green: 0.0, blue: 0.0)
        default:
            bg = Color.clear
            fg = .primary
        }
        return Text(line.isEmpty ? " " : line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !store.files.isEmpty {
                Button(action: { showingCommitSheet = true }) {
                    Label("Commit…", systemImage: "checkmark.seal")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var commitSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit staged changes")
                .font(.system(size: 16, weight: .semibold))
            TextField("Commit message", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .frame(minWidth: 360)
            if let err = store.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    showingCommitSheet = false
                    commitMessage = ""
                }
                .keyboardShortcut(.cancelAction)
                Button(isCommitting ? "Committing…" : "Commit") {
                    Task {
                        isCommitting = true
                        defer { isCommitting = false }
                        let ok = await store.commit(message: commitMessage)
                        if ok {
                            commitMessage = ""
                            showingCommitSheet = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCommitting)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}
