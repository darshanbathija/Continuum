import Foundation
import ClawdmeterShared

/// Materialized sidebar projection — everything the SidebarPane body
/// needs to render its content, computed once per unique
/// `SidebarProjectionKey`. The body re-runs every time SwiftUI ticks any
/// of the @ObservedObject sources (registry, repos, query, filters,
/// presentation pins, prCache); the cache avoids re-doing this work when
/// none of the inputs that actually shape the projection changed.
///
/// Two render paths because the repo-grouped sidebar reuses per-repo
/// `repoSection(...)` chrome (expand/collapse, "Recent (last 30 days)",
/// empty-state CTAs), while the other groupings flatten into
/// `SessionSidebarGroup` rows. The cache stores either the canonical
/// repo list OR the flattened groups list, plus the
/// search-and-archive-filtered `visibleSessions` list both paths share.
///
/// Plan: A11 (Phase 2) — see .claude/plans/study-this-codebase-crystalline-shore.md
struct SidebarProjection {
    /// Search-filtered, archive-aware first-party session list in the
    /// same recency order as the priority workspace sections.
    let visibleSessions: [AgentSession]

    /// Sessions currently in the "in review" bucket (planText != nil, or
    /// open/draft PR mirror). Cached here because the sidebar buckets
    /// view + statusGroup tint both read it; recomputing per body pass
    /// scaled with session count.
    let reviewSessionIds: Set<UUID>

    /// Repo-grouped path: canonicalized repos with merged aliases.
    /// nil for non-repo grouping paths.
    let canonicalRepos: SessionSidebarGrouper.CanonicalRepos?

    /// Non-repo grouping path: pre-bucketed sections.
    /// nil for the repo grouping path.
    let groups: [SessionSidebarGroup]?

    /// Priority Code sidebar path: Clawdmeter-created code workspaces first.
    /// Sorted by each workspace's latest child session activity.
    let workspaceSections: [SidebarWorkspaceSection]

    /// Outside-Clawdmeter JSONLs touched within the active window, grouped
    /// by repo. These are controllable/readable now, but not first-party
    /// workspace tabs.
    let activeExternalSections: [SidebarExternalRepoSection]

    /// Older outside-Clawdmeter JSONLs. Rendered only in the bottom History
    /// area so old transcripts never compete with active work.
    let historySections: [SidebarHistoryRepoSection]

    var hasPriorityContent: Bool {
        !workspaceSections.isEmpty || !activeExternalSections.isEmpty || !historySections.isEmpty
    }
}

/// Maps the active status filter to archived-row visibility. The filter is
/// driven entirely from the sidebar's funnel menu now (the always-visible
/// bucket strip was removed as redundant); only `.archived` reveals
/// archived sessions.
enum SidebarStatusBucketState {
    static func showsArchived(for filter: SessionStatusFilter) -> Bool {
        filter == .archived
    }
}

struct SidebarWorkspaceSection: Identifiable, Hashable {
    let workspaceKey: WorkspaceKey
    let repo: AgentRepo
    let workspacePath: String
    let sessions: [AgentSession]
    /// v0.29.28: historical JSONLs that belong to the same canonical
    /// repo as this workspace. Surfaced under the workspace's header
    /// so a freshly-added repo doesn't strand its prior sessions in
    /// "Active outside Clawdmeter" / "History" — they're INSIDE the
    /// workspace now, just not Clawdmeter-managed.
    let recentSessions: [RecentSession]
    let latestActivity: Date
    /// Earliest Clawdmeter session `createdAt` in this repo — a stable
    /// "first use" anchor that, unlike `latestActivity`, does NOT move when a
    /// new session is created. Drives the default oldest-first project order
    /// so a fresh session never floats its repo to the top. Empty managed
    /// sections (just-added repo, no session yet) get `.distantFuture` so they
    /// land at the bottom.
    let firstActivity: Date

    var id: String { "\(workspaceKey.repoKey)|\(workspaceKey.workspacePath)" }
}

struct SidebarExternalRepoSection: Identifiable, Hashable {
    let repo: AgentRepo
    let recents: [RecentSession]
    let latestActivity: Date

    var id: String { repo.key }
}

struct SidebarHistoryRepoSection: Identifiable, Hashable {
    let repo: AgentRepo
    let dateGroups: [SidebarHistoryDateGroup]
    let latestActivity: Date

    var id: String { repo.key }
}

struct SidebarHistoryDateGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let recents: [RecentSession]
    let latestActivity: Date
}

