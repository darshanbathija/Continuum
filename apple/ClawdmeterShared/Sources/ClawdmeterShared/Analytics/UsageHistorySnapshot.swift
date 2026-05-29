import Foundation

/// Aggregated, calendar-day-aligned usage summary that drives the analytics
/// UI on both Mac and iOS. Computed by `UsageHistoryLoader.loadAll()` and
/// published via `UsageHistoryStore.snapshot`.
///
/// Plan A12 + A13: per-window `byDay` keys are `Calendar.current.startOfDay(for:)`
/// in the user's local timezone, matching `ccusage`'s default; `byRepo` keys
/// are normalized cwd paths (`RepoKey`) with the `"(unknown)"` sentinel for
/// records missing a cwd.
///
/// Plan A19: `computedAt` + `sequenceNumber` form the monotonic ordering
/// tuple iCloud readers use to reject stale snapshots.
///
/// 2026-05-19 Gemini provider: storage refactored from hardcoded `claude`/
/// `codex` properties to a provider-keyed `byProvider` dictionary so N>2
/// providers slot in without churn. Compat computed getters (`claude`,
/// `codex`, `gemini`) return `.empty` when the corresponding key is absent,
/// preserving every existing call site. Codable round-trips through the
/// dictionary form; unknown provider keys (from future-version snapshots
/// written by newer clients) are dropped silently on decode.
public struct UsageHistorySnapshot: Codable, Sendable, Equatable {

    public enum Window: String, CaseIterable, Codable, Sendable {
        case today
        case past7d
        case past30d
        case allTime

        public var label: String {
            switch self {
            case .today: return "Today"
            case .past7d: return "Past 7d"
            case .past30d: return "Past 30d"
            case .allTime: return "All time"
            }
        }
    }

    /// Provider-keyed totals. New entries materialize when a provider has
    /// any activity within the loader's scan; absent providers are looked
    /// up via the compat getters and return `.empty`.
    public let byProvider: [UsageRecord.Provider: ProviderTotals]
    public let computedAt: Date
    public let sequenceNumber: UInt64
    public let sessionCount: Int
    /// Per-model unpriced token rollups (surfaces in the UI footer per A17).
    public let unpricedModelTokens: [String: TokenTotals]
    /// Per-model token rollups across ALL models (priced + unpriced), keyed by
    /// raw model name. Powers the Usage tab's tokens-by-model / family section.
    public let tokensByModel: [String: TokenTotals]
    /// Per-day-by-model token rollups (priced + unpriced), keyed by day then
    /// raw model name. Powers the windowed (today/7d/30d/90d) tokens-by-model
    /// section; `tokensByModel` stays the all-time aggregate.
    public let byDayByModel: [Date: [String: TokenTotals]]

    public init(
        byProvider: [UsageRecord.Provider: ProviderTotals],
        computedAt: Date,
        sequenceNumber: UInt64,
        sessionCount: Int,
        unpricedModelTokens: [String: TokenTotals],
        tokensByModel: [String: TokenTotals] = [:],
        byDayByModel: [Date: [String: TokenTotals]] = [:]
    ) {
        self.byProvider = byProvider
        self.computedAt = computedAt
        self.sequenceNumber = sequenceNumber
        self.sessionCount = sessionCount
        self.unpricedModelTokens = unpricedModelTokens
        self.tokensByModel = tokensByModel
        self.byDayByModel = byDayByModel
    }

    // MARK: - Compat getters

    /// Back-compat shim for call sites that used the old `claude` stored
    /// property. Returns `.empty` when the provider isn't in the dict
    /// (regression-tested by `UsageHistorySnapshotCompatGetterTests`).
    public var claude: ProviderTotals { byProvider[.claude] ?? .empty }
    public var codex: ProviderTotals  { byProvider[.codex]  ?? .empty }
    public var gemini: ProviderTotals { byProvider[.gemini] ?? .empty }

    public static let empty = UsageHistorySnapshot(
        byProvider: [:],
        computedAt: .distantPast,
        sequenceNumber: 0,
        sessionCount: 0,
        unpricedModelTokens: [:]
    )

