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

    func test_defaultSnapshotUsesPlanPane() {
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))

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
        state.updateWorkspaceWidth(1216)
        state.setSidebarWidth(300)
        state.setReviewWidth(420)
        state.markRefreshStarted()
        state.markRefreshCompleted()
        state.queueSend(QueuedWorkbenchSend(sessionId: sessionId, text: "follow up"))

        let reloaded = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        XCTAssertEqual(reloaded.selectedSessionId, sessionId)
        XCTAssertEqual(reloaded.selectedRightPane, .diff)
        XCTAssertTrue(reloaded.showingReviewPane)
        XCTAssertEqual(reloaded.workspaceWidth, 1216)
        XCTAssertEqual(reloaded.sidebarWidth, 300)
        XCTAssertEqual(reloaded.storedReviewWidth, 420)
        XCTAssertEqual(reloaded.snapshot.queuedSends.map(\.text), ["follow up"])
        XCTAssertEqual(reloaded.snapshot.refresh.generation, 1)
        XCTAssertNotNil(reloaded.snapshot.refresh.completedAt)
    }

    func test_paneWidthsClampAgainstWorkspaceMinimums() {
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        state.updateWorkspaceWidth(1000)

        state.setSidebarWidth(999)
        XCTAssertEqual(state.sidebarWidth, 276)

        state.setSidebarWidth(120)
        XCTAssertEqual(state.sidebarWidth, WorkbenchState.minSidebarWidth)

        state.setReviewWidth(999)
        XCTAssertLessThanOrEqual(state.storedReviewWidth ?? 0, WorkbenchState.maxReviewWidth)

        state.setReviewWidth(100)
        XCTAssertEqual(state.storedReviewWidth, WorkbenchState.minReviewWidth)
    }

    func test_legacySnapshotMissingFieldsMigratesToDefaults() throws {
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
        XCTAssertEqual(state.selectedRightPane, .plan)
        XCTAssertTrue(state.showingReviewPane)
        XCTAssertEqual(state.workspaceWidth, 1111)
    }

    func test_unknownPaneFallbackIsLenient() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "snapshot": {
            "selectedRightPane": "FuturePane",
            "workspaceWidth": 1400
          }
        }
        """
        try raw.data(using: .utf8)!.write(to: storeURL)

        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))

        XCTAssertEqual(state.selectedRightPane, .plan)
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

    func test_latestCheckpointIgnoresSafetyRestoreSnapshots() {
        let sessionId = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        let manual = CheckpointStateSnapshot(
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/\(sessionId.uuidString)/manual",
            turnId: "turn-1",
            createdAt: Date(timeIntervalSince1970: 100),
            summary: "Manual checkpoint"
        )
        let safety = CheckpointStateSnapshot(
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/\(sessionId.uuidString)/safety-101",
            turnId: "safety-101",
            createdAt: Date(timeIntervalSince1970: 101),
            summary: "Safety before restoring \(manual.refName)"
        )

        state.recordCheckpoint(manual)
        state.recordCheckpoint(safety)

        XCTAssertEqual(state.checkpoints(for: sessionId).map(\.id), [safety.id, manual.id])
        XCTAssertEqual(state.latestCheckpoint(for: sessionId)?.id, manual.id)
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

    func test_browserPaneStateSwitchingStaysUnder250msBudget() {
        let sessionA = UUID()
        let sessionB = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        let iterations = 50
        let started = CFAbsoluteTimeGetCurrent()

        for index in 0..<iterations {
            let sessionId = index.isMultiple(of: 2) ? sessionA : sessionB
            state.selectSession(sessionId)
            state.selectRightPane(.browser)
            state.enterImmersiveBrowser(sessionId: sessionId)
            state.exitImmersiveBrowser()
            state.selectRightPane(.plan)
        }

        let average = (CFAbsoluteTimeGetCurrent() - started) / Double(iterations)
        XCTAssertLessThan(average, 0.25)
    }

    func test_codeWorkbenchLocalControlsSurfaceVisibleFeedbackWithin100ms() {
        let sessionA = UUID()
        let sessionB = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        state.selectSession(sessionA)

        assertCodeTabFeedbackLatency(
            name: "right-pane tab selection",
            cases: WorkbenchPaneTab.allCases,
            iterations: 12
        ) { tab in
            state.selectRightPane(tab)
        } verify: { tab in
            let normalized = WorkbenchPaneTab.normalizedReviewPaneTab(tab)
            XCTAssertEqual(state.selectedRightPane, normalized)
            XCTAssertEqual(state.snapshot.selectedRightPaneBySession[sessionA], normalized)
            if normalized != .browser {
                XCTAssertNil(state.immersiveBrowserSessionId)
            }
        }

        assertCodeTabFeedbackLatency(
            name: "review-pane visibility toggle",
            cases: [true, false],
            iterations: 50
        ) { visible in
            state.setReviewPaneVisible(visible)
        } verify: { visible in
            XCTAssertEqual(state.showingReviewPane, visible)
        }

        assertCodeTabFeedbackLatency(
            name: "preview chip browser routing",
            cases: [false, true],
            iterations: 25
        ) { forceRestart in
            state.requestPreview(sessionId: sessionB, forceRestart: forceRestart)
        } verify: { forceRestart in
            XCTAssertEqual(state.selectedSessionId, sessionB)
            XCTAssertEqual(state.selectedRightPane, .browser)
            XCTAssertEqual(state.immersiveBrowserSessionId, sessionB)
            XCTAssertFalse(state.showingReviewPane)
            XCTAssertEqual(state.previewIntent?.sessionId, sessionB)
            XCTAssertEqual(state.previewIntent?.forceRestart, forceRestart)
        }

        let queuedDrafts = (0..<40).map { index in
            QueuedWorkbenchSend(
                sessionId: sessionA,
                text: "follow-up \(index)",
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        assertCodeTabFeedbackLatency(
            name: "queued follow-up row insertion",
            cases: queuedDrafts
        ) { draft in
            state.queueSend(draft)
        } verify: { draft in
            XCTAssertTrue(state.queuedSends(for: sessionA).contains { $0.id == draft.id })
        }

        assertCodeTabFeedbackLatency(
            name: "queued follow-up row edit",
            cases: queuedDrafts
        ) { draft in
            state.updateQueuedSend(id: draft.id, text: "edited \(draft.id.uuidString.prefix(6))")
        } verify: { draft in
            XCTAssertTrue(state.queuedSends(for: sessionA).contains {
                $0.id == draft.id && $0.text.hasPrefix("edited ")
            })
        }

        assertCodeTabFeedbackLatency(
            name: "queued follow-up row removal",
            cases: queuedDrafts
        ) { draft in
            state.removeQueuedSend(id: draft.id)
        } verify: { draft in
            XCTAssertFalse(state.queuedSends(for: sessionA).contains { $0.id == draft.id })
        }
    }

    func test_diffToolbarDescriptorExposesStableTargetsAndEnabledState() {
        let empty = TahoeDiffPreviewPane.toolbarDescriptor(fileCount: 0, unviewedCount: 0)
        XCTAssertEqual(empty.fileCountText, "0 files")
        XCTAssertEqual(empty.unviewedCountText, "0 unviewed")
        XCTAssertFalse(empty.nextEnabled)
        XCTAssertFalse(empty.markAllEnabled)

        let populated = TahoeDiffPreviewPane.toolbarDescriptor(fileCount: 3, unviewedCount: 2)
        XCTAssertEqual(populated.fileCountText, "3 files")
        XCTAssertEqual(populated.unviewedCountText, "2 unviewed")
        XCTAssertTrue(populated.nextEnabled)
        XCTAssertTrue(populated.markAllEnabled)

        XCTAssertEqual(TahoeDiffPreviewPane.ToolbarDescriptor.accessibilityIdentifier, "code.diff.toolbar")
        XCTAssertEqual(TahoeDiffPreviewPane.ToolbarDescriptor.fileCountAccessibilityIdentifier, "code.diff.files-count")
        XCTAssertEqual(TahoeDiffPreviewPane.ToolbarDescriptor.unviewedCountAccessibilityIdentifier, "code.diff.unviewed-count")
        XCTAssertEqual(TahoeDiffPreviewPane.ToolbarDescriptor.layoutAccessibilityIdentifier, "code.diff.layout")
        XCTAssertEqual(TahoeDiffPreviewPane.ToolbarDescriptor.nextAccessibilityIdentifier, "code.diff.next-unviewed")
        XCTAssertEqual(TahoeDiffPreviewPane.ToolbarDescriptor.markAllAccessibilityIdentifier, "code.diff.mark-all-viewed")
    }

    func test_diffRowActionDescriptorsExposeStableTargets() {
        let unviewedFile = TahoeDiffPreviewPane.fileActionDescriptors(viewed: false)
        XCTAssertEqual(TahoeDiffPreviewPane.FileActionDescriptors.rowAccessibilityIdentifier, "code.diff.file.row")
        XCTAssertEqual(unviewedFile.reviewed.title, "Mark reviewed")
        XCTAssertEqual(unviewedFile.reviewed.accessibilityIdentifier, "code.diff.file.mark-reviewed")
        XCTAssertTrue(unviewedFile.reviewed.isEnabled)
        XCTAssertEqual(unviewedFile.flagChanges.title, "Flag changes")
        XCTAssertEqual(unviewedFile.flagChanges.accessibilityIdentifier, "code.diff.file.flag-changes")
        XCTAssertEqual(unviewedFile.markViewed.title, "Mark viewed")
        XCTAssertEqual(unviewedFile.markViewed.accessibilityIdentifier, "code.diff.file.mark-viewed")
        XCTAssertTrue(unviewedFile.markViewed.isEnabled)
        XCTAssertEqual(unviewedFile.open.title, "Open")
        XCTAssertEqual(unviewedFile.open.accessibilityIdentifier, "code.diff.file.open")

        let viewedFile = TahoeDiffPreviewPane.fileActionDescriptors(viewed: true)
        XCTAssertEqual(viewedFile.markViewed.title, "Viewed")
        XCTAssertFalse(viewedFile.markViewed.isEnabled)

        let expandedHunk = TahoeDiffPreviewPane.hunkActionDescriptors(collapsed: false)
        XCTAssertEqual(TahoeDiffPreviewPane.HunkActionDescriptors.rowAccessibilityIdentifier, "code.diff.hunk.row")
        XCTAssertEqual(expandedHunk.toggle.title, "Collapse hunk")
        XCTAssertEqual(expandedHunk.toggle.accessibilityIdentifier, "code.diff.hunk.toggle-collapse")
        XCTAssertEqual(expandedHunk.toggle.systemImage, "chevron.down")
        XCTAssertEqual(expandedHunk.explain.title, "Explain")
        XCTAssertEqual(expandedHunk.explain.accessibilityIdentifier, "code.diff.hunk.explain")

        let collapsedHunk = TahoeDiffPreviewPane.hunkActionDescriptors(collapsed: true)
        XCTAssertEqual(collapsedHunk.toggle.title, "Expand hunk")
        XCTAssertEqual(collapsedHunk.toggle.systemImage, "chevron.right")
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

    func test_queuedDraftPayloadRoundTripsBrowserComments() {
        let sessionId = UUID()
        let state = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        let comment = BrowserCommentContext(
            urlString: "http://localhost:5173",
            selector: "#save",
            snippet: "Save",
            comment: "button missing contrast"
        )

        state.queueSend(QueuedWorkbenchSend(
            sessionId: sessionId,
            payload: ComposerDraftPayload(
                text: "fix preview",
                attachmentPaths: ["/tmp/screenshot.png"],
                browserComments: [comment]
            )
        ))

        let reloaded = WorkbenchState(store: WorkbenchStateStore(storeURL: storeURL))
        guard let draft = reloaded.nextQueuedSend(for: sessionId) else {
            return XCTFail("Expected queued draft after reload")
        }
        XCTAssertEqual(draft.payload.text, "fix preview")
        XCTAssertEqual(draft.payload.attachmentPaths, ["/tmp/screenshot.png"])
        XCTAssertEqual(draft.payload.browserComments.first?.chipLabel, "Comment: button missing contrast")
        XCTAssertTrue(QueuedPromptRenderer.render(payload: draft.payload, attachmentPaths: [])
            .contains("[BROWSER COMMENT]"))
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
        let ticker = TestDateTicker(startingAt: 1_700_000_100.0)
        let service = CheckpointService(now: { ticker.next() })
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

    func test_checkpointRestoreRevalidatesUntrackedOverwriteRiskAfterPreview() async throws {
        guard let git = ShellRunner.locateBinary("git") else {
            throw XCTSkip("git is required for CheckpointService tests")
        }
        let repo = tmpDir.appendingPathComponent("checkpoint-race-conflict-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await runGit(git, repo, ["init"])
        try await runGit(git, repo, ["config", "user.email", "tests@clawdmeter.local"])
        try await runGit(git, repo, ["config", "user.name", "Clawdmeter Tests"])
        let conflict = repo.appendingPathComponent("conflict.txt")
        try "checkpoint tracked\n".write(to: conflict, atomically: true, encoding: .utf8)
        try await runGit(git, repo, ["add", "conflict.txt"])
        try await runGit(git, repo, ["commit", "-m", "tracked conflict"])

        let session = makeSession(id: UUID(), repo: repo)
        let service = CheckpointService(now: { Date(timeIntervalSince1970: 1_700_000_250) })
        let checkpoint = try await service.createCheckpoint(session: session, summary: "Has conflict file")

        try await runGit(git, repo, ["rm", "conflict.txt"])
        try await runGit(git, repo, ["commit", "-m", "remove conflict"])

        let plan = try await service.prepareRestore(checkpoint, session: session)
        XCTAssertFalse(plan.isBlocked)
        XCTAssertEqual(plan.untrackedOverwritePaths, [])

        try "untracked after preview\n".write(to: conflict, atomically: true, encoding: .utf8)

        do {
            try await service.restore(plan, in: repo.path)
            XCTFail("Restore should revalidate and block when an untracked file appears after preview.")
        } catch let error as CheckpointService.Error {
            guard case .restoreBlocked(let reasons) = error else {
                XCTFail("Expected restoreBlocked, got \(error)")
                return
            }
            XCTAssertTrue(reasons.contains { $0.contains("Untracked files would be overwritten") })
            XCTAssertTrue(reasons.contains { $0.contains("conflict.txt") })
        }

        XCTAssertEqual(try String(contentsOf: conflict, encoding: .utf8), "untracked after preview\n")
        let status = try await runGit(git, repo, ["status", "--porcelain"])
        XCTAssertTrue(status.stdoutString.split(whereSeparator: \.isNewline).contains { $0 == "?? conflict.txt" })
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

    private func assertCodeTabFeedbackLatency<Case>(
        name: String,
        cases: [Case],
        iterations: Int = 1,
        budget: Duration = .milliseconds(100),
        action: (Case) -> Void,
        verify: (Case) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var worst = Duration.zero
        var samples = 0

        for _ in 0..<iterations {
            for testCase in cases {
                let start = ContinuousClock.now
                action(testCase)
                verify(testCase)
                let elapsed = start.duration(to: ContinuousClock.now)
                worst = max(worst, elapsed)
                samples += 1
            }
        }

        XCTContext.runActivity(named: "Code tab \(name) feedback latency") { activity in
            activity.add(XCTAttachment(string: """
            samples=\(samples)
            worst=\(worst)
            budget=\(budget) per visible local-state interaction
            """))
        }
        XCTAssertLessThan(
            worst,
            budget,
            "Code tab \(name) must update visible local state within \(budget) before async work starts.",
            file: file,
            line: line
        )
    }
}

private final class TestDateTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(startingAt value: TimeInterval) {
        self.value = value
    }

    func next() -> Date {
        lock.lock()
        defer {
            value += 1
            lock.unlock()
        }
        return Date(timeIntervalSince1970: value)
    }
}
