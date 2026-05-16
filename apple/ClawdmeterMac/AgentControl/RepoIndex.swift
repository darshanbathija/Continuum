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

    /// Narrow "writing right now" window. JSONLs touched within this window
    /// drive the green "live" dot in the sidebar. 5 minutes catches typical
    /// agent pause-between-turns without flickering off.
    public static let liveNowWindow: TimeInterval = 5 * 60

    /// Wide recent-activity window. JSONLs touched within this window are
    /// surfaced as individual outside-Clawdmeter rows in the sidebar so the
    /// user can revisit past sessions as read-only chat. 30 days mirrors the
    /// existing analytics "Past 30d" window.
    public static let recentActivityWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Legacy alias (still used in tests / callers). Equal to `liveNowWindow`.
    public static var liveActivityWindow: TimeInterval { liveNowWindow }

    /// Hard cap on recent-session rows surfaced per repo, so a repo with
    /// hundreds of past JSONLs doesn't bloat the sidebar.
    private static let maxRecentSessionsPerRepo: Int = 50

    private nonisolated func buildSnapshot() async -> [AgentRepo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var keysSeen = Set<String>()
        var displayNames: [String: String] = [:]
        /// Per repo: how many JSONL files have been touched in the last
        /// `liveNowWindow`. Non-zero = at least one agent actively writing.
        var liveCounts: [String: Int] = [:]
        /// Per repo: every JSONL within `recentActivityWindow` with its
        /// path + mtime + provider. Newest first after sorting below.
        var recentByRepo: [String: [RecentSession]] = [:]
        let liveCutoff = Date().addingTimeInterval(-Self.liveNowWindow)
        let recentCutoff = Date().addingTimeInterval(-Self.recentActivityWindow)

        // Source 1: ~/.claude/projects/ directory names (encoded cwds)
        let claudeProjects = home.appendingPathComponent(".claude/projects")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: claudeProjects, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for entry in entries where entry.hasDirectoryPath {
                if let cwd = readCwdFromClaudeProject(at: entry) {
                    let key = RepoIdentity.normalize(cwd)
                    if !keysSeen.contains(key) {
                        keysSeen.insert(key)
                        displayNames[key] = RepoIdentity.displayName(for: key)
                    }
                    if let jsonls = try? FileManager.default.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: [.contentModificationDateKey]
                    ) {
                        for jsonl in jsonls where jsonl.pathExtension == "jsonl" {
                            guard let mtime = try? jsonl.resourceValues(
                                forKeys: [.contentModificationDateKey]
                            ).contentModificationDate else { continue }
                            if mtime > liveCutoff {
                                liveCounts[key, default: 0] += 1
                            }
                            if mtime > recentCutoff {
                                let prompt = Self.readFirstUserPrompt(from: jsonl)
                                recentByRepo[key, default: []].append(
                                    RecentSession(
                                        path: jsonl.path,
                                        lastModified: mtime,
                                        provider: .claude,
                                        firstPrompt: prompt
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        // Source 2: ~/.codex/sessions/**/*.jsonl — collect cwd + mtime + path
        let codexSessions = home.appendingPathComponent(".codex/sessions")
        let codexJSONLs = await readCodexSessionMeta(at: codexSessions, recentCutoff: recentCutoff)
        for meta in codexJSONLs {
            let key = RepoIdentity.normalize(meta.cwd)
            if !keysSeen.contains(key) {
                keysSeen.insert(key)
                displayNames[key] = RepoIdentity.displayName(for: key)
            }
            if meta.mtime > liveCutoff {
                liveCounts[key, default: 0] += 1
            }
            let prompt = Self.readFirstUserPrompt(from: URL(fileURLWithPath: meta.path))
            recentByRepo[key, default: []].append(
                RecentSession(
                    path: meta.path,
                    lastModified: meta.mtime,
                    provider: .codex,
                    firstPrompt: prompt
                )
            )
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

        // Sort by most-recent activity (newest first) so the user's hot repos
        // float to the top of the sidebar. Repos with no recent activity fall
        // back to alphabetical. "Other" always last.
        let mostRecentByRepo: [String: Date] = recentByRepo.mapValues { entries in
            entries.map(\.lastModified).max() ?? .distantPast
        }
        let sortedKeys = keysSeen.sorted { a, b in
            if a == RepoKey.other { return false }
            if b == RepoKey.other { return true }
            let mra = mostRecentByRepo[a]
            let mrb = mostRecentByRepo[b]
            if let mra, let mrb {
                if mra != mrb { return mra > mrb }
            } else if mra != nil {
                return true
            } else if mrb != nil {
                return false
            }
            let da = displayNames[a] ?? a
            let db = displayNames[b] ?? b
            return da.localizedCaseInsensitiveCompare(db) == .orderedAscending
        }

        let repos = sortedKeys.map { key -> AgentRepo in
            let recent = (recentByRepo[key] ?? [])
                .sorted { $0.lastModified > $1.lastModified }
                .prefix(Self.maxRecentSessionsPerRepo)
            return AgentRepo(
                key: key,
                displayName: displayNames[key] ?? key,
                hasActiveSessions: false,  // filled in from registry
                liveSessionCount: liveCounts[key, default: 0],
                recentSessions: Array(recent)
            )
        }
        let liveTotal = liveCounts.values.reduce(0, +)
        let recentTotal = recentByRepo.values.reduce(0) { $0 + $1.count }
        repoIndexLogger.info("Snapshot built: \(repos.count) repos, \(liveTotal) live, \(recentTotal) recent (30d)")
        return repos
    }

    /// Read the cwd from the first JSONL entry under a Claude project dir.
    /// Falls back to decoding the directory name itself if no cwd is found
    /// (Claude encodes the cwd in the dir name with `/` and ` ` replaced by `-`).
    private nonisolated func readCwdFromClaudeProject(at dir: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        for entry in entries where entry.pathExtension == "jsonl" {
            if let cwd = readFirstCwd(from: entry) {
                return cwd
            }
        }
        // Fallback: decode the dir name. Claude's encoding replaces `/` AND
        // ` ` with `-`. Reversal is lossy (we can't tell underscores or real
        // hyphens apart from path-separator hyphens), but for cases where
        // the JSONL parse fails we'd rather show *something* than nothing.
        return Self.decodeClaudeDirName(dir.lastPathComponent)
    }

    /// Best-effort: turn `-Users-darshanbathija-1-Downloads-CC-Watch` into
    /// `/Users/darshanbathija_1/Downloads/CC Watch` by probing the filesystem.
    /// If a guess doesn't exist on disk we keep going; the first guess that
    /// matches a real directory wins. Falls back to the naive `-` → `/`
    /// substitution when nothing matches.
    static func decodeClaudeDirName(_ name: String) -> String? {
        // Strip leading `-` (it represents the leading `/`).
        guard name.hasPrefix("-") else { return nil }
        let trimmed = String(name.dropFirst())
        let segments = trimmed.split(separator: "-").map(String.init)
        guard !segments.isEmpty else { return nil }

        let fm = FileManager.default
        // Walk segments greedily: at each step, try the longest run that
        // matches an actual filesystem entry. If `Users-darshanbathija-1`
        // exists as `darshanbathija_1`, accept it.
        var currentPath = "/" + segments[0]
        var i = 1
        while i < segments.count {
            var matched = false
            // Try combining 1..5 remaining segments (handles `CC Watch`
            // which is 2 segments, and `darshanbathija_1` 2 segments).
            for combineCount in stride(from: 5, through: 1, by: -1) {
                let endIdx = min(i + combineCount, segments.count)
                let raw = segments[i..<endIdx].joined(separator: "-")
                // Try the literal version first, then with `-` → `_`, then ` ` → `-`.
                let candidates = [
                    raw,
                    raw.replacingOccurrences(of: "-", with: "_"),
                    raw.replacingOccurrences(of: "-", with: " "),
                ]
                for candidate in candidates {
                    let trial = (currentPath as NSString).appendingPathComponent(candidate)
                    if fm.fileExists(atPath: trial) {
                        currentPath = trial
                        i = endIdx
                        matched = true
                        break
                    }
                }
                if matched { break }
            }
            if !matched {
                // Nothing on disk matches — fall back to joining all remaining
                // with `-`. The repo display name will still look right.
                let rest = segments[i...].joined(separator: "-")
                currentPath = (currentPath as NSString).appendingPathComponent(rest)
                break
            }
        }
        return currentPath
    }

    /// Walk a tmux/codex sessions directory recursively for `*.jsonl` and
    /// extract the cwd from the first line of each. Returns one row per
    /// JSONL with its mtime + path so the caller can both register the cwd
    /// and surface each JSONL as a recent-session row.
    struct CodexSessionMeta: Sendable {
        let cwd: String
        let path: String
        let mtime: Date
    }
    private nonisolated func readCodexSessionMeta(
        at root: URL,
        recentCutoff: Date
    ) async -> [CodexSessionMeta] {
        var out: [CodexSessionMeta] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var inspected = 0
        for case let entry as URL in enumerator {
            inspected += 1
            if inspected > 5000 { break }
            guard entry.pathExtension == "jsonl" else { continue }
            guard let mtime = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { continue }
            // Cheap pre-filter: skip JSONLs older than the recent-activity
            // window unless we still need their cwd for repo discovery. We
            // always need the cwd, but very old ones don't need parsing past
            // the first hit, so just read on a wider net.
            guard mtime > recentCutoff else { continue }
            if let cwd = readFirstCwd(from: entry) {
                out.append(CodexSessionMeta(cwd: cwd, path: entry.path, mtime: mtime))
            }
        }
        return out
    }

    /// Scan the first ~64KB of a JSONL file looking for the first line with
    /// a `cwd` field. Claude wraps the actual user/assistant events in a
    /// `queue-operation` preamble that doesn't have `cwd` — we have to read
    /// past it. Codex's first line typically does have cwd.
    private nonisolated func readFirstCwd(from url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        // Read up to 256KB — single lines can be ~10KB (queue-operation with
        // a big content blob), so we need enough for a handful of lines.
        guard let chunk = try? fh.read(upToCount: 256 * 1024), !chunk.isEmpty else { return nil }
        var lineStart = chunk.startIndex
        while lineStart < chunk.endIndex {
            let newlineIdx = chunk[lineStart...].firstIndex(of: 0x0A) ?? chunk.endIndex
            let lineBytes = chunk[lineStart..<newlineIdx]
            lineStart = (newlineIdx < chunk.endIndex)
                ? chunk.index(after: newlineIdx)
                : chunk.endIndex
            guard !lineBytes.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any]
            else { continue }
            if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }

    /// Extract the first real user prompt from a JSONL. Used as the
    /// sidebar row title so "Claude session" becomes
    /// "fix the auth bug" / "review my eng plan" / etc. — actual intent.
    ///
    /// Skips:
    /// - `type: queue-operation` / `last-prompt` / `custom-title` (system
    ///   meta the user never typed)
    /// - `type: user` whose `message.content` is an array of `tool_result`
    ///   blocks (continuation messages, not prompts)
    /// - System reminders Claude Code injects (start with `<system-reminder>`)
    ///
    /// Returns a trimmed, single-line, ~80-character preview. Caller is
    /// responsible for fitting it into the row.
    static func readFirstUserPrompt(from url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let chunk = try? fh.read(upToCount: 256 * 1024), !chunk.isEmpty else { return nil }
        var lineStart = chunk.startIndex
        while lineStart < chunk.endIndex {
            let newlineIdx = chunk[lineStart...].firstIndex(of: 0x0A) ?? chunk.endIndex
            let lineBytes = chunk[lineStart..<newlineIdx]
            lineStart = (newlineIdx < chunk.endIndex)
                ? chunk.index(after: newlineIdx)
                : chunk.endIndex
            guard !lineBytes.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any]
            else { continue }
            guard (json["type"] as? String) == "user" else { continue }
            guard let message = json["message"] as? [String: Any] else { continue }
            // content can be a string (prompt) or array of blocks.
            if let text = message["content"] as? String,
               let cleaned = cleanPrompt(text) {
                return cleaned
            }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    let blockType = block["type"] as? String
                    if blockType == "text", let text = block["text"] as? String,
                       let cleaned = cleanPrompt(text) {
                        return cleaned
                    }
                    // `tool_result` blocks aren't user prompts — skip.
                }
            }
        }
        return nil
    }

    /// Normalize a raw user prompt: strip system reminders, collapse
    /// whitespace, trim to one line, cap at 80 chars. Returns nil if
    /// nothing user-visible remains.
    private static func cleanPrompt(_ raw: String) -> String? {
        var text = raw
        // Claude Code wraps system-reminder content in <system-reminder>
        // tags; strip them so the row doesn't read "<system-reminder>...".
        while let openRange = text.range(of: "<system-reminder>") {
            let afterOpen = openRange.upperBound
            if let closeRange = text.range(of: "</system-reminder>", range: afterOpen..<text.endIndex) {
                text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                text.removeSubrange(openRange.lowerBound..<text.endIndex)
            }
        }
        // Also strip <command-name> / <command-message> / <command-args>
        // wrappers Claude Code uses for slash commands. We keep the
        // command name itself as it's a useful summary.
        for tag in ["command-name", "command-args", "command-message", "local-command-stdout"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            while let openRange = text.range(of: open) {
                if let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex) {
                    if tag == "command-name" {
                        // Keep the inner text as the prompt.
                        let inner = text[openRange.upperBound..<closeRange.lowerBound]
                        text = String(inner)
                        break
                    } else {
                        text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                    }
                } else {
                    text.removeSubrange(openRange.lowerBound..<text.endIndex)
                    break
                }
            }
        }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= 80 { return collapsed }
        let head = collapsed.prefix(80)
        // Prefer a word boundary to avoid mid-word truncation.
        if let lastSpace = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: lastSpace) > 40 {
            return String(collapsed[..<lastSpace]) + "…"
        }
        return String(head) + "…"
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
