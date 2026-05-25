import XCTest
import Combine
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class SessionLifecycleReducerTests: XCTestCase {
    func test_phaseMatrixCoversLifecycleSpine() {
        let sessionId = UUID()
        let scenarios: [(String, SessionLifecycleSnapshot, SessionLifecyclePhase)] = [
            (
                "draft",
                snapshot(session: session(id: sessionId), flags: .init(isDraft: true)),
                .draft
            ),
            (
                "provider preflight",
                snapshot(
                    session: session(id: sessionId),
                    preflightBlockers: [LifecycleBlocker(kind: .providerAuth, summary: "Claude auth missing")]
                ),
                .preflightBlocked
            ),
            (
                "repo preflight",
                snapshot(
                    session: session(id: sessionId),
                    preflightBlockers: [LifecycleBlocker(kind: .repoState, summary: "dirty base")]
                ),
                .preflightBlocked
            ),
            (
                "tmux-backed spawning",
                snapshot(session: session(id: sessionId, status: .running, tmuxWindowId: nil, tmuxPaneId: nil)),
                .spawning
            ),
            (
                "codex sdk chat running without tmux",
                snapshot(
                    session: session(
                        id: sessionId,
                        agent: .codex,
                        tmuxWindowId: nil,
                        tmuxPaneId: nil,
                        kind: .chat,
                        codexChatBackend: .sdk
                    )
                ),
                .running
            ),
            (
                "gemini agentapi running without tmux",
                snapshot(
                    session: session(
                        id: sessionId,
                        agent: .gemini,
                        tmuxWindowId: nil,
                        tmuxPaneId: nil,
                        geminiBackend: .agentapi
                    )
                ),
                .running
            ),
            (
                "opencode running without tmux",
                snapshot(
                    session: session(
                        id: sessionId,
                        agent: .opencode,
                        tmuxWindowId: nil,
                        tmuxPaneId: nil
                    )
                ),
                .running
            ),
            (
                "explicit spawning",
                snapshot(session: session(id: sessionId), flags: .init(isSpawning: true)),
                .spawning
            ),
            (
                "researching",
                snapshot(session: session(id: sessionId), flags: .init(isResearching: true)),
                .researching
            ),
            (
                "planning",
                snapshot(session: session(id: sessionId, status: .planning)),
                .planning
            ),
            (
                "awaiting approval",
                snapshot(session: session(id: sessionId, status: .planning, planText: "1. Build it")),
                .awaitingApproval
            ),
            (
                "approved plan stays planning",
                snapshot(
                    session: session(
                        id: sessionId,
                        status: .planning,
                        planText: "1. Build it",
                        approvedPlanText: "1. Build it"
                    )
                ),
                .planning
            ),
            (
                "running",
                snapshot(session: session(id: sessionId)),
                .running
            ),
            (
                "paused",
                snapshot(session: session(id: sessionId, status: .paused)),
                .needsInput
            ),
            (
                "degraded",
                snapshot(session: session(id: sessionId, status: .degraded)),
                .needsInput
            ),
            (
                "done review",
                snapshot(session: session(id: sessionId, status: .done)),
                .reviewing
            ),
            (
                "validation running",
                snapshot(
                    session: session(id: sessionId),
                    validationStatus: SessionLifecycleValidationStatus(state: .running)
                ),
                .validating
            ),
            (
                "validation failed",
                snapshot(
                    session: session(id: sessionId),
                    validationStatus: SessionLifecycleValidationStatus(state: .failed, summary: "swift test failed")
                ),
                .checksBlocked
            ),
            (
                "pr drafting",
                snapshot(session: session(id: sessionId), flags: .init(isPrDrafting: true)),
                .prDrafting
            ),
            (
                "pending checks",
                snapshot(session: session(id: sessionId, prMirrorState: pr(checksRollup: .pending))),
                .checksBlocked
            ),
            (
                "failing checks",
                snapshot(session: session(id: sessionId, prMirrorState: pr(checksRollup: .failure))),
                .checksBlocked
            ),
            (
                "changes requested",
                snapshot(session: session(id: sessionId, prMirrorState: pr(reviewState: .changesRequested))),
                .checksBlocked
            ),
            (
                "merge conflict",
                snapshot(session: session(id: sessionId, prMirrorState: pr(mergeability: .dirty))),
                .checksBlocked
            ),
            (
                "draft pr",
                snapshot(session: session(id: sessionId, prMirrorState: pr(state: .draft))),
                .prOpen
            ),
            (
                "open pr unknown gates",
                snapshot(session: session(id: sessionId, prMirrorState: pr())),
                .prOpen
            ),
            (
                "ready to merge",
                snapshot(
                    session: session(
                        id: sessionId,
                        prMirrorState: pr(
                            checksRollup: .success,
                            reviewState: .approved,
                            mergeability: .mergeable
                        )
                    )
                ),
                .readyToMerge
            ),
            (
                "merged state",
                snapshot(session: session(id: sessionId, prMirrorState: pr(state: .merged))),
                .merged
            ),
            (
                "merged result",
                snapshot(
                    session: session(
                        id: sessionId,
                        prMirrorState: pr(lastMergeResult: PRMergeResult(merged: true))
                    )
                ),
                .merged
            ),
            (
                "archived wins",
                snapshot(
                    session: session(
                        id: sessionId,
                        archivedAt: Date(timeIntervalSince1970: 1_777_200_000),
                        prMirrorState: pr(state: .merged)
                    )
                ),
                .archived
            ),
        ]

        XCTAssertGreaterThanOrEqual(scenarios.count, 24)
        XCTAssertEqual(Set(SessionLifecyclePhase.allCases).subtracting(scenarios.map(\.2)), [])
        for (name, snapshot, expected) in scenarios {
            XCTAssertEqual(snapshot.phase, expected, name)
        }
    }

    func test_snapshotIncludesPlanCheckpointPREvidenceAndActions() {
        let sessionId = UUID()
        let checkpoint = CodeCheckpointSnapshot(
            id: UUID(),
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/demo",
            createdAt: Date(timeIntervalSince1970: 1_777_200_000),
            summary: "Before CI fix"
        )
        let lifecycle = snapshot(
            session: session(
                id: sessionId,
                status: .planning,
                planText: "Plan text",
                prMirrorState: pr(checksRollup: .failure)
            ),
            checkpoints: [checkpoint]
        )

        XCTAssertEqual(lifecycle.phase, .checksBlocked)
        XCTAssertEqual(lifecycle.goal?.text, "Ship lifecycle")
        XCTAssertEqual(lifecycle.nextAction?.kind, .inspectChecks)
        XCTAssertTrue(lifecycle.blockers.contains { $0.kind == .ciFailing })
        XCTAssertTrue(lifecycle.evidence.contains { $0.kind == .plan && $0.payload.text == "Plan text" })
        XCTAssertTrue(lifecycle.evidence.contains { $0.kind == .checkpoint && $0.id == checkpoint.id })
        XCTAssertTrue(lifecycle.evidence.contains { $0.kind == .pr })
        XCTAssertEqual(lifecycle.checkpointStatus?.latest?.id, checkpoint.id)
        XCTAssertEqual(lifecycle.branchInfo.branchName, "feature/lifecycle")
        XCTAssertEqual(lifecycle.prInfo?.checksRollup, .failure)
    }

    func test_providerCapabilitiesReflectRuntimeReality() {
        let claude = SessionLifecycleReducer.providerCapabilities(for: .claude)
        let cursor = SessionLifecycleReducer.providerCapabilities(for: .cursor)
        let unknown = SessionLifecycleReducer.providerCapabilities(for: .unknown)

        XCTAssertTrue(claude.supportsPlanApproval)
        XCTAssertTrue(claude.supportsProviderHandoff)
        XCTAssertFalse(cursor.supportsPlanApproval)
        XCTAssertFalse(cursor.supportsTranscriptImport)
        XCTAssertFalse(unknown.supportsInterrupt)
    }

    func test_lifecycleWebSocketDedupeIdentityIncludesCheckpointState() {
        let sessionId = UUID()
        let base = snapshot(session: session(id: sessionId))
        let checkpoint = CodeCheckpointSnapshot(
            id: UUID(),
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/demo",
            createdAt: Date(timeIntervalSince1970: 1_777_200_000),
            summary: "Checkpoint"
        )
        let withCheckpoint = snapshot(
            session: session(id: sessionId),
            checkpoints: [checkpoint]
        )

        XCTAssertNotEqual(
            LifecycleWebSocketChannel.dedupeIdentity(for: base),
            LifecycleWebSocketChannel.dedupeIdentity(for: withCheckpoint)
        )
    }

    func test_lifecycleWebSocketDedupeIdentityIncludesPlanEvidenceText() {
        let sessionId = UUID()
        let base = snapshot(session: session(id: sessionId, status: .planning, planText: "1. Inspect route"))
        let changedPlan = snapshot(session: session(id: sessionId, status: .planning, planText: "1. Inspect route\n2. Fix stream"))

        XCTAssertEqual(base.seq, changedPlan.seq)
        XCTAssertEqual(base.phase, changedPlan.phase)
        XCTAssertNotEqual(
            LifecycleWebSocketChannel.dedupeIdentity(for: base),
            LifecycleWebSocketChannel.dedupeIdentity(for: changedPlan)
        )
    }

    func test_registryPlanMutationsAdvanceLifecycleSequence() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdmeter-lifecycle-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let registry = AgentSessionRegistry(storeURL: dir.appendingPathComponent("sessions.json"))
        let session = registry.create(
            repoKey: "/tmp/clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: .claude,
            model: "sonnet",
            goal: "Ship lifecycle",
            worktreePath: "/tmp/clawdmeter",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            planMode: true,
            mode: .worktree
        )

        registry.setPlanText(id: session.id, planText: "1. Inspect route")
        let afterPlan = try XCTUnwrap(registry.session(id: session.id))
        XCTAssertEqual(afterPlan.lastEventSeq, session.lastEventSeq + 1)

        registry.markPlanApproved(id: session.id)
        let afterApproval = try XCTUnwrap(registry.session(id: session.id))
        XCTAssertNil(afterApproval.planText)
        XCTAssertEqual(afterApproval.approvedPlanText, "1. Inspect route")
        XCTAssertEqual(afterApproval.lastEventSeq, afterPlan.lastEventSeq + 1)
    }

    func test_checkpointInvalidationNotifiesLifecycleSubscribers() {
        let sessionId = UUID()
        let expectation = expectation(description: "checkpoint invalidation emitted")
        var cancellable: AnyCancellable?
        cancellable = LifecycleWebSocketChannel.externalInvalidations
            .sink { invalidatedId in
                if invalidatedId == sessionId {
                    expectation.fulfill()
                }
            }

        LifecycleWebSocketChannel.notifyCheckpointStateChanged(sessionId: sessionId)

        wait(for: [expectation], timeout: 1)
        cancellable?.cancel()
    }

    private func snapshot(
        session: AgentSession,
        checkpoints: [CodeCheckpointSnapshot] = [],
        validationStatus: SessionLifecycleValidationStatus? = nil,
        preflightBlockers: [LifecycleBlocker] = [],
        flags: SessionLifecycleReducerFlags = SessionLifecycleReducerFlags()
    ) -> SessionLifecycleSnapshot {
        SessionLifecycleReducer.snapshot(
            for: session,
            checkpoints: checkpoints,
            validationStatus: validationStatus,
            preflightBlockers: preflightBlockers,
            flags: flags,
            now: Date(timeIntervalSince1970: 1_777_200_120)
        )
    }

    private func session(
        id: UUID,
        agent: AgentKind = .claude,
        status: AgentSessionStatus = .running,
        planText: String? = nil,
        approvedPlanText: String? = nil,
        tmuxWindowId: String? = "@1",
        tmuxPaneId: String? = "%1",
        archivedAt: Date? = nil,
        prMirrorState: PRMirrorState? = nil,
        kind: SessionKind = .code,
        codexChatBackend: CodexChatBackend? = nil,
        geminiBackend: GeminiBackend? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: "/Users/example/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: agent,
            model: "sonnet",
            goal: "Ship lifecycle",
            worktreePath: "/Users/example/Clawdmeter/.claude/worktrees/lifecycle",
            tmuxWindowId: tmuxWindowId,
            tmuxPaneId: tmuxPaneId,
            status: status,
            planText: planText,
            approvedPlanText: approvedPlanText,
            createdAt: Date(timeIntervalSince1970: 1_777_199_000),
            lastEventAt: Date(timeIntervalSince1970: 1_777_200_000),
            lastEventSeq: 12,
            mode: .worktree,
            archivedAt: archivedAt,
            runtimeCwd: "/Users/example/Clawdmeter/.claude/worktrees/lifecycle",
            prMirrorState: prMirrorState,
            kind: kind,
            codexChatBackend: codexChatBackend,
            geminiBackend: geminiBackend
        )
    }

    private func pr(
        branchName: String? = "feature/lifecycle",
        state: PRStatus.State = .open,
        checksRollup: PRCheckState = .unknown,
        reviewState: PRReviewState = .unknown,
        mergeability: PRMergeability = .unknown,
        lastMergeResult: PRMergeResult? = nil
    ) -> PRMirrorState {
        PRMirrorState(
            branchName: branchName,
            prURL: "https://github.com/example/repo/pull/12",
            number: 12,
            title: "Lifecycle",
            state: state,
            checks: [
                PRCheckMirror(name: "build", state: checksRollup),
            ],
            checksRollup: checksRollup,
            reviewState: reviewState,
            mergeability: mergeability,
            protectedBranchGate: true,
            lastMergeResult: lastMergeResult,
            lastCheckedAt: Date(timeIntervalSince1970: 1_777_200_060)
        )
    }
}
