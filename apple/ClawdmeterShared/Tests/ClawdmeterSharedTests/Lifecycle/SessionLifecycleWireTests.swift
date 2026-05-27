import XCTest
@testable import ClawdmeterShared

final class SessionLifecycleWireTests: XCTestCase {
    func test_wireV19LifecycleGate() {
        XCTAssertEqual(AgentControlWireVersion.current, 20)
        XCTAssertEqual(AgentControlWireVersion.lifecycleMinimum, 19)
        XCTAssertFalse(AgentControlWireVersion.supportsLifecycle(serverWireVersion: nil))
        XCTAssertFalse(AgentControlWireVersion.supportsLifecycle(serverWireVersion: 18))
        XCTAssertTrue(AgentControlWireVersion.supportsLifecycle(serverWireVersion: 19))
    }

    func test_snapshotRoundTripsWithEvidenceBlockersAndCapabilities() throws {
        let sessionId = UUID()
        let checkpoint = CodeCheckpointSnapshot(
            id: UUID(),
            sessionId: sessionId,
            refName: "refs/clawdmeter/checkpoints/demo",
            turnId: "turn-7",
            createdAt: Date(timeIntervalSince1970: 1_777_100_000),
            summary: "Before merge"
        )
        let snapshot = SessionLifecycleSnapshot(
            sessionId: sessionId,
            phase: .checksBlocked,
            goal: SessionGoalSnapshot(text: "Ship lifecycle spine", createdAt: Date(timeIntervalSince1970: 1_777_099_000)),
            blockers: [
                LifecycleBlocker(
                    kind: .ciFailing,
                    summary: "build failed",
                    resolution: "Open failed check",
                    canOverride: false
                ),
            ],
            evidence: [
                LifecycleEvidence(
                    id: UUID(),
                    kind: .checkpoint,
                    title: "Before merge",
                    createdAt: checkpoint.createdAt,
                    payload: LifecycleEvidencePayload(refId: checkpoint.refName)
                ),
            ],
            nextAction: SessionLifecycleNextAction(kind: .inspectChecks, title: "Inspect blockers"),
            branchInfo: SessionLifecycleBranchInfo(
                repoKey: "/repo",
                repoDisplayName: "Clawdmeter",
                mode: .worktree,
                worktreePath: "/repo/.claude/worktrees/demo",
                runtimeCwd: "/repo/.claude/worktrees/demo",
                branchName: "feat/lifecycle",
                baseBranch: "main"
            ),
            prInfo: SessionLifecyclePRInfo(
                number: 42,
                title: "Lifecycle spine",
                url: "https://github.com/example/repo/pull/42",
                state: .open,
                checksRollup: .failure,
                reviewState: .approved,
                mergeability: .blocked,
                protectedBranchGate: true,
                lastCheckedAt: Date(timeIntervalSince1970: 1_777_100_120)
            ),
            providerCapabilities: SessionLifecycleProviderCapabilities(
                agent: .claude,
                supportsPlanApproval: true,
                supportsResume: true,
                supportsTranscriptImport: true,
                supportsInterrupt: true,
                supportsPRs: true,
                supportsCheckpoints: true,
                supportsProviderHandoff: true
            ),
            validationStatus: SessionLifecycleValidationStatus(
                state: .failed,
                title: "Swift tests",
                summary: "1 failure",
                updatedAt: Date(timeIntervalSince1970: 1_777_100_180)
            ),
            checkpointStatus: SessionLifecycleCheckpointStatus(latest: checkpoint, count: 1, canRestore: true),
            updatedAt: Date(timeIntervalSince1970: 1_777_100_240),
            seq: 99
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(SessionLifecycleSnapshotResponse(snapshot: snapshot))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionLifecycleSnapshotResponse.self, from: data).snapshot

        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.phase, .checksBlocked)
        XCTAssertEqual(decoded.goal?.text, "Ship lifecycle spine")
        XCTAssertEqual(decoded.blockers.first?.kind, .ciFailing)
        XCTAssertEqual(decoded.evidence.first?.payload.refId, checkpoint.refName)
        XCTAssertEqual(decoded.nextAction?.kind, .inspectChecks)
        XCTAssertEqual(decoded.branchInfo.branchName, "feat/lifecycle")
        XCTAssertEqual(decoded.prInfo?.number, 42)
        XCTAssertEqual(decoded.providerCapabilities.agent, .claude)
        XCTAssertEqual(decoded.validationStatus?.state, .failed)
        XCTAssertEqual(decoded.checkpointStatus?.latest?.id, checkpoint.id)
        XCTAssertEqual(decoded.seq, 99)
    }

    func test_unknownEnumsDecodeToSafeDefaults() throws {
        let phase = try JSONDecoder().decode(SessionLifecyclePhase.self, from: Data("\"future\"".utf8))
        let blocker = try JSONDecoder().decode(LifecycleBlockerKind.self, from: Data("\"future\"".utf8))
        let evidence = try JSONDecoder().decode(LifecycleEvidenceKind.self, from: Data("\"future\"".utf8))
        let action = try JSONDecoder().decode(SessionLifecycleNextActionKind.self, from: Data("\"future\"".utf8))

        XCTAssertEqual(phase, .running)
        XCTAssertEqual(blocker, .unknown)
        XCTAssertEqual(evidence, .unknown)
        XCTAssertEqual(action, .unknown)
    }
}
