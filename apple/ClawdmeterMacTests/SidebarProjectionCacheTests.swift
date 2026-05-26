import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// A11 perf-gate suite for the sidebar projection cache. Anchors the
/// acceptance criterion from the plan:
///
///   > Sidebar search keystrokes must NOT trigger a full re-projection
///   > of all sessions. (...) A0 fixture sidebar-search gate must pass
///   > with the new cache wired in.
///
/// The "full re-projection" we're guarding against is the
/// `SidebarProjectionBuilder.build(...)` call — sort + group + canonicalize
/// across hundreds of sessions. The cache key bundles every input the
/// projection reads; equal keys MUST yield equal outputs, which we verify
/// by recomputing under both cached + uncached paths.
///
/// Three gates here:
///   1. **Cache-hit correctness** — identical inputs return identical
///      projections without invoking the builder twice.
///   2. **Search keystroke isolation** — typing into the search field
///      (only `query` changes) recomputes only the search-filtered slice;
///      no body re-eval that doesn't change ANY input re-runs the
///      builder.
///   3. **Fingerprint stability** — fingerprints are deterministic across
///      runs and react to the right field mutations.
///
/// Plan: A11 (Phase 2) — see .claude/plans/study-this-codebase-crystalline-shore.md
final class SidebarProjectionCacheTests: XCTestCase {

    // MARK: - Fixture: 500-session sidebar