/// Cache key bundling everything that, when changed, requires recomputing
/// the sidebar projection. Equality is structural — equal keys MUST yield
/// equal projections, otherwise the cache will serve a stale view.
///
/// **Why the per-session/per-repo fingerprints are Ints rather than full
/// arrays:** the cache key is compared on every SwiftUI body pass. Hashing
/// + Int equality is O(N) once at fingerprint build-time, then O(1) per
/// body re-eval. If we held the full arrays, the cache comparison itself
/// would scan every element on every body pass — defeating the cache.
///
/// **What goes into each fingerprint:** every field the downstream
/// projection actually reads PLUS every field the row renderer reads off
/// the cached `AgentSession` snapshot. The projection's
/// `visibleSessions` / group `sessions` are value-type snapshots taken at
/// build-time; if `sessionRow` dereferences a session field that isn't
/// in the fingerprint AND that field can mutate without bumping
/// `lastEventSeq`, the cache will serve stale rows for that field. If
/// the projection or renderer ever starts reading a new session field
/// (e.g. a new `colorTag` baked into the session record), add it to the
/// fingerprint. The included fields today:
///   - registryFingerprint: id, lastEventSeq, status, archivedAt,
///     planText.isEmpty, prMirrorState?.state — every field the grouper
///     buckets / sorts / filters on, plus the review-bucket inputs —
///     and customName, because Rename persists through
///     `registry.rename(...)` and mutates it without bumping
///     `lastEventSeq`.
///   - reposFingerprint: per-repo key, displayName, liveSessionCount,
///     hasActiveSessions, recents (path + lastModified + alias).
///   - workbenchPRCacheFingerprint: per-session prCache.state, since
///     reviewSessionIds folds workbench PR state in.
struct SidebarProjectionKey: Equatable {
    let registryFingerprint: UInt64
    let reposFingerprint: UInt64
    let workbenchPRCacheFingerprint: UInt64
    /// Fingerprint of the post-search session list. Distinct from
    /// `registryFingerprint` because chat-store body matches can change
    /// which sessions pass the search filter without the upstream
    /// registry mutating. Including this in the key means a chat-store
    /// tick that changes the search hit set invalidates the cache.
    let searchFilteredFingerprint: UInt64
    let query: String                       // already trimmed + lowercased
    let archiveFilter: Bool                 // showArchived
    let statusFilter: SessionStatusFilter
    let grouping: SessionGrouping
    let sorting: SessionSorting
    let pinnedSet: [UUID]                   // order matters (pin order)
    let ownedJSONLPathsFingerprint: UInt64
    let externalActivityClockBucket: Int
    /// v0.29.28: Set<String> of normalized repoRoots for every workspace
    /// registered in `WorkspaceStore`. Workspace-managed repos are
    /// pulled out of "Active outside" + "History" and folded into the
    /// Managed section, so the cache must invalidate when the set
    /// changes (e.g., the user just added a repo).
    let workspaceRepoKeysFingerprint: UInt64
}

enum SidebarProjectionBuilder {
    /// v0.29.28: tightened from 10 min to 5 min so the sidebar's
    /// "active" categorization matches `RepoIndex.liveNowWindow` (the
    /// same window that drives the green dot). The two used to disagree
    /// — a session would lose its live dot at 5 min but still claim a
    /// spot in "Active outside Clawdmeter" for another 5.
    static let externalActiveWindow: TimeInterval = 5 * 60

