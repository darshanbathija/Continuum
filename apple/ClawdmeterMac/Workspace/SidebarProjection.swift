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
/// chrome (expand/collapse and empty-state CTAs), while the other
/// groupings flatten into `SessionSidebarGroup` rows. The cache stores
/// either the canonical repo list OR the flattened groups list, plus the
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

    var hasPriorityContent: Bool {
        !workspaceSections.isEmpty
    }
}

struct SidebarWorkspaceSection: Identifiable, Hashable {
    let workspaceKey: WorkspaceKey
    let repo: AgentRepo
    let workspacePath: String
    let sessions: [AgentSession]
    let latestActivity: Date

    var id: String { "\(workspaceKey.repoKey)|\(workspaceKey.workspacePath)" }
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
///     hasActiveSessions.
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
    /// Set<String> of normalized repoRoots for every workspace registered
    /// in `WorkspaceStore`. The cache must invalidate when the set changes
    /// so newly added repos appear immediately even before they have a
    /// Continuum-created session.
    let workspaceRepoKeysFingerprint: UInt64
}

enum SidebarProjectionBuilder {
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
                && passesCodeStatus($0, statusFilter: statusFilter, reviewSessionIds: reviewIds, now: now)
        }
        let canonicalRepos = SessionSidebarGrouper.canonicalizeRepos(repos)
        let workspaceSections = buildWorkspaceSections(
            sessions: firstPartySessions,
            repos: canonicalRepos.repos,
            keyAliases: canonicalRepos.keyAliases,
            workspaceRepoKeys: workspaceRepoKeys
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
                workspaceSections: workspaceSections
            )
        case .date, .status, .agent, .none:
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
                workspaceSections: workspaceSections
            )
        }
    }

    /// Invalidates the projection cache when the user adds or removes a
    /// workspace.
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
            return false
        }
        return true
    }

    private static func passesCodeStatus(
        _ session: AgentSession,
        statusFilter: SessionStatusFilter,
        reviewSessionIds: Set<UUID>,
        now: Date
    ) -> Bool {
        guard passesArchiveGate(session, statusFilter: statusFilter, showArchived: false) else {
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
                latestActivity: latest
            )
        }

        // Emit sections for workspace-registered repos that have no
        // Continuum-spawned AgentSession yet. The user just added the repo
        // via the Add-Repo flow, so the empty workspace should still be
        // visible and ready for quick spawn.
        let representedKeys = Set(sections.map { keyAliases[$0.workspaceKey.repoKey] ?? $0.workspaceKey.repoKey })
        for repoKey in workspaceRepoKeys where !representedKeys.contains(repoKey) {
            let canonicalKey = keyAliases[repoKey] ?? repoKey
            let repo = repoByKey[canonicalKey] ?? AgentRepo(
                key: canonicalKey,
                displayName: RepoIdentity.displayName(for: canonicalKey),
                hasActiveSessions: false
            )
            let workspaceKey = WorkspaceKey(repoKey: canonicalKey, workspacePath: canonicalKey)
            sections.append(SidebarWorkspaceSection(
                workspaceKey: workspaceKey,
                repo: repo,
                workspacePath: canonicalKey,
                sessions: [],
                latestActivity: .distantPast
            ))
        }

        return sections.sorted {
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
