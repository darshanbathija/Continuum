import SwiftUI
import AppKit
import OSLog
import ClawdmeterShared

private let diffLogger = Logger(subsystem: "com.clawdmeter.mac", category: "GitDiffPane")

// MARK: - Model

enum GitDiffChangeState: String, Hashable, Sendable {
    case unstaged
    case staged
    case untracked

    var label: String {
        switch self {
        case .unstaged: return "Unstaged"
        case .staged: return "Staged"
        case .untracked: return "Untracked"
        }
    }
}

/// Single-file unified-diff representation.
struct GitDiffFile: Identifiable, Hashable, Sendable {
    let id = UUID()
    let path: String         // post-image path (a/foo/bar.swift → foo/bar.swift)
    let isNewFile: Bool
    let isDeleted: Bool
    let isUntracked: Bool
    let changeState: GitDiffChangeState
    let oldPath: String?     // pre-image path for renames; nil otherwise
    let hunks: [GitDiffHunk]
    /// The verbatim diff text for THIS file (headers + all hunks). Lets us
    /// pipe a per-file patch into `git apply --cached`.
    let rawPatch: String
}

struct GitDiffHunk: Identifiable, Hashable, Sendable {
    let id = UUID()
    /// `@@ -L1,N1 +L2,N2 @@ context` line text.
    let header: String
    /// Lines including the prefix char (` `, `+`, `-`).
    let lines: [String]
    let changeState: GitDiffChangeState
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
    private let runner: ShellRunning
    private let gitLocator: @Sendable () -> String?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var refreshTask: Task<Void, Never>?

    init(
        repoCwd: String,
        runner: ShellRunning = ShellRunner.shared,
        gitLocator: @escaping @Sendable () -> String? = { ShellRunner.locateBinary("git") }
    ) {
        self.repoCwd = repoCwd
        self.runner = runner
        self.gitLocator = gitLocator
    }

    deinit {
        // P1-Mac-14: FD ownership lives entirely in the dispatch source's
        // cancel handler. Closing here AND there created a double-close
        // window: when deinit ran first, the kernel could hand the same
        // fd number to a new socket before the cancel handler fired, and
        // the late `close()` then killed that unrelated descriptor.
        watcher?.cancel()
    }

