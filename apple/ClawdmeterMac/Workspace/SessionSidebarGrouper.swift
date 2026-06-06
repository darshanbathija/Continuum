import Foundation
import ClawdmeterShared

/// One section in the sidebar's grouped view. Carries Continuum-owned
/// `AgentSession`s only; `recents` is retained as an empty compatibility
/// field for older tests/callers that still construct the type directly.
public struct SessionSidebarGroup: Identifiable, Hashable {
    public let id: String
    /// Header label, e.g. "Today", "Running", "Claude", "my-repo".
    public let title: String
    /// Optional repo key — only set when grouping by `.repo` so callers
    /// can route "Start a session here" buttons to the right cwd.
    public let repoKey: String?
    /// Sort key used to order the groups themselves. Lower-is-higher.
    public let sortRank: Int
    public let sessions: [AgentSession]
    public let recents: [RecentSession]

    public var isEmpty: Bool { sessions.isEmpty }
}

public enum SessionSidebarStatusBucket: String, CaseIterable, Sendable {
    case active
    case inReview
    case done
    case archived

    public var title: String {
        switch self {
        case .active: return "Active"
        case .inReview: return "In Review"
        case .done: return "Done"
        case .archived: return "Archived"
        }
    }

    public var sortRank: Int {
        switch self {
        case .active: return 0
        case .inReview: return 1
        case .done: return 2
        case .archived: return 3
        }
    }
}

/// Bucketing + sorting helpers that map the registry's flat session list
/// into the sidebar's section structure.
/// Pure logic, no SwiftUI — testable from the shared package.
public enum SessionSidebarGrouper {

    /// Build the sidebar's section list according to the user's prefs.
    /// `repos` provides the Repo grouping path. `sessions` are the
    /// already-search-filtered AgentSessions.
    public static func group(
        sessions: [AgentSession],
        repos: [AgentRepo],
        grouping: SessionGrouping,
        sorting: SessionSorting,
        statusFilter: SessionStatusFilter,
        reviewSessionIds: Set<UUID> = [],
        now: Date = Date()
    ) -> [SessionSidebarGroup] {
        let filtered = sessions.filter { passes(statusFilter, $0, reviewSessionIds: reviewSessionIds, now: now) }
        let canonicalRepos = canonicalizeRepos(repos)
        switch grouping {
        case .repo:
            return groupByRepo(
                sessions: filtered,
                repos: canonicalRepos.repos,
                keyAliases: canonicalRepos.keyAliases,
                sorting: sorting
            )
        case .date:
            return groupByDate(sessions: filtered, repos: canonicalRepos.repos, sorting: sorting)
        case .status:
            return groupByStatus(sessions: filtered, sorting: sorting, reviewSessionIds: reviewSessionIds, now: now)
        case .agent:
            return groupByAgent(sessions: filtered, repos: canonicalRepos.repos, sorting: sorting)
        case .none:
            return [SessionSidebarGroup(
                id: "all",
                title: "All sessions",
                repoKey: nil,
                sortRank: 0,
                sessions: sorted(filtered, by: sorting),
                recents: []
            )]
        }
    }

    public static func bucket(
        for session: AgentSession,
        reviewSessionIds: Set<UUID> = [],
        now: Date = Date()
    ) -> SessionSidebarStatusBucket {
        if session.archivedAt != nil {
            return .archived
        }
        if session.planText != nil || reviewSessionIds.contains(session.id) {
            return .inReview
        }
        if session.status == .done {
            return .done
        }
        if session.status == .running || now.timeIntervalSince(session.lastEventAt) < 30 {
            return .active
        }
        return .active
    }

    private static func passes(
        _ filter: SessionStatusFilter,
        _ session: AgentSession,
        reviewSessionIds: Set<UUID>,
        now: Date
    ) -> Bool {
        switch filter {
        case .all: return true
        case .active:
            return bucket(for: session, reviewSessionIds: reviewSessionIds, now: now) == .active
        case .inReview:
            return bucket(for: session, reviewSessionIds: reviewSessionIds, now: now) == .inReview
        case .done:
            return bucket(for: session, reviewSessionIds: reviewSessionIds, now: now) == .done
        case .archived:
            return bucket(for: session, reviewSessionIds: reviewSessionIds, now: now) == .archived
        }
    }

    // MARK: - Repo (legacy default)

    private static func groupByRepo(
        sessions: [AgentSession],
        repos: [AgentRepo],
        keyAliases: [String: String],
        sorting: SessionSorting
    ) -> [SessionSidebarGroup] {
        // Preserve the order returned by SessionsModel.filteredRepos.
        var byRepo: [String: [AgentSession]] = [:]
        for s in sessions {
            // v0.8 schema v5: chat sessions have nil repoKey and live in
            // the Chat sidebar, not the Sessions sidebar. Skip them here
            // so they don't grouped under a synthetic empty-string key.
            guard let key = s.repoKey else { continue }
            byRepo[keyAliases[key] ?? key, default: []].append(s)
        }
        return repos.enumerated().map { (idx, repo) in
            let live = sorted(byRepo[repo.key] ?? [], by: sorting)
            return SessionSidebarGroup(
                id: "repo:\(repo.key)",
                title: repo.displayName,
                repoKey: repo.key,
                sortRank: idx,
                sessions: live,
                recents: []
            )
        }
    }

    struct CanonicalRepos {
        let repos: [AgentRepo]
        let keyAliases: [String: String]
    }