    /// Compute the projection. Pure function — no @MainActor isolation
    /// needed because the inputs are value types snapshotted upstream
    /// and the outputs are value types. The non-pure parts (model,
    /// registry, presentationStore, chat-store body search) are
    /// dereferenced before this is invoked, so this can be exercised
    /// from XCTest without spinning up a SwiftUI environment.
    ///
    /// `searchFilteredSessions` is the post-search session list. The
    /// caller (SidebarPane) runs `model.filter(...)` first so transcript-
    /// body matches keep working; the cache key fingerprints the filtered
    /// list so identical search results hit the cache even if the
    /// underlying chat stores ticked between body re-evals.
    static func build(
        searchFilteredSessions: [AgentSession],
        repos: [AgentRepo],
        searchQuery: String,
        showArchived: Bool,
        statusFilter: SessionStatusFilter,
        grouping: SessionGrouping,
        sorting: SessionSorting,
        pinnedSessionIds: [UUID],
        workbenchPRStateBySession: [UUID: String?],
        ownedJSONLPaths: Set<String> = [],
        workspaceRepoKeys: Set<String> = [],
        now: Date = Date()
    ) -> SidebarProjection {
        let reviewIds = reviewSessionIds(
            sessions: searchFilteredSessions,
            workbenchPRStateBySession: workbenchPRStateBySession
        )

        // Archived sessions are hidden in every normal Code sidebar mode.
        // They re-enter only through the explicit Archive status filter.
        let archiveFiltered = searchFilteredSessions.filter {
            passesArchiveGate($0, statusFilter: statusFilter, showArchived: showArchived)
        }
        let pinSorted = pinSorted(archiveFiltered, pinnedSessionIds: pinnedSessionIds)
        let firstPartySessions = searchFilteredSessions.filter {
            isFirstPartyCodeSession($0)
                && passesCodeStatus($0, statusFilter: statusFilter, showArchived: showArchived, reviewSessionIds: reviewIds, now: now)
        }
        let canonicalRepos = SessionSidebarGrouper.canonicalizeRepos(repos)
        let workspaceSections = buildWorkspaceSections(
            sessions: firstPartySessions,
            repos: canonicalRepos.repos,
            keyAliases: canonicalRepos.keyAliases,
            workspaceRepoKeys: workspaceRepoKeys
        )
        let external = buildExternalSections(
            repos: canonicalRepos.repos,
            searchQuery: searchQuery,
            statusFilter: statusFilter,
            ownedJSONLPaths: ownedJSONLPaths,
            workspaceRepoKeys: workspaceRepoKeys,
            now: now
        )
        let priorityVisibleSessions = workspaceSections.flatMap(\.sessions)

        switch grouping {
        case .repo:
            let searchFilteredRepos = repos.filter { repo in
                let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !trimmed.isEmpty else { return true }
                if repo.displayName.lowercased().contains(trimmed) { return true }
                // Any visible session whose repoKey matches counts as a hit.
                return pinSorted.contains { $0.repoKey == repo.key }
            }
            let canonical = SessionSidebarGrouper.canonicalizeRepos(searchFilteredRepos)
            return SidebarProjection(
                visibleSessions: priorityVisibleSessions,
                reviewSessionIds: reviewIds,
                canonicalRepos: canonical,
                groups: nil,
                workspaceSections: workspaceSections,
                activeExternalSections: external.active,
                historySections: external.history
            )
        case .date, .status, .agent, .host, .none:
            let groups = SessionSidebarGrouper.group(
                sessions: priorityVisibleSessions,
                repos: reposWithoutRecents(repos),
                grouping: grouping,
                sorting: sorting,
                statusFilter: statusFilter,
                reviewSessionIds: reviewIds,
                now: now
            )
            return SidebarProjection(
                visibleSessions: priorityVisibleSessions,
                reviewSessionIds: reviewIds,
                canonicalRepos: nil,
                groups: groups,
                workspaceSections: workspaceSections,
                activeExternalSections: external.active,
                historySections: external.history
            )
        }
    }

    static func externalActivityClockBucket(now: Date, repos: [AgentRepo]) -> Int {
        let cutoff = now.addingTimeInterval(-externalActiveWindow)
        var hasher = Hasher()
        for repo in repos.sorted(by: { $0.key < $1.key }) {
            hasher.combine(repo.key)
            for recent in repo.recentSessions.sorted(by: { $0.path < $1.path }) {
                hasher.combine(recent.path)
                hasher.combine(recent.lastModified >= cutoff)
            }
        }
        return hasher.finalize()
    }