    public func totals(for provider: UsageRecord.Provider) -> ProviderTotals {
        byProvider[provider] ?? .empty
    }

    // MARK: - Codable

    /// Custom Codable round-trip. byProvider is encoded as a `[String:
    /// ProviderTotals]` dict (string keys = provider rawValues) so old
    /// snapshots that lack a provider key decode cleanly + new snapshots
    /// with unknown keys (from future clients) drop unknowns silently.
    /// Legacy snapshots written with the v8 schema (top-level `claude`
    /// + `codex` fields, no byProvider) are migrated at decode by reading
    /// those legacy fields and populating the dict.
    private enum CodingKeys: String, CodingKey {
        case byProvider
        case computedAt
        case sequenceNumber
        case sessionCount
        case unpricedModelTokens
        case tokensByModel
        case byDayByModel
        // Legacy v8 fields, retained for backward-compat decode.
        case claude
        case codex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.computedAt = try c.decode(Date.self, forKey: .computedAt)
        self.sequenceNumber = try c.decode(UInt64.self, forKey: .sequenceNumber)
        self.sessionCount = try c.decode(Int.self, forKey: .sessionCount)
        self.unpricedModelTokens = (try c.decodeIfPresent([String: TokenTotals].self, forKey: .unpricedModelTokens)) ?? [:]
        self.tokensByModel = (try c.decodeIfPresent([String: TokenTotals].self, forKey: .tokensByModel)) ?? [:]
        self.byDayByModel = (try c.decodeIfPresent([Date: [String: TokenTotals]].self, forKey: .byDayByModel)) ?? [:]

        // Prefer the new byProvider shape. Unknown provider raw values
        // (future-client snapshots) are dropped silently.
        if let dict = try c.decodeIfPresent([String: ProviderTotals].self, forKey: .byProvider) {
            var out: [UsageRecord.Provider: ProviderTotals] = [:]
            for (k, v) in dict {
                if let p = UsageRecord.Provider(rawValue: k) { out[p] = v }
            }
            self.byProvider = out
            return
        }

        // Legacy v8 fallback: top-level claude/codex fields. Cold cache or
        // pre-Gemini snapshot.
        var legacy: [UsageRecord.Provider: ProviderTotals] = [:]
        if let claude = try c.decodeIfPresent(ProviderTotals.self, forKey: .claude) {
            legacy[.claude] = claude
        }
        if let codex = try c.decodeIfPresent(ProviderTotals.self, forKey: .codex) {
            legacy[.codex] = codex
        }
        self.byProvider = legacy
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(computedAt, forKey: .computedAt)
        try c.encode(sequenceNumber, forKey: .sequenceNumber)
        try c.encode(sessionCount, forKey: .sessionCount)
        try c.encode(unpricedModelTokens, forKey: .unpricedModelTokens)
        try c.encode(tokensByModel, forKey: .tokensByModel)
        try c.encode(byDayByModel, forKey: .byDayByModel)
        // Write the new byProvider dict (canonical) AND the legacy
        // claude/codex fields (for one release of overlap, so a v5 reader
        // can still pick up totals from a v6 writer's snapshot).
        var dict: [String: ProviderTotals] = [:]
        for (k, v) in byProvider { dict[k.rawValue] = v }
        try c.encode(dict, forKey: .byProvider)
        if let claude = byProvider[.claude] { try c.encode(claude, forKey: .claude) }
        if let codex = byProvider[.codex] { try c.encode(codex, forKey: .codex) }
    }
}

/// All windows + per-window rollups for one provider.
public struct ProviderTotals: Codable, Sendable, Equatable {
    public let today: WindowTotals
    public let past7d: WindowTotals
    public let past30d: WindowTotals
    /// Trailing-90d window. Uses the same 84-day (12-week) span as the 90d
    /// chart so the per-repo rows can never sum past the 90d headline. Added
    /// in v0.29.31 to give the Usage "90d" card a true trailing-90d per-repo
    /// split instead of falling back to the 30d window.
    public let past90d: WindowTotals
    public let allTime: WindowTotals
    /// Per-day totals across the full activity span (`Calendar.current.startOfDay(for:)`
    /// keys, local timezone). Used to draw the daily-spend chart.
    public let byDay: [Date: TokenTotals]