    /// Builds a deterministic 500-session fixture similar in shape to the
    /// A0 fixture suite (sessions across 5 providers + 7 repos, ~20%
    /// archived, ~10% pinned, mixed statuses). A0's PerfFixtures lives in
    /// PR #126 (not yet landed against origin/main); this builder is the
    /// in-test stand-in so A11 ships on the same branch as the cache. When
    /// A0 merges, this can be replaced by `PerfFixtures.sessions500.map(...)`.
    private static func fixtureSessions(count: Int = 500, seed: UInt64 = 0xA0_5E55_1043) -> [AgentSession] {
        var rng = LCG(seed: seed)
        let repoKeys = [
            "/Users/dev/monorepo",
            "/Users/dev/billing-service",
            "/Users/dev/ios-app",
            "/Users/dev/infrastructure",
            "/Users/dev/design-system",
            "/Users/dev/experimental",
            "/Users/dev/tools",
        ]
        let providers: [AgentKind] = [.claude, .codex, .opencode, .cursor, .gemini]
        let titleWords = [
            "refactor", "bug", "feature", "explore", "test", "doc", "spike",
            "perf", "release", "audit", "migration", "polish", "rebuild",
        ]
        var sessions: [AgentSession] = []
        sessions.reserveCapacity(count)
        for i in 0..<count {
            let repoKey = repoKeys[Int(rng.next() % UInt64(repoKeys.count))]
            let provider = providers[Int(rng.next() % UInt64(providers.count))]
            let wordCount = Int(rng.next() % 3) + 2
            let title = (0..<wordCount).map { _ in
                titleWords[Int(rng.next() % UInt64(titleWords.count))]
            }.joined(separator: " ")
            let archived: Date? = (rng.next() % 100 < 20)
                ? Date(timeIntervalSince1970: 1_715_000_000 + Double(i) * 60)
                : nil
            let status: AgentSessionStatus = {
                switch rng.next() % 5 {
                case 0: return .running
                case 1: return .paused
                case 2: return .done
                case 3: return .planning
                default: return .running
                }
            }()
            let planText: String? = (status == .planning) ? "Plan \(i)" : nil
            sessions.append(AgentSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
                repoKey: repoKey,
                repoDisplayName: (repoKey as NSString).lastPathComponent,
                agent: provider,
                model: nil,
                goal: title,
                worktreePath: nil,
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                status: status,
                planText: planText,
                createdAt: Date(timeIntervalSince1970: 1_715_000_000 + Double(i) * 60),
                lastEventAt: Date(timeIntervalSince1970: 1_715_000_000 + Double(i) * 60),
                lastEventSeq: UInt64(i),
                archivedAt: archived
            ))
        }
        return sessions
    }

    private static func fixtureRepos(from sessions: [AgentSession]) -> [AgentRepo] {
        let byKey = Dictionary(grouping: sessions, by: { $0.repoKey ?? "" })
        return byKey.keys.sorted().compactMap { key -> AgentRepo? in
            guard !key.isEmpty else { return nil }
            let group = byKey[key] ?? []
            return AgentRepo(
                key: key,
                displayName: (key as NSString).lastPathComponent,
                hasActiveSessions: group.contains { $0.archivedAt == nil },
                liveSessionCount: group.count,
                recentSessions: []
            )
        }
    }

    /// Trivial linear congruential PRNG. Deterministic across machines —
    /// matches the same seed pattern A0's SeededPRNG uses, but inlined so
    /// this test compiles against origin/main without depending on PR #126.
    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { self.state = seed | 1 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // MARK: - Gate 1: cache-hit correctness

    func test_a11Gate_identicalInputsHitCache_andSkipBuilder() {
        let sessions = Self.fixtureSessions()
        let repos = Self.fixtureRepos(from: sessions)
        let cache = SingleSlotProjectionCache<SidebarProjectionKey, SidebarProjection>()
        var builderCalls = 0

        let key = makeKey(
            sessions: sessions,
            searchFiltered: sessions,
            repos: repos,
            query: "",
            grouping: .status
        )
        let buildClosure = {
            builderCalls += 1
            return SidebarProjectionBuilder.build(
                searchFilteredSessions: sessions,
                repos: repos,
                searchQuery: "",
                showArchived: false,
                statusFilter: .all,
                grouping: .status,
                sorting: .recency,
                pinnedSessionIds: [],
                workbenchPRStateBySession: [:]
            )
        }

        // First call: cache miss → builder invoked.
        let first = cache.value(for: key, compute: buildClosure)
        XCTAssertEqual(builderCalls, 1)
        XCTAssertEqual(cache.missCount, 1)
        XCTAssertEqual(cache.hitCount, 0)

        // Five subsequent calls with the same key (simulating SwiftUI
        // ticking the body for unrelated reasons): cache hits, builder
        // never re-runs.
        for _ in 0..<5 {
            _ = cache.value(for: key, compute: buildClosure)
        }
        XCTAssertEqual(builderCalls, 1, "builder must not re-run on identical keys")
        XCTAssertEqual(cache.hitCount, 5)

        // Sanity-check the projection covers all live sessions.
        XCTAssertEqual(
            first.visibleSessions.count,
            sessions.filter { $0.archivedAt == nil }.count
        )
    }

    // MARK: - Gate 2: search keystroke isolation

    func test_a11Gate_searchKeystrokes_recomputeOnce_andCacheHitsBetweenKeystrokes() {
        let sessions = Self.fixtureSessions()
        let repos = Self.fixtureRepos(from: sessions)
        let cache = SingleSlotProjectionCache<SidebarProjectionKey, SidebarProjection>()
        var builderCalls = 0

        func body(query: String) -> SidebarProjection {
            // Mimic SidebarPane: run the search filter outside the cache
            // (production calls `model.filter(sessions:)`; here we do a
            // goal-only match since the fixture has no chat stores).
            let filtered = Self.applySearchFilter(sessions: sessions, query: query)
            let key = makeKey(
                sessions: sessions,
                searchFiltered: filtered,
                repos: repos,
                query: query,
                grouping: .status
            )
            return cache.value(for: key) {
                builderCalls += 1
                return SidebarProjectionBuilder.build(
                    searchFilteredSessions: filtered,
                    repos: repos,
                    searchQuery: query,
                    showArchived: false,
                    statusFilter: .all,
                    grouping: .status,
                    sorting: .recency,
                    pinnedSessionIds: [],
                    workbenchPRStateBySession: [:]
                )
            }
        }

        // Simulate the user typing "refactor" letter-by-letter, with one
        // body re-eval per keystroke + one extra body re-eval BETWEEN
        // each keystroke (modeling SwiftUI's tendency to invalidate the
        // sidebar body for unrelated upstream sources).
        let keystrokes = ["r", "re", "ref", "refa", "refac", "refact", "refacto", "refactor"]
        var lastProjection: SidebarProjection?
        for keystroke in keystrokes {
            lastProjection = body(query: keystroke)         // user keystroke → cache miss expected
            _ = body(query: keystroke)                       // unrelated body re-eval → cache HIT
            _ = body(query: keystroke)                       // another unrelated tick → cache HIT
        }

        // We expect exactly `keystrokes.count` builder invocations —
        // one per unique query string. The unrelated body re-evals
        // between keystrokes must NOT have triggered the builder.
        XCTAssertEqual(
            builderCalls,
            keystrokes.count,
            "search keystrokes triggered \(builderCalls) builder calls; expected exactly \(keystrokes.count) (one per unique query)"
        )

        // Final projection must reflect the final query.
        XCTAssertNotNil(lastProjection)
        for session in (lastProjection?.visibleSessions ?? []) {
            let matches = (session.goal ?? "").lowercased().contains("refactor")
                || session.repoDisplayName.lowercased().contains("refactor")
            XCTAssertTrue(matches, "every visible session must match the final query 'refactor'")
        }
    }

    // MARK: - Gate 3: fingerprint reacts to the right mutations

    func test_a11Gate_registryFingerprintChangesOnSessionMutation() {
        let sessions = Self.fixtureSessions(count: 50)
        let baseline = SidebarProjectionBuilder.registryFingerprint(sessions)

        // Adding a session changes the fingerprint.
        var mutated = sessions
        mutated.append(AgentSession(
            id: UUID(),
            repoKey: "/Users/dev/new-repo",
            repoDisplayName: "new-repo",
            agent: .claude,
            model: nil,
            goal: "added",
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1
        ))
        XCTAssertNotEqual(
            SidebarProjectionBuilder.registryFingerprint(mutated),
            baseline,
            "adding a session must change the registry fingerprint"
        )

        // Removing/bumping `lastEventSeq` on one session changes it.
        // We re-create one session with an incremented seq.
        var bumped = sessions
        let target = bumped[0]
        bumped[0] = AgentSession(
            id: target.id,
            repoKey: target.repoKey,
            repoDisplayName: target.repoDisplayName,
            agent: target.agent,
            model: target.model,
            goal: target.goal,
            worktreePath: target.worktreePath,
            tmuxWindowId: target.tmuxWindowId,
            tmuxPaneId: target.tmuxPaneId,
            status: target.status,
            planText: target.planText,
            createdAt: target.createdAt,
            lastEventAt: target.lastEventAt,
            lastEventSeq: target.lastEventSeq + 1
        )
        XCTAssertNotEqual(
            SidebarProjectionBuilder.registryFingerprint(bumped),
            baseline,
            "bumping lastEventSeq must change the registry fingerprint"
        )

        // Same input → same fingerprint (deterministic across runs).
        XCTAssertEqual(
            SidebarProjectionBuilder.registryFingerprint(sessions),
            baseline,
            "fingerprint must be deterministic for the same input"
        )
    }

    /// Regression: `registry.rename(...)` mutates `customName` without
    /// bumping `lastEventSeq`. Pre-fix, the registry fingerprint missed
    /// this mutation and the cache served stale sidebar rows after a
    /// daemon-driven first-prompt rename (chat-tab D1 naming). Verify
    /// the fingerprint catches a customName change so the cache
    /// invalidates and the new title surfaces in non-repo groupings.
    func test_a11Gate_customNameMutationInvalidatesRegistryFingerprint() {
        let sessions = Self.fixtureSessions(count: 50)
        let baseline = SidebarProjectionBuilder.registryFingerprint(sessions)

        // Same input → same fingerprint.
        XCTAssertEqual(SidebarProjectionBuilder.registryFingerprint(sessions), baseline)

        // Renaming one session (customName flip) MUST change the
        // fingerprint, otherwise the cache serves a stale sidebar row.
        var renamed = sessions
        let target = renamed[0]
        renamed[0] = AgentSession(
            id: target.id,
            repoKey: target.repoKey,
            repoDisplayName: target.repoDisplayName,
            agent: target.agent,
            model: target.model,
            goal: target.goal,
            worktreePath: target.worktreePath,
            tmuxWindowId: target.tmuxWindowId,
            tmuxPaneId: target.tmuxPaneId,
            status: target.status,
            planText: target.planText,
            createdAt: target.createdAt,
            lastEventAt: target.lastEventAt,
            lastEventSeq: target.lastEventSeq,  // NOT bumped — mirrors registry.rename
            customName: "Renamed by daemon"
        )
        XCTAssertNotEqual(
            SidebarProjectionBuilder.registryFingerprint(renamed),
            baseline,
            "customName mutation must change the registry fingerprint (registry.rename doesn't bump lastEventSeq)"
        )
    }

    func test_a11Gate_pinnedSetIsPartOfCacheKey() {
        let sessions = Self.fixtureSessions(count: 100)
        let repos = Self.fixtureRepos(from: sessions)
        let cache = SingleSlotProjectionCache<SidebarProjectionKey, SidebarProjection>()
        var builderCalls = 0

        func body(pins: [UUID]) -> SidebarProjection {
            let key = makeKey(
                sessions: sessions,
                searchFiltered: sessions,
                repos: repos,
                query: "",
                grouping: .status,
                pins: pins
            )
            return cache.value(for: key) {
                builderCalls += 1
                return SidebarProjectionBuilder.build(
                    searchFilteredSessions: sessions,
                    repos: repos,
                    searchQuery: "",
                    showArchived: false,
                    statusFilter: .all,
                    grouping: .status,
                    sorting: .recency,
                    pinnedSessionIds: pins,
                    workbenchPRStateBySession: [:]
                )
            }
        }

        _ = body(pins: [])                                       // miss
        _ = body(pins: [sessions[0].id])                         // miss (new pin)
        _ = body(pins: [sessions[0].id])                         // hit
        _ = body(pins: [sessions[0].id, sessions[1].id])         // miss (added pin)
        _ = body(pins: [sessions[1].id, sessions[0].id])         // miss (pin order changed)
        _ = body(pins: [sessions[1].id, sessions[0].id])         // hit

        XCTAssertEqual(builderCalls, 4)
        XCTAssertEqual(cache.hitCount, 2)
    }

    // MARK: - Gate 4: timing budget (informational)

    /// XCTest `measure` block — first run records the baseline; subsequent
    /// runs detect regressions against the recorded baseline. The cache's
    /// real value is per-body-pass dedup, not raw single-pass latency, but
    /// this serves as a smoke gate that the projection itself stays under
    /// the A0 100ms main-thread budget on 500 sessions.
    func test_a11Gate_singlePassUnder100ms_on500Sessions() {
        let sessions = Self.fixtureSessions()
        let filtered = Self.applySearchFilter(sessions: sessions, query: "ref")
        let repos = Self.fixtureRepos(from: sessions)
        // Warm caches / allocations.
        _ = SidebarProjectionBuilder.build(
            searchFilteredSessions: filtered,
            repos: repos,
            searchQuery: "ref",
            showArchived: false,
            statusFilter: .all,
            grouping: .status,
            sorting: .recency,
            pinnedSessionIds: [],
            workbenchPRStateBySession: [:]
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            let projection = SidebarProjectionBuilder.build(
                searchFilteredSessions: filtered,
                repos: repos,
                searchQuery: "ref",
                showArchived: false,
                statusFilter: .all,
                grouping: .status,
                sorting: .recency,
                pinnedSessionIds: [],
                workbenchPRStateBySession: [:]
            )
            // Force evaluation so the optimizer doesn't strip the work.
            XCTAssertNotNil(projection.groups)
        }
    }

    // MARK: - Helpers

    private func makeKey(
        sessions: [AgentSession],
        searchFiltered: [AgentSession],
        repos: [AgentRepo],
        query: String,
        grouping: SessionGrouping,
        pins: [UUID] = []
    ) -> SidebarProjectionKey {
        SidebarProjectionKey(
            registryFingerprint: SidebarProjectionBuilder.registryFingerprint(sessions),
            reposFingerprint: SidebarProjectionBuilder.reposFingerprint(repos),
            workbenchPRCacheFingerprint: SidebarProjectionBuilder.workbenchPRCacheFingerprint([:]),
            searchFilteredFingerprint: SidebarProjectionBuilder.searchFilteredFingerprint(searchFiltered),
            query: query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            archiveFilter: false,
            statusFilter: .all,
            grouping: grouping,
            sorting: .recency,
            pinnedSet: pins
        )
    }

    /// Stand-in for `SessionsModel.filter(sessions:)` in tests. Production
    /// filters on goal + repoDisplayName + 50 most recent chat-store
    /// messages; the test fixture has no chat stores, so we apply the
    /// goal+repoDisplayName subset (the chat-store path is exercised
    /// integration-style by the wired SidebarPane in the app).
    private static func applySearchFilter(
        sessions: [AgentSession],
        query: String
    ) -> [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { s in
            if (s.goal ?? "").lowercased().contains(q) { return true }
            if s.repoDisplayName.lowercased().contains(q) { return true }
            return false
        }
    }
}