    static func ownedJSONLPathsFingerprint(_ paths: Set<String>) -> UInt64 {
        var hasher = Hasher()
        for path in paths.sorted() {
            hasher.combine(path)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// v0.29.28: invalidates the projection cache when the user adds or
    /// removes a workspace, so external/managed buckets re-split.
    static func workspaceRepoKeysFingerprint(_ keys: Set<String>) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(keys.count)
        for key in keys.sorted() {
            hasher.combine(key)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Fingerprint the post-search session list. Used by the cache key
    /// so a chat-store body match that changes which sessions pass the
    /// search filter invalidates the cache, even though the upstream
    /// `searchQuery` string is identical.
    static func searchFilteredFingerprint(_ sessions: [AgentSession]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(sessions.count)
        for s in sessions {
            hasher.combine(s.id)
            hasher.combine(s.lastEventSeq)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    // MARK: - Pin-aware sort

    private static func pinSorted(
        _ sessions: [AgentSession],
        pinnedSessionIds: [UUID]
    ) -> [AgentSession] {
        let pins = pinnedSessionIds
        return sessions.sorted { lhs, rhs in
            let lhsPin = pins.firstIndex(of: lhs.id)
            let rhsPin = pins.firstIndex(of: rhs.id)
            switch (lhsPin, rhsPin) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs.lastEventAt > rhs.lastEventAt
            }
        }
    }

    private static func recencySorted(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted {
            if $0.lastEventAt != $1.lastEventAt { return $0.lastEventAt > $1.lastEventAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func isFirstPartyCodeSession(_ session: AgentSession) -> Bool {
        session.kind == .code && WorkspaceKey.of(session) != nil
    }

    private static func passesArchiveGate(
        _ session: AgentSession,
        statusFilter: SessionStatusFilter,
        showArchived: Bool
    ) -> Bool {
        if statusFilter == .archived {
            return session.archivedAt != nil
        }
        if session.archivedAt != nil {
            return showArchived
        }
        return true
    }

    private static func passesCodeStatus(
        _ session: AgentSession,
        statusFilter: SessionStatusFilter,
        showArchived: Bool,
        reviewSessionIds: Set<UUID>,
        now: Date
    ) -> Bool {
        guard passesArchiveGate(session, statusFilter: statusFilter, showArchived: showArchived) else {
            return false
        }
        switch statusFilter {
        case .all:
            return true
        case .active:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds, now: now) == .active
        case .inReview:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds, now: now) == .inReview
        case .done:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds, now: now) == .done
        case .archived:
            return session.archivedAt != nil
        }
    }

    private static func buildWorkspaceSections(
        sessions: [AgentSession],
        repos: [AgentRepo],
        keyAliases: [String: String],
        workspaceRepoKeys: Set<String>
    ) -> [SidebarWorkspaceSection] {
        let repoByKey = Dictionary(uniqueKeysWithValues: repos.map { ($0.key, $0) })
        // Group by CANONICAL repo, not per-worktree WorkspaceKey: a repo with
        // many worktree/Conductor sessions collapses to ONE managed row with all
        // its sessions nested underneath — instead of a separate
        // "Clawdmeter · Workspace <city>" row for every worktree.
        let grouped = Dictionary(grouping: sessions.compactMap { session -> (String, AgentSession)? in
            guard let key = WorkspaceKey.of(session) else { return nil }
            let canonicalRepoKey = keyAliases[key.repoKey] ?? key.repoKey
            return (canonicalRepoKey, session)
        }, by: { $0.0 })

        var sections: [SidebarWorkspaceSection] = grouped.compactMap { repoKey, pairs -> SidebarWorkspaceSection? in
            let sessions = recencySorted(pairs.map(\.1))
            guard let latest = sessions.map(\.lastEventAt).max() else { return nil }
            let repo = repoByKey[repoKey] ?? AgentRepo(
                key: repoKey,
                displayName: RepoIdentity.displayName(for: repoKey),
                hasActiveSessions: true
            )
            return SidebarWorkspaceSection(
                workspaceKey: WorkspaceKey(repoKey: repoKey, workspacePath: repoKey),
                repo: repo,
                workspacePath: repoKey,
                sessions: sessions,
                recentSessions: repo.recentSessions,
                latestActivity: latest,
                firstActivity: sessions.map(\.createdAt).min() ?? .distantFuture
            )
        }

        // v0.29.28: emit sections for workspace-registered repos that
        // have no Clawdmeter-spawned AgentSession yet. The user just
        // added the repo via the Add-Repo flow — they expect to see it
        // immediately, with whatever historical JSONLs exist underneath.
        // Without this, the workspace's Recents would land in "Active
        // outside Clawdmeter" / "History", which is confusing when the
        // repo IS managed.
        let representedKeys = Set(sections.map { keyAliases[$0.workspaceKey.repoKey] ?? $0.workspaceKey.repoKey })
        for repoKey in workspaceRepoKeys where !representedKeys.contains(repoKey) {
            let canonicalKey = keyAliases[repoKey] ?? repoKey
            let repo = repoByKey[canonicalKey] ?? AgentRepo(
                key: canonicalKey,
                displayName: RepoIdentity.displayName(for: canonicalKey),
                hasActiveSessions: false
            )
            let workspaceKey = WorkspaceKey(repoKey: canonicalKey, workspacePath: canonicalKey)
            // Sort recents into the section's slot; the "latest" anchors
            // ordering against active workspaces.
            let recents = repo.recentSessions.sorted { $0.lastModified > $1.lastModified }
            let latest = recents.first?.lastModified ?? .distantPast
            sections.append(SidebarWorkspaceSection(
                workspaceKey: workspaceKey,
                repo: repo,
                workspacePath: canonicalKey,
                sessions: [],
                recentSessions: recents,
                latestActivity: latest,
                // Just-added repo with no Clawdmeter session yet → bottom.
                firstActivity: .distantFuture
            ))
        }

        // Oldest-first by first use: the repo you've used longest stays on
        // top, a brand-new repo appends to the bottom, and creating a session
        // never reorders the list (firstActivity is immutable per repo). The
        // user's persisted manual order, when present, is layered on top of
        // this in the view (`orderedWorkspaceSections`).
        return sections.sorted {
            if $0.firstActivity != $1.firstActivity { return $0.firstActivity < $1.firstActivity }
            return $0.id < $1.id
        }
    }

    private static func buildExternalSections(
        repos: [AgentRepo],
        searchQuery: String,
        statusFilter: SessionStatusFilter,
        ownedJSONLPaths: Set<String>,
        workspaceRepoKeys: Set<String>,
        now: Date
    ) -> (active: [SidebarExternalRepoSection], history: [SidebarHistoryRepoSection]) {
        guard statusFilter == .all || statusFilter == .active else {
            return ([], [])
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let activeCutoff = now.addingTimeInterval(-externalActiveWindow)
        let owned = Set(ownedJSONLPaths.map(canonicalJSONLPath))
        var activeSections: [SidebarExternalRepoSection] = []
        var historySections: [SidebarHistoryRepoSection] = []

        for repo in repos {
            // v0.29.28: workspace-registered repos' JSONLs belong to
            // their workspace section, not "Active outside Clawdmeter"
            // / "History". `buildWorkspaceSections` already folded the
            // recents into the matching section above.
            if workspaceRepoKeys.contains(repo.key) { continue }
            let filtered = repo.recentSessions
                .filter { !owned.contains(canonicalJSONLPath($0.path)) }
                .filter { recentMatches($0, repo: repo, query: query) }
                .sorted { $0.lastModified > $1.lastModified }
            guard !filtered.isEmpty else { continue }

            let active = filtered.filter { $0.lastModified >= activeCutoff }
            if let latest = active.first?.lastModified {
                activeSections.append(SidebarExternalRepoSection(
                    repo: AgentRepo(
                        key: repo.key,
                        displayName: repo.displayName,
                        hasActiveSessions: repo.hasActiveSessions,
                        liveSessionCount: repo.liveSessionCount,
                        recentSessions: active
                    ),
                    recents: active,
                    latestActivity: latest
                ))
            }

            let history = filtered.filter { $0.lastModified < activeCutoff }
            if !history.isEmpty {
                let groups = historyDateGroups(for: history, now: now)
                if let latest = history.first?.lastModified {
                    historySections.append(SidebarHistoryRepoSection(
                        repo: AgentRepo(
                            key: repo.key,
                            displayName: repo.displayName,
                            hasActiveSessions: repo.hasActiveSessions,
                            liveSessionCount: repo.liveSessionCount,
                            recentSessions: history
                        ),
                        dateGroups: groups,
                        latestActivity: latest
                    ))
                }
            }
        }

        return (
            activeSections.sorted {
                if $0.latestActivity != $1.latestActivity { return $0.latestActivity > $1.latestActivity }
                return $0.repo.displayName < $1.repo.displayName
            },
            historySections.sorted {
                if $0.latestActivity != $1.latestActivity { return $0.latestActivity > $1.latestActivity }
                return $0.repo.displayName < $1.repo.displayName
            }
        )
    }

    private static func historyDateGroups(
        for recents: [RecentSession],
        now: Date
    ) -> [SidebarHistoryDateGroup] {
        let calendar = Calendar.current
        var buckets: [Date: [RecentSession]] = [:]
        for recent in recents {
            let day = calendar.startOfDay(for: recent.lastModified)
            buckets[day, default: []].append(recent)
        }
        return buckets.map { day, rows in
            let sortedRows = rows.sorted { $0.lastModified > $1.lastModified }
            return SidebarHistoryDateGroup(
                id: "\(day.timeIntervalSince1970)",
                title: historyTitle(for: day, calendar: calendar),
                recents: sortedRows,
                latestActivity: sortedRows.first?.lastModified ?? day
            )
        }
        .sorted {
            if $0.latestActivity != $1.latestActivity { return $0.latestActivity > $1.latestActivity }
            return $0.id < $1.id
        }
    }

    private static func reposWithoutRecents(_ repos: [AgentRepo]) -> [AgentRepo] {
        repos.map {
            AgentRepo(
                key: $0.key,
                displayName: $0.displayName,
                hasActiveSessions: $0.hasActiveSessions,
                liveSessionCount: $0.liveSessionCount,
                recentSessions: []
            )
        }
    }

    private static func recentMatches(_ recent: RecentSession, repo: AgentRepo, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if repo.displayName.lowercased().contains(query) { return true }
        if recent.path.lowercased().contains(query) { return true }
        if let title = recent.firstPrompt?.lowercased(), title.contains(query) { return true }
        if let alias = recent.customName?.lowercased(), alias.contains(query) { return true }
        if AgentKindUI.displayName(for: recent.provider).lowercased().contains(query) { return true }
        return false
    }

    private static func canonicalJSONLPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func historyTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    // MARK: - Review-bucket inputs

    private static func reviewSessionIds(
        sessions: [AgentSession],
        workbenchPRStateBySession: [UUID: String?]
    ) -> Set<UUID> {
        var out: Set<UUID> = []
        out.reserveCapacity(sessions.count / 4)
        for session in sessions {
            if session.planText != nil {
                out.insert(session.id)
                continue
            }
            if let state = session.prMirrorState?.state,
               state == .open || state == .draft {
                out.insert(session.id)
                continue
            }
            if let raw = workbenchPRStateBySession[session.id] ?? nil {
                let state = raw.lowercased()
                if state == "open" || state == "draft" || state == "pending" {
                    out.insert(session.id)
                    continue
                }
            }
        }
        return out
    }

    // MARK: - Fingerprints

    /// Order-sensitive xor-fold of the per-session fields the projection
    /// reads. Cheap to compute (one pass), comparable as a single Int on
    /// every body re-eval. Collision-resistant enough for cache
    /// invalidation — a collision would only cause a missed recompute on
    /// one body pass and self-heal as soon as the next mutation tips a
    /// bit in the fingerprint.
    static func registryFingerprint(_ sessions: [AgentSession]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(sessions.count)
        for s in sessions {
            hasher.combine(s.id)
            hasher.combine(s.lastEventSeq)
            hasher.combine(s.status)
            hasher.combine(s.archivedAt)
            hasher.combine(s.planText == nil)
            hasher.combine(s.prMirrorState?.state)
            hasher.combine(s.parentSessionId)
            hasher.combine(s.repoKey)
            hasher.combine(s.repoDisplayName)
            hasher.combine(s.goal)
            hasher.combine(s.agent)
            hasher.combine(s.lastEventAt)
            // Sidebar row title uses `customName` before legacy
            // titleOverrides and before goal (see `sessionTitle` in
            // SessionWorkspaceView). `registry.rename(...)` mutates
            // customName *without* bumping `lastEventSeq` (it's a
            // local-state mutation, not a cross-device event), so we
            // must hash it explicitly — otherwise a daemon-driven
            // first-prompt rename (chat-tab D1 naming, /rename HTTP
            // endpoint) updates the registry but leaves the cached
            // projection's `[AgentSession]` snapshots holding stale
            // customNames. Non-repo groupings (date/status/agent/none)
            // render rows out of the cached projection directly, so
            // this stale snapshot is what `sessionRow` sees until
            // something else invalidates the cache. Repo grouping
            // dodges this because `repoSection` re-reads
            // `model.registry.sessions` live per repo.
            hasher.combine(s.customName)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    static func reposFingerprint(_ repos: [AgentRepo]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(repos.count)
        for repo in repos {
            hasher.combine(repo.key)
            hasher.combine(repo.displayName)
            hasher.combine(repo.hasActiveSessions)
            hasher.combine(repo.liveSessionCount)
            hasher.combine(repo.recentSessions.count)
            for recent in repo.recentSessions {
                hasher.combine(recent.path)
                hasher.combine(recent.lastModified)
                hasher.combine(recent.customName)
                hasher.combine(recent.firstPrompt)
                hasher.combine(recent.provider)
            }
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    static func workbenchPRCacheFingerprint(_ prCache: [UUID: PRCacheStateSnapshot]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(prCache.count)
        // Deterministic order — sort keys by uuidString so different
        // insertion orders produce identical fingerprints. UUID isn't
        // Comparable, but its string form is, and the cost is one
        // String allocation per cached PR row (small in practice).
        for key in prCache.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            hasher.combine(key)
            hasher.combine(prCache[key]?.state)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