    func start() {
        refresh()
        installIndexWatch()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Re-run staged, unstaged, and untracked diff scans. Coalesces overlapping refreshes (vnode events
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

    func reloadNowForTesting() async {
        refreshTask?.cancel()
        await runDiff()
    }

    private func runDiff() async {
        guard let git = gitLocator() else {
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
            // Keep staged and unstaged deltas as separate action domains.
            // `git diff HEAD` flattens both into one patch; reverse-applying
            // that patch to the worktree can hide staged changes in the UI
            // while leaving them commit-ready in the index.
            let unstagedResult = try await runner.run(
                executable: git,
                arguments: ["-C", repoCwd, "diff", "--unified=3"],
                cwd: nil,
                environment: nil,
                timeout: 10
            )
            let stagedResult = try await runner.run(
                executable: git,
                arguments: ["-C", repoCwd, "diff", "--cached", "--unified=3"],
                cwd: nil,
                environment: nil,
                timeout: 10
            )
            // Treat as error only when git exited non-zero AND produced
            // no diff output. `git diff HEAD` returns 0 even with deltas,
            // so a non-zero exit with no stdout is a real failure (missing
            // repo, lock contention, etc.).
            if unstagedResult.exitStatus != 0 && unstagedResult.stdoutString.isEmpty {
                lastError = unstagedResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                files = []
                return
            }
            if stagedResult.exitStatus != 0 && stagedResult.stdoutString.isEmpty {
                lastError = stagedResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                files = []
                return
            }
            // T11 codex tension #7d: parse off main. `parse(unified:)`
            // walks a potentially huge string (5,000-line diffs hit the
            // 10s timeout previously). Run on a detached task to keep
            // the @MainActor responsive; commit the result back here.
            let untrackedResult = try await runner.run(
                executable: git,
                arguments: ["-C", repoCwd, "ls-files", "--others", "--exclude-standard"],
                cwd: nil,
                environment: nil,
                timeout: 10
            )
            let untrackedPaths: [String]
            if untrackedResult.exitStatus == 0 {
                untrackedPaths = untrackedResult.stdoutString
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
            } else {
                untrackedPaths = []
                diffLogger.warning("git ls-files failed exit=\(untrackedResult.exitStatus, privacy: .public) stderrBytes=\(untrackedResult.stderr.count, privacy: .public)")
            }
            let unstagedStdout = unstagedResult.stdoutString
            let stagedStdout = stagedResult.stdoutString
            let parsed = await Task.detached(priority: .userInitiated) {
                GitDiffStore.parse(unified: stagedStdout, changeState: .staged)
                    + GitDiffStore.parse(unified: unstagedStdout, changeState: .unstaged)
            }.value
            let untracked = untrackedPaths.compactMap {
                Self.syntheticUntrackedPatch(path: $0, repoCwd: repoCwd)
            }
            self.files = parsed + untracked
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
        guard hunk.changeState == .unstaged else {
            lastError = hunk.changeState == .staged
                ? "hunk is already staged"
                : "stage the whole untracked file"
            return
        }
        await applyPatch(hunk.rawPatch, cached: true, reverse: false, label: "stage hunk")
    }

    func revert(_ hunk: GitDiffHunk) async {
        switch hunk.changeState {
        case .unstaged:
            // Reverse-apply to the working tree. Removes only the unstaged
            // change without affecting the index.
            await applyPatch(hunk.rawPatch, cached: false, reverse: true, label: "revert hunk")
        case .staged:
            // Reverse-apply to the index. This is an unstage operation, not
            // a destructive file revert.
            await applyPatch(hunk.rawPatch, cached: true, reverse: true, label: "unstage hunk")
        case .untracked:
            lastError = "stage or trash the whole untracked file"
        }
    }

    func stageFile(_ file: GitDiffFile) async {
        switch file.changeState {
        case .untracked:
            await runGit(arguments: ["add", "--", file.path], label: "stage file")
        case .unstaged:
            await applyPatch(file.rawPatch, cached: true, reverse: false, label: "stage file")
        case .staged:
            lastError = nil
        }
    }

    func revertFile(_ file: GitDiffFile) async {
        switch file.changeState {
        case .untracked:
            let fileURL = URL(fileURLWithPath: repoCwd).appendingPathComponent(file.path)
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
                refresh()
            } catch {
                lastError = "move to Trash failed: \(error)"
            }
        case .unstaged:
            await applyPatch(file.rawPatch, cached: false, reverse: true, label: "revert file")
        case .staged:
            await applyPatch(file.rawPatch, cached: true, reverse: true, label: "unstage file")
        }
    }

    private func applyPatch(_ patch: String, cached: Bool, reverse: Bool, label: String) async {
        guard let git = gitLocator() else {
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
            let result = try await runner.run(
                executable: git,
                arguments: args,
                cwd: nil,
                environment: nil,
                timeout: 10
            )
            if result.exitStatus != 0 {
                lastError = "\(label) failed: \(result.stderrString.prefix(200))"
                diffLogger.error("\(label, privacy: .public) failed exit=\(result.exitStatus, privacy: .public) stderrBytes=\(result.stderr.count, privacy: .public)")
            } else {
                refresh()
            }
        } catch {
            lastError = "\(label) failed: \(error)"
        }
    }

    private func runGit(arguments: [String], label: String) async {
        guard let git = gitLocator() else {
            lastError = "git not found"
            return
        }
        do {
            let result = try await runner.run(
                executable: git,
                arguments: ["-C", repoCwd] + arguments,
                cwd: nil,
                environment: nil,
                timeout: 10
            )
            if result.exitStatus != 0 {
                lastError = "\(label) failed: \(result.stderrString.prefix(200))"
                diffLogger.error("\(label, privacy: .public) failed exit=\(result.exitStatus, privacy: .public) stderrBytes=\(result.stderr.count, privacy: .public)")
            } else {
                refresh()
            }
        } catch {
            lastError = "\(label) failed: \(error)"
        }
    }

    func commit(message: String) async -> Bool {
        guard let git = gitLocator() else {
            lastError = "git not found"
            return false
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { lastError = "commit message empty"; return false }
        do {
            let result = try await runner.run(
                executable: git,
                arguments: ["-C", repoCwd, "commit", "-m", trimmed],
                cwd: nil,
                environment: nil,
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

    nonisolated static func syntheticUntrackedPatch(path: String, repoCwd: String) -> GitDiffFile? {
        let fileURL = URL(fileURLWithPath: repoCwd).appendingPathComponent(path)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }

        let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let permissions = attributes[.posixPermissions] as? NSNumber
        let isExecutable = permissions.map { ($0.intValue & 0o111) != 0 } ?? false
        let mode = isExecutable ? "100755" : "100644"

        var header = [
            "diff --git a/\(path) b/\(path)",
            "new file mode \(mode)",
            "index 0000000..0000000",
            "--- /dev/null",
            "+++ b/\(path)",
        ].joined(separator: "\n") + "\n"

        guard let data = try? Data(contentsOf: fileURL) else {
            return GitDiffFile(
                path: path,
                isNewFile: true,
                isDeleted: false,
                isUntracked: true,
                changeState: .untracked,
                oldPath: nil,
                hunks: [],
                rawPatch: header
            )
        }
        guard data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8)
        else {
            return GitDiffFile(
                path: path,
                isNewFile: true,
                isDeleted: false,
                isUntracked: true,
                changeState: .untracked,
                oldPath: nil,
                hunks: [],
                rawPatch: header
            )
        }

        var lines = text.components(separatedBy: "\n")
        let endedWithNewline = text.hasSuffix("\n")
        if endedWithNewline, !lines.isEmpty {
            lines.removeLast()
        }
        if !lines.isEmpty {
            header += "@@ -0,0 +1,\(lines.count) @@\n"
            header += lines.map { "+\($0)" }.joined(separator: "\n")
            header += "\n"
            if !endedWithNewline {
                header += "\\ No newline at end of file\n"
            }
        }

        guard var file = parse(unified: header, changeState: .untracked).first else { return nil }
        file = GitDiffFile(
            path: file.path,
            isNewFile: file.isNewFile,
            isDeleted: file.isDeleted,
            isUntracked: true,
            changeState: .untracked,
            oldPath: file.oldPath,
            hunks: file.hunks,
            rawPatch: file.rawPatch
        )
        return file
    }

    // MARK: - File-change watch

    private func installIndexWatch() {
        // Watch .git/index (changes on every stage / unstage) and HEAD (commits).
        // A single watcher on the .git directory is the simplest reliable
        // signal — anything that changes index, HEAD, or refs lands there.
        let dotGit = Self.gitWatchDirectory(repoCwd: repoCwd)
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
        // Codex fix: capture the fd STRONGLY in the cancel handler. The
        // previous `[weak self]` capture meant that on deinit (when the
        // store has already begun deallocation), `self` is nil and the
        // fd never closes — opening / closing diff panes leaked an
        // fd per pane. The local `let fd = fd` capture is independent
        // of the store's lifetime and the cancel handler is guaranteed
        // to run exactly once after cancel(), so the close is safe
        // either way. `self.watchedFD` is still nilled inside the
        // weak-self path so stop()'s post-cancel close is a no-op.
        source.setCancelHandler { [weak self] in
            close(fd)
            if self?.watchedFD == fd {
                self?.watchedFD = -1
            }
        }
        source.resume()
        self.watcher = source
    }

    nonisolated static func gitWatchDirectory(repoCwd: String) -> String {
        let dotGit = URL(fileURLWithPath: repoCwd).appendingPathComponent(".git")
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return dotGit.path
        }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else {
            return dotGit.path
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else {
            return dotGit.path
        }
        let rawPath = String(trimmed.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if rawPath.hasPrefix("/") {
            url = URL(fileURLWithPath: rawPath)
        } else {
            url = URL(fileURLWithPath: repoCwd).appendingPathComponent(rawPath)
        }
        return url.standardizedFileURL.path
    }

    // MARK: - Unified diff parser

    nonisolated static func parse(
        unified: String,
        changeState: GitDiffChangeState = .unstaged
    ) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        var lines = unified.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        while !lines.isEmpty {
            guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("diff --git ") })
            else { break }
            let trailing = lines.firstIndex(from: headerIdx + 1,
                                            where: { $0.hasPrefix("diff --git ") })
                ?? lines.endIndex
            let fileSlice = Array(lines[headerIdx..<trailing])
            if let file = parseFile(fileSlice, changeState: changeState) {
                files.append(file)
            }
            lines = Array(lines[trailing..<lines.endIndex])
        }
        return files
    }

    private nonisolated static func parseFile(
        _ lines: [String],
        changeState: GitDiffChangeState
    ) -> GitDiffFile? {
        guard let first = lines.first, first.hasPrefix("diff --git ") else { return nil }
        // Header parse: "diff --git a/path b/path"
        //
        // P1-Mac-14: paths may contain spaces, so we can't split on " " naively
        // (a path like "my file.txt" splits the b-side away from itself). The
        // shape is always `a/<path> b/<same path>` with a single ` b/` delimiter
        // between the two halves, so anchor on ` b/` instead of whitespace.
        let header = String(first.dropFirst("diff --git ".count))
        var postPath: String = ""
        if let range = header.range(of: " b/"),
           header[..<range.lowerBound].hasPrefix("a/") {
            postPath = String(header[range.upperBound...])
        } else {
            // Fallback to the original split for unusual headers (e.g. no a/
            // prefix, mergetool output) — better to render something than
            // crash silently.
            let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
            if let bPart = parts.last, bPart.hasPrefix("b/") {
                postPath = String(bPart.dropFirst(2))
            }
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
                hunks.append(GitDiffHunk(
                    header: hunkHeader,
                    lines: body,
                    changeState: changeState,
                    rawPatch: patch
                ))
                i = j
            }
        }

        let rawPatch = lines.joined(separator: "\n") + "\n"
        return GitDiffFile(
            path: postPath,
            isNewFile: isNew,
            isDeleted: isDel,
            isUntracked: changeState == .untracked,
            changeState: changeState,
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
    let onBeforeDestructiveChange: (() async -> Bool)?
    @State private var expandedFiles: Set<UUID> = []
    @State private var showingCommitSheet = false
    @State private var commitMessage = ""
    @State private var isCommitting = false
    @State private var pendingTrashFile: GitDiffFile?
    @State private var safetyCheckpointError: String?

    @Environment(\.colorScheme) private var colorScheme

    init(repoCwd: String, onBeforeDestructiveChange: (() async -> Bool)? = nil) {
        self.onBeforeDestructiveChange = onBeforeDestructiveChange
        _store = StateObject(wrappedValue: GitDiffStore(repoCwd: repoCwd))
    }

    struct ActionDescriptor: Equatable {
        let title: String
        let accessibilityIdentifier: String
        let isEnabled: Bool

        init(title: String, accessibilityIdentifier: String, isEnabled: Bool = true) {
            self.title = title
            self.accessibilityIdentifier = accessibilityIdentifier
            self.isEnabled = isEnabled
        }
    }

    struct FileActionDescriptors: Equatable {
        static let rowAccessibilityIdentifier = "code.diff.git.file.row"
        static let toggleAccessibilityIdentifier = "code.diff.git.file.toggle"

        let stage: ActionDescriptor?
        let revert: ActionDescriptor?
        let unstage: ActionDescriptor?
        let trash: ActionDescriptor?
    }

    struct HunkActionDescriptors: Equatable {
        static let rowAccessibilityIdentifier = "code.diff.git.hunk.row"

        let stage: ActionDescriptor?
        let revert: ActionDescriptor?
        let unstage: ActionDescriptor?
    }

    struct CommitSheetDescriptor: Equatable {
        static let openAccessibilityIdentifier = "code.diff.git.commit.open"
        static let sheetAccessibilityIdentifier = "code.diff.git.commit.sheet"
        static let messageAccessibilityIdentifier = "code.diff.git.commit.message"
        static let cancelAccessibilityIdentifier = "code.diff.git.commit.cancel"

        let submit: ActionDescriptor
    }

    static func fileActionDescriptors(for changeState: GitDiffChangeState) -> FileActionDescriptors {
        switch changeState {
        case .unstaged:
            return FileActionDescriptors(
                stage: ActionDescriptor(title: "Stage", accessibilityIdentifier: "code.diff.git.file.stage"),
                revert: ActionDescriptor(title: "Revert", accessibilityIdentifier: "code.diff.git.file.revert"),
                unstage: nil,
                trash: nil
            )
        case .staged:
            return FileActionDescriptors(
                stage: nil,
                revert: nil,
                unstage: ActionDescriptor(title: "Unstage", accessibilityIdentifier: "code.diff.git.file.unstage"),
                trash: nil
            )
        case .untracked:
            return FileActionDescriptors(
                stage: ActionDescriptor(title: "Stage", accessibilityIdentifier: "code.diff.git.file.stage"),
                revert: nil,
                unstage: nil,
                trash: ActionDescriptor(title: "Trash", accessibilityIdentifier: "code.diff.git.file.trash")
            )
        }
    }

    static func hunkActionDescriptors(for changeState: GitDiffChangeState) -> HunkActionDescriptors {
        switch changeState {
        case .unstaged:
            return HunkActionDescriptors(
                stage: ActionDescriptor(title: "Stage", accessibilityIdentifier: "code.diff.git.hunk.stage"),
                revert: ActionDescriptor(title: "Revert", accessibilityIdentifier: "code.diff.git.hunk.revert"),
                unstage: nil
            )
        case .staged:
            return HunkActionDescriptors(
                stage: nil,
                revert: nil,
                unstage: ActionDescriptor(title: "Unstage", accessibilityIdentifier: "code.diff.git.hunk.unstage")
            )
        case .untracked:
            return HunkActionDescriptors(stage: nil, revert: nil, unstage: nil)
        }
    }

    static func commitSheetDescriptor(message: String, isCommitting: Bool) -> CommitSheetDescriptor {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitSheetDescriptor(
            submit: ActionDescriptor(
                title: isCommitting ? "Committing..." : "Commit",
                accessibilityIdentifier: "code.diff.git.commit.submit",
                isEnabled: !trimmed.isEmpty && !isCommitting
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .accessibilityIdentifier("code.diff.git.pane")
        .overlay(alignment: .topLeading) {
            Text(accessibilityStateValue)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("code.diff.git.state")
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .sheet(isPresented: $showingCommitSheet) { commitSheet }
        .alert(
            "Move untracked file to Trash?",
            isPresented: Binding(
                get: { pendingTrashFile != nil },
                set: { if !$0 { pendingTrashFile = nil } }
            ),
            presenting: pendingTrashFile
        ) { file in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive, action: ContinuumAnalytics.wrapButton(
                    "move_to_trash",
                    {
                runDestructiveChange {
                    await store.revertFile(file)
                }
            
                    }
                ))
        } message: { file in
            Text(file.path)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Diff")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if store.isLoading {
                ProgressView().controlSize(.mini)
                    .accessibilityIdentifier("code.diff.git.loading")
            }
            Spacer()
            if let last = store.lastRefresh {
                Text(last, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Button(action: ContinuumAnalytics.wrapButton(
                    "gitdiffpane_l788",
                    {
 store.refresh() 
                    }
                )) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(PressableButtonStyle())
            .help("Refresh diff")
            .accessibilityIdentifier("code.diff.git.refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("code.diff.git.header")
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
            .accessibilityIdentifier("code.diff.git.error")
        } else if let safetyCheckpointError {
            VStack(spacing: 8) {
                Image(systemName: "shield.slash")
                    .foregroundStyle(.orange)
                Text(safetyCheckpointError)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("code.diff.git.safety-error")
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
            .accessibilityIdentifier("code.diff.git.clean")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(store.files) { file in
                        fileSection(file)
                    }
                }
                .padding(8)
            }
            .accessibilityIdentifier("code.diff.git.files")
        }
    }

    private func fileSection(_ file: GitDiffFile) -> some View {
        let isExpanded = expandedFiles.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: ContinuumAnalytics.wrapButton(
                        "gitdiffpane_l855",
                        {
                    if isExpanded { expandedFiles.remove(file.id) }
                    else { expandedFiles.insert(file.id) }
                
                        }
                    )) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(isExpanded ? "Collapse \(file.path)" : "Expand \(file.path)")
                .accessibilityIdentifier(FileActionDescriptors.toggleAccessibilityIdentifier)
                Image(systemName: fileBadgeIcon(file))
                    .font(.system(size: 10))
                    .foregroundStyle(fileBadgeTint(file))
                Text(file.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 24, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                Text(file.changeState.label)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                Text("+\(file.hunks.reduce(0) { $0 + $1.addedCount })")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green)
                Text("-\(file.hunks.reduce(0) { $0 + $1.removedCount })")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                fileActionButtons(file)
                    .fixedSize()
                    .layoutPriority(2)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { expandedFiles.remove(file.id) }
                else { expandedFiles.insert(file.id) }
            }
            .accessibilityElement(children: .contain)

            if isExpanded {
                ForEach(file.hunks) { hunk in
                    hunkView(file: file, hunk: hunk)
                }
            }
        }
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(FileActionDescriptors.rowAccessibilityIdentifier)
    }

    @ViewBuilder
    private func fileActionButtons(_ file: GitDiffFile) -> some View {
        let actions = Self.fileActionDescriptors(for: file.changeState)
        if let stage = actions.stage {
            Button(stage.title, action: ContinuumAnalytics.wrapButton(
                    "title",
                    {
                Task { await store.stageFile(file) }
            
                    }
                ))
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .help("Stage all hunks in this file")
            .accessibilityIdentifier(stage.accessibilityIdentifier)
        }
        if let revert = actions.revert {
            Button(revert.title, action: ContinuumAnalytics.wrapButton(
                    "title",
                    {
                runDestructiveChange {
                    await store.revertFile(file)
                }
            
                    }
                ))
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .foregroundStyle(.red)
            .help("Revert unstaged hunks in this file")
            .accessibilityIdentifier(revert.accessibilityIdentifier)
        }
        if let unstage = actions.unstage {
            Button(unstage.title, action: ContinuumAnalytics.wrapButton(
                    "title",
                    {
                Task { await store.revertFile(file) }
            
                    }
                ))
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .help("Move this staged file back to unstaged changes")
            .accessibilityIdentifier(unstage.accessibilityIdentifier)
        }
        if let trash = actions.trash {
            Button(trash.title, action: ContinuumAnalytics.wrapButton(
                    "title",
                    {
                pendingTrashFile = file
            
                    }
                ))
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .foregroundStyle(.red)
            .help("Move this untracked file to Trash")
            .accessibilityIdentifier(trash.accessibilityIdentifier)
        }
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
                hunkActionButtons(hunk)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.06))
            .accessibilityIdentifier(HunkActionDescriptors.rowAccessibilityIdentifier)

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                hunkLineView(line)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func hunkActionButtons(_ hunk: GitDiffHunk) -> some View {
        let actions = Self.hunkActionDescriptors(for: hunk.changeState)
        if let stage = actions.stage {
            Button(stage.title, action: ContinuumAnalytics.wrapButton(
                    "title",
                    {
 Task { await store.stage(hunk) } 
                    }
                ))
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .accessibilityIdentifier(stage.accessibilityIdentifier)
        }
        if let revert = actions.revert {
            Button(revert.title, action: ContinuumAnalytics.wrapButton(
                    "title",
                    {
                runDestructiveChange {
                    await store.revert(hunk)
                }
            
                    }
                ))
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .accessibilityIdentifier(revert.accessibilityIdentifier)
        }
        if let unstage = actions.unstage {
            Button(unstage.title, action: ContinuumAnalytics.wrapButton(
                    "title",
                    {
 Task { await store.revert(hunk) } 
                    }
                ))
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .accessibilityIdentifier(unstage.accessibilityIdentifier)
        }
    }

    private func runDestructiveChange(_ action: @escaping () async -> Void) {
        Task {
            if let onBeforeDestructiveChange {
                guard await onBeforeDestructiveChange() else {
                    safetyCheckpointError = "Safety checkpoint failed. Destructive diff action cancelled."
                    return
                }
            }
            safetyCheckpointError = nil
            await action()
        }
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

    private var accessibilityStateValue: String {
        if let err = store.lastError {
            return "error:\(err.prefix(80))"
        }
        if let safetyCheckpointError {
            return "safety-error:\(safetyCheckpointError.prefix(80))"
        }
        let staged = store.files.filter { $0.changeState == .staged }.count
        let unstaged = store.files.filter { $0.changeState == .unstaged }.count
        let untracked = store.files.filter { $0.changeState == .untracked }.count
        let loading = store.isLoading ? " loading:true" : ""
        if store.files.isEmpty {
            return "clean\(loading)"
        }
        return "files:\(store.files.count) staged:\(staged) unstaged:\(unstaged) untracked:\(untracked)\(loading)"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !store.files.isEmpty {
                Button(action: ContinuumAnalytics.wrapButton(
                        "gitdiffpane_l1080",
                        {
 showingCommitSheet = true 
                        }
                    )) {
                    Label("Commit…", systemImage: "checkmark.seal")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
                .controlSize(.small)
                .accessibilityIdentifier(CommitSheetDescriptor.openAccessibilityIdentifier)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var commitSheet: some View {
        let descriptor = Self.commitSheetDescriptor(message: commitMessage, isCommitting: isCommitting)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Commit staged changes")
                .font(.system(size: 16, weight: .semibold))
            TextField("Commit message", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .frame(minWidth: 360)
                .accessibilityIdentifier(CommitSheetDescriptor.messageAccessibilityIdentifier)
            if let err = store.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("code.diff.git.commit.error")
            }
            HStack {
                Spacer()
                Button("Cancel", action: ContinuumAnalytics.wrapButton(
                        "cancel",
                        {
                    showingCommitSheet = false
                    commitMessage = ""
                
                        }
                    ))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(CommitSheetDescriptor.cancelAccessibilityIdentifier)
                Button(descriptor.submit.title, action: ContinuumAnalytics.wrapButton(
                        "title",
                        {
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
                    ))
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
                .disabled(!descriptor.submit.isEnabled)
                .accessibilityIdentifier(descriptor.submit.accessibilityIdentifier)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .accessibilityIdentifier(CommitSheetDescriptor.sheetAccessibilityIdentifier)
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}
