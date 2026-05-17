import Foundation
import ClawdmeterShared

/// One section in the sidebar's grouped view. Carries both live
/// `AgentSession`s and outside `RecentSession`s — the renderer decides
/// which subset to display based on the grouping mode.
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

    public var isEmpty: Bool { sessions.isEmpty && recents.isEmpty }
}

/// Bucketing + sorting helpers that map the registry's flat session list
/// (+ per-repo recent JSONLs) into the sidebar's section structure.
/// Pure logic, no SwiftUI — testable from the shared package.
public enum SessionSidebarGrouper {

    /// Build the sidebar's section list according to the user's prefs.
    /// `repos` provides the Repo grouping path (and supplies recent
    /// JSONLs for non-Repo groupings via flattening). `sessions` are the
    /// already-search-filtered live AgentSessions.
    public static func group(
        sessions: [AgentSession],
        repos: [AgentRepo],
        grouping: SessionGrouping,
        sorting: SessionSorting,
        statusFilter: SessionStatusFilter
    ) -> [SessionSidebarGroup] {
        let filtered = sessions.filter { passes(statusFilter, $0) }
        switch grouping {
        case .repo:
            return groupByRepo(sessions: filtered, repos: repos, sorting: sorting)
        case .date:
            return groupByDate(sessions: filtered, repos: repos, sorting: sorting)
        case .status:
            return groupByStatus(sessions: filtered, sorting: sorting)
        case .agent:
            return groupByAgent(sessions: filtered, repos: repos, sorting: sorting)
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

    private static func passes(_ filter: SessionStatusFilter, _ session: AgentSession) -> Bool {
        switch filter {
        case .all: return true
        case .active:
            return [.planning, .running, .paused].contains(session.status)
                && session.archivedAt == nil
        case .done:
            return session.status == .done && session.archivedAt == nil
        case .archived:
            return session.archivedAt != nil
        }
    }

    // MARK: - Repo (legacy default)

    private static func groupByRepo(
        sessions: [AgentSession],
        repos: [AgentRepo],
        sorting: SessionSorting
    ) -> [SessionSidebarGroup] {
        // Preserve the order returned by SessionsModel.filteredRepos —
        // it's already sorted by most-recent activity. Each section
        // carries the repo's live sessions + outside JSONLs.
        var byRepo: [String: [AgentSession]] = [:]
        for s in sessions {
            byRepo[s.repoKey, default: []].append(s)
        }
        return repos.enumerated().map { (idx, repo) in
            let live = sorted(byRepo[repo.key] ?? [], by: sorting)
            return SessionSidebarGroup(
                id: "repo:\(repo.key)",
                title: repo.displayName,
                repoKey: repo.key,
                sortRank: idx,
                sessions: live,
                recents: repo.recentSessions
            )
        }
    }

    // MARK: - Date

    /// "Today", "Yesterday", "Earlier this week", "Last 30 days", "Older".
    /// Buckets driven by `lastEventAt` for sessions and `lastModified`
    /// for recents — the most-recent activity wins regardless of source.
    private static func groupByDate(
        sessions: [AgentSession],
        repos: [AgentRepo],
        sorting: SessionSorting
    ) -> [SessionSidebarGroup] {
        let allRecents = repos.flatMap(\.recentSessions)
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
        for r in allRecents {
            let (rank, title) = bucket(for: r.lastModified)
            let existing = buckets[rank]
            buckets[rank] = SessionSidebarGroup(
                id: "date:\(rank)",
                title: title,
                repoKey: nil,
                sortRank: rank,
                sessions: existing?.sessions ?? [],
                recents: (existing?.recents ?? []) + [r]
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
                    recents: group.recents.sorted { $0.lastModified > $1.lastModified }
                )
            }
    }

    // MARK: - Status

    private static func groupByStatus(
        sessions: [AgentSession],
        sorting: SessionSorting
    ) -> [SessionSidebarGroup] {
        let order: [(AgentSessionStatus, Int)] = [
            (.running, 0), (.planning, 1), (.paused, 2),
            (.degraded, 3), (.done, 4)
        ]
        var buckets: [AgentSessionStatus: [AgentSession]] = [:]
        for s in sessions {
            buckets[s.status, default: []].append(s)
        }
        return order.compactMap { (status, rank) in
            guard let items = buckets[status], !items.isEmpty else { return nil }
            return SessionSidebarGroup(
                id: "status:\(status.rawValue)",
                title: status.rawValue.capitalized,
                repoKey: nil,
                sortRank: rank,
                sessions: sorted(items, by: sorting),
                recents: []  // recents have no status field
            )
        }
    }

    // MARK: - Agent

    private static func groupByAgent(
        sessions: [AgentSession],
        repos: [AgentRepo],
        sorting: SessionSorting
    ) -> [SessionSidebarGroup] {
        let allRecents = repos.flatMap(\.recentSessions)
        var sBuckets: [AgentKind: [AgentSession]] = [:]
        for s in sessions {
            sBuckets[s.agent, default: []].append(s)
        }
        var rBuckets: [AgentKind: [RecentSession]] = [:]
        for r in allRecents {
            rBuckets[r.provider, default: []].append(r)
        }
        let order: [(AgentKind, Int)] = [(.claude, 0), (.codex, 1)]
        return order.compactMap { (agent, rank) in
            let live = sorted(sBuckets[agent] ?? [], by: sorting)
            let recents = (rBuckets[agent] ?? []).sorted { $0.lastModified > $1.lastModified }
            guard !live.isEmpty || !recents.isEmpty else { return nil }
            return SessionSidebarGroup(
                id: "agent:\(agent.rawValue)",
                title: agent.rawValue.capitalized,
                repoKey: nil,
                sortRank: rank,
                sessions: live,
                recents: recents
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
