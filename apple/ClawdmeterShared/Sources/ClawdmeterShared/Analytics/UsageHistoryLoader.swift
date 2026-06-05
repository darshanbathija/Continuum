import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Loads + aggregates Claude and Codex history. One actor per app instance.
///
/// Architecture (plan A11 + A14 + A15 + A21 absorb):
///   - Parsers (`ClaudeUsageParser`, `CodexUsageParser`) are `nonisolated`
///     `static` functions. `withTaskGroup` parallelizes file walks without
///     re-entering the actor on every line — Apple Silicon hits its
///     `activeProcessorCount` cap.
///   - `inFlight: Task<UsageHistorySnapshot, Never>?` makes reentrant
///     `loadAll()` calls coalesce: the second caller awaits the first's
///     result instead of starting a parallel walk.
///   - Newest-mtime file per provider directory ALWAYS re-parses; its mtime
///     might match the cache but the file could still be mid-append.
///   - Per-file error isolation: one bad file logs + skips, the rest still
///     show up in the snapshot.
public actor UsageHistoryLoader {

    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "Analytics")
    private let claudeDir: URL
    private let codexDir: URL
    private let geminiDir: URL
    /// v0.23.8: agy CLI conversation root. Antigravity 2.0.6 ships two
    /// surfaces — the desktop Electron IDE at `~/.gemini/antigravity/`
    /// and the `agy` CLI at `~/.gemini/antigravity-cli/`. Both write
    /// per-conversation files under a `conversations/` subdir and a
    /// matching `brain/<uuid>/` content dir, but the CLI was invisible
    /// to analytics until this loader started walking it. Optional so
    /// machines without the CLI installed skip the pass cleanly.
    private let agyDir: URL?
    /// v0.22.8: OpenCode SQLite database (`~/.local/share/opencode/opencode.db`).
    /// Optional. Non-macOS builds do not auto-discover OpenCode's host DB,
    /// but tests and explicit callers may still inject a path.
    private let opencodeDBURL: URL?
    /// Continuum-owned Grok harness ledger. Optional so tests can inject a
    /// fixture and machines without Grok usage skip this pass cleanly.
    private let grokLedgerURL: URL?
    /// Grok CLI session root (`~/.grok/sessions`). This is distinct from the
    /// Continuum-owned ledger: it imports the CLI's own context-token metadata
    /// so ordinary Grok sessions show up in analytics.
    private let grokSessionsDir: URL?
    private let cursorLedgerURL: URL?
    /// Cursor IDE hook-log root (`~/Library/Application Support/Cursor/logs`).
    /// Optional so unit tests with synthetic history dirs do not accidentally
    /// ingest the developer machine's live Cursor logs.
    private let cursorHooksLogsDir: URL?
    private let cacheURL: URL?
    private let pricing: Pricing

    private var inFlight: Task<UsageHistorySnapshot, Never>?
    private var sequenceCounter: UInt64 = 0

    public init(
        claudeDir: URL? = nil,
        codexDir: URL? = nil,
        geminiDir: URL? = nil,
        agyDir: URL? = nil,
        opencodeDBURL: URL? = nil,
        grokLedgerURL: URL? = nil,
        grokSessionsDir: URL? = nil,
        cursorLedgerURL: URL? = nil,
        cursorHooksLogsDir: URL? = nil,
        cacheURL: URL? = nil,
        pricing: Pricing = .shared
    ) {
        // v0.26.3: ClawdmeterRealHome (getpwuid) rather than NSHomeDirectory()
        // so the sandboxed Release build resolves spend-history source
        // paths (~/.claude/projects/, ~/.codex/sessions/, ~/.gemini/...) to
        // the user's real home instead of the empty sandbox container. The
        // Release entitlements grant read-only access to /.claude/,
        // /.codex/, /.gemini/ — see ClawdmeterMac-Release.entitlements.
        let home = ClawdmeterRealHome.url()
        self.claudeDir = claudeDir ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexDir = codexDir ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        // v0.6.0: Antigravity 2 native. Replaces Gemini CLI v0.42's
        // ~/.gemini/tmp/<repo>/logs.json (which Antigravity stopped writing).
        // AntigravityUsageParser walks ~/.gemini/antigravity/conversations/{*.pb,*.db}
        // and resolves UUIDs to repos via BrainSummaryIndexer.
        // v0.23.8: SQLite `.db` files joined `.pb` files in this dir
        // when Antigravity migrated mid-2026; we now walk both extensions.
        self.geminiDir = geminiDir ?? home.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        // v0.23.8: agy CLI corpus. Resolves to nil when the dir is
        // missing so machines without agy installed skip the pass.
        let defaultAgy = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        self.agyDir = agyDir ?? (FileManager.default.fileExists(atPath: defaultAgy.path) ? defaultAgy : nil)
        // v0.22.8: lookup OPENCODE_DATA_DIR + standard XDG fallback.
        // OpencodeUsageParser.defaultDatabaseURL() returns nil if the
        // DB doesn't exist, so the analytics pipeline naturally skips
        // the opencode pass on machines without OpenCode installed.
        #if os(macOS)
        self.opencodeDBURL = opencodeDBURL ?? OpencodeUsageParser.defaultDatabaseURL()
        #else
        self.opencodeDBURL = opencodeDBURL
        #endif
        self.grokLedgerURL = grokLedgerURL ?? GrokUsageLedger.defaultURL()
        self.cursorLedgerURL = cursorLedgerURL ?? CursorACPUsageLedger.defaultURL()
        let usingDefaultHistoryDirs = claudeDir == nil && codexDir == nil && geminiDir == nil
        self.grokSessionsDir = grokSessionsDir ?? (usingDefaultHistoryDirs ? GrokCLIUsageParser.defaultSessionsDir(home: home) : nil)
        self.cursorHooksLogsDir = cursorHooksLogsDir ?? (usingDefaultHistoryDirs ? CursorHooksUsageParser.defaultLogsDir() : nil)
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
        self.pricing = pricing
    }

    private static func defaultCacheURL() -> URL? {
        guard let root = UsageStore.containerURL else { return nil }
        return root.appendingPathComponent("analytics-cache.json")
    }

    // MARK: - Public API

    public func loadAll() async -> UsageHistorySnapshot {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task<UsageHistorySnapshot, Never> {
            await self.performLoad()
        }
        self.inFlight = task
        let result = await task.value
        self.inFlight = nil
        return result
    }

    public func refresh() async -> UsageHistorySnapshot {
        await loadAll()
    }

    public func invalidate() {
        // Best-effort delete of the cache file. Next loadAll() does a full
        // cold parse.
        if let cacheURL {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    /// Lightweight probe: returns the most-recent mtime across every
    /// source dir + file we would parse. **Does not parse anything** —
    /// just stats files. Consumers (B2 mtime probe + idle backoff in
    /// `UsageHistoryStore`) use this to short-circuit `loadAll()` when
    /// no source data changed since the last refresh.
    ///
    /// Returns `nil` if no source files exist (fresh machine, no agents
    /// run yet). Caller treats `nil` as "no activity yet" — same as a
    /// successful probe with an old timestamp.
    ///
    /// Per-provider strategy:
    /// - Claude / Codex: walk top of `~/.claude/projects/` /
    ///   `~/.codex/sessions/` (recursive); take the newest mtime found.
    /// - Gemini Antigravity (`.pb` + `.db`) and `agy` CLI: same recursive
    ///   walk over their respective dirs.
    /// - OpenCode: `stat` the SQLite db file PLUS its WAL/SHM sidecars.
    ///   OpenCode runs in WAL mode (see `OpencodeUsageParser`), so commits
    ///   land in `opencode.db-wal` before the next checkpoint touches
    ///   `opencode.db` itself — stat'ing only the main file would let the
    ///   probe short-circuit a refresh that the SSE adapter just kicked
    ///   off via `.opencodeUsageRecorded` (see PR #137 review P0 #1).
    ///
    /// Plan: B2 (Phase 2) — see
    /// `.claude/plans/study-this-codebase-crystalline-shore.md`. Codex
    /// eng-review #9 (analytics retention) folds into this probe — it's
    /// the foundation for idle-backoff polling.
    public func mostRecentSourceMtime() -> Date? {
        var maxMtime: Date? = nil
        func observe(_ date: Date?) {
            guard let date else { return }
            if let current = maxMtime {
                if date > current { maxMtime = date }
            } else {
                maxMtime = date
            }
        }

        for dir in [claudeDir, codexDir, geminiDir] {
            observe(Self.mostRecentMtime(inDirectory: dir))
        }
        if let agyDir { observe(Self.mostRecentMtime(inDirectory: agyDir)) }
        if let opencodeDBURL {
            // OpenCode writes in SQLite WAL mode. The committed-but-not-
            // checkpointed page-deltas live in `<db>-wal`; the shared-
            // memory index lives in `<db>-shm`. Take the max across all
            // three so a hot stream of SSE `usage` events doesn't get
            // throttled by a probe that only sees the rarely-touched
            // main file.
            observe(Self.fileMtime(opencodeDBURL))
            let walURL = URL(fileURLWithPath: opencodeDBURL.path + "-wal")
            observe(Self.fileMtime(walURL))
            let shmURL = URL(fileURLWithPath: opencodeDBURL.path + "-shm")
            observe(Self.fileMtime(shmURL))
        }
        if let grokLedgerURL {
            observe(Self.fileMtime(grokLedgerURL))
        }
        if let grokSessionsDir { observe(Self.mostRecentMtime(inDirectory: grokSessionsDir)) }
        observe(CursorACPUsageLedger.mostRecentMtime(url: cursorLedgerURL))
        if let cursorHooksLogsDir {
            observe(Self.mostRecentMtime(inDirectory: cursorHooksLogsDir))
        }
        return maxMtime
    }

    private static func fileMtime(_ url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    private static func mostRecentMtime(inDirectory dir: URL) -> Date? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        // Enumerate recursively; we only need the mtime, no read.
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var maxMtime: Date? = nil
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate
            else { continue }
            if let current = maxMtime {
                if mtime > current { maxMtime = mtime }
            } else {
                maxMtime = mtime
            }
        }
        return maxMtime
    }

    private static func grokCLISessionKey(_ record: UsageRecord) -> String? {
        guard let key = record.dedupKey,
              key.hasPrefix("grok-cli:")
        else { return nil }
        guard let range = key.range(of: ":signals") else { return key }
        return String(key[..<range.upperBound])
    }

    // MARK: - Aggregation

    private func performLoad() async -> UsageHistorySnapshot {
        let startedAt = Date()

        let cache = readCache()
        var nextCache = AnalyticsCache(version: AnalyticsCache.currentVersion, files: [:])

        let claudeFiles = enumerate(dir: claudeDir, suffix: ".jsonl")
        let codexFiles = enumerate(dir: codexDir, suffix: ".jsonl")
        // v0.6.0 Antigravity 2: per-conversation files in
        // ~/.gemini/antigravity/conversations/. Pre-build the brain index
        // once per load so the per-file parser doesn't re-read the
        // global index for every conversation.
        // v0.23.8: walk both `.pb` (legacy proto) and `.db` (SQLite
        // WAL — the newer format Antigravity migrated to mid-2026).
        // The user's $0.026/day was caused by the loader ignoring 31
        // of 69 desktop conversations because they were `.db` files;
        // see `Self.dedupedDesktopFiles(...)` for the UUID dedup that
        // handles the rare case where the same conversation has both.
        let geminiPBFiles = enumerate(dir: geminiDir, suffix: ".pb")
        let geminiDBFiles = enumerate(dir: geminiDir, suffix: ".db")
        let geminiFiles = Self.dedupedDesktopFiles(pb: geminiPBFiles, db: geminiDBFiles)
        let cursorHookFiles: [FileMeta] = {
            guard let cursorHooksLogsDir else { return [] }
            return enumerate(dir: cursorHooksLogsDir, suffix: ".log")
                .filter { $0.url.lastPathComponent.hasPrefix("cursor.hooks.workspaceId-") }
        }()
        let antigravityDataDir = geminiDir.deletingLastPathComponent()
        let brainIndex = BrainSummaryIndexer.read(
            at: antigravityDataDir.appendingPathComponent("agyhub_summaries_proto.pb")
        )
        // Read the current model from antigravity_state.pbtxt — used by
        // every UsageRecord we emit for pricing lookup.
        let antigravityModel = (try? AntigravityStateReader.read(
            at: antigravityDataDir.appendingPathComponent("antigravity_state.pbtxt")
        ))?.displayModelName ?? "gemini-3.5-flash"

        // v0.23.8: agy CLI walk. Same shape as desktop (per-conversation
        // .pb file + matching brain/<uuid>/ dir) but a separate root,
        // separate brain index, separate model setting, and a distinct
        // `agy:` dedup prefix so the two surfaces can't collide.
        let agyFiles: [FileMeta]
        let agyDataDir: URL?
        let agyBrainIndex: BrainSummaryIndex
        let agyModel: String
        if let agyDir, FileManager.default.fileExists(atPath: agyDir.path) {
            // agy writes SQLite `.db` conversations (no `.pb`), so walk BOTH
            // extensions and dedup by UUID exactly like the desktop pass.
            // The prior `.pb`-only walk silently dropped 100% of agy CLI
            // usage — every agy conversation in antigravity-cli/ is a `.db`.
            let agyPB = enumerate(dir: agyDir, suffix: ".pb")
            let agyDB = enumerate(dir: agyDir, suffix: ".db")
            agyFiles = Self.dedupedDesktopFiles(pb: agyPB, db: agyDB)
            let root = agyDir.deletingLastPathComponent()
            agyDataDir = root
            // agy doesn't write `agyhub_summaries_proto.pb`; the loader
            // falls back to the brain-UUID prefix for repo bucketing.
            agyBrainIndex = BrainSummaryIndex(byUUID: [:], byCwdPath: [:])
            // Prefer the agy-specific model from settings.json; fall
            // back to the desktop's selection when settings.json is
            // missing or unparseable (covers the common case where the
            // user runs one model across both surfaces).
            agyModel = AgyConversationReader.resolveModelKey(rootURL: root) ?? antigravityModel
        } else {
            agyFiles = []
            agyDataDir = nil
            agyBrainIndex = BrainSummaryIndex(byUUID: [:], byCwdPath: [:])
            agyModel = antigravityModel
        }

        // Identify active (newest mtime) per dir — those bypass cache.
        let claudeActive = claudeFiles.max(by: { $0.mtime < $1.mtime })?.url
        let codexActive = codexFiles.max(by: { $0.mtime < $1.mtime })?.url
        let geminiActive = geminiFiles.max(by: { $0.mtime < $1.mtime })?.url
        let cursorHookActive = cursorHookFiles.max(by: { $0.mtime < $1.mtime })?.url

        let claudeResults = await parseConcurrently(
            files: claudeFiles,
            cache: cache,
            activeURL: claudeActive,
            parser: { url in
                try Self.parseClaudeFile(at: url)
            }
        )

        let codexResults = await parseConcurrently(
            files: codexFiles,
            cache: cache,
            activeURL: codexActive,
            parser: { url in
                try Self.parseCodexFile(at: url)
            }
        )

        let cursorHookResults = await parseConcurrently(
            files: cursorHookFiles,
            cache: cache,
            activeURL: cursorHookActive,
            parser: { url in
                try Self.parseCursorHooksFile(at: url)
            }
        )

        let geminiResults = await parseConcurrently(
            files: geminiFiles,
            cache: cache,
            activeURL: geminiActive,
            parser: { url in
                try Self.parseAntigravityFile(
                    at: url,
                    antigravityDataDir: antigravityDataDir,
                    brainIndex: brainIndex,
                    modelName: antigravityModel,
                    dedupPrefix: "antigravity"
                )
            }
        )

        // v0.23.8: agy CLI pass. Runs only when the corpus exists on
        // disk — `agyDataDir` is nil otherwise. Same parser as desktop
        // with a distinct dedup prefix so brain UUIDs don't collide.
        let agyResults: [PerFileResult]
        if let agyDataDir, !agyFiles.isEmpty {
            let agyActive = agyFiles.max(by: { $0.mtime < $1.mtime })?.url
            agyResults = await parseConcurrently(
                files: agyFiles,
                cache: cache,
                activeURL: agyActive,
                parser: { url in
                    try Self.parseAntigravityFile(
                        at: url,
                        antigravityDataDir: agyDataDir,
                        brainIndex: agyBrainIndex,
                        modelName: agyModel,
                        dedupPrefix: "agy"
                    )
                }
            )
        } else {
            agyResults = []
        }

        // Merge all per-file results, applying global cross-file dedup. Per
        // plan A9: the per-file `dedupKeys` set is unioned into a global Set
        // so duplicates that span files are caught even on cache hits.
        var claudeDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        var codexDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        // Gemini per-day-per-repo bucket — populated by GeminiUsageParser
        // walking `~/.gemini/tmp/<repo>/logs.json`. The cloudcode-pa quota
        // endpoint doesn't expose per-request tokens; UsageRecord carries
        // `tokens.requestCount = 1` with `costUSD = 0` per Gemini record
        // (the analytics schema split — see plan §Analytics schema split).
        // Optional so a missing parser pass writes an empty `.gemini` slot.
        var geminiDayByRepo: [Date: [RepoKey: TokenTotals]]? = nil
        var cursorDayByRepo: [Date: [RepoKey: TokenTotals]]? = nil
        var seenDedupKeys = Set<String>()
        var unpricedModelTokens: [String: TokenTotals] = [:]
        var tokensByModel: [String: TokenTotals] = [:]
        var byDayByModel: [Date: [String: TokenTotals]] = [:]
        var sessionCount = 0

        for result in claudeResults {
            mergePerFileResult(
                result,
                into: &claudeDayByRepo,
                dedup: &seenDedupKeys,
                unpriced: &unpricedModelTokens,
                byModel: &tokensByModel,
                byDayByModel: &byDayByModel
            )
            sessionCount += 1
            nextCache.files[result.path] = result.cacheEntry
        }
        for result in codexResults {
            mergePerFileResult(
                result,
                into: &codexDayByRepo,
                dedup: &seenDedupKeys,
                unpriced: &unpricedModelTokens,
                byModel: &tokensByModel,
                byDayByModel: &byDayByModel
            )
            sessionCount += 1
            nextCache.files[result.path] = result.cacheEntry
        }
        if !cursorHookResults.isEmpty {
            var bucket = cursorDayByRepo ?? [:]
            for result in cursorHookResults {
                mergePerFileResult(
                    result,
                    into: &bucket,
                    dedup: &seenDedupKeys,
                    unpriced: &unpricedModelTokens,
                    byModel: &tokensByModel,
                    byDayByModel: &byDayByModel
                )
                sessionCount += 1
                nextCache.files[result.path] = result.cacheEntry
            }
            cursorDayByRepo = bucket
        }
        // v0.23.8: fold desktop IDE and agy CLI results into the same
        // .gemini bucket. The two surfaces share pricing and share the
        // user's Gemini-monthly-spend mental model, so analytics treats
        // them as one provider. Per-record `dedupKey` ("antigravity:UUID"
        // vs "agy:UUID") still keeps the two sets from cross-talking on
        // brain-UUID collisions.
        let combinedGemini = geminiResults + agyResults
        if !combinedGemini.isEmpty {
            geminiDayByRepo = [:]
            for result in combinedGemini {
                mergePerFileResult(
                    result,
                    into: &geminiDayByRepo!,
                    dedup: &seenDedupKeys,
                    unpriced: &unpricedModelTokens,
                    byModel: &tokensByModel,
                    byDayByModel: &byDayByModel
                )
                sessionCount += 1
                nextCache.files[result.path] = result.cacheEntry
            }
        }

        writeCache(nextCache)

        // v0.22.8: parse OpenCode SQLite store. Skipped when the DB is
        // missing (no OpenCode install) or on non-macOS targets.
        var opencodeDayByRepo: [Date: [RepoKey: TokenTotals]]? = nil
        #if os(macOS)
        if let opencodeDBURL {
            let records = OpencodeUsageParser.parse(databaseURL: opencodeDBURL)
            if !records.isEmpty {
                var bucket: [Date: [RepoKey: TokenTotals]] = [:]
                var localDedup = Set<String>()
                var localUnpriced: [String: TokenTotals] = [:]
                var localByModel: [String: TokenTotals] = [:]
                var localByDayByModel: [Date: [String: TokenTotals]] = [:]
                for record in records {
                    Self.accumulate(
                        record: record,
                        into: &bucket,
                        dedup: &localDedup,
                        unpriced: &localUnpriced,
                        byModel: &localByModel,
                        byDayByModel: &localByDayByModel
                    )
                }
                opencodeDayByRepo = bucket
                // Fold opencode's unpriced + per-model buckets into the shared maps.
                for (model, totals) in localUnpriced {
                    unpricedModelTokens[model, default: .zero] += totals
                }
                for (model, totals) in localByModel {
                    tokensByModel[model, default: .zero] += totals
                }
                for (day, modelMap) in localByDayByModel {
                    var existing = byDayByModel[day, default: [:]]
                    for (model, totals) in modelMap { existing[model, default: .zero] += totals }
                    byDayByModel[day] = existing
                }
                // Single SQLite source → one "session" for the metrics counter.
                sessionCount += 1
            }
        }
        #endif

        // Grok usage comes from two historical sources:
        //   1. Continuum's own harness ledger for precise per-turn ACP usage.
        //   2. Grok CLI `signals.json` files for ordinary `grok` sessions. Those
        //      carry the same context-token limit numbers the TUI displays.
        // Neither source synthesizes a live account quota endpoint.
        var grokDayByRepo: [Date: [RepoKey: TokenTotals]]? = nil
        var grokRecords: [UsageRecord] = []
        var grokLedgerRecordCount = 0
        var grokContextLimit: GrokCLIUsageParser.ContextLimit?
        if let grokLedgerURL {
            let ledgerRecords = GrokUsageLedger.records(from: grokLedgerURL)
            grokLedgerRecordCount = ledgerRecords.count
            grokRecords.append(contentsOf: ledgerRecords)
        }
        if let grokSessionsDir {
            let cliRecords = GrokCLIUsageParser.parseSessions(root: grokSessionsDir)
            grokRecords.append(contentsOf: cliRecords)
            grokContextLimit = GrokCLIUsageParser.latestContextLimit(root: grokSessionsDir)
            let cliSessionKeys = Set(cliRecords.compactMap(Self.grokCLISessionKey))
            sessionCount += cliSessionKeys.isEmpty ? cliRecords.count : cliSessionKeys.count
        }
        if !grokRecords.isEmpty {
            var bucket: [Date: [RepoKey: TokenTotals]] = [:]
            var localDedup = Set<String>()
            var localUnpriced: [String: TokenTotals] = [:]
            var localByModel: [String: TokenTotals] = [:]
            var localByDayByModel: [Date: [String: TokenTotals]] = [:]
            for record in grokRecords {
                Self.accumulate(
                    record: record,
                    into: &bucket,
                    dedup: &localDedup,
                    unpriced: &localUnpriced,
                    byModel: &localByModel,
                    byDayByModel: &localByDayByModel
                )
            }
            grokDayByRepo = bucket
            for (model, totals) in localUnpriced {
                unpricedModelTokens[model, default: .zero] += totals
            }
            for (model, totals) in localByModel {
                tokensByModel[model, default: .zero] += totals
            }
            for (day, modelMap) in localByDayByModel {
                var existing = byDayByModel[day, default: [:]]
                for (model, totals) in modelMap { existing[model, default: .zero] += totals }
                byDayByModel[day] = existing
            }
            if grokLedgerRecordCount > 0 {
                sessionCount += 1
            }
        }

        let cursorRecords = CursorACPUsageLedger.parseFile(at: cursorLedgerURL)
        if !cursorRecords.isEmpty {
            var bucket: [Date: [RepoKey: TokenTotals]] = [:]
            var localDedup = Set<String>()
            var localUnpriced: [String: TokenTotals] = [:]
            var localByModel: [String: TokenTotals] = [:]
            var localByDayByModel: [Date: [String: TokenTotals]] = [:]
            for record in cursorRecords {
                Self.accumulate(
                    record: record,
                    into: &bucket,
                    dedup: &localDedup,
                    unpriced: &localUnpriced,
                    byModel: &localByModel,
                    byDayByModel: &localByDayByModel
                )
            }
            var mergedCursorDayByRepo = cursorDayByRepo ?? [:]
            for (day, repoMap) in bucket {
                var existing = mergedCursorDayByRepo[day, default: [:]]
                for (repo, totals) in repoMap {
                    existing[repo, default: .zero] += totals
                }
                mergedCursorDayByRepo[day] = existing
            }
            cursorDayByRepo = mergedCursorDayByRepo
            for (model, totals) in localUnpriced {
                unpricedModelTokens[model, default: .zero] += totals
            }
            for (model, totals) in localByModel {
                tokensByModel[model, default: .zero] += totals
            }
            for (day, modelMap) in localByDayByModel {
                var existing = byDayByModel[day, default: [:]]
                for (model, totals) in modelMap { existing[model, default: .zero] += totals }
                byDayByModel[day] = existing
            }
            sessionCount += 1
        }

        // Build per-provider windows. byProvider dict slot lands here per
        // 2026-05-19 Gemini-provider refactor; the Gemini parsing pass is
        // wired through `geminiDayByRepo` below once `GeminiUsageParser`
        // lands. Until then, Gemini analytics surfaces as `.empty`.
        let now = Date()
        var byProvider: [UsageRecord.Provider: ProviderTotals] = [:]
        byProvider[.claude] = buildProviderTotals(from: claudeDayByRepo, now: now)
        byProvider[.codex] = buildProviderTotals(from: codexDayByRepo, now: now)
        if let geminiDayByRepo, !geminiDayByRepo.isEmpty {
            byProvider[.gemini] = buildProviderTotals(from: geminiDayByRepo, now: now)
        }
        if let opencodeDayByRepo, !opencodeDayByRepo.isEmpty {
            byProvider[.opencode] = buildProviderTotals(from: opencodeDayByRepo, now: now)
        }
        if let grokDayByRepo, !grokDayByRepo.isEmpty {
            byProvider[.grok] = buildProviderTotals(from: grokDayByRepo, now: now)
        }
        if let cursorDayByRepo, !cursorDayByRepo.isEmpty {
            byProvider[.cursor] = buildProviderTotals(from: cursorDayByRepo, now: now)
        }

        sequenceCounter += 1
        let snapshot = UsageHistorySnapshot(
            byProvider: byProvider,
            computedAt: Date(),
            sequenceNumber: sequenceCounter,
            sessionCount: sessionCount,
            unpricedModelTokens: unpricedModelTokens,
            tokensByModel: tokensByModel,
            byDayByModel: byDayByModel,
            grokContextLimit: grokContextLimit
        )

        let elapsed = Date().timeIntervalSince(startedAt)
        logger.info("Analytics loadAll: \(sessionCount, privacy: .public) files, \(String(format: "%.2f", elapsed), privacy: .public)s")

        return snapshot
    }

    // MARK: - Per-file walk

    private struct FileMeta: Sendable {
        let url: URL
        let mtime: Date
        let size: Int
    }

    private struct PerFileResult: Sendable {
        let path: String
        let byDayByRepo: [Date: [RepoKey: TokenTotals]]
        let byDayByModel: [Date: [String: TokenTotals]]
        let dedupKeys: Set<String>
        let unpricedModelTokens: [String: TokenTotals]
        let byModelTokens: [String: TokenTotals]
        let cacheEntry: AnalyticsCache.FileEntry
    }

    /// Merges the desktop IDE's `.pb` (legacy) and `.db` (SQLite WAL,
    /// post-migration) conversation files into a single list, deduping
    /// by UUID. When a UUID appears in both formats — which can happen
    /// after Antigravity rewrites a session to SQLite — we keep the
    /// newer file. Brain-dir token estimates are identical regardless
    /// of which conversation-file format we pass to the probe, so the
    /// choice only affects file-mtime / file-size recorded in the cache.
    private nonisolated static func dedupedDesktopFiles(pb: [FileMeta], db: [FileMeta]) -> [FileMeta] {
        var byUUID: [String: FileMeta] = [:]
        for file in pb + db {
            let uuid = file.url.deletingPathExtension().lastPathComponent
            if let existing = byUUID[uuid] {
                if file.mtime > existing.mtime {
                    byUUID[uuid] = file
                }
            } else {
                byUUID[uuid] = file
            }
        }
        return Array(byUUID.values)
    }

    private func enumerate(dir: URL, suffix: String) -> [FileMeta] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var out: [FileMeta] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(suffix) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            out.append(FileMeta(url: url, mtime: mtime, size: size))
        }
        return out
    }

    private func parseConcurrently(
        files: [FileMeta],
        cache: AnalyticsCache,
        activeURL: URL?,
        parser: @Sendable @escaping (URL) throws -> PerFileResult
    ) async -> [PerFileResult] {
        // Resolve from cache where possible, schedule parses for the rest.
        var cached: [PerFileResult] = []
        var toParse: [FileMeta] = []
        for file in files {
            let isActive = file.url == activeURL
            if !isActive,
               let entry = cache.files[file.url.path],
               entry.mtime == file.mtime.timeIntervalSince1970,
               entry.size == file.size {
                cached.append(PerFileResult(
                    path: file.url.path,
                    byDayByRepo: entry.decodedByDayByRepo(),
                    byDayByModel: entry.decodedByDayByModel(),
                    dedupKeys: entry.decodedDedupKeys(),
                    unpricedModelTokens: entry.decodedUnpricedModelTokens(),
                    byModelTokens: entry.decodedByModelTokens(),
                    cacheEntry: entry
                ))
            } else {
                toParse.append(file)
            }
        }

        let parsed: [PerFileResult] = await withTaskGroup(of: PerFileResult?.self) { group in
            let concurrency = min(toParse.count, max(2, ProcessInfo.processInfo.activeProcessorCount))
            var iterator = toParse.makeIterator()
            var inFlight = 0

            // Seed with N tasks, then add one for each completion.
            while inFlight < concurrency, let file = iterator.next() {
                inFlight += 1
                group.addTask {
                    do {
                        return try parser(file.url)
                    } catch {
                        return nil
                    }
                }
            }

            var out: [PerFileResult] = []
            while let result = await group.next() {
                inFlight -= 1
                if let r = result { out.append(r) }
                if let file = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        do {
                            return try parser(file.url)
                        } catch {
                            return nil
                        }
                    }
                }
            }
            return out
        }

        return cached + parsed
    }

    private nonisolated static func parseClaudeFile(at url: URL) throws -> PerFileResult {
        let data = try Data(contentsOf: url)
        var byDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        var dedupKeys = Set<String>()
        var unpriced: [String: TokenTotals] = [:]
        var byModel: [String: TokenTotals] = [:]
        var byDayByModel: [Date: [String: TokenTotals]] = [:]

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // F1a-wire shipped in #152 and is now the default-ON path: every
        // raw JSONL line flows through `ClaudeAdapter` (via the bridge)
        // → canonical `ProviderRuntimeEvent` → `UsageRecord`. The
        // `FeatureFlags.useClaudeAdapter` env/UserDefaults override
        // remains live as a rollback escape hatch — flip the env to
        // `CLAWDMETER_USE_CLAUDE_ADAPTER=0` and the legacy
        // `ClaudeUsageParser` path lights back up. Parity is enforced by
        // `F1aParityTests`; the legacy parser stays in place precisely
        // so that suite + the rollback path keep working.
        let useAdapter = FeatureFlags.useClaudeAdapter
        for rawLine in lines {
            let lineData = Data(rawLine)
            let record: UsageRecord? = useAdapter
                ? ClaudeAdapterUsageBridge.parseLine(lineData)
                : ClaudeUsageParser.parse(line: lineData)
            guard let record else { continue }
            accumulate(record: record, into: &byDayByRepo, dedup: &dedupKeys, unpriced: &unpriced, byModel: &byModel, byDayByModel: &byDayByModel)
        }

        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let entry = AnalyticsCache.FileEntry(
            mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? data.count,
            byDayByRepo: AnalyticsCache.FileEntry.encode(byDayByRepo),
            dedupKeys: Array(dedupKeys),
            unpricedModelTokens: unpriced,
            byModelTokens: byModel,
            byDayByModel: AnalyticsCache.FileEntry.encodeModels(byDayByModel)
        )

        return PerFileResult(
            path: url.path,
            byDayByRepo: byDayByRepo,
            byDayByModel: byDayByModel,
            dedupKeys: dedupKeys,
            unpricedModelTokens: unpriced,
            byModelTokens: byModel,
            cacheEntry: entry
        )
    }

    private nonisolated static func parseCursorHooksFile(at url: URL) throws -> PerFileResult {
        let records = try CursorHooksUsageParser.parse(file: url)
        var byDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        var dedupKeys = Set<String>()
        var unpriced: [String: TokenTotals] = [:]
        var byModel: [String: TokenTotals] = [:]
        var byDayByModel: [Date: [String: TokenTotals]] = [:]
        for record in records {
            accumulate(
                record: record,
                into: &byDayByRepo,
                dedup: &dedupKeys,
                unpriced: &unpriced,
                byModel: &byModel,
                byDayByModel: &byDayByModel
            )
        }

        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let entry = AnalyticsCache.FileEntry(
            mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? 0,
            byDayByRepo: AnalyticsCache.FileEntry.encode(byDayByRepo),
            dedupKeys: Array(dedupKeys),
            unpricedModelTokens: unpriced,
            byModelTokens: byModel,
            byDayByModel: AnalyticsCache.FileEntry.encodeModels(byDayByModel)
        )

        return PerFileResult(
            path: url.path,
            byDayByRepo: byDayByRepo,
            byDayByModel: byDayByModel,
            dedupKeys: dedupKeys,
            unpricedModelTokens: unpriced,
            byModelTokens: byModel,
            cacheEntry: entry
        )
    }

    private nonisolated static func parseCodexFile(at url: URL) throws -> PerFileResult {
        // F1b-wire shipped in #165 and is now the default-ON path: every
        // Codex JSONL file flows through `CodexAdapter` (via the bridge)
        // → canonical `ProviderRuntimeEvent` → `UsageRecord`. The
        // `FeatureFlags.useCodexAdapter` env/UserDefaults override
        // remains live as a rollback escape hatch — flip the env to
        // `CLAWDMETER_USE_CODEX_ADAPTER=0` and the legacy
        // `CodexUsageParser` path lights back up.
        //
        // CodexAdapter is stateful (cumulative→delta math + running
        // model/cwd), so the bridge constructs one adapter per file and
        // walks lines in order. The legacy parser owns its own internal
        // state machine of the same shape — the bridge is a behavioral
        // identity over it. Parity enforced by `F1bParityTests`.
        let records: [UsageRecord] = FeatureFlags.useCodexAdapter
            ? try CodexAdapterUsageBridge.parseFile(at: url)
            : try CodexUsageParser.parse(file: url)
        var byDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        var dedupKeys = Set<String>()
        var unpriced: [String: TokenTotals] = [:]
        var byModel: [String: TokenTotals] = [:]
        var byDayByModel: [Date: [String: TokenTotals]] = [:]
        for record in records {
            accumulate(record: record, into: &byDayByRepo, dedup: &dedupKeys, unpriced: &unpriced, byModel: &byModel, byDayByModel: &byDayByModel)
        }

        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let entry = AnalyticsCache.FileEntry(
            mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? 0,
            byDayByRepo: AnalyticsCache.FileEntry.encode(byDayByRepo),
            dedupKeys: Array(dedupKeys),
            unpricedModelTokens: unpriced,
            byModelTokens: byModel,
            byDayByModel: AnalyticsCache.FileEntry.encodeModels(byDayByModel)
        )

        return PerFileResult(
            path: url.path,
            byDayByRepo: byDayByRepo,
            byDayByModel: byDayByModel,
            dedupKeys: dedupKeys,
            unpricedModelTokens: unpriced,
            byModelTokens: byModel,
            cacheEntry: entry
        )
    }

    private nonisolated static func parseAntigravityFile(
        at url: URL,
        antigravityDataDir: URL,
        brainIndex: BrainSummaryIndex,
        modelName: String,
        dedupPrefix: String
    ) throws -> PerFileResult {
        // v0.6.0 Antigravity 2: per-conversation file (.pb or .db).
        // The file itself is encrypted at rest (see ConversationProtoParser);
        // tokens are estimated from the matching brain dir's metadata.
        //
        // F1e-wire shipped in #169 and is now the default-ON path: every
        // Antigravity conversation flows through the canonical adapter
        // via `AntigravityAdapterUsageBridge` → `AntigravityAdapter` →
        // canonical `ProviderRuntimeEvent` → `UsageRecord`. The
        // `FeatureFlags.useAntigravityAdapter` env/UserDefaults override
        // remains live as a rollback escape hatch — flip the env to
        // `CLAWDMETER_USE_ANTIGRAVITY_ADAPTER=0` and the legacy
        // `AntigravityUsageParser` path lights back up. Parity enforced
        // by `F1eParityTests`. The bridge mirrors the existing PR #154
        // OS guard for the `.db` overload; watchOS / tvOS always falls
        // back to the byte-estimator path regardless of the flag.
        let records: [UsageRecord]
        if FeatureFlags.useAntigravityAdapter {
            records = try AntigravityAdapterUsageBridge.parse(
                conversationURL: url,
                antigravityDataDir: antigravityDataDir,
                brainIndex: brainIndex,
                modelName: modelName,
                dedupPrefix: dedupPrefix
            )
        } else {
            records = try AntigravityUsageParser.parse(
                conversationURL: url,
                antigravityDataDir: antigravityDataDir,
                brainIndex: brainIndex,
                modelName: modelName,
                dedupPrefix: dedupPrefix
            )
        }
        var byDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        var dedupKeys = Set<String>()
        var unpriced: [String: TokenTotals] = [:]
        var byModel: [String: TokenTotals] = [:]
        var byDayByModel: [Date: [String: TokenTotals]] = [:]
        for record in records {
            accumulate(record: record, into: &byDayByRepo, dedup: &dedupKeys, unpriced: &unpriced, byModel: &byModel, byDayByModel: &byDayByModel)
        }

        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let entry = AnalyticsCache.FileEntry(
            mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? 0,
            byDayByRepo: AnalyticsCache.FileEntry.encode(byDayByRepo),
            dedupKeys: Array(dedupKeys),
            unpricedModelTokens: unpriced,
            byModelTokens: byModel,
            byDayByModel: AnalyticsCache.FileEntry.encodeModels(byDayByModel)
        )

        return PerFileResult(
            path: url.path,
            byDayByRepo: byDayByRepo,
            byDayByModel: byDayByModel,
            dedupKeys: dedupKeys,
            unpricedModelTokens: unpriced,
            byModelTokens: byModel,
            cacheEntry: entry
        )
    }

    private nonisolated static func accumulate(
        record: UsageRecord,
        into byDayByRepo: inout [Date: [RepoKey: TokenTotals]],
        dedup: inout Set<String>,
        unpriced: inout [String: TokenTotals],
        byModel: inout [String: TokenTotals],
        byDayByModel: inout [Date: [String: TokenTotals]]
    ) {
        // Per-file dedup: within a single file we skip records whose dedupKey
        // we've already seen. Cross-file dedup happens at merge time inside
        // the actor.
        if let key = record.dedupKey, !dedup.insert(key).inserted {
            return
        }

        let day = Calendar.current.startOfDay(for: record.timestamp)
        let repo = record.repo ?? RepoKey.unknown

        // Compute cost.
        let pricedByRateCard = Pricing.shared.isPriced(record.model)
        let cost = record.tokens.costUSD > 0
            ? record.tokens.costUSD
            : Pricing.shared.cost(for: record.model, tokens: record.tokens)
        var tokensWithCost = record.tokens
        tokensWithCost.costUSD = cost
        let isPriced = record.tokens.costUSD > 0 || pricedByRateCard

        // Track unpriced model tokens.
        if !isPriced && record.tokens.totalTokens > 0 {
            unpriced[record.model, default: .zero] += tokensWithCost
        }

        // Per-model token rollup for ALL models (powers the Usage tab's
        // tokens-by-model/family section), keyed by the raw model name.
        if record.tokens.totalTokens > 0 {
            let modelKey = Self.modelRollupKey(for: record)
            byModel[modelKey, default: .zero] += tokensWithCost
            // Per-day-by-model adds the time dimension so the Usage tab's
            // tokens-by-model section can be windowed (today/7d/30d/90d) the
            // same way byDayByRepo powers the dollar charts.
            byDayByModel[day, default: [:]][modelKey, default: .zero] += tokensWithCost
        }

        // Bucket.
        var dayMap = byDayByRepo[day, default: [:]]
        dayMap[repo, default: .zero] += tokensWithCost
        byDayByRepo[day] = dayMap
    }

    /// Merge a per-file result into the cross-file rollup. Applies global
    /// cross-file dedup using the unioned `seenDedupKeys` set; if a key
    /// appears in two files, only the first contributes.
    private func mergePerFileResult(
        _ result: PerFileResult,
        into byDayByRepo: inout [Date: [RepoKey: TokenTotals]],
        dedup: inout Set<String>,
        unpriced: inout [String: TokenTotals],
        byModel: inout [String: TokenTotals],
        byDayByModel: inout [Date: [String: TokenTotals]]
    ) {
        // Cached files store already-aggregated totals, but Claude can
        // duplicate individual `(messageId, requestId)` rows across files.
        // If this file collides with anything already seen, reparse it and
        // apply the global dedup row-by-row instead of guessing at a whole-
        // file skip/accept heuristic.
        if !result.dedupKeys.isDisjoint(with: dedup) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: result.path)) {
                // F1-finalize: mirror the strangler-fig flag check used in
                // `parseClaudeFile` so the cross-file reparse path stays
                // consistent with the per-file path. With the default
                // flipped to ON in F1-finalize, the canonical adapter
                // path is the default; the env override
                // (`CLAWDMETER_USE_CLAUDE_ADAPTER=0`) still threads
                // through here so a rollback reparses lines via the
                // legacy parser too — keeping both legs identical.
                let useAdapter = FeatureFlags.useClaudeAdapter
                for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    let lineData = Data(rawLine)
                    let record: UsageRecord? = useAdapter
                        ? ClaudeAdapterUsageBridge.parseLine(lineData)
                        : ClaudeUsageParser.parse(line: lineData)
                    guard let record else { continue }
                    Self.accumulateGlobal(record: record, into: &byDayByRepo, dedup: &dedup, unpriced: &unpriced, byModel: &byModel, byDayByModel: &byDayByModel)
                }
            }
            return
        }

        dedup.formUnion(result.dedupKeys)

        for (day, repoMap) in result.byDayByRepo {
            var existing = byDayByRepo[day, default: [:]]
            for (repo, totals) in repoMap {
                existing[repo, default: .zero] += totals
            }
            byDayByRepo[day] = existing
        }
        for (model, totals) in result.unpricedModelTokens {
            unpriced[model, default: .zero] += totals
        }
        for (model, totals) in result.byModelTokens {
            byModel[model, default: .zero] += totals
        }
        for (day, modelMap) in result.byDayByModel {
            var existing = byDayByModel[day, default: [:]]
            for (model, totals) in modelMap {
                existing[model, default: .zero] += totals
            }
            byDayByModel[day] = existing
        }
    }

    private nonisolated static func accumulateGlobal(
        record: UsageRecord,
        into byDayByRepo: inout [Date: [RepoKey: TokenTotals]],
        dedup: inout Set<String>,
        unpriced: inout [String: TokenTotals],
        byModel: inout [String: TokenTotals],
        byDayByModel: inout [Date: [String: TokenTotals]]
    ) {
        if let key = record.dedupKey, !dedup.insert(key).inserted {
            return
        }

        let day = Calendar.current.startOfDay(for: record.timestamp)
        let repo = record.repo ?? RepoKey.unknown
        let pricedByRateCard = Pricing.shared.isPriced(record.model)
        let cost = record.tokens.costUSD > 0
            ? record.tokens.costUSD
            : Pricing.shared.cost(for: record.model, tokens: record.tokens)
        var tokensWithCost = record.tokens
        tokensWithCost.costUSD = cost
        if !(record.tokens.costUSD > 0 || pricedByRateCard), record.tokens.totalTokens > 0 {
            unpriced[record.model, default: .zero] += tokensWithCost
        }
        if record.tokens.totalTokens > 0 {
            let modelKey = Self.modelRollupKey(for: record)
            byModel[modelKey, default: .zero] += tokensWithCost
            // Per-day-by-model adds the time dimension so the Usage tab's
            // tokens-by-model section can be windowed (today/7d/30d/90d) the
            // same way byDayByRepo powers the dollar charts.
            byDayByModel[day, default: [:]][modelKey, default: .zero] += tokensWithCost
        }

        var dayMap = byDayByRepo[day, default: [:]]
        dayMap[repo, default: .zero] += tokensWithCost
        byDayByRepo[day] = dayMap
    }

    private nonisolated static func modelRollupKey(for record: UsageRecord) -> String {
        let model = record.model.isEmpty ? record.provider.rawValue : record.model
        switch record.provider {
        case .cursor:
            return model.lowercased().hasPrefix("cursor/") ? model : "cursor/\(model)"
        default:
            return model
        }
    }

    // MARK: - Window rollups

    private func buildProviderTotals(
        from byDayByRepo: [Date: [RepoKey: TokenTotals]],
        now: Date
    ) -> ProviderTotals {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let past7Start = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let past30Start = cal.date(byAdding: .day, value: -29, to: today) ?? today
        // 84-day (12-week) span to match the 90d chart's weekly12 window, so the
        // per-repo 90d rows can't sum past the 90d headline (totalsForRange).
        let past90Start = cal.date(byAdding: .day, value: -83, to: today) ?? today

        var byDayForChart: [Date: TokenTotals] = [:]
        var todayMap: [RepoKey: TokenTotals] = [:]
        var past7Map: [RepoKey: TokenTotals] = [:]
        var past30Map: [RepoKey: TokenTotals] = [:]
        var past90Map: [RepoKey: TokenTotals] = [:]
        var allMap: [RepoKey: TokenTotals] = [:]

        for (day, repoMap) in byDayByRepo {
            // Per-day total for the chart.
            let dayTotal = repoMap.values.reduce(TokenTotals.zero, +)
            byDayForChart[day] = dayTotal

            for (repo, totals) in repoMap {
                allMap[repo, default: .zero] += totals
                if day >= past90Start {
                    past90Map[repo, default: .zero] += totals
                }
                if day >= past30Start {
                    past30Map[repo, default: .zero] += totals
                }
                if day >= past7Start {
                    past7Map[repo, default: .zero] += totals
                }
                if day == today {
                    todayMap[repo, default: .zero] += totals
                }
            }
        }

        return ProviderTotals(
            today: rollupWindow(todayMap),
            past7d: rollupWindow(past7Map),
            past30d: rollupWindow(past30Map),
            past90d: rollupWindow(past90Map),
            allTime: rollupWindow(allMap),
            byDay: byDayForChart
        )
    }

    private func rollupWindow(_ map: [RepoKey: TokenTotals]) -> WindowTotals {
        let totals = map.values.reduce(TokenTotals.zero, +)
        let sorted = map.sorted { $0.value.costUSD > $1.value.costUSD }
        let topN = 8
        let top = Array(sorted.prefix(topN))
        let restRows = Array(sorted.dropFirst(topN))
        let restTotals = restRows.map(\.value).reduce(TokenTotals.zero, +)
        var byRepo: [(repo: RepoKey, totals: TokenTotals)] = top.map { ($0.key, $0.value) }
        if !restRows.isEmpty {
            byRepo.append((repo: "__rest__", totals: restTotals))
        }
        return WindowTotals(totals: totals, byRepo: byRepo, restCount: restRows.count)
    }

    // MARK: - Cache I/O

    private func readCache() -> AnalyticsCache {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(AnalyticsCache.self, from: data),
              decoded.version == AnalyticsCache.currentVersion
        else {
            return AnalyticsCache(version: AnalyticsCache.currentVersion, files: [:])
        }
        return decoded
    }

    private func writeCache(_ cache: AnalyticsCache) {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            logger.error("Analytics cache write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - On-disk cache schema (v4)

/// Plan A12: cache schema v4 stores per-file `byDayByRepo` instead of the v3
/// `byDay + singleRepo` shape, because a single Claude JSONL can contain
/// records for multiple repos.
struct AnalyticsCache: Codable, Sendable {
    // v8 (2026-05-15): RepoIdentity now buckets every non-git cwd under
    // the single `RepoKey.other` sentinel — previously paths like
    // `/Users/x` or `~/.paperclip/instances/<env>/workspaces/<UUID>` (with
    // no findable `.git`) showed up as their own rows, polluting the
    // by-repo list. Old v7 caches re-parse on first load.
    // v9 (2026-05-19): UsageHistorySnapshot now stores `byProvider` dict
    // instead of hardcoded `claude`/`codex` fields; TokenTotals gains
    // `requestCount` for Gemini's quota-only telemetry. Custom Codable
    // in both types handles missing-field decode for older snapshots, but
    // the v9 bump forces a cold reparse so the on-disk cache shape stays
    // consistent with the in-memory shape after upgrade.
    // v10 (2026-05-23): Antigravity token estimator now sums every
    // content-bearing file in the brain dir (.md/.txt/.json/.jsonl/.log
    // recursively, minus *.metadata.json) instead of top-level *.md only,
    // and the loader now walks both `.pb` and `.db` desktop files plus
    // the previously-invisible `~/.gemini/antigravity-cli/conversations/`
    // agy CLI corpus. Cached file rows from v9 carry the old estimates
    // and would underreport Antigravity cost by ~60×, so the bump forces
    // a one-time full reparse.
    // v11 (2026-05-23): .db files now use AntigravityDBUsageParser to
    // extract real input/output/cached/reasoning token counts from the
    // plaintext step_payload protobuf, replacing the bytes-÷-4 heuristic.
    // Real counts run ~10-30× higher than the heuristic; bumping the
    // schema forces a one-time reparse so v10 caches don't keep showing
    // estimated numbers.
    // v12 (2026-05-29): FileEntry gains `byModelTokens`, a per-model token
    // rollup across all models, to power the Usage tab's tokens-by-model /
    // family section. v11 caches lack it; the bump forces a one-time reparse
    // so per-model totals are complete rather than only covering changed files.
    // v13 (2026-05-29): FileEntry gains `byDayByModel`, the per-day-by-model
    // rollup that lets the tokens-by-model section be windowed by time range
    // (today/7d/30d/90d) like the dollar charts. v12 caches carry no day
    // dimension for models; the bump forces a one-time reparse so windowed
    // model totals are complete rather than only covering changed files.
    // v14 (2026-05-29): Claude dedup now collapses on `message.id` alone when
    // the top-level `requestId` is absent (Claude Code dropped it in the
    // opus-4-8-era JSONL). v13 caches baked in the pre-fix per-file costs that
    // counted replayed/resumed history 2-3x (today's Claude read ~$1528 vs
    // ccusage's ~$625); without this bump those inflated costs would survive
    // the code fix for every already-cached file. The bump forces a one-time
    // reparse so the corrected dedup actually applies to historical days.
    // v15 (2026-06-06): Cursor Composer hook records now resolve
    // composer-2.5 / composer-2.5-fast to OpenRouter's Kimi K2.5 pricing.
    // v14 caches could have baked the same token rows with costUSD == 0, so
    // force one reparse to make Analytics and tokens-by-model show dollars.
    static let currentVersion: Int = 15

    let version: Int
    var files: [String: FileEntry]

    struct FileEntry: Codable, Sendable {
        let mtime: TimeInterval
        let size: Int
        /// Flat encoding of `[Date: [RepoKey: TokenTotals]]` — Codable doesn't
        /// support `Date` dict keys cleanly, so we use `[DayBucket]`.
        let byDayByRepo: [DayBucket]
        let dedupKeys: [String]
        let unpricedModelTokens: [String: TokenTotals]
        // v12: per-model token rollup across ALL models (powers the Usage
        // tab's tokens-by-model/family section). Optional so a stale entry
        // decodes gracefully; the v12 version bump re-parses to populate it.
        let byModelTokens: [String: TokenTotals]?
        // v13: per-day-by-model rollup so the tokens-by-model section can be
        // windowed by time range. Optional so v12 entries decode gracefully;
        // the v13 bump re-parses to populate it.
        let byDayByModel: [ModelDayBucket]?

        struct DayBucket: Codable, Sendable {
            let day: Date
            let byRepo: [RepoRow]

            struct RepoRow: Codable, Sendable {
                let repo: RepoKey
                let totals: TokenTotals
            }
        }

        /// Flat encoding of `[Date: [String: TokenTotals]]` (per-day per-model),
        /// mirroring `DayBucket` — Codable can't key dicts by `Date`.
        struct ModelDayBucket: Codable, Sendable {
            let day: Date
            let byModel: [ModelRow]

            struct ModelRow: Codable, Sendable {
                let model: String
                let totals: TokenTotals
            }
        }

        static func encode(_ map: [Date: [RepoKey: TokenTotals]]) -> [DayBucket] {
            map.map { (day, repoMap) in
                DayBucket(
                    day: day,
                    byRepo: repoMap.map { DayBucket.RepoRow(repo: $0.key, totals: $0.value) }
                )
            }
        }

        static func encodeModels(_ map: [Date: [String: TokenTotals]]) -> [ModelDayBucket] {
            map.map { (day, modelMap) in
                ModelDayBucket(
                    day: day,
                    byModel: modelMap.map { ModelDayBucket.ModelRow(model: $0.key, totals: $0.value) }
                )
            }
        }

        func decodedByDayByRepo() -> [Date: [RepoKey: TokenTotals]] {
            var out: [Date: [RepoKey: TokenTotals]] = [:]
            for bucket in byDayByRepo {
                var inner: [RepoKey: TokenTotals] = [:]
                for row in bucket.byRepo {
                    inner[row.repo] = row.totals
                }
                out[bucket.day] = inner
            }
            return out
        }

        func decodedDedupKeys() -> Set<String> {
            Set(dedupKeys)
        }

        func decodedUnpricedModelTokens() -> [String: TokenTotals] {
            unpricedModelTokens
        }

        func decodedByModelTokens() -> [String: TokenTotals] {
            byModelTokens ?? [:]
        }

        func decodedByDayByModel() -> [Date: [String: TokenTotals]] {
            var out: [Date: [String: TokenTotals]] = [:]
            for bucket in byDayByModel ?? [] {
                var inner: [String: TokenTotals] = [:]
                for row in bucket.byModel {
                    inner[row.model] = row.totals
                }
                out[bucket.day] = inner
            }
            return out
        }
    }
}
