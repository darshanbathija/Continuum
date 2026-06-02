import Foundation
import ClawdmeterShared

public struct SessionLifecycleReducerFlags: Hashable, Sendable {
    public let isDraft: Bool
    public let isSpawning: Bool
    public let isResearching: Bool
    public let isValidating: Bool
    public let isPrDrafting: Bool

    public init(
        isDraft: Bool = false,
        isSpawning: Bool = false,
        isResearching: Bool = false,
        isValidating: Bool = false,
        isPrDrafting: Bool = false
    ) {
        self.isDraft = isDraft
        self.isSpawning = isSpawning
        self.isResearching = isResearching
        self.isValidating = isValidating
        self.isPrDrafting = isPrDrafting
    }
}

public enum SessionLifecycleReducer {
    public static func snapshot(
        for session: AgentSession,
        checkpoints: [CodeCheckpointSnapshot] = [],
        ledger: [SessionLifecycleLedgerEntry] = [],
        validationStatus: SessionLifecycleValidationStatus? = nil,
        preflightBlockers: [LifecycleBlocker] = [],
        flags: SessionLifecycleReducerFlags = SessionLifecycleReducerFlags(),
        now: Date = Date()
    ) -> SessionLifecycleSnapshot {
        let prMirror = session.prMirrorState
        let prInfo = prMirror.map {
            SessionLifecyclePRInfo(
                number: $0.number,
                title: $0.title,
                url: $0.prURL,
                state: $0.state,
                checksRollup: $0.checksRollup,
                reviewState: $0.reviewState,
                mergeability: $0.mergeability,
                protectedBranchGate: $0.protectedBranchGate,
                lastCheckedAt: $0.lastCheckedAt
            )
        }
        let blockers = blockers(
            for: session,
            prMirror: prMirror,
            validationStatus: validationStatus,
            preflightBlockers: preflightBlockers
        )
        let phase = phase(
            for: session,
            prMirror: prMirror,
            blockers: blockers,
            validationStatus: validationStatus,
            flags: flags
        )
        let latestCheckpoint = checkpoints.sorted { $0.createdAt > $1.createdAt }.first
        let checkpointStatus = SessionLifecycleCheckpointStatus(
            latest: latestCheckpoint,
            count: checkpoints.count,
            canRestore: latestCheckpoint != nil
        )

        return SessionLifecycleSnapshot(
            sessionId: session.id,
            phase: phase,
            goal: goalSnapshot(for: session),
            blockers: blockers,
            evidence: evidence(
                for: session,
                checkpoints: checkpoints,
                ledger: ledger,
                prMirror: prMirror,
                validationStatus: validationStatus,
                now: now
            ),
            nextAction: nextAction(for: phase, blockers: blockers, prInfo: prInfo),
            branchInfo: SessionLifecycleBranchInfo(
                repoKey: session.repoKey,
                repoDisplayName: session.repoDisplayName,
                mode: session.mode,
                worktreePath: session.worktreePath,
                runtimeCwd: session.runtimeCwd ?? session.effectiveCwd,
                branchName: prMirror?.branchName,
                baseBranch: nil
            ),
            prInfo: prInfo,
            providerCapabilities: providerCapabilities(for: session.agent),
            validationStatus: validationStatus,
            checkpointStatus: checkpointStatus,
            updatedAt: now,
            seq: max(session.lastEventSeq, ledger.map(\.seq).max() ?? 0)
        )
    }

