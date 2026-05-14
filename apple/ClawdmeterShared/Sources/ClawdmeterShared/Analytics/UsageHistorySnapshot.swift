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

    public let claude: ProviderTotals
    public let codex: ProviderTotals
    public let computedAt: Date
    public let sequenceNumber: UInt64
    public let sessionCount: Int
    /// Per-model unpriced token rollups (surfaces in the UI footer per A17).
    public let unpricedModelTokens: [String: TokenTotals]

    public init(
        claude: ProviderTotals,
        codex: ProviderTotals,
        computedAt: Date,
        sequenceNumber: UInt64,
        sessionCount: Int,
        unpricedModelTokens: [String: TokenTotals]
    ) {
        self.claude = claude
        self.codex = codex
        self.computedAt = computedAt
        self.sequenceNumber = sequenceNumber
        self.sessionCount = sessionCount
        self.unpricedModelTokens = unpricedModelTokens
    }

    public static let empty = UsageHistorySnapshot(
        claude: .empty,
        codex: .empty,
        computedAt: .distantPast,
        sequenceNumber: 0,
        sessionCount: 0,
        unpricedModelTokens: [:]
    )

    public func totals(for provider: UsageRecord.Provider) -> ProviderTotals {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        }
    }
}

/// All windows + per-window rollups for one provider.
public struct ProviderTotals: Codable, Sendable, Equatable {
    public let today: WindowTotals
    public let past7d: WindowTotals
    public let past30d: WindowTotals
    public let allTime: WindowTotals
    /// Per-day totals across the full 30-day chart window (`Calendar.current.startOfDay(for:)`
    /// keys, local timezone). Used to draw the daily-spend chart.
    public let byDay: [Date: TokenTotals]

    public init(
        today: WindowTotals,
        past7d: WindowTotals,
        past30d: WindowTotals,
        allTime: WindowTotals,
        byDay: [Date: TokenTotals]
    ) {
        self.today = today
        self.past7d = past7d
        self.past30d = past30d
        self.allTime = allTime
        self.byDay = byDay
    }

    public static let empty = ProviderTotals(
        today: .empty,
        past7d: .empty,
        past30d: .empty,
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
