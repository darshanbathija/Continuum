import Foundation
import ClawdmeterShared
import OSLog

private let repoIndexLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RepoIndex")

/// Builds and maintains the repo list shown in the Sessions tab.
///
/// Per E6 (Phase 4 review decision): this is a background refresh actor
/// with 60s automatic refresh + pull-to-refresh + bounded depth on scan
/// roots. Tab activation is INSTANT — reads `latestSnapshot` from cache.
///
/// Sources unioned:
/// 1. Every directory under `~/.claude/projects/` (decoded → cwd → normalized)
/// 2. First-line cwd of every `*.jsonl` under `~/.codex/sessions/`
/// 3. Configured scan roots: `UserDefaults.clawdmeter.sessions.scanRoots`
///    (default EMPTY per Codex eng-round Round 1; user opts in)
///
/// Per Codex Round 1 concern #5: default scan roots are empty. Users add
/// `~/Downloads`, `~/Desktop`, etc. via the Settings UI. Depth bounded to
/// 4 levels so pathological roots don't hang the UI thread.
public actor RepoIndex {

    /// Current cached snapshot. The view layer reads this synchronously.
    public private(set) var latestSnapshot: [AgentRepo] = []

    /// UserDefaults key for configured scan roots.
    public static let scanRootsKey = "clawdmeter.sessions.scanRoots"

    /// Bounded depth for `.git` discovery. Codex review concern #5: deep
    /// roots like `~/` would otherwise traverse thousands of directories.
    public static let maxScanDepth = 4

    /// Track the most-recent refresh task so callers can `await` it.
    private var refreshTask: Task<[AgentRepo], Never>?

    public init() {}

    // MARK: - Public API

    /// Returns the current snapshot. Always cheap (in-memory).
    public func snapshot() -> [AgentRepo] {
        latestSnapshot
    }

    /// Trigger a background refresh. If one is already in flight, returns
    /// the existing task's result (debounces concurrent refresh requests).
    @discardableResult
    public func refresh() async -> [AgentRepo] {
        if let task = refreshTask, !task.isCancelled {
            return await task.value
        }
        let task = Task<[AgentRepo], Never> { @Sendable in
            await self.buildSnapshot()
        }
        refreshTask = task
        let result = await task.value
        // Self-reference is fine here — we're inside the actor.
        latestSnapshot = result
        refreshTask = nil
        return result
    }

    /// Start a periodic refresh loop. Every `interval` seconds, rebuild
    /// the snapshot. Caller is responsible for managing the returned Task
    /// (cancel on shutdown).
    public func startPeriodicRefresh(interval: TimeInterval = 60) -> Task<Void, Never> {
        Task { [weak self] in
            // Initial refresh immediately on launch.
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    // MARK: - Snapshot build

    private nonisolated func buildSnapshot() async -> [AgentRepo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var keysSeen = Set<String>()
        var displayNames: [String: String] = [:]

        // Source 1: ~/.claude/projects/ directory names (encoded cwds)
        let claudeProjects = home.appendingPathComponent(".claude/projects")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: claudeProjects, includingPropertiesForKeys: nil
        ) {
            for entry in entries where entry.hasDirectoryPath {
                // Claude encodes the cwd as the directory name with `/`
                // replaced by `-`. We can't reliably reverse this (since
                // the original path might've had `-`s already), so we read
                // a JSONL line from inside to get the canonical cwd.
                if let cwd = readCwdFromClaudeProject(at: entry) {
                    let key = RepoIdentity.normalize(cwd)
                    if !keysSeen.contains(key) {
                        keysSeen.insert(key)
                        displayNames[key] = RepoIdentity.displayName(for: key)
                    }
                }
            }
        }

        // Source 2: ~/.codex/sessions/**/*.jsonl
        let codexSessions = home.appendingPathComponent(".codex/sessions")
        let codexCwds = await readCwdsFromCodexSessions(at: codexSessions)
        for cwd in codexCwds {
            let key = RepoIdentity.normalize(cwd)
            if !keysSeen.contains(key) {
                keysSeen.insert(key)
                displayNames[key] = RepoIdentity.displayName(for: key)
            }
        }

        // Source 3: configured scan roots (default empty)
        let scanRoots = UserDefaults.standard.stringArray(forKey: RepoIndex.scanRootsKey) ?? []
        for rootRaw in scanRoots {
            let root = (rootRaw as NSString).expandingTildeInPath
            for repoPath in findGitRepos(under: root, maxDepth: RepoIndex.maxScanDepth) {
                let key = RepoIdentity.normalize(repoPath)
                if !keysSeen.contains(key) {
                    keysSeen.insert(key)
                    displayNames[key] = RepoIdentity.displayName(for: key)
                }
            }
        }

        // Sort alphabetically by display name, with "Other" last.
        let sortedKeys = keysSeen.sorted { a, b in
            let da = displayNames[a] ?? a
            let db = displayNames[b] ?? b
            if a == RepoKey.other { return false }
            if b == RepoKey.other { return true }
            return da.localizedCaseInsensitiveCompare(db) == .orderedAscending
        }

        let repos = sortedKeys.map { key in
            AgentRepo(
                key: key,
                displayName: displayNames[key] ?? key,
                hasActiveSessions: false  // Phase 2 fills this in from registry
            )
        }
        repoIndexLogger.info("Snapshot built: \(repos.count) repos")
        return repos
    }

    /// Read the cwd from the first JSONL entry under a Claude project dir.
    private nonisolated func readCwdFromClaudeProject(at dir: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        for entry in entries where entry.pathExtension == "jsonl" {
            if let cwd = readFirstCwd(from: entry) {
                return cwd
            }
        }
        return nil
    }

    /// Walk a tmux/codex sessions directory recursively for `*.jsonl` and
    /// extract the cwd from the first line of each.
    private nonisolated func readCwdsFromCodexSessions(at root: URL) async -> [String] {
        var found: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        // Bound the walk so a corrupted ~/.codex/ doesn't hang us.
        var inspected = 0
        for case let entry as URL in enumerator {
            inspected += 1
            if inspected > 5000 { break }
            guard entry.pathExtension == "jsonl" else { continue }
            if let cwd = readFirstCwd(from: entry) {
                found.insert(cwd)
            }
        }
        return Array(found)
    }

    /// Read the first JSON line of a JSONL file and extract the `cwd` field
    /// if present. Both Claude and Codex sessions stamp cwd in their first
    /// header line.
    private nonisolated func readFirstCwd(from url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        // First 8KB is plenty for a header.
        guard let chunk = try? fh.read(upToCount: 8192), !chunk.isEmpty else { return nil }
        // Find first newline.
        let newlineIdx = chunk.firstIndex(of: 0x0A) ?? chunk.endIndex
        let firstLine = chunk[..<newlineIdx]
        guard let json = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any] else {
            return nil
        }
        return json["cwd"] as? String
    }

    /// BFS under `root` for `.git` directories or files (worktree markers).
    /// Bounded by `maxDepth` so pathological roots like `~/` can't hang.
    private nonisolated func findGitRepos(under root: String, maxDepth: Int) -> [String] {
        var result: [String] = []
        let fm = FileManager.default
        var queue: [(path: String, depth: Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty {
            let (path, depth) = queue.removeFirst()
            visited += 1
            // Hard cap on directories visited to bound worst case.
            if visited > 10_000 { break }
            // Does this dir contain a `.git`?
            let gitPath = (path as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) {
                result.append(path)
                continue  // don't recurse into a repo (no nested repos in scope)
            }
            if depth >= maxDepth { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries {
                if entry.hasPrefix(".") { continue }  // skip hidden
                let child = (path as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                    queue.append((child, depth + 1))
                }
            }
        }
        return result
    }
}
