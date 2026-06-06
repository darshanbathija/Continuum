import Foundation
import ClawdmeterShared
import OSLog
import os.signpost

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

    /// 4th source provider (A1-A in /plan-eng-review). Returns the current
    /// `WorkspaceStore.workspaces` snapshot. Workspaces not already
    /// discovered by sources 1-3 (by canonical repoKey) are added to the
    /// sidebar so freshly-added repos with no JSONL history appear
    /// immediately. Defaults to `{ [] }` so back-compat call sites work
    /// without wiring the workspace store.
    nonisolated let workspaceSnapshotProvider: @Sendable () async -> [CodeWorkspaceRecord]

    public init(
        workspaceSnapshotProvider: @escaping @Sendable () async -> [CodeWorkspaceRecord] = { [] }
    ) {
        self.workspaceSnapshotProvider = workspaceSnapshotProvider
    }

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
        // T14 signpost: brackets the entire refresh so Instruments can
        // show how long a snapshot build takes (especially on cold cache).
        let signpostID = OSSignpostID(log: chatPerfLog)
        os_signpost(.begin, log: chatPerfLog, name: "repo-refresh",
                    signpostID: signpostID)
        defer {
            os_signpost(.end, log: chatPerfLog, name: "repo-refresh",
                        signpostID: signpostID)
        }
        // v0.26.3: ClawdmeterRealHome (getpwuid) rather than
        // homeDirectoryForCurrentUser so the sandboxed Release build
        // reads /Users/<you>/.claude/projects + /Users/<you>/.codex/sessions
        // (where the CLIs actually write rollouts) instead of the empty
        // container path. The Release entitlements grant read-only access
        // to /.claude/ and /.codex/ — see ClawdmeterMac-Release.entitlements.
        let home = ClawdmeterRealHome.url()
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
        // Snapshot the alias store once per refresh so we fold custom names
        // into RecentSession rows without taking the store's lock per file.
        let aliases = JSONLAliasStore.shared.snapshot()

        // Source 1: ~/.claude/projects/ directory names (encoded cwds)
        let claudeProjects = home.appendingPathComponent(".claude/projects")
        // v0.29.33: gate ~/.claude discovery on the Code "Discover parallel
        // sessions" opt-in alone. Off by default → opening Code does no
        // filesystem/cross-app read (no Downloads prompt). Opting in surfaces
        // all sessions regardless of which gauges are enabled — the prior
        // behavior the user expects from "discover".
        if ProviderEnablement.discoverParallelSessions,
           let entries = try? FileManager.default.contentsOfDirectory(
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
                                let result = Self.cachedFirstPromptResult(at: jsonl, mtime: mtime)
                                // Skip cron-style automations — they show
                                // up as `<scheduled-task>...` first user
                                // messages and aren't user-driven work.
                                if result.isScheduledTask { continue }
                                let title = result.prompt ?? Self.inferredRecentTitle(
                                    provider: .claude,
                                    cwd: cwd,
                                    jsonlURL: jsonl
                                )
                                recentByRepo[key, default: []].append(
                                    RecentSession(
                                        path: jsonl.path,
                                        lastModified: mtime,
                                        provider: .claude,
                                        firstPrompt: title,
                                        customName: aliases[jsonl.path]
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
        // v0.29.33: gate ~/.codex discovery on the opt-in alone.
        let codexJSONLs = ProviderEnablement.discoverParallelSessions
            ? readCodexSessionMeta(at: codexSessions, recentCutoff: recentCutoff)
            : []
        for meta in codexJSONLs {
            let key = RepoIdentity.normalize(meta.cwd)
            if !keysSeen.contains(key) {
                keysSeen.insert(key)
                displayNames[key] = RepoIdentity.displayName(for: key)
            }
            if meta.mtime > liveCutoff {
                liveCounts[key, default: 0] += 1
            }
            let result = Self.cachedFirstPromptResult(
                at: URL(fileURLWithPath: meta.path), mtime: meta.mtime
            )
            // Same scheduled-task filter as the Claude side — drop them
            // before they reach the sidebar.
            if result.isScheduledTask { continue }
            let jsonl = URL(fileURLWithPath: meta.path)
            let title = result.prompt ?? Self.inferredRecentTitle(
                provider: .codex,
                cwd: meta.cwd,
                jsonlURL: jsonl
            )
            recentByRepo[key, default: []].append(
                RecentSession(
                    path: meta.path,
                    lastModified: meta.mtime,
                    provider: .codex,
                    firstPrompt: title,
                    customName: aliases[meta.path]
                )
            )
        }

        // Source 3: configured scan roots (default empty). Gated on the
        // discovery opt-in so no user folders (Downloads/Desktop/…) are
        // walked until the user taps "Discover parallel sessions".
        let scanRoots = ProviderEnablement.discoverParallelSessions
            ? (UserDefaults.standard.stringArray(forKey: RepoIndex.scanRootsKey) ?? [])
            : []
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

        // Source 4 (A1-A, /plan-eng-review): WorkspaceStore.workspaces.
        // Workspaces explicitly added via the Add-Repo flow live here even
        // when they have no JSONL history yet. Dedup against sources 1-3
        // by canonical repoKey. Workspace metadata's display name wins
        // over the auto-derived one so user-renamed repos surface their
        // chosen label in the sidebar.
        let workspaces = await workspaceSnapshotProvider()
        for ws in workspaces {
            let key = RepoIdentity.normalize(ws.repoRoot)
            // Prefer explicit display names from WorkspaceStore even on
            // dedup; the user may have renamed the repo. The map gets
            // updated either way.
            displayNames[key] = ws.repoDisplayName.isEmpty
                ? (displayNames[key] ?? RepoIdentity.displayName(for: key))
                : ws.repoDisplayName
            if !keysSeen.contains(key) {
                keysSeen.insert(key)
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
        // T12: persist any cache mutations we picked up during this
        // refresh, then sweep entries whose JSONLs no longer exist on
        // disk. Both are cheap (sync writes < 50 ms even with thousands
        // of entries) and run AFTER the snapshot is ready so we never
        // hold the user's click waiting on a save.
        let pruned = FirstPromptCache.shared.pruneDeadFiles()
        FirstPromptCache.shared.save()
        let cacheSize = FirstPromptCache.shared.count
        repoIndexLogger.info("Snapshot built: \(repos.count) repos, \(liveTotal) live, \(recentTotal) recent (30d); first-prompt cache: \(cacheSize) entries, \(pruned) pruned")
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
    ) -> [CodexSessionMeta] {
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
            let info = readCodexSessionInfo(from: entry)
            guard let cwd = info.cwd else { continue }
            // Hide Codex sub-agents from the sidebar's Recent list. A
            // single user-driven Codex turn can spawn 5-10 worker
            // threads, each of which writes its own rollout JSONL —
            // surfacing every one duplicates the parent thread visually
            // and drowns out everything else. The parent thread (the
            // one the user actually launched) still shows up; its
            // worker children stay attached to it conceptually.
            //
            // Detection: Codex marks subagent rollouts with
            // `payload.thread_source = "subagent"` (and a non-null
            // `payload.agent_role`); top-level rollouts have
            // `thread_source = "user"`.
            if info.isSubagent { continue }
            out.append(CodexSessionMeta(cwd: cwd, path: entry.path, mtime: mtime))
        }
        return out
    }

    /// Returns the cwd + a flag indicating whether this rollout is a
    /// Codex sub-agent (worker thread spawned by a parent turn). Both
    /// fields come from the `session_meta` line at the top of the
    /// JSONL.
    struct CodexSessionInfo {
        let cwd: String?
        let isSubagent: Bool
    }
    private nonisolated func readCodexSessionInfo(from url: URL) -> CodexSessionInfo {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return CodexSessionInfo(cwd: nil, isSubagent: false)
        }
        defer { try? fh.close() }
        guard let chunk = try? fh.read(upToCount: 256 * 1024), !chunk.isEmpty else {
            return CodexSessionInfo(cwd: nil, isSubagent: false)
        }
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
            // Top-level cwd (Claude shape; rare for a file under
            // ~/.codex/sessions but cheap to check).
            if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                return CodexSessionInfo(cwd: cwd, isSubagent: false)
            }
            if let payload = json["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                let threadSource = payload["thread_source"] as? String
                let agentRole = payload["agent_role"] as? String
                let isSub = (threadSource == "subagent")
                    || (agentRole != nil && !(agentRole?.isEmpty ?? true))
                return CodexSessionInfo(cwd: cwd, isSubagent: isSub)
            }
        }
        return CodexSessionInfo(cwd: nil, isSubagent: false)
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
            // Top-level cwd — Claude Code JSONLs put it here.
            if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
            // Codex CLI nests cwd under payload (`session_meta` /
            // `turn_context` events). Without this branch, every Codex
            // JSONL produced nil cwd, the recent-session loop skipped
            // them, and the sidebar showed no Codex sessions for repos
            // that only had Codex JSONLs. Real bug: axtior-platform's
            // 10+ live Codex sessions were invisible because of this.
            if let payload = json["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }

    /// Result of inspecting a JSONL's first user line. Used by callers
    /// to label the row AND decide whether to surface it at all
    /// (scheduled-task automations are dropped from the sidebar).
    struct FirstPromptResult: Sendable, Hashable {
        let prompt: String?
        let isScheduledTask: Bool
    }

    /// T12 cached wrapper around `readFirstUserPrompt`. Hits the on-disk
    /// FirstPromptCache first; only reads from the JSONL when mtime+size
    /// have changed. Misses populate the cache for next refresh.
    ///
    /// Uses `URLResourceValues` with `.fileSizeKey` rather than
    /// `FileManager.attributesOfItem` so a JSONL that's a symlink to an
    /// offline network volume doesn't stall the actor for the TCP
    /// timeout (~75 s on macOS). The URL-resource-value path returns
    /// quickly with nil on unreachable paths.
    nonisolated static func cachedFirstPromptResult(
        at url: URL, mtime: Date
    ) -> FirstPromptResult {
        let path = url.path
        let size: Int64? = {
            // Bounded-time stat via URLResourceValues.
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let n = values?.fileSize { return Int64(n) }
            return nil
        }()
        guard let size else {
            // Couldn't stat — skip cache and try to read; if the file is
            // unreachable readFirstPrompt will fail quickly via the
            // FileHandle init returning nil.
            return readFirstPrompt(from: url)
        }
        let mtimeEpoch = mtime.timeIntervalSince1970
        if let entry = FirstPromptCache.shared.lookup(path: path),
           entry.mtime == mtimeEpoch, entry.size == size {
            return FirstPromptResult(
                prompt: entry.prompt,
                isScheduledTask: entry.isScheduledTask
            )
        }
        // Cache miss / stale — read + store.
        let result = readFirstPrompt(from: url)
        FirstPromptCache.shared.set(
            path: path,
            entry: .init(
                mtime: mtimeEpoch,
                size: size,
                prompt: result.prompt,
                isScheduledTask: result.isScheduledTask
            )
        )
        return result
    }

    /// Back-compat shim: existing call sites that only want the prompt
    /// string keep working without dealing with the scheduled-task flag.
    nonisolated static func cachedFirstUserPrompt(at url: URL, mtime: Date) -> String? {
        cachedFirstPromptResult(at: url, mtime: mtime).prompt
    }

    /// Some Codex/Conductor JSONLs have no real user prompt because they
    /// were created as continuation/title-generation runs. In that case,
    /// prefer transcript content first, then the live branch/feature name.
    /// That keeps old rows from being silently relabeled when the checkout
    /// later moves to a different branch.
    nonisolated static func inferredRecentTitle(
        provider _: AgentKind,
        cwd: String,
        jsonlURL: URL
    ) -> String? {
        if let summary = latestAssistantSummaryTitle(from: jsonlURL) {
            return summary
        }
        if let branch = branchTitle(at: cwd) {
            return branch
        }
        return pathFeatureTitle(from: cwd)
    }

    private nonisolated static func branchTitle(at cwd: String) -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd, isDirectory: true)
        for _ in 0..<5 {
            let gitURL = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    if let title = branchTitle(fromHeadFile: gitURL.appendingPathComponent("HEAD")) {
                        return title
                    }
                } else if let marker = try? String(contentsOf: gitURL, encoding: .utf8) {
                    let prefix = "gitdir:"
                    let trimmed = marker.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix(prefix) {
                        let raw = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        let gitDir = raw.hasPrefix("/")
                            ? URL(fileURLWithPath: raw)
                            : dir.appendingPathComponent(raw)
                        if let title = branchTitle(fromHeadFile: gitDir.appendingPathComponent("HEAD")) {
                            return title
                        }
                    }
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private nonisolated static func branchTitle(fromHeadFile headURL: URL) -> String? {
        guard let head = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty else { return nil }
        let raw: String
        if head.hasPrefix("ref: refs/heads/") {
            raw = String(head.dropFirst("ref: refs/heads/".count))
        } else {
            raw = head
        }
        let lower = raw.lowercased()
        guard lower != "main", lower != "master", lower != "head", raw.count < 120 else {
            return nil
        }
        return cleanBranchTitle(raw)
    }

    private nonisolated static func cleanBranchTitle(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("/") {
            let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2,
               ["darshanbathija", "codex", "claude"].contains(parts[0].lowercased()) {
                text = parts.dropFirst().joined(separator: "/")
            }
        }
        return cleanRecentTitle(text, maxLength: 80)
    }

    private nonisolated static func pathFeatureTitle(from cwd: String) -> String? {
        guard cwd.contains("/.claude/worktrees/") || cwd.contains("/.git/worktrees/") else {
            return nil
        }
        return cleanRecentTitle(URL(fileURLWithPath: cwd).lastPathComponent, maxLength: 80)
    }

    private nonisolated static func latestAssistantSummaryTitle(from url: URL) -> String? {
        for line in tailLines(from: url).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let candidate = assistantSummaryCandidate(from: json),
                  let title = cleanRecentTitle(candidate, maxLength: 96) else { continue }
            return title
        }
        return nil
    }

    private nonisolated static func tailLines(from url: URL, maxBytes: UInt64 = 512 * 1024) -> [Data] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return [] }
        let offset = size > maxBytes ? size - maxBytes : 0
        do {
            try fh.seek(toOffset: offset)
            guard let data = try fh.readToEnd(), !data.isEmpty else { return [] }
            var lines = data.split(separator: UInt8(0x0A)).map { Data($0) }
            if offset > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            return lines
        } catch {
            return []
        }
    }

    private nonisolated static func assistantSummaryCandidate(from json: [String: Any]) -> String? {
        if json["type"] as? String == "event_msg",
           let payload = json["payload"] as? [String: Any],
           payload["type"] as? String == "agent_message",
           let message = payload["message"] as? String {
            return message
        }
        if json["type"] as? String == "response_item",
           let payload = json["payload"] as? [String: Any] {
            return assistantSummaryCandidate(from: payload)
        }
        if let role = json["role"] as? String, role == "assistant",
           let text = textFromContent(json["content"]) {
            return text
        }
        if let message = json["message"] as? [String: Any],
           let role = message["role"] as? String, role == "assistant",
           let text = textFromContent(message["content"]) {
            return text
        }
        if json["type"] as? String == "assistant",
           let message = json["message"] as? [String: Any],
           let text = textFromContent(message["content"]) {
            return text
        }
        return nil
    }

    private nonisolated static func textFromContent(_ content: Any?) -> String? {
        if let text = content as? String {
            return text
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            if let text = block["output_text"] as? String { return text }
            return nil
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private nonisolated static func cleanRecentTitle(_ raw: String, maxLength: Int) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let citationRange = text.range(of: "<oai-mem-citation>") {
            text.removeSubrange(citationRange.lowerBound..<text.endIndex)
        }
        text = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'")))
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if ["done", "ok", "okay", "completed"].contains(lower) {
            return nil
        }
        if text.count > maxLength {
            let idx = text.index(text.startIndex, offsetBy: maxLength)
            text = String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
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
    /// Returns a trimmed, single-line, ~80-character preview PLUS a flag
    /// indicating whether the JSONL is an automation/scheduled-task
    /// session (the sidebar filters those out). Caller is responsible
    /// for fitting the prompt into the row.
    static func readFirstPrompt(from url: URL) -> FirstPromptResult {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return FirstPromptResult(prompt: nil, isScheduledTask: false)
        }
        defer { try? fh.close() }
        guard let chunk = try? fh.read(upToCount: 256 * 1024), !chunk.isEmpty else {
            return FirstPromptResult(prompt: nil, isScheduledTask: false)
        }
        var lineStart = chunk.startIndex
        while lineStart < chunk.endIndex {
            let newlineIdx = chunk[lineStart...].firstIndex(of: 0x0A) ?? chunk.endIndex
            let lineBytes = chunk[lineStart..<newlineIdx]
            lineStart = (newlineIdx < chunk.endIndex)
                ? chunk.index(after: newlineIdx)
                : chunk.endIndex
            // Delegate to the shared JSONLLineDecoder so the
            // `<system-reminder>` stripping, `<command-name>` unwrap,
            // `<scheduled-task>` detection, and 80-char truncation all
            // live in exactly one place. JSONLLineDecoderTests in
            // ClawdmeterShared protects the regex behavior.
            guard let json = JSONLLineDecoder.decodeJSON(line: Data(lineBytes)) else { continue }
            let line = JSONLLineDecoder.decodeFirstUserLine(from: json)
            if line.isScheduledTask {
                return FirstPromptResult(prompt: nil, isScheduledTask: true)
            }
            if let prompt = line.prompt {
                return FirstPromptResult(prompt: prompt, isScheduledTask: false)
            }
            // Otherwise (no prompt yet, no scheduled-task) — keep scanning.
        }
        return FirstPromptResult(prompt: nil, isScheduledTask: false)
    }

    /// Back-compat for callers that only want the prompt string.
    static func readFirstUserPrompt(from url: URL) -> String? {
        readFirstPrompt(from: url).prompt
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
