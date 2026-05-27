import XCTest
import Combine
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class WorkbenchStateTests: XCTestCase {
    private var tmpDir: URL!
    private var storeURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbenchStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        storeURL = tmpDir.appendingPathComponent("workbench-state.json")
    }

    override func tearDown() async throws {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        try await super.tearDown()
    }

    func test_defaultSnapshotUsesBalancedDensityAndPlanPane() {
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))

        XCTAssertEqual(state.density, .balanced)
        XCTAssertEqual(state.selectedRightPane, .plan)
        // v0.30: new users default to a collapsed review pane — see
        // WorkbenchStateSnapshot.init(showingReviewPane:) for rationale.
        // Persisted state still wins on subsequent launches.
        XCTAssertFalse(state.showingReviewPane)
        XCTAssertEqual(state.workspaceWidth, 1400)
    }

    func test_mutationsPersistToVersionedStore() {
        let sessionId = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))

        state.selectSession(sessionId)
        state.selectRightPane(.diff)
        state.setReviewPaneVisible(true)
        state.setDensity(.compact)
        state.updateWorkspaceWidth(1216)
        state.markRefreshStarted()
        state.markRefreshCompleted()
        state.queueSend(QueuedWorkbenchSend(sessionId: sessionId, text: "follow up"))

        let reloaded = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        XCTAssertEqual(reloaded.selectedSessionId, sessionId)
        XCTAssertEqual(reloaded.selectedRightPane, .diff)
        XCTAssertTrue(reloaded.showingReviewPane)
        XCTAssertEqual(reloaded.density, .compact)
        XCTAssertEqual(reloaded.workspaceWidth, 1216)
        XCTAssertEqual(reloaded.snapshot.queuedSends.map(\.text), ["follow up"])
        XCTAssertEqual(reloaded.snapshot.refresh.generation, 1)
        XCTAssertNotNil(reloaded.snapshot.refresh.completedAt)
    }

    func test_legacySnapshotMissingDensityMigratesToBalanced() throws {
        let sessionId = UUID()
        let raw = """
        {
          "selectedSessionId": "\(sessionId.uuidString)",
          "selectedRightPane": "PR",
          "showingReviewPane": true,
          "workspaceWidth": 1111
        }
        """
        try raw.data(using: .utf8)!.write(to: storeURL)

        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))

        XCTAssertEqual(state.selectedSessionId, sessionId)
        XCTAssertEqual(state.selectedRightPane, .pr)
        XCTAssertEqual(state.density, .balanced)
        XCTAssertTrue(state.showingReviewPane)
        XCTAssertEqual(state.workspaceWidth, 1111)
    }

    func test_unknownDensityAndPaneFallbacksAreLenient() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "snapshot": {
            "selectedRightPane": "FuturePane",
            "density": "microscopic",
            "workspaceWidth": 1400
          }
        }
        """
        try raw.data(using: .utf8)!.write(to: storeURL)

        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))

        XCTAssertEqual(state.selectedRightPane, .plan)
        XCTAssertEqual(state.density, .balanced)
        // v0.30: snapshot decode default matches the init default — see
        // WorkbenchStateSnapshot.init(from:) decodeIfPresent fallback.
        XCTAssertFalse(state.showingReviewPane)
    }

    func test_serviceCachesPersist() {
        let sessionId = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))

        state.recordPRCache(PRCacheStateSnapshot(
            sessionId: sessionId,
            prURL: "https://github.com/example/repo/pull/7",
            state: "OPEN",
            checksConclusion: "success"
        ))
        state.recordCheckpoint(CheckpointStateSnapshot(
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/\(sessionId.uuidString)/turn-1",
            turnId: "turn-1",
            summary: "Before prompt"
        ))

        let reloaded = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        XCTAssertEqual(reloaded.snapshot.prCache[sessionId]?.state, "OPEN")
        XCTAssertEqual(reloaded.snapshot.prCache[sessionId]?.checksConclusion, "success")
        XCTAssertEqual(reloaded.snapshot.checkpoints[sessionId]?.first?.turnId, "turn-1")
    }

    func test_recordCheckpointInvalidatesLifecycleSubscribers() {
        let sessionId = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        let expectation = expectation(description: "lifecycle checkpoint invalidation emitted")
        var cancellable: AnyCancellable?
        cancellable = LifecycleWebSocketChannel.externalInvalidations
            .sink { invalidatedId in
                if invalidatedId == sessionId {
                    expectation.fulfill()
                }
            }

        state.recordCheckpoint(CheckpointStateSnapshot(
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/\(sessionId.uuidString)/turn-1",
            turnId: "turn-1",
            summary: "Before prompt"
        ))

        wait(for: [expectation], timeout: 1)
        cancellable?.cancel()
    }

    func test_rightPaneSelectionIsRememberedPerSession() {
        let sessionA = UUID()
        let sessionB = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))

        state.selectSession(sessionA)
        state.selectRightPane(.browser)
        state.selectSession(sessionB)
        state.selectRightPane(.diff)
        state.selectSession(sessionA)

        XCTAssertEqual(state.selectedRightPane, .browser)
        let reloaded = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        reloaded.selectSession(sessionB)
        XCTAssertEqual(reloaded.selectedRightPane, .diff)
    }

    func test_queueDraftsAreEditableAndScopedBySession() {
        let sessionA = UUID()
        let sessionB = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        let first = QueuedWorkbenchSend(sessionId: sessionA, text: "first")
        let second = QueuedWorkbenchSend(sessionId: sessionA, text: "second")
        let other = QueuedWorkbenchSend(sessionId: sessionB, text: "other")

        state.queueSend(second)
        state.queueSend(other)
        state.queueSend(first)
        state.updateQueuedSend(id: second.id, text: "edited second")
        state.removeQueuedSend(id: first.id)

        XCTAssertEqual(state.queuedSends(for: sessionA).map(\.text), ["edited second"])
        XCTAssertEqual(state.queuedSendCount(for: sessionB), 1)
        state.clearSessionState(sessionId: sessionA)
        XCTAssertTrue(state.queuedSends(for: sessionA).isEmpty)
        XCTAssertEqual(state.queuedSends(for: sessionB).map(\.text), ["other"])
    }

    func test_queuedPromptRendererMirrorsComposerAttachmentSyntax() {
        let body = QueuedPromptRenderer.render(
            text: "  fix this  ",
            attachmentPaths: [URL(fileURLWithPath: "/tmp/a.png")]
        )

        XCTAssertEqual(body, "@/tmp/a.png\nfix this\n")
    }

    func test_checkpointServiceCreatesRefAndRestoresCleanWorktree() async throws {
        guard let git = ShellRunner.locateBinary("git") else {
            throw XCTSkip("git is required for CheckpointService tests")
        }
        let repo = tmpDir.appendingPathComponent("checkpoint-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await runGit(git, repo, ["init"])
        try await runGit(git, repo, ["config", "user.email", "tests@clawdmeter.local"])
        try await runGit(git, repo, ["config", "user.name", "Clawdmeter Tests"])
        let tracked = repo.appendingPathComponent("tracked.txt")
        try "one\n".write(to: tracked, atomically: true, encoding: .utf8)
        try await runGit(git, repo, ["add", "tracked.txt"])
        try await runGit(git, repo, ["commit", "-m", "one"])

        let sessionId = UUID()
        let session = AgentSession(
            id: sessionId,
            repoKey: repo.path,
            repoDisplayName: "checkpoint-repo",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .done,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1
        )
        let service = CheckpointService(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let checkpoint = try await service.createCheckpoint(session: session, summary: "Before edit")
        let sameSecondCheckpoint = try await service.createCheckpoint(session: session, summary: "Same second")

        XCTAssertNotEqual(checkpoint.refName, sameSecondCheckpoint.refName)

        try "two\n".write(to: tracked, atomically: true, encoding: .utf8)
        try await runGit(git, repo, ["add", "tracked.txt"])
        try await runGit(git, repo, ["commit", "-m", "two"])
        try await service.restore(checkpoint, in: repo.path)

        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "one\n")
        XCTAssertTrue(checkpoint.refName.hasPrefix("refs/clawdmeter/checkpoints/\(sessionId.uuidString)/1700000000000000000-"))
    }

    func test_checkpointPrepareRestoreCreatesSafetyPreviewAndRestoresUntrackedSidecar() async throws {
        guard let git = ShellRunner.locateBinary("git") else {
            throw XCTSkip("git is required for CheckpointService tests")
        }
        let repo = tmpDir.appendingPathComponent("checkpoint-plan-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await runGit(git, repo, ["init"])
        try await runGit(git, repo, ["config", "user.email", "tests@clawdmeter.local"])
        try await runGit(git, repo, ["config", "user.name", "Clawdmeter Tests"])
        let tracked = repo.appendingPathComponent("tracked.txt")
        try "one\n".write(to: tracked, atomically: true, encoding: .utf8)
        try await runGit(git, repo, ["add", "tracked.txt"])
        try await runGit(git, repo, ["commit", "-m", "one"])
        let scratch = repo.appendingPathComponent("scratch.txt")
        try "sidecar\n".write(to: scratch, atomically: true, encoding: .utf8)

        let sessionId = UUID()
        let session = makeSession(id: sessionId, repo: repo)
        var tick = 1_700_000_100.0
        let service = CheckpointService(now: {
            defer { tick += 1 }
            return Date(timeIntervalSince1970: tick)
        })
        let checkpoint = try await service.createCheckpoint(session: session, summary: "Before edit")

        try FileManager.default.removeItem(at: scratch)
        try "two\n".write(to: tracked, atomically: true, encoding: .utf8)
        try await runGit(git, repo, ["add", "tracked.txt"])
        try await runGit(git, repo, ["commit", "-m", "two"])

        let plan = try await service.prepareRestore(checkpoint, session: session)

        XCTAssertFalse(plan.isBlocked)
        XCTAssertTrue(plan.safety.refName.contains("/safety-"))
        XCTAssertTrue(plan.diffStat.contains("tracked.txt"))
        XCTAssertTrue(plan.diffPatch.contains("-two"))
        XCTAssertTrue(plan.diffPatch.contains("+one"))
        XCTAssertEqual(plan.untrackedSnapshotPaths, ["scratch.txt"])

        try await service.restore(plan, in: repo.path)

        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "one\n")
        XCTAssertEqual(try String(contentsOf: scratch, encoding: .utf8), "sidecar\n")
    }

    func test_checkpointCapturesDirtyTrackedWorktreeState() async throws {
        guard let git = ShellRunner.locateBinary("git") else {
            throw XCTSkip("git is required for CheckpointService tests")
        }
        let repo = tmpDir.appendingPathComponent("checkpoint-dirty-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await runGit(git, repo, ["init"])
        try await runGit(git, repo, ["config", "user.email", "tests@clawdmeter.local"])
        try await runGit(git, repo, ["config", "user.name", "Clawdmeter Tests"])
        let tracked = repo.appendingPathComponent("tracked.txt")
        try "one\n".write(to: tracked, atomically: true, encoding: .utf8)
        try await runGit(git, repo, ["add", "tracked.txt"])
        try await runGit(git, repo, ["commit", "-m", "one"])

        let session = makeSession(id: UUID(), repo: repo)
        let service = CheckpointService(now: { Date(timeIntervalSince1970: 1_700_000_300) })
        try "dirty checkpoint\n".write(to: tracked, atomically: true, encoding: .utf8)
        let checkpoint = try await service.createCheckpoint(session: session, summary: "Dirty state")

        try "two\n".write(to: tracked, atomically: true, encoding: .utf8)
        try await runGit(git, repo, ["add", "tracked.txt"])
        try await runGit(git, repo, ["commit", "-m", "two"])

        let plan = try await service.prepareRestore(checkpoint, session: session)
        XCTAssertFalse(plan.isBlocked)
        XCTAssertTrue(plan.diffPatch.contains("+dirty checkpoint"))

        try await service.restore(plan, in: repo.path)
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "dirty checkpoint\n")
    }

    func test_checkpointPrepareRestoreBlocksUntrackedOverwriteRisk() async throws {
        guard let git = ShellRunner.locateBinary("git") else {
            throw XCTSkip("git is required for CheckpointService tests")
        }
        let repo = tmpDir.appendingPathComponent("checkpoint-conflict-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await runGit(git, repo, ["init"])
        try await runGit(git, repo, ["config", "user.email", "tests@clawdmeter.local"])
        try await runGit(git, repo, ["config", "user.name", "Clawdmeter Tests"])
        let tracked = repo.appendingPathComponent("conflict.txt")
        try "tracked\n".write(to: tracked, atomically: true, encoding: .utf8)
        try await runGit(git, repo, ["add", "conflict.txt"])
        try await runGit(git, repo, ["commit", "-m", "tracked"])

        let session = makeSession(id: UUID(), repo: repo)
        let service = CheckpointService(now: { Date(timeIntervalSince1970: 1_700_000_200) })
        let checkpoint = try await service.createCheckpoint(session: session, summary: "Has conflict file")

        try await runGit(git, repo, ["rm", "conflict.txt"])
        try await runGit(git, repo, ["commit", "-m", "remove tracked"])
        try "untracked\n".write(to: tracked, atomically: true, encoding: .utf8)

        let plan = try await service.prepareRestore(checkpoint, session: session)

        XCTAssertTrue(plan.isBlocked)
        XCTAssertEqual(plan.untrackedOverwritePaths, ["conflict.txt"])
        XCTAssertTrue(plan.blockingReasons.contains { $0.contains("Untracked files would be overwritten") })
    }

    @discardableResult
    private func runGit(_ git: String, _ repo: URL, _ arguments: [String]) async throws -> ShellRunner.Result {
        try await ShellRunner.shared.runOrThrow(
            executable: git,
            arguments: arguments,
            cwd: repo.path,
            environment: nil,
            timeout: 20
        )
    }

    private func makeSession(id: UUID, repo: URL) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: repo.path,
            repoDisplayName: repo.lastPathComponent,
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .done,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1
        )
    }
}
