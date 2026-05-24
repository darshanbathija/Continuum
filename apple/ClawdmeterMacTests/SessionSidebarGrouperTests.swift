import XCTest
import ClawdmeterShared
@testable import Clawdmeter

final class SessionSidebarGrouperTests: XCTestCase {
    func test_statusGroupingUsesConductorFourBucketModel() {
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        let prReview = UUID()
        let sessions = [
            session(status: .running, lastEventAt: now.addingTimeInterval(-5), goal: "running"),
            session(status: .paused, lastEventAt: now.addingTimeInterval(-10), goal: "recent"),
            session(status: .planning, lastEventAt: now.addingTimeInterval(-300), goal: "plan", planText: "Ship this"),
            session(id: prReview, status: .done, lastEventAt: now.addingTimeInterval(-500), goal: "pr"),
            session(status: .done, lastEventAt: now.addingTimeInterval(-900), goal: "done"),
            session(status: .done, lastEventAt: now.addingTimeInterval(-1200), goal: "archived", archivedAt: now),
        ]

        let groups = SessionSidebarGrouper.group(
            sessions: sessions,
            repos: [],
            grouping: .status,
            sorting: .recency,
            statusFilter: .all,
            reviewSessionIds: [prReview],
            now: now
        )

        XCTAssertEqual(groups.map(\.title), ["Active", "In Review", "Done", "Archived"])
        XCTAssertEqual(groups.map { $0.sessions.count }, [2, 2, 1, 1])
        XCTAssertEqual(groups[1].sessions.map(\.goal), ["plan", "pr"])
    }

    func test_statusFilterNarrowsWithinFourBucketView() {
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        let review = session(status: .planning, lastEventAt: now.addingTimeInterval(-60), planText: "Review")
        let done = session(status: .done, lastEventAt: now.addingTimeInterval(-90))

        let groups = SessionSidebarGrouper.group(
            sessions: [review, done],
            repos: [],
            grouping: .status,
            sorting: .recency,
            statusFilter: .inReview,
            now: now
        )

        XCTAssertEqual(groups.map(\.title), ["Active", "In Review", "Done", "Archived"])
        XCTAssertEqual(groups.map { $0.sessions.count }, [0, 1, 0, 0])
        XCTAssertEqual(groups[1].sessions.first?.id, review.id)
    }

    private func session(
        id: UUID = UUID(),
        status: AgentSessionStatus,
        lastEventAt: Date,
        goal: String? = nil,
        planText: String? = nil,
        archivedAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: "/tmp/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: goal,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: status,
            planText: planText,
            createdAt: lastEventAt.addingTimeInterval(-60),
            lastEventAt: lastEventAt,
            lastEventSeq: 1,
            archivedAt: archivedAt
        )
    }
}