    public static func providerCapabilities(for agent: AgentKind) -> SessionLifecycleProviderCapabilities {
        switch agent {
        case .claude, .codex:
            return SessionLifecycleProviderCapabilities(
                agent: agent,
                supportsPlanApproval: true,
                supportsResume: true,
                supportsTranscriptImport: true,
                supportsInterrupt: true,
                supportsPRs: true,
                supportsCheckpoints: true,
                supportsProviderHandoff: true
            )
        case .cursor:
            return SessionLifecycleProviderCapabilities(
                agent: agent,
                supportsPlanApproval: false,
                supportsResume: false,
                supportsTranscriptImport: false,
                supportsInterrupt: true,
                supportsPRs: true,
                supportsCheckpoints: true,
                supportsProviderHandoff: false
            )
        case .gemini, .opencode:
            return SessionLifecycleProviderCapabilities(
                agent: agent,
                supportsPlanApproval: false,
                supportsResume: true,
                supportsTranscriptImport: agent == .opencode,
                supportsInterrupt: true,
                supportsPRs: true,
                supportsCheckpoints: true,
                supportsProviderHandoff: false
            )
        case .grok:
            // ACP: plan-approval via session/request_permission; resume via
            // session/load. PR/checkpoint reuse the daemon plumbing.
            return SessionLifecycleProviderCapabilities(
                agent: agent,
                supportsPlanApproval: true,
                supportsResume: true,
                supportsTranscriptImport: false,
                supportsInterrupt: true,
                supportsPRs: true,
                supportsCheckpoints: true,
                supportsProviderHandoff: false
            )
        case .unknown:
            return SessionLifecycleProviderCapabilities(
                agent: agent,
                supportsPlanApproval: false,
                supportsResume: false,
                supportsTranscriptImport: false,
                supportsInterrupt: false,
                supportsPRs: false,
                supportsCheckpoints: false,
                supportsProviderHandoff: false
            )
        }
    }

    private static func phase(
        for session: AgentSession,
        prMirror: PRMirrorState?,
        blockers: [LifecycleBlocker],
        validationStatus: SessionLifecycleValidationStatus?,
        flags: SessionLifecycleReducerFlags
    ) -> SessionLifecyclePhase {
        if session.archivedAt != nil {
            return .archived
        }
        if prMirror?.lastMergeResult?.merged == true || prMirror?.state == .merged {
            return .merged
        }
        if flags.isDraft {
            return .draft
        }
        if !blockers.filter({ $0.kind == .preflight || $0.kind == .providerAuth || $0.kind == .repoState }).isEmpty {
            return .preflightBlocked
        }
        if flags.isSpawning || isTmuxBackedSpawnPending(session) {
            return .spawning
        }
        if flags.isValidating || validationStatus?.state == .running {
            return .validating
        }
        if validationStatus?.state == .failed {
            return .checksBlocked
        }
        if flags.isPrDrafting {
            return .prDrafting
        }
        if let prMirror {
            if hasMergeGateBlocker(blockers) {
                return .checksBlocked
            }
            if isReadyToMerge(prMirror) {
                return .readyToMerge
            }
            if prMirror.state == .open || prMirror.state == .draft {
                return .prOpen
            }
        }
        if session.status == .planning && hasPendingPlan(session) {
            return .awaitingApproval
        }
        if session.status == .planning {
            return .planning
        }
        if session.status == .paused || session.status == .degraded {
            return .needsInput
        }
        if session.status == .done {
            return .reviewing
        }
        if flags.isResearching {
            return .researching
        }
        return .running
    }