    public init(
        today: WindowTotals,
        past7d: WindowTotals,
        past30d: WindowTotals,
        past90d: WindowTotals,
        allTime: WindowTotals,
        byDay: [Date: TokenTotals]
    ) {
        self.today = today
        self.past7d = past7d
        self.past30d = past30d
        self.past90d = past90d
        self.allTime = allTime
        self.byDay = byDay
    }

    public static let empty = ProviderTotals(
        today: .empty,
        past7d: .empty,
        past30d: .empty,
        past90d: .empty,
        allTime: .empty,
        byDay: [:]
    )

    public func window(_ w: UsageHistorySnapshot.Window) -> WindowTotals {
        switch w {
        case .today: return today
        case .past7d: return past7d
        case .past30d: return past30d
        case .allTime: return allTime
        }
    }

    // Custom Codable so `past90d` (added later) decode-defaults to `past30d`
    // for snapshots written before it existed, rather than throwing.
    enum CodingKeys: String, CodingKey {
        case today, past7d, past30d, past90d, allTime, byDay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.today = try c.decode(WindowTotals.self, forKey: .today)
        self.past7d = try c.decode(WindowTotals.self, forKey: .past7d)
        self.past30d = try c.decode(WindowTotals.self, forKey: .past30d)
        self.past90d = (try c.decodeIfPresent(WindowTotals.self, forKey: .past90d)) ?? self.past30d
        self.allTime = try c.decode(WindowTotals.self, forKey: .allTime)
        self.byDay = try c.decode([Date: TokenTotals].self, forKey: .byDay)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(today, forKey: .today)
        try c.encode(past7d, forKey: .past7d)
        try c.encode(past30d, forKey: .past30d)
        try c.encode(past90d, forKey: .past90d)
        try c.encode(allTime, forKey: .allTime)
        try c.encode(byDay, forKey: .byDay)
    }
}

/// One window's aggregated totals + the top-8 byRepo rollup for that window.
public struct WindowTotals: Codable, Sendable, Equatable {
    public let totals: TokenTotals
    /// Top 8 repos sorted by `costUSD` descending, plus optional `"…N more"`
    /// rollup row stored under `RepoKey` `"__rest__"`.
    public let byRepo: [(repo: RepoKey, totals: TokenTotals)]
    /// The number of repos rolled into the "rest" bucket. Zero if everything
    /// fit in the top 8.
    public let restCount: Int

    public init(
        totals: TokenTotals,
        byRepo: [(repo: RepoKey, totals: TokenTotals)],
        restCount: Int
    ) {
        self.totals = totals
        self.byRepo = byRepo
        self.restCount = restCount
    }

    public static let empty = WindowTotals(totals: .zero, byRepo: [], restCount: 0)

    // Custom codable because tuple arrays aren't auto-synthesizable.
    enum CodingKeys: String, CodingKey {
        case totals, byRepoFlat, restCount
    }

    private struct RepoRowFlat: Codable {
        let repo: RepoKey
        let totals: TokenTotals
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.totals = try c.decode(TokenTotals.self, forKey: .totals)
        let flat = try c.decode([RepoRowFlat].self, forKey: .byRepoFlat)
        self.byRepo = flat.map { ($0.repo, $0.totals) }
        self.restCount = try c.decode(Int.self, forKey: .restCount)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(totals, forKey: .totals)
        let flat = byRepo.map { RepoRowFlat(repo: $0.repo, totals: $0.totals) }
        try c.encode(flat, forKey: .byRepoFlat)
        try c.encode(restCount, forKey: .restCount)
    }

    public static func == (lhs: WindowTotals, rhs: WindowTotals) -> Bool {
        guard lhs.totals == rhs.totals, lhs.restCount == rhs.restCount else { return false }
        guard lhs.byRepo.count == rhs.byRepo.count else { return false }
        for (a, b) in zip(lhs.byRepo, rhs.byRepo) {
            if a.repo != b.repo || a.totals != b.totals { return false }
        }
        return true
    }
}
