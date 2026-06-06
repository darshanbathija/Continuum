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

        // Sanity-check the projection covers the normal first-party input.
        // Archived rows are now visible only through the explicit Archive
        // status filter, never through default Status grouping.
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

    // MARK: - Active Code sidebar projection

    func test_priorityWorkspaceSectionsOrderByRecencyAndPinsDoNotOverride() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let repoKey = "/Users/dev/clawdmeter"
        let oldA = Self.makeSession(
            index: 1,
            repoKey: repoKey,
            workspacePath: "\(repoKey)/.claude/worktrees/a",
            lastEventAt: now.addingTimeInterval(-20)
        )
        let newA = Self.makeSession(
            index: 2,
            repoKey: repoKey,
            workspacePath: "\(repoKey)/.claude/worktrees/a",
            lastEventAt: now.addingTimeInterval(-10)
        )
        let newestB = Self.makeSession(
            index: 3,
            repoKey: repoKey,
            workspacePath: "\(repoKey)/.claude/worktrees/b",
            lastEventAt: now
        )
        let oldC = Self.makeSession(
            index: 4,
            repoKey: repoKey,
            workspacePath: "\(repoKey)/.claude/worktrees/c",
            lastEventAt: now.addingTimeInterval(-30)
        )

        let projection = Self.buildProjection(
            sessions: [oldA, newA, newestB, oldC],
            repos: [Self.repo(key: repoKey)],
            pinnedSessionIds: [oldC.id, oldA.id],
            now: now
        )

        XCTAssertEqual(
            projection.workspaceSections.map { ($0.workspacePath as NSString).lastPathComponent },
            ["b", "a", "c"],
            "Pinned sessions may show indicators/actions, but default workspace ordering must stay recency-based."
        )
        let aSection = projection.workspaceSections.first {
            ($0.workspacePath as NSString).lastPathComponent == "a"
        }
        XCTAssertEqual(aSection?.sessions.map(\.id), [newA.id, oldA.id])
        XCTAssertEqual(projection.visibleSessions.map(\.id), [newestB.id, newA.id, oldA.id, oldC.id])
    }

    func test_priorityProjectionHidesArchivedInNormalStatusAndShowsOnlyArchiveFilter() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let repoKey = "/Users/dev/clawdmeter"
        let active = Self.makeSession(
            index: 10,
            repoKey: repoKey,
            workspacePath: "\(repoKey)/.claude/worktrees/active",
            lastEventAt: now
        )
        let archived = Self.makeSession(
            index: 11,
            repoKey: repoKey,
            workspacePath: "\(repoKey)/.claude/worktrees/archive",
            lastEventAt: now.addingTimeInterval(10),
            archivedAt: now
        )

        let normal = Self.buildProjection(
            sessions: [active, archived],
            repos: [Self.repo(key: repoKey)],
            statusFilter: .all,
            grouping: .status,
            now: now
        )
        XCTAssertEqual(normal.workspaceSections.flatMap(\.sessions).map(\.id), [active.id])
        XCTAssertFalse((normal.groups ?? []).flatMap(\.sessions).contains { $0.id == archived.id })

        let archiveOnly = Self.buildProjection(
            sessions: [active, archived],
            repos: [Self.repo(key: repoKey)],
            statusFilter: .archived,
            grouping: .status,
            now: now
        )
        XCTAssertEqual(archiveOnly.workspaceSections.flatMap(\.sessions).map(\.id), [archived.id])
        XCTAssertEqual((archiveOnly.groups ?? []).flatMap(\.sessions).map(\.id), [archived.id])
        XCTAssertTrue(archiveOnly.activeExternalSections.isEmpty)
        XCTAssertTrue(archiveOnly.historySections.isEmpty)
    }

    func test_externalSessionsUseFiveMinuteActiveCutoffBoundaries() {
        // SidebarProjection.externalActiveWindow is 5 min (300s) and the boundary
        // is inclusive (lastModified >= now - 300 => active). Fixtures straddle 300s.
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let repoKey = "/Users/dev/clawdmeter"
        let activeAt299 = Self.recent(path: "/tmp/active-299.jsonl", lastModified: now.addingTimeInterval(-299))
        let activeAt300 = Self.recent(path: "/tmp/active-300.jsonl", lastModified: now.addingTimeInterval(-300))
        let historyAt301 = Self.recent(path: "/tmp/history-301.jsonl", lastModified: now.addingTimeInterval(-301))

        let projection = Self.buildProjection(
            sessions: [],
            repos: [Self.repo(key: repoKey, recents: [historyAt301, activeAt300, activeAt299])],
            now: now
        )

        XCTAssertEqual(
            projection.activeExternalSections.flatMap(\.recents).map(\.path),
            [activeAt299.path, activeAt300.path]
        )
        XCTAssertEqual(
            projection.historySections.flatMap { $0.dateGroups.flatMap(\.recents) }.map(\.path),
            [historyAt301.path]
        )
    }

    func test_projectionCacheInvalidatesWhenExternalRecentCrossesCutoffWithinSameMinute() {
        let sessions: [AgentSession] = []
        let firstNow = Date(timeIntervalSince1970: 1_900_000_000)
        let repos = [
            Self.repo(
                key: "/Users/dev/clawdmeter",
                recents: [Self.recent(path: "/tmp/external.jsonl", lastModified: firstNow.addingTimeInterval(-299))]
            )
        ]
        let cache = SingleSlotProjectionCache<SidebarProjectionKey, SidebarProjection>()
        var builderCalls = 0

        func body(now: Date) -> SidebarProjection {
            let key = makeKey(
                sessions: sessions,
                searchFiltered: sessions,
                repos: repos,
                query: "",
                grouping: .repo,
                now: now
            )
            return cache.value(for: key) {
                builderCalls += 1
                return Self.buildProjection(sessions: sessions, repos: repos, now: now)
            }
        }

        _ = body(now: firstNow)
        _ = body(now: firstNow)
        _ = body(now: firstNow.addingTimeInterval(2))

        XCTAssertEqual(builderCalls, 2)
        XCTAssertEqual(cache.hitCount, 1)
        XCTAssertEqual(cache.missCount, 2)
    }

    func test_externalRecentNeverAppearsInBothActiveAndHistory() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let repoKey = "/Users/dev/clawdmeter"
        let recents = [
            Self.recent(path: "/tmp/active-a.jsonl", lastModified: now.addingTimeInterval(-120)),
            Self.recent(path: "/tmp/active-b.jsonl", lastModified: now.addingTimeInterval(-600)),
            Self.recent(path: "/tmp/history-a.jsonl", lastModified: now.addingTimeInterval(-601)),
            Self.recent(path: "/tmp/history-b.jsonl", lastModified: now.addingTimeInterval(-3_600)),
        ]

        let projection = Self.buildProjection(
            sessions: [],
            repos: [Self.repo(key: repoKey, recents: recents)],
            now: now
        )
        let active = Set(projection.activeExternalSections.flatMap(\.recents).map(\.path))
        let history = Set(projection.historySections.flatMap { $0.dateGroups.flatMap(\.recents) }.map(\.path))

        XCTAssertTrue(active.isDisjoint(with: history))
        XCTAssertEqual(active.union(history), Set(recents.map(\.path)))
    }

    func test_nonRepoGroupingsDoNotLeakOldRecentsIntoActiveSections() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let repoKey = "/Users/dev/clawdmeter"
        let oldRecent = Self.recent(path: "/tmp/old-external.jsonl", lastModified: now.addingTimeInterval(-3_600))

        for grouping in [SessionGrouping.date, .agent, .none] {
            let projection = Self.buildProjection(
                sessions: [],
                repos: [Self.repo(key: repoKey, recents: [oldRecent])],
                grouping: grouping,
                now: now
            )

            XCTAssertTrue(projection.activeExternalSections.isEmpty)
            XCTAssertEqual(
                projection.historySections.flatMap { $0.dateGroups.flatMap(\.recents) }.map(\.path),
                [oldRecent.path]
            )
            XCTAssertTrue((projection.groups ?? []).allSatisfy { $0.recents.isEmpty })
        }
    }

    func test_ownedJSONLPathsAreExcludedFromExternalActiveAndHistory() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let repoKey = "/Users/dev/clawdmeter"
        let ownedActive = Self.recent(path: "/tmp/owned-active.jsonl", lastModified: now.addingTimeInterval(-120))
        let ownedHistory = Self.recent(path: "/tmp/owned-history.jsonl", lastModified: now.addingTimeInterval(-3_600))
        let external = Self.recent(path: "/tmp/external.jsonl", lastModified: now.addingTimeInterval(-60))

        let projection = Self.buildProjection(
            sessions: [],
            repos: [Self.repo(key: repoKey, recents: [ownedActive, ownedHistory, external])],
            ownedJSONLPaths: [ownedActive.path, ownedHistory.path],
            now: now
        )

        XCTAssertEqual(projection.activeExternalSections.flatMap(\.recents).map(\.path), [external.path])
        XCTAssertTrue(projection.historySections.isEmpty)
    }

    @MainActor
    func test_openingExternalJSONLReadOnlyDoesNotCreateFirstPartyWorkspaceRow() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarProjectionExternal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = AgentSessionRegistry(storeURL: directory.appendingPathComponent("sessions.json"))
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: Self.makeWorkspaceStore(in: directory)
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let jsonlURL = directory.appendingPathComponent("read-only-external.jsonl")
        try! Data().write(to: jsonlURL)
        let recent = Self.recent(path: jsonlURL.path, lastModified: now)
        let repoKey = "/Users/dev/clawdmeter"

        model.openOutsideSession(
            recent: recent,
            repoKey: repoKey,
            repoDisplayName: "Clawdmeter"
        )

        let opened = model.openSession
        XCTAssertNotNil(opened)
        XCTAssertTrue(model.openSessionIsReadOnly)
        XCTAssertNil(opened?.repoKey)
        XCTAssertEqual(opened?.effectiveCwd, repoKey)
        XCTAssertNil(opened.flatMap { WorkspaceKey.of($0) })
        if let opened {
            XCTAssertNotNil(model.chatStore(for: opened))
        }
        XCTAssertFalse(model.knownOwnedJSONLPaths.contains((recent.path as NSString).standardizingPath))

        let projection = Self.buildProjection(
            sessions: opened.map { [$0] } ?? [],
            repos: [Self.repo(key: repoKey, recents: [recent])],
            ownedJSONLPaths: model.knownOwnedJSONLPaths,
            now: now
        )
        XCTAssertTrue(projection.workspaceSections.isEmpty)
        XCTAssertEqual(projection.activeExternalSections.flatMap { $0.recents }.map { $0.path }, [recent.path])
    }

    @MainActor
    func test_filteredReposSearchMatchesExternalRecentMetadata() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarProjectionExternalSearch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = AgentSessionRegistry(storeURL: directory.appendingPathComponent("sessions.json"))
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: Self.makeWorkspaceStore(in: directory)
        )
        let recent = Self.recent(
            path: directory.appendingPathComponent("outside-session.jsonl").path,
            lastModified: Date(timeIntervalSince1970: 1_900_000_000),
            provider: .codex,
            firstPrompt: "Repair active sidebar projection"
        )
        let repo = Self.repo(key: "/Users/dev/clawdmeter", displayName: "Clawdmeter", recents: [recent])
        model.repos = [repo]
        model.searchQuery = "sidebar projection"

        XCTAssertEqual(model.filteredRepos.map { $0.key }, [repo.key])

        model.searchQuery = "codex"
        XCTAssertEqual(model.filteredRepos.map { $0.key }, [repo.key])
    }

    @MainActor
    func test_prepareNewSessionPreselectsRepoWithoutTogglingExpansion() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarProjectionPrepare-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = AgentSessionRegistry(storeURL: directory.appendingPathComponent("sessions.json"))
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: Self.makeWorkspaceStore(in: directory)
        )
        model.expandedRepoKeys = ["/Users/dev/existing"]

        model.prepareNewSession(in: "/Users/dev/clawdmeter")

        XCTAssertEqual(model.selectedRepoKey, "/Users/dev/clawdmeter")
        XCTAssertTrue(model.showingNewSessionSheet)
        XCTAssertEqual(model.expandedRepoKeys, ["/Users/dev/existing"])

        model.prepareNewSession(in: nil as String?)
        XCTAssertNil(model.selectedRepoKey)
        XCTAssertEqual(model.expandedRepoKeys, ["/Users/dev/existing"])
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
        pins: [UUID] = [],
        statusFilter: SessionStatusFilter = .all,
        ownedJSONLPaths: Set<String> = [],
        now: Date = Date(timeIntervalSince1970: 1_715_000_000)
    ) -> SidebarProjectionKey {
        SidebarProjectionKey(
            registryFingerprint: SidebarProjectionBuilder.registryFingerprint(sessions),
            reposFingerprint: SidebarProjectionBuilder.reposFingerprint(repos),
            workbenchPRCacheFingerprint: SidebarProjectionBuilder.workbenchPRCacheFingerprint([:]),
            searchFilteredFingerprint: SidebarProjectionBuilder.searchFilteredFingerprint(searchFiltered),
            query: query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            archiveFilter: false,
            statusFilter: statusFilter,
            grouping: grouping,
            sorting: .recency,
            pinnedSet: pins,
            ownedJSONLPathsFingerprint: SidebarProjectionBuilder.ownedJSONLPathsFingerprint(ownedJSONLPaths),
            externalActivityClockBucket: SidebarProjectionBuilder.externalActivityClockBucket(now: now, repos: repos),
            workspaceRepoKeysFingerprint: SidebarProjectionBuilder.workspaceRepoKeysFingerprint([])
        )
    }

    private static func buildProjection(
        sessions: [AgentSession],
        repos: [AgentRepo],
        statusFilter: SessionStatusFilter = .all,
        grouping: SessionGrouping = .repo,
        pinnedSessionIds: [UUID] = [],
        ownedJSONLPaths: Set<String> = [],
        now: Date
    ) -> SidebarProjection {
        SidebarProjectionBuilder.build(
            searchFilteredSessions: sessions,
            repos: repos,
            searchQuery: "",
            showArchived: false,
            statusFilter: statusFilter,
            grouping: grouping,
            sorting: .recency,
            pinnedSessionIds: pinnedSessionIds,
            workbenchPRStateBySession: [:],
            ownedJSONLPaths: ownedJSONLPaths,
            now: now
        )
    }

    private static func makeSession(
        index: Int,
        repoKey: String,
        repoDisplayName: String? = nil,
        workspacePath: String,
        lastEventAt: Date,
        status: AgentSessionStatus = .running,
        archivedAt: Date? = nil,
        kind: SessionKind = .code
    ) -> AgentSession {
        AgentSession(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index))!,
            repoKey: repoKey,
            repoDisplayName: repoDisplayName ?? (repoKey as NSString).lastPathComponent,
            agent: .claude,
            model: nil,
            goal: "Session \(index)",
            worktreePath: workspacePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: status,
            planText: nil,
            createdAt: lastEventAt.addingTimeInterval(-60),
            lastEventAt: lastEventAt,
            lastEventSeq: UInt64(index),
            mode: .worktree,
            archivedAt: archivedAt,
            runtimeCwd: workspacePath,
            kind: kind,
            ownsWorktree: true
        )
    }

    private static func repo(
        key: String,
        displayName: String? = nil,
        liveSessionCount: Int = 0,
        recents: [RecentSession] = []
    ) -> AgentRepo {
        AgentRepo(
            key: key,
            displayName: displayName ?? (key as NSString).lastPathComponent,
            hasActiveSessions: liveSessionCount > 0,
            liveSessionCount: liveSessionCount,
            recentSessions: recents
        )
    }

    private static func recent(
        path: String,
        lastModified: Date,
        provider: AgentKind = .claude,
        firstPrompt: String? = nil,
        customName: String? = nil
    ) -> RecentSession {
        RecentSession(
            path: path,
            lastModified: lastModified,
            provider: provider,
            firstPrompt: firstPrompt,
            customName: customName
        )
    }

    @MainActor
    private static func makeWorkspaceStore(in directory: URL) -> WorkspaceStore {
        WorkspaceStore(
            storeURL: directory.appendingPathComponent("workspaces.json"),
            sessionsURL: directory.appendingPathComponent("workspace-sessions.json")
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