    private static func blockers(
        for session: AgentSession,
        prMirror: PRMirrorState?,
        validationStatus: SessionLifecycleValidationStatus?,
        preflightBlockers: [LifecycleBlocker]
    ) -> [LifecycleBlocker] {
        var blockers = preflightBlockers
        if session.status == .degraded {
            blockers.append(
                LifecycleBlocker(
                    kind: .runtimeDegraded,
                    summary: "The session runtime is disconnected.",
                    resolution: "Reconnect or respawn the session runtime.",
                    canOverride: false
                )
            )
        }
        if session.status == .paused {
            blockers.append(
                LifecycleBlocker(
                    kind: .needsUserInput,
                    summary: "The session is paused.",
                    resolution: "Send a reply or resume the agent.",
                    canOverride: true
                )
            )
        }
        if validationStatus?.state == .failed {
            blockers.append(
                LifecycleBlocker(
                    kind: .validationFailing,
                    summary: validationStatus?.summary ?? "Validation failed.",
                    resolution: "Open the validation output and fix the failing recipe.",
                    canOverride: false
                )
            )
        }
        if let prMirror {
            switch prMirror.checksRollup {
            case .failure:
                blockers.append(
                    LifecycleBlocker(
                        kind: .ciFailing,
                        summary: "Required checks are failing.",
                        resolution: "Open the failed checks and fix the regression.",
                        canOverride: prMirror.protectedBranchGate == false
                    )
                )
            case .pending:
                blockers.append(
                    LifecycleBlocker(
                        kind: .ciPending,
                        summary: "Checks are still running.",
                        resolution: "Wait for CI or inspect pending checks.",
                        canOverride: false
                    )
                )
            default:
                break
            }
            switch prMirror.reviewState {
            case .changesRequested:
                blockers.append(
                    LifecycleBlocker(
                        kind: .reviewPending,
                        summary: "A reviewer requested changes.",
                        resolution: "Address the review before merging.",
                        canOverride: false
                    )
                )
            case .reviewRequired, .pending:
                blockers.append(
                    LifecycleBlocker(
                        kind: .reviewPending,
                        summary: "Review approval is still pending.",
                        resolution: "Request or wait for the required review.",
                        canOverride: false
                    )
                )
            default:
                break
            }
            switch prMirror.mergeability {
            case .dirty:
                blockers.append(
                    LifecycleBlocker(
                        kind: .mergeConflict,
                        summary: "The PR branch has merge conflicts.",
                        resolution: "Rebase or merge the base branch and resolve conflicts.",
                        canOverride: false
                    )
                )
            case .blocked:
                blockers.append(
                    LifecycleBlocker(
                        kind: .mergeBlocked,
                        summary: "The PR is blocked by a merge gate.",
                        resolution: "Clear branch protection and mergeability blockers.",
                        canOverride: false
                    )
                )
            default:
                break
            }
        }
        return blockers
    }

    private static func evidence(
        for session: AgentSession,
        checkpoints: [CodeCheckpointSnapshot],
        ledger: [SessionLifecycleLedgerEntry],
        prMirror: PRMirrorState?,
        validationStatus: SessionLifecycleValidationStatus?,
        now: Date
    ) -> [LifecycleEvidence] {
        var evidence: [LifecycleEvidence] = []
        if let planText = normalized(session.planText) {
            evidence.append(
                LifecycleEvidence(
                    kind: .plan,
                    title: "Plan ready",
                    createdAt: session.lastEventAt,
                    payload: LifecycleEvidencePayload(text: planText)
                )
            )
        }
        if let approved = normalized(session.approvedPlanText) {
            evidence.append(
                LifecycleEvidence(
                    kind: .approvedPlan,
                    title: "Plan approved",
                    createdAt: session.lastEventAt,
                    payload: LifecycleEvidencePayload(text: approved)
                )
            )
        }
        for checkpoint in checkpoints.sorted(by: { $0.createdAt < $1.createdAt }) {
            evidence.append(
                LifecycleEvidence(
                    id: checkpoint.id,
                    kind: .checkpoint,
                    title: checkpoint.summary ?? "Checkpoint",
                    createdAt: checkpoint.createdAt,
                    payload: LifecycleEvidencePayload(
                        refId: checkpoint.refName,
                        metadata: ["turnId": checkpoint.turnId ?? ""]
                    )
                )
            )
        }
        if let validationStatus {
            evidence.append(
                LifecycleEvidence(
                    kind: .validationRun,
                    title: validationStatus.title ?? "Validation",
                    createdAt: validationStatus.updatedAt ?? now,
                    payload: LifecycleEvidencePayload(
                        text: validationStatus.summary,
                        metadata: ["state": validationStatus.state.rawValue]
                    )
                )
            )
        }
        if let prMirror {
            evidence.append(
                LifecycleEvidence(
                    kind: .pr,
                    title: prMirror.title ?? "Pull request",
                    createdAt: prMirror.lastCheckedAt ?? now,
                    payload: LifecycleEvidencePayload(
                        url: prMirror.prURL,
                        metadata: [
                            "state": prMirror.state?.rawValue ?? "",
                            "checksRollup": prMirror.checksRollup.rawValue,
                            "reviewState": prMirror.reviewState.rawValue,
                            "mergeability": prMirror.mergeability.rawValue,
                        ]
                    )
                )
            )
            for check in prMirror.checks {
                evidence.append(
                    LifecycleEvidence(
                        kind: .prCheck,
                        title: check.name,
                        createdAt: check.completedAt ?? prMirror.lastCheckedAt ?? now,
                        payload: LifecycleEvidencePayload(
                            url: check.url,
                            metadata: ["state": check.state.rawValue]
                        )
                    )
                )
            }
        }
        evidence.append(contentsOf: ledger.flatMap(\.evidence))
        return evidence
    }