    static func canonicalizeRepos(_ repos: [AgentRepo]) -> CanonicalRepos {
        struct Accumulator {
            var repo: AgentRepo
        }

        var orderedKeys: [String] = []
        var displayKeyToRepoKey: [String: String] = [:]
        var accumulators: [String: Accumulator] = [:]
        var keyAliases: [String: String] = [:]

        for repo in repos {
            let displayKey = normalizedVisibleRepoName(repo.displayName)
            if let primaryKey = displayKeyToRepoKey[displayKey],
               var accumulator = accumulators[primaryKey] {
                keyAliases[repo.key] = primaryKey
                accumulator.repo = AgentRepo(
                    key: accumulator.repo.key,
                    displayName: accumulator.repo.displayName,
                    hasActiveSessions: accumulator.repo.hasActiveSessions || repo.hasActiveSessions,
                    liveSessionCount: accumulator.repo.liveSessionCount + repo.liveSessionCount,
                    recentSessions: []
                )
                accumulators[primaryKey] = accumulator
            } else {
                displayKeyToRepoKey[displayKey] = repo.key
                orderedKeys.append(repo.key)
                keyAliases[repo.key] = repo.key
                accumulators[repo.key] = Accumulator(
                    repo: AgentRepo(
                        key: repo.key,
                        displayName: repo.displayName,
                        hasActiveSessions: repo.hasActiveSessions,
                        liveSessionCount: repo.liveSessionCount,
                        recentSessions: []
                    )
                )
            }
        }

        return CanonicalRepos(
            repos: orderedKeys.compactMap { accumulators[$0]?.repo },
            keyAliases: keyAliases
        )
    }

    private static func normalizedVisibleRepoName(_ name: String) -> String {
        let normalized = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? name : normalized
    }

    // MARK: - Date

    /// "Today", "Yesterday", "Earlier this week", "Last 30 days", "Older".
    /// Buckets driven by `lastEventAt` for Continuum-owned sessions.
    private static func groupByDate(
        sessions: [AgentSession],
        repos: [AgentRepo],
        sorting: SessionSorting
    ) -> [SessionSidebarGroup] {
        _ = repos
        let calendar = Calendar.current
        let now = Date()

        func bucket(for date: Date) -> (rank: Int, title: String) {
            if calendar.isDateInToday(date)     { return (0, "Today") }
            if calendar.isDateInYesterday(date) { return (1, "Yesterday") }
            let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
            if days < 7  { return (2, "Earlier this week") }
            if days < 30 { return (3, "Last 30 days") }
            return (4, "Older")
        }

        var buckets: [Int: SessionSidebarGroup] = [:]
        for s in sessions {
            let (rank, title) = bucket(for: s.lastEventAt)
            let existing = buckets[rank]
            buckets[rank] = SessionSidebarGroup(
                id: "date:\(rank)",
                title: title,
                repoKey: nil,
                sortRank: rank,
                sessions: (existing?.sessions ?? []) + [s],
                recents: existing?.recents ?? []
            )
        }
        return buckets.values
            .sorted { $0.sortRank < $1.sortRank }
            .map { group in
                SessionSidebarGroup(
                    id: group.id,
                    title: group.title,
                    repoKey: nil,
                    sortRank: group.sortRank,
                    sessions: sorted(group.sessions, by: sorting),
                    recents: []
                )
            }
    }

    // MARK: - Status

    private static func groupByStatus(
        sessions: [AgentSession],
        sorting: SessionSorting,
        reviewSessionIds: Set<UUID>,
        now: Date
    ) -> [SessionSidebarGroup] {
        var buckets: [SessionSidebarStatusBucket: [AgentSession]] = [:]
        for s in sessions {
            buckets[bucket(for: s, reviewSessionIds: reviewSessionIds, now: now), default: []].append(s)
        }
        return SessionSidebarStatusBucket.allCases.map { bucket in
            SessionSidebarGroup(
                id: "status:\(bucket.rawValue)",
                title: bucket.title,
                repoKey: nil,
                sortRank: bucket.sortRank,
                sessions: sorted(buckets[bucket] ?? [], by: sorting),
                recents: []
            )
        }
    }

    // MARK: - Agent

    private static func groupByAgent(
        sessions: [AgentSession],
        repos: [AgentRepo],
        sorting: SessionSorting
    ) -> [SessionSidebarGroup] {
        _ = repos
        var sBuckets: [AgentKind: [AgentSession]] = [:]
        for s in sessions {
            sBuckets[s.agent, default: []].append(s)
        }
        let order: [(AgentKind, Int)] = [(.claude, 0), (.codex, 1)]
        return order.compactMap { (agent, rank) in
            let live = sorted(sBuckets[agent] ?? [], by: sorting)
            guard !live.isEmpty else { return nil }
            return SessionSidebarGroup(
                id: "agent:\(agent.rawValue)",
                title: agent.rawValue.capitalized,
                repoKey: nil,
                sortRank: rank,
                sessions: live,
                recents: []
            )
        }
    }

    // MARK: - Sorting helpers

    private static func sorted(_ sessions: [AgentSession], by sorting: SessionSorting) -> [AgentSession] {
        switch sorting {
        case .recency:
            return sessions.sorted { $0.lastEventAt > $1.lastEventAt }
        case .created:
            return sessions.sorted { $0.createdAt > $1.createdAt }
        case .name:
            return sessions.sorted { lhs, rhs in
                let l = (lhs.goal ?? lhs.repoDisplayName).lowercased()
                let r = (rhs.goal ?? rhs.repoDisplayName).lowercased()
                return l < r
            }
        }
    }
}
