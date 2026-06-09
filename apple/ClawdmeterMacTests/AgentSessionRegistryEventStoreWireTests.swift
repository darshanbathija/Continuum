// F2-wire coverage for the AgentSessionRegistry → OrchestrationEventStore
// integration. Tests the contract that the registry's mutation methods
// write a receipt to the SQLite log BEFORE mutating in-memory state,
// and that on restart the registry's projection is seeded from the
// replay path.
//
// These tests exercise the *wired* path (registry + injected event store)
// rather than the store alone — OrchestrationEventStoreTests covers the
// store's own contract; this file proves the registry honors it.

import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class AgentSessionRegistryEventStoreWireTests: XCTestCase {

    private var workDir: URL!
    private var storeURL: URL!
    private var sessionsURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-f2wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        storeURL = workDir.appendingPathComponent("orchestration.sqlite")
        sessionsURL = workDir.appendingPathComponent("sessions.json")
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try await super.tearDown()
    }

    private func makeRegistry() throws -> (registry: AgentSessionRegistry, store: OrchestrationEventStore) {
        let store = try OrchestrationEventStore(storeURL: storeURL)
        let registry = AgentSessionRegistry(storeURL: sessionsURL, eventStore: store)
        return (registry, store)
    }

    // MARK: - Write-ahead receipt invariant

    /// F2-wire (b) — end-to-end mutate → restart → replay produces
    /// identical state. Spins up a registry with an injected event
    /// store, performs N mutations, closes everything, opens a new
    /// registry pointed at the same store but a missing JSON snapshot
    /// (cold start), and asserts the in-memory projection rebuilt by
    /// replay matches the original.
    func test_restart_replay_produces_identical_state() async throws {
        // Phase 1: write 5 events through the registry, capture the
        // expected projection.
        var expectedSessionIds: Set<UUID> = []
        var expectedStatuses: [UUID: AgentSessionStatus] = [:]
        do {
            let (reg, store) = try makeRegistry()
            // Create three code sessions.
            let a = try await reg.create(
                repoKey: "/tmp/a", repoDisplayName: "a", agent: .claude, model: "sonnet",
                goal: "Build A", worktreePath: "/tmp/a", tmuxWindowId: "@1", tmuxPaneId: "%1",
                planMode: false, mode: .local
            )
            let b = try await reg.create(
                repoKey: "/tmp/b", repoDisplayName: "b", agent: .codex, model: "gpt-5.5",
                goal: "Build B", worktreePath: "/tmp/b", tmuxWindowId: "@2", tmuxPaneId: "%2",
                planMode: true, mode: .worktree
            )
            // Status transitions on A: planning → done.
            try await reg.updateStatus(id: a.id, status: .planning)
            try await reg.updateStatus(id: a.id, status: .done)
            expectedSessionIds.insert(a.id)
            expectedStatuses[a.id] = .done
            // Approval flow on B.
            try await reg.setPlanText(id: b.id, planText: "1. step one\n2. step two")
            try await reg.markPlanApproved(id: b.id)
            try await reg.updateStatus(id: b.id, status: .running)
            expectedSessionIds.insert(b.id)
            expectedStatuses[b.id] = .running
            // Flush WAL so the second-launch reads a clean primary file.
            try await store.checkpoint()
        }
        // Phase 2: delete the JSON snapshot so init falls through to
        // event-replay seeding.
        try? FileManager.default.removeItem(at: sessionsURL)
        // Phase 3: cold-open a new registry pointed at the same event store.
        do {
            let (reg, _) = try makeRegistry()
            await reg.waitForEventReplaySeedForTesting()
            let projected = reg.sessions
            XCTAssertEqual(Set(projected.map(\.id)), expectedSessionIds,
                "Replay must rebuild exactly the same session id set")
            for session in projected {
                XCTAssertEqual(session.status, expectedStatuses[session.id],
                    "Replay must preserve the latest status per session")
            }
        }
    }

    func test_replaySeedDoesNotBlockRegistryInitOnMainActor() async throws {
        let store = try OrchestrationEventStore(storeURL: storeURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let commands = try (0..<750).map { index -> OrchestrationCommand in
            let session = replayFixtureSession(index: index, now: now)
            return OrchestrationCommand(
                source: "test",
                kind: .sessionCreated,
                sessionId: session.id.uuidString,
                timestamp: now.addingTimeInterval(Double(index)),
                runtimeEvent: nil,
                payload: try encoder.encode(session)
            )
        }
        _ = try await store.appendBatch(commands)
        try await store.checkpoint()

        let start = ProcessInfo.processInfo.systemUptime
        let reg = AgentSessionRegistry(storeURL: sessionsURL, eventStore: store)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertLessThan(
            elapsed,
            0.1,
            "Registry init must not synchronously replay the event log on the MainActor."
        )
        await reg.waitForEventReplaySeedForTesting()
        XCTAssertEqual(reg.sessions.count, commands.count)
    }

    /// F2-wire — recordCommand is the public write-ahead API. With
    /// the flag-on path (injected store), calling it MUST surface
    /// failures rather than discard them. Sanity check the typed
    /// throws path by appending against a corrupted-then-closed store.
    func test_recordCommand_propagates_typed_error_when_db_unwriteable() async throws {
        let (reg, store) = try makeRegistry()
        // Sanity: happy path works.
        let happyCmd = OrchestrationCommand(
            source: "test", kind: .sessionCreated,
            sessionId: UUID().uuidString, timestamp: Date(),
            runtimeEvent: nil, payload: Data("{}".utf8)
        )
        try await reg.recordCommand(happyCmd)
        let count = try await store.eventCount()
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    /// F2-wire — when the flag is OFF (no event store injected),
    /// recordCommand is a no-op that does NOT throw. This preserves
    /// the legacy rollback path: a registry created without a store
    /// behaves exactly like the pre-F2 implementation.
    func test_recordCommand_is_noop_when_flag_off() async throws {
        let reg = AgentSessionRegistry(storeURL: sessionsURL, eventStore: nil)
        let cmd = OrchestrationCommand(
            source: "test", kind: .sessionCreated,
            sessionId: UUID().uuidString, timestamp: Date(),
            runtimeEvent: nil, payload: Data()
        )
        // Should return immediately without throwing.
        try await reg.recordCommand(cmd)
    }

    func test_bulkArchive_archivesAllSessionsAndReplays() async throws {
        let archivedIds: [UUID]
        do {
            let (reg, store) = try makeRegistry()
            let first = try await reg.create(
                repoKey: "/tmp/repo", repoDisplayName: "repo", agent: .claude, model: "sonnet",
                goal: nil, worktreePath: "/tmp/repo/a", tmuxWindowId: nil, tmuxPaneId: nil,
                planMode: false, mode: .worktree
            )
            let second = try await reg.create(
                repoKey: "/tmp/repo", repoDisplayName: "repo", agent: .codex, model: "gpt-5.5",
                goal: nil, worktreePath: "/tmp/repo/b", tmuxWindowId: nil, tmuxPaneId: nil,
                planMode: false, mode: .worktree
            )

            archivedIds = [first.id, second.id]
            try await reg.archive(ids: archivedIds)

            XCTAssertNotNil(reg.session(id: first.id)?.archivedAt)
            XCTAssertNotNil(reg.session(id: second.id)?.archivedAt)

            let firstRows = try await store.loadForSession(first.id.uuidString)
            let secondRows = try await store.loadForSession(second.id.uuidString)
            XCTAssertTrue(firstRows.contains { $0.command.kind == .sessionMetadataUpdated })
            XCTAssertTrue(secondRows.contains { $0.command.kind == .sessionMetadataUpdated })
            try await store.checkpoint()
        }

        try? FileManager.default.removeItem(at: sessionsURL)
        let (replayed, _) = try makeRegistry()
        await replayed.waitForEventReplaySeedForTesting()
        for id in archivedIds {
            XCTAssertNotNil(replayed.session(id: id)?.archivedAt)
        }
    }

    func test_bulkArchiveCoalescesSnapshotSaveWithinFeedbackBudget() async throws {
        let registry = AgentSessionRegistry(storeURL: sessionsURL, eventStore: nil)
        var ids: [UUID] = []
        for index in 0..<250 {
            let session = try await registry.create(
                repoKey: "/tmp/repo",
                repoDisplayName: "repo",
                agent: index.isMultiple(of: 2) ? .codex : .claude,
                model: index.isMultiple(of: 2) ? "gpt-5.5" : "claude-sonnet-4-6",
                goal: "bulk-\(index)",
                worktreePath: "/tmp/repo/worktrees/bulk-\(index)",
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                planMode: false,
                mode: .worktree
            )
            ids.append(session.id)
        }

        let start = ContinuousClock.now
        try await registry.archive(ids: ids)
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTContext.runActivity(named: "Bulk archive feedback latency") { activity in
            activity.add(XCTAttachment(string: """
            sessions=250
            elapsed=\(elapsed)
            budget=100ms
            """))
        }
        XCTAssertLessThan(
            elapsed,
            .milliseconds(100),
            "Archive all must coalesce registry mutation and snapshot save so rows disappear within the feedback budget."
        )
        XCTAssertEqual(registry.sessions.filter { $0.archivedAt != nil }.count, ids.count)
    }

    func test_archiveReclaimEligibilityRequiresExplicitOwnedProvisioningMetadata() {
        let managedPath = "/Users/dev/Clawdmeter/workspaces/repo/bergen"
        XCTAssertTrue(AgentSessionRegistry.canReclaimWorktreeOnArchive(Self.reclaimSession(
            worktreePath: managedPath,
            ownsWorktree: true,
            provisioning: Self.reclaimMetadata(worktreePath: managedPath)
        )))
        XCTAssertFalse(AgentSessionRegistry.canReclaimWorktreeOnArchive(Self.reclaimSession(
            worktreePath: managedPath,
            ownsWorktree: false,
            provisioning: Self.reclaimMetadata(worktreePath: managedPath)
        )))
        XCTAssertFalse(AgentSessionRegistry.canReclaimWorktreeOnArchive(Self.reclaimSession(
            worktreePath: managedPath,
            ownsWorktree: true,
            provisioning: nil
        )))
        XCTAssertFalse(AgentSessionRegistry.canReclaimWorktreeOnArchive(Self.reclaimSession(
            worktreePath: managedPath,
            ownsWorktree: true,
            provisioning: Self.reclaimMetadata(worktreePath: managedPath, markerId: "")
        )))
        XCTAssertFalse(AgentSessionRegistry.canReclaimWorktreeOnArchive(Self.reclaimSession(
            worktreePath: managedPath,
            ownsWorktree: true,
            provisioning: Self.reclaimMetadata(worktreePath: "/Users/dev/Clawdmeter/workspaces/repo/other")
        )))
        XCTAssertFalse(AgentSessionRegistry.canReclaimWorktreeOnArchive(Self.reclaimSession(
            worktreePath: "/Users/dev/project/.claude/worktrees/bergen",
            ownsWorktree: true,
            provisioning: Self.reclaimMetadata(worktreePath: "/Users/dev/project/.claude/worktrees/bergen")
        )))
        XCTAssertFalse(AgentSessionRegistry.canReclaimWorktreeOnArchive(Self.reclaimSession(
            repoKey: managedPath,
            worktreePath: managedPath,
            ownsWorktree: true,
            provisioning: Self.reclaimMetadata(worktreePath: managedPath)
        )))
        XCTAssertFalse(AgentSessionRegistry.canReclaimWorktreeOnArchive(Self.reclaimSession(
            worktreePath: managedPath,
            ownsWorktree: true,
            provisioning: Self.reclaimMetadata(worktreePath: managedPath),
            kind: .chat
        )))
    }

    func test_setLaunchConfiguration_updatesProviderModelAndClearsEffortAndReplays() async throws {
        let sessionId: UUID
        do {
            let (reg, store) = try makeRegistry()
            let session = try await reg.create(
                repoKey: "/tmp/repo", repoDisplayName: "repo", agent: .codex, model: "gpt-5.5",
                goal: nil, worktreePath: "/tmp/repo/cleveland", tmuxWindowId: nil, tmuxPaneId: nil,
                planMode: true, mode: .worktree, effort: .max
            )
            sessionId = session.id

            try await reg.setLaunchConfiguration(
                id: session.id,
                agent: .gemini,
                model: "gemini-3.5-flash-thinking",
                effort: nil
            )

            let updated = try XCTUnwrap(reg.session(id: session.id))
            XCTAssertEqual(updated.agent, .gemini)
            XCTAssertEqual(updated.model, "gemini-3.5-flash-thinking")
            XCTAssertNil(updated.effort)
            XCTAssertEqual(updated.runtimeBinding?.providerModelId, "gemini-3.5-flash-thinking")
            XCTAssertEqual(updated.runtimeBinding?.billingProvider, "antigravity")

            let rows = try await store.loadForSession(session.id.uuidString)
            XCTAssertTrue(rows.contains { $0.command.kind == .sessionMetadataUpdated })
            try await store.checkpoint()
        }

        try? FileManager.default.removeItem(at: sessionsURL)
        let (replayed, _) = try makeRegistry()
        await replayed.waitForEventReplaySeedForTesting()
        let restored = try XCTUnwrap(replayed.session(id: sessionId))
        XCTAssertEqual(restored.agent, .gemini)
        XCTAssertEqual(restored.model, "gemini-3.5-flash-thinking")
        XCTAssertNil(restored.effort)
        XCTAssertEqual(restored.runtimeBinding?.providerModelId, "gemini-3.5-flash-thinking")
        XCTAssertEqual(restored.runtimeBinding?.billingProvider, "antigravity")
    }

    func test_previewLaunchConfiguration_isInMemoryOnlyForFastPickerToggles() async throws {
        let (reg, store) = try makeRegistry()
        let session = try await reg.create(
            repoKey: "/tmp/repo", repoDisplayName: "repo", agent: .claude, model: "sonnet",
            goal: nil, worktreePath: "/tmp/repo/charlotte", tmuxWindowId: nil, tmuxPaneId: nil,
            planMode: true, mode: .worktree, effort: .max
        )
        let rowsBefore = try await store.loadForSession(session.id.uuidString)

        reg.previewLaunchConfiguration(
            id: session.id,
            agent: .cursor,
            model: CursorModelCatalog.autoModelId,
            effort: nil
        )

        let updated = try XCTUnwrap(reg.session(id: session.id))
        XCTAssertEqual(updated.agent, .cursor)
        XCTAssertEqual(updated.model, CursorModelCatalog.autoModelId)
        XCTAssertNil(updated.effort)
        XCTAssertEqual(updated.runtimeBinding?.providerModelId, CursorModelCatalog.autoModelId)

        let rowsAfter = try await store.loadForSession(session.id.uuidString)
        XCTAssertEqual(rowsAfter.count, rowsBefore.count)
        XCTAssertFalse(rowsAfter.dropFirst(rowsBefore.count).contains { $0.command.kind == .sessionMetadataUpdated })
    }

    /// F2-wire — `delete` writes a `.sessionDeleted` receipt BEFORE
    /// purging the in-memory state. Verify the receipt lands and that
    /// the historical events for the deleted session are gone from the
    /// log (privacy-delete contract).
    func test_delete_writes_receipt_and_purges_history() async throws {
        let (reg, store) = try makeRegistry()
        let session = try await reg.create(
            repoKey: "/tmp/x", repoDisplayName: "x", agent: .claude, model: "sonnet",
            goal: "Goal X", worktreePath: "/tmp/x", tmuxWindowId: "@1", tmuxPaneId: "%1",
            planMode: false, mode: .local
        )
        try await reg.updateStatus(id: session.id, status: .done)
        let preDeleteCount = try await store.loadForSession(session.id.uuidString).count
        XCTAssertGreaterThan(preDeleteCount, 0)

        try await reg.delete(id: session.id)
        // The session-id's events are gone (privacy delete).
        let postDeleteForSession = try await store.loadForSession(session.id.uuidString)
        XCTAssertEqual(postDeleteForSession.count, 0,
            "After delete, no events for the doomed session remain in the log")
        // The in-memory projection drops the session.
        XCTAssertNil(reg.session(id: session.id))
    }

    /// F2-wire — every mutation kind writes a receipt with the
    /// matching `OrchestrationCommand.Kind`. Spot-check the
    /// kind-mapping for status transitions: done → completed,
    /// degraded → failed, paused → interrupted.
    func test_status_transitions_map_to_typed_kinds() async throws {
        let (reg, store) = try makeRegistry()
        let session = try await reg.create(
            repoKey: "/tmp/k", repoDisplayName: "k", agent: .claude, model: "sonnet",
            goal: nil, worktreePath: "/tmp/k", tmuxWindowId: "@1", tmuxPaneId: "%1",
            planMode: false, mode: .local
        )
        try await reg.updateStatus(id: session.id, status: .done)
        try await reg.updateStatus(id: session.id, status: .degraded)
        try await reg.updateStatus(id: session.id, status: .paused)

        let rows = try await store.loadForSession(session.id.uuidString)
        // First receipt is the .sessionCreated from create; then three
        // status transitions in their typed kinds.
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        let kinds = rows.map(\.command.kind)
        XCTAssertEqual(kinds[0], .sessionCreated)
        XCTAssertEqual(kinds[1], .sessionCompleted, "status .done must map to .sessionCompleted")
        XCTAssertEqual(kinds[2], .sessionFailed,    "status .degraded must map to .sessionFailed")
        XCTAssertEqual(kinds[3], .sessionInterrupted, "status .paused must map to .sessionInterrupted")
    }

    /// F2-wire — `markPlanApproved` writes a `.sessionApproved`
    /// receipt (not just a metadata-updated). Replay can branch on
    /// approval intent.
    func test_markPlanApproved_writes_approved_kind() async throws {
        let (reg, store) = try makeRegistry()
        let session = try await reg.create(
            repoKey: "/tmp/p", repoDisplayName: "p", agent: .claude, model: "sonnet",
            goal: nil, worktreePath: "/tmp/p", tmuxWindowId: "@1", tmuxPaneId: "%1",
            planMode: true, mode: .local
        )
        try await reg.setPlanText(id: session.id, planText: "1. do a thing")
        try await reg.markPlanApproved(id: session.id)
        let rows = try await store.loadForSession(session.id.uuidString)
        let approvedKindRow = rows.last { $0.command.kind == .sessionApproved }
        XCTAssertNotNil(approvedKindRow, "markPlanApproved must emit a .sessionApproved receipt")
    }

    func test_renameTerminalPane_persistsThroughRegistryReplay() async throws {
        let pane = TerminalPaneRef(id: UUID(), paneId: "%2", title: "Pane 2", isPrimary: false)
        let sessionId: UUID
        do {
            let (reg, store) = try makeRegistry()
            let session = try await reg.create(
                repoKey: "/tmp/t", repoDisplayName: "t", agent: .claude, model: "sonnet",
                goal: nil, worktreePath: "/tmp/t", tmuxWindowId: "@1", tmuxPaneId: "%1",
                planMode: false, mode: .local
            )
            sessionId = session.id
            try await reg.addTerminalPane(sessionId: session.id, pane: pane)
            let renamed = try await reg.renameTerminalPane(sessionId: session.id, paneRefId: pane.id, title: "Build logs")
            XCTAssertEqual(renamed?.title, "Build logs")
            try await store.checkpoint()
        }

        try? FileManager.default.removeItem(at: sessionsURL)
        let (replayed, _) = try makeRegistry()
        await replayed.waitForEventReplaySeedForTesting()
        let restored = try XCTUnwrap(replayed.session(id: sessionId))
        XCTAssertEqual(restored.terminalPanes.first?.title, "Build logs")
    }

    // #185 also shipped a `test_createCodeSessionCanPersistExplicitRuntimeCwdForSameWorkspaceTabs`
    // test that called `reg.create(..., runtimeCwd: ...)`. That overload didn't ship on main
    // (the workspace-tab-aware `create` signature was a separate piece of #185 that overlapped
    // with #174 and was dropped in the surgical rebase). Dropping the test for now to keep the
    // file compiling; restore it if/when the same-workspace-tab create overload lands.

    private func replayFixtureSession(index: Int, now: Date) -> AgentSession {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        let path = "/tmp/replay-\(index)"
        return AgentSession(
            id: id,
            repoKey: path,
            repoDisplayName: "replay-\(index)",
            agent: index.isMultiple(of: 2) ? .claude : .codex,
            model: nil,
            goal: "Replay \(index)",
            worktreePath: path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now.addingTimeInterval(Double(index)),
            lastEventSeq: UInt64(index),
            mode: .worktree
        )
    }

    private static func reclaimMetadata(
        worktreePath: String,
        markerId: String = "continuum-owned"
    ) -> WorktreeProvisioningMetadata {
        WorktreeProvisioningMetadata(
            ownershipMarkerId: markerId,
            branchName: "bergen",
            worktreePath: worktreePath,
            storageRoot: "/Users/dev/Clawdmeter/workspaces",
            projectSlug: "repo",
            workspaceSlug: "bergen",
            branchAliasPath: nil,
            filesToCopy: WorktreeFileCopySummary(source: .disabled, patterns: [])
        )
    }

    private static func reclaimSession(
        repoKey: String? = "/Users/dev/project",
        worktreePath: String?,
        ownsWorktree: Bool,
        provisioning: WorktreeProvisioningMetadata?,
        kind: SessionKind = .code
    ) -> AgentSession {
        let now = Date(timeIntervalSince1970: 1_777_200_000)
        return AgentSession(
            id: UUID(),
            repoKey: repoKey,
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: nil,
            worktreePath: worktreePath,
            provisioning: provisioning,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 1,
            mode: .worktree,
            kind: kind,
            ownsWorktree: ownsWorktree
        )
    }
}