    private static func nextAction(
        for phase: SessionLifecyclePhase,
        blockers: [LifecycleBlocker],
        prInfo: SessionLifecyclePRInfo?
    ) -> SessionLifecycleNextAction? {
        switch phase {
        case .draft:
            return SessionLifecycleNextAction(kind: .startSession, title: "Start session")
        case .preflightBlocked:
            return SessionLifecycleNextAction(
                kind: .resolvePreflight,
                title: blockers.first?.resolution ?? "Resolve preflight blockers"
            )
        case .awaitingApproval:
            return SessionLifecycleNextAction(kind: .approvePlan, title: "Review and approve plan")
        case .needsInput:
            return SessionLifecycleNextAction(kind: .answerQuestion, title: "Answer the agent")
        case .reviewing:
            return SessionLifecycleNextAction(kind: .inspectDiff, title: "Inspect diff")
        case .validating:
            return SessionLifecycleNextAction(kind: .runValidation, title: "Watch validation")
        case .prDrafting:
            return SessionLifecycleNextAction(kind: .createPR, title: "Finish PR draft")
        case .prOpen:
            if let url = prInfo?.url {
                return SessionLifecycleNextAction(kind: .openPR, title: "Open pull request", deeplink: url)
            }
            return SessionLifecycleNextAction(kind: .openPR, title: "Open pull request")
        case .checksBlocked:
            return SessionLifecycleNextAction(kind: .inspectChecks, title: blockers.first?.resolution ?? "Inspect blockers")
        case .readyToMerge:
            return SessionLifecycleNextAction(kind: .mergePR, title: "Merge pull request", deeplink: prInfo?.url)
        case .spawning, .researching, .planning, .running, .merged, .archived:
            return nil
        }
    }

    private static func goalSnapshot(for session: AgentSession) -> SessionGoalSnapshot? {
        guard let text = normalized(session.goal) else { return nil }
        return SessionGoalSnapshot(text: text, createdAt: session.createdAt)
    }

    private static func hasPendingPlan(_ session: AgentSession) -> Bool {
        normalized(session.planText) != nil && normalized(session.approvedPlanText) == nil
    }

    private static func isTmuxBackedSpawnPending(_ session: AgentSession) -> Bool {
        guard session.status == .running,
              session.tmuxPaneId == nil,
              session.tmuxWindowId == nil
        else { return false }

        if session.kind == .chat { return false }
        if session.agent == .gemini && session.geminiBackend == .agentapi { return false }
        if session.agent == .opencode { return false }
        return true
    }

    private static func hasMergeGateBlocker(_ blockers: [LifecycleBlocker]) -> Bool {
        blockers.contains { blocker in
            switch blocker.kind {
            case .ciPending, .ciFailing, .reviewPending, .mergeBlocked, .mergeConflict, .validationFailing:
                return true
            default:
                return false
            }
        }
    }

    private static func isReadyToMerge(_ prMirror: PRMirrorState) -> Bool {
        guard prMirror.state == .open else { return false }
        let checksGreen = prMirror.checksRollup == .success || prMirror.checksRollup == .skipped
        let reviewGreen = prMirror.reviewState == .approved || prMirror.reviewState == .unknown
        let mergeGreen = prMirror.mergeability == .mergeable || prMirror.mergeability == .unknown
        return checksGreen && reviewGreen && mergeGreen
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
