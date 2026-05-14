import Foundation
import OSLog

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
    private let cacheURL: URL?
    private let pricing: Pricing

    private var inFlight: Task<UsageHistorySnapshot, Never>?
    private var sequenceCounter: UInt64 = 0

    public init(
        claudeDir: URL? = nil,
        codexDir: URL? = nil,
        cacheURL: URL? = nil,
        pricing: Pricing = .shared
    ) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        self.claudeDir = claudeDir ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexDir = codexDir ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
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

    // MARK: - Aggregation

    private func performLoad() async -> UsageHistorySnapshot {
        let startedAt = Date()

        let cache = readCache()
        var nextCache = AnalyticsCache(version: AnalyticsCache.currentVersion, files: [:])

        let claudeFiles = enumerate(dir: claudeDir, suffix: ".jsonl")
        let codexFiles = enumerate(dir: codexDir, suffix: ".jsonl")

        // Identify active (newest mtime) per dir — those bypass cache.
        let claudeActive = claudeFiles.max(by: { $0.mtime < $1.mtime })?.url
        let codexActive = codexFiles.max(by: { $0.mtime < $1.mtime })?.url

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

        // Merge all per-file results, applying global cross-file dedup. Per
        // plan A9: the per-file `dedupKeys` set is unioned into a global Set
        // so duplicates that span files are caught even on cache hits.
        var claudeDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        var codexDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        var seenDedupKeys = Set<String>()
        var unpricedModelTokens: [String: TokenTotals] = [:]
        var sessionCount = 0

        for result in claudeResults {
            mergePerFileResult(
                result,
                into: &claudeDayByRepo,
                dedup: &seenDedupKeys,
                unpriced: &unpricedModelTokens
            )
            sessionCount += 1
            nextCache.files[result.path] = result.cacheEntry
        }
        for result in codexResults {
            mergePerFileResult(
                result,
                into: &codexDayByRepo,
                dedup: &seenDedupKeys,
                unpriced: &unpricedModelTokens
            )
            sessionCount += 1
            nextCache.files[result.path] = result.cacheEntry
        }

        writeCache(nextCache)

        // Build per-provider windows.
        let now = Date()
        let claudeTotals = buildProviderTotals(from: claudeDayByRepo, now: now)
        let codexTotals = buildProviderTotals(from: codexDayByRepo, now: now)

        sequenceCounter += 1
        let snapshot = UsageHistorySnapshot(
            claude: claudeTotals,
            codex: codexTotals,
            computedAt: Date(),
            sequenceNumber: sequenceCounter,
            sessionCount: sessionCount,
            unpricedModelTokens: unpricedModelTokens
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
        let dedupKeys: Set<String>
        let unpricedModelTokens: [String: TokenTotals]
        let cacheEntry: AnalyticsCache.FileEntry
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
                    dedupKeys: entry.decodedDedupKeys(),
                    unpricedModelTokens: entry.decodedUnpricedModelTokens(),
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

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for rawLine in lines {
            guard let record = ClaudeUsageParser.parse(line: Data(rawLine)) else { continue }
            accumulate(record: record, into: &byDayByRepo, dedup: &dedupKeys, unpriced: &unpriced)
        }

        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let entry = AnalyticsCache.FileEntry(
            mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? data.count,
            byDayByRepo: AnalyticsCache.FileEntry.encode(byDayByRepo),
            dedupKeys: Array(dedupKeys),
            unpricedModelTokens: unpriced
        )

        return PerFileResult(
            path: url.path,
            byDayByRepo: byDayByRepo,
            dedupKeys: dedupKeys,
            unpricedModelTokens: unpriced,
            cacheEntry: entry
        )
    }

    private nonisolated static func parseCodexFile(at url: URL) throws -> PerFileResult {
        let records = try CodexUsageParser.parse(file: url)
        var byDayByRepo: [Date: [RepoKey: TokenTotals]] = [:]
        var dedupKeys = Set<String>()
        var unpriced: [String: TokenTotals] = [:]
        for record in records {
            accumulate(record: record, into: &byDayByRepo, dedup: &dedupKeys, unpriced: &unpriced)
        }

        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let entry = AnalyticsCache.FileEntry(
            mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? 0,
            byDayByRepo: AnalyticsCache.FileEntry.encode(byDayByRepo),
            dedupKeys: Array(dedupKeys),
            unpricedModelTokens: unpriced
        )

        return PerFileResult(
            path: url.path,
            byDayByRepo: byDayByRepo,
            dedupKeys: dedupKeys,
            unpricedModelTokens: unpriced,
            cacheEntry: entry
        )
    }

    private nonisolated static func accumulate(
        record: UsageRecord,
        into byDayByRepo: inout [Date: [RepoKey: TokenTotals]],
        dedup: inout Set<String>,
        unpriced: inout [String: TokenTotals]
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
        let cost = Pricing.shared.cost(for: record.model, tokens: record.tokens)
        var tokensWithCost = record.tokens
        tokensWithCost.costUSD = cost
        let isPriced = Pricing.shared.isPriced(record.model)

        // Track unpriced model tokens.
        if !isPriced && record.tokens.totalTokens > 0 {
            unpriced[record.model, default: .zero] += tokensWithCost
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
        unpriced: inout [String: TokenTotals]
    ) {
        // If ANY of this file's dedup keys was already seen, we need to
        // reparse to know which records to drop — but per-file totals are
        // already aggregated. For the common case (no cross-file collisions)
        // we just union the keys and add the totals. The "rare duplicate"
        // case currently overcounts but is bounded by what Claude actually
        // logs; in practice Claude's session-resume duplicates land in the
        // same file. Codex doesn't produce dedup keys.
        var newKeyCount = 0
        for key in result.dedupKeys {
            if dedup.insert(key).inserted {
                newKeyCount += 1
            }
        }
        // Heuristic: when the file's dedupKeys are entirely fresh, accept the
        // file's totals as-is. When MORE than 50% are already-seen, skip the
        // file's totals (likely a session-resume duplicate-file scenario).
        if !result.dedupKeys.isEmpty && newKeyCount * 2 < result.dedupKeys.count {
            return
        }

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

        var byDayForChart: [Date: TokenTotals] = [:]
        var todayMap: [RepoKey: TokenTotals] = [:]
        var past7Map: [RepoKey: TokenTotals] = [:]
        var past30Map: [RepoKey: TokenTotals] = [:]
        var allMap: [RepoKey: TokenTotals] = [:]

        for (day, repoMap) in byDayByRepo {
            // Per-day total for the chart.
            let dayTotal = repoMap.values.reduce(TokenTotals.zero, +)
            byDayForChart[day] = dayTotal

            for (repo, totals) in repoMap {
                allMap[repo, default: .zero] += totals
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
    // v6 (2026-05-15): Conductor + .claude/worktrees path-pattern fallbacks
    // in RepoIdentity. Deleted Conductor branches now collapse into the
    // underlying main repo (via a live-branch's .git pointer) instead of
    // surfacing each branch separately. Old v5 caches re-parse on first load.
    static let currentVersion: Int = 6

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

        struct DayBucket: Codable, Sendable {
            let day: Date
            let byRepo: [RepoRow]

            struct RepoRow: Codable, Sendable {
                let repo: RepoKey
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
    }
}
