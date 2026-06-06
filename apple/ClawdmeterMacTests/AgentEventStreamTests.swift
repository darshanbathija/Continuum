import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class AgentEventStreamTests: XCTestCase {

    override func tearDown() {
        AgentEventStream.resetEventLogForTesting()
        super.tearDown()
    }

    func test_syntheticDiffRecordsOnceForConcurrentSubscribers() {
        AgentEventStream.resetEventLogForTesting()
        let session = makeSession(planText: "approve this plan")

        AgentEventStream.recordSyntheticDiffEventsForTesting(currentSessions: [session])
        AgentEventStream.recordSyntheticDiffEventsForTesting(currentSessions: [session])

        XCTAssertEqual(
            AgentEventStream.eventLogCountForTesting,
            1,
            "Two subscribers seeing the same registry snapshot must not duplicate-write the global event log."
        )
    }

    private func makeSession(planText: String?) -> AgentSession {
        let now = Date(timeIntervalSince1970: 1_000)
        return AgentSession(
            id: UUID(),
            repoKey: "/tmp/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: planText,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 0,
            mode: .local
        )
    }
}
