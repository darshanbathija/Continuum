import XCTest
@testable import ClawdmeterShared

final class WorkspaceKeyTests: XCTestCase {

    func test_sameCanonicalWorkspacePathGroupsSiblings() {
        let a = makeSession(repo: "/repo", cwd: "/repo/.claude/worktrees/kolkata", createdAt: 2)
        let b = makeSession(repo: "/repo", cwd: "/repo/.claude/worktrees/kolkata/../kolkata", createdAt: 1)
        let c = makeSession(repo: "/repo", cwd: "/repo/.claude/worktrees/oslo", createdAt: 3)

        let key = WorkspaceKey.of(a)!
        let siblings = WorkspaceKey.siblings(of: key, in: [a, b, c])

        XCTAssertEqual(siblings.map(\.id), [b.id, a.id])
    }

    func test_localSessionFallsBackToRepoPath() {
        let session = makeSession(repo: "/repo", cwd: nil, mode: .local)

        XCTAssertEqual(WorkspaceKey.of(session), WorkspaceKey(repoKey: "/repo", workspacePath: "/repo"))
    }

    func test_siblingsExcludeChatArchivedAndDifferentRepo() {
        let active = makeSession(repo: "/repo", cwd: "/repo/.claude/worktrees/kolkata")
        let chat = makeSession(repo: "/repo", cwd: "/repo/.claude/worktrees/kolkata", kind: .chat)
        let archived = makeSession(repo: "/repo", cwd: "/repo/.claude/worktrees/kolkata", archived: true)
        let otherRepo = makeSession(repo: "/other", cwd: "/repo/.claude/worktrees/kolkata")

        let siblings = WorkspaceKey.siblings(of: WorkspaceKey.of(active)!, in: [active, chat, archived, otherRepo])

        XCTAssertEqual(siblings.map(\.id), [active.id])
    }

    func test_workspaceBranchLabelUsesWorktreeSlugNotRepoName() {
        let session = makeSession(
            repo: "/Users/dev/conductor/repos/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            cwd: "/Users/dev/conductor/workspaces/Clawdmeter/oslo"
        )

        XCTAssertEqual(session.displayLabel, "Clawdmeter")
        XCTAssertEqual(session.workspaceBranchLabel, "oslo")
    }

    func test_workspaceBranchLabelPrefersProvisioningWorkspaceSlug() {
        let session = makeSession(
            repo: "/Users/dev/conductor/repos/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            cwd: "/Users/dev/Clawdmeter/workspaces/Clawdmeter/kolkata",
            provisioning: WorktreeProvisioningMetadata(
                ownershipMarkerId: "marker",
                branchName: "feature/kolkata",
                worktreePath: "/Users/dev/Clawdmeter/workspaces/Clawdmeter/kolkata",
                workspaceSlug: "kolkata",
                filesToCopy: WorktreeFileCopySummary(source: .disabled, patterns: [])
            )
        )

        XCTAssertEqual(session.workspaceBranchLabel, "kolkata")
    }

    func test_workspaceSessionTabLabelDefaultsToRepoDashBranchWithoutSummary() {
        let session = makeSession(
            repo: "/Users/dev/conductor/repos/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            cwd: "/Users/dev/conductor/workspaces/Clawdmeter/kigali"
        )

        XCTAssertEqual(
            WorkspaceSessionTabLabel.labels(for: session),
            WorkspaceSessionTabLabel.Labels(title: "Clawdmeter - kigali", subtitle: "")
        )
    }

    func test_workspaceSessionTabLabelUsesFiveWordSummaryAndBranchSubtitle() {
        let session = makeSession(
            repo: "/Users/dev/conductor/repos/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            cwd: "/Users/dev/conductor/workspaces/Clawdmeter/kigali",
            goal: "Fix the cramped workspace tab labels for Conductor sessions"
        )

        XCTAssertEqual(
            WorkspaceSessionTabLabel.labels(for: session),
            WorkspaceSessionTabLabel.Labels(
                title: "Fix the cramped workspace tab…",
                subtitle: "kigali"
            )
        )
    }

    func test_workspaceSessionTabLabelPrefersCustomNameOverGoal() {
        let session = makeSession(
            repo: "/Users/dev/conductor/repos/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            cwd: "/Users/dev/conductor/workspaces/Clawdmeter/kigali",
            goal: "This goal should not win",
            customName: "Ship tab rename polish"
        )

        XCTAssertEqual(
            WorkspaceSessionTabLabel.labels(for: session),
            WorkspaceSessionTabLabel.Labels(title: "Ship tab rename polish", subtitle: "kigali")
        )
    }

    func test_workspaceSessionTabLabelUsesAssistantSummaryFallback() {
        let session = makeSession(
            repo: "/Users/dev/conductor/repos/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            cwd: "/Users/dev/conductor/workspaces/Clawdmeter/kigali"
        )

        XCTAssertEqual(
            WorkspaceSessionTabLabel.labels(
                for: session,
                assistantSummary: "Restored active session stream animation behind branch names"
            ),
            WorkspaceSessionTabLabel.Labels(
                title: "Restored active session stream animation…",
                subtitle: "kigali"
            )
        )
    }

    func test_workspaceSessionShortSummaryCapsAtFiveWords() {
        let session = makeSession(
            repo: "/Users/dev/conductor/repos/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            cwd: "/Users/dev/conductor/workspaces/Clawdmeter/kigali",
            customName: "Fix active session tab naming and data stream"
        )

        XCTAssertEqual(
            WorkspaceSessionTabLabel.shortSummary(for: session),
            "Fix active session tab naming…"
        )
    }

    private func makeSession(
        repo: String,
        repoDisplayName: String = "repo",
        cwd: String?,
        goal: String? = nil,
        customName: String? = nil,
        provisioning: WorktreeProvisioningMetadata? = nil,
        mode: SessionMode = .worktree,
        kind: SessionKind = .code,
        archived: Bool = false,
        createdAt: TimeInterval = 0
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: kind == .code ? repo : nil,
            repoDisplayName: repoDisplayName,
            agent: .claude,
            model: nil,
            goal: goal,
            worktreePath: cwd,
            provisioning: provisioning,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(timeIntervalSince1970: createdAt),
            lastEventAt: Date(timeIntervalSince1970: createdAt),
            lastEventSeq: 1,
            mode: mode,
            archivedAt: archived ? Date(timeIntervalSince1970: 99) : nil,
            runtimeCwd: cwd,
            customName: customName,
            kind: kind
        )
    }
}
