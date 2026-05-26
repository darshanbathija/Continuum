import XCTest
@testable import ClawdmeterShared

/// Back-compat + round-trip tests for the new `AgentSession.planProgress`
/// wire field. Same pattern as `AgentSessionSchemaV5Tests`:
///
/// - existing persisted sessions.json (no `planProgress` key) decode
///   cleanly into a session whose `planProgress` is nil
/// - sessions encoded with `planProgress` round-trip through Codable
final class AgentSessionPlanProgressTests: XCTestCase {

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Back-compat: missing `planProgress` key decodes as nil

    func test_decodeWithoutPlanProgress_succeeds() throws {
        // Hand-crafted sessions.json shape representing a pre-feature
        // session — every field that AgentSession requires, but no
        // planProgress key at all.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "repoKey": "/Users/foo/repo",
          "repoDisplayName": "repo",
          "agent": "claude",
          "status": "running",
          "createdAt": "2026-05-26T07:30:00Z",
          "lastEventAt": "2026-05-26T07:31:00Z",
          "lastEventSeq": 5,
          "mode": "local"
        }
        """.data(using: .utf8)!
        let session = try decoder().decode(AgentSession.self, from: json)
        XCTAssertNil(session.planProgress,
            "Missing planProgress key must decode as nil for sessions persisted before this feature shipped.")
        XCTAssertEqual(session.lastEventSeq, 5)
    }

    // MARK: - Round-trip with planProgress populated

    func test_roundTripWithPlanProgress() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let progress = PlanProgress(completed: 3, total: 8, lastComputedAt: now)
        let session = AgentSession(
            id: UUID(),
            repoKey: "/Users/foo/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "opus",
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            status: .running,
            planText: nil,
            approvedPlanText: "1. step a\n2. step b",
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 1,
            mode: .local,
            planProgress: progress
        )
        let encoded = try encoder().encode(session)
        let decoded = try decoder().decode(AgentSession.self, from: encoded)
        let p = try XCTUnwrap(decoded.planProgress)
        XCTAssertEqual(p.completed, 3)
        XCTAssertEqual(p.total, 8)
        XCTAssertEqual(p.lastComputedAt, now)
        XCTAssertEqual(p.fraction, 3.0 / 8.0, accuracy: 1e-9)
    }

    // MARK: - PlanProgress.from(steps:) factory

    func test_planProgressFromSteps_emptyReturnsNil() {
        XCTAssertNil(PlanProgress.from(steps: []))
    }

    func test_planProgressFromSteps_mixedComputesCompleted() throws {
        let steps = [
            PlanStep(id: "1", text: "a", isComplete: true),
            PlanStep(id: "2", text: "b", isComplete: false),
            PlanStep(id: "3", text: "c", isComplete: true),
            PlanStep(id: "4", text: "d", isComplete: false),
        ]
        let progress = try XCTUnwrap(PlanProgress.from(steps: steps))
        XCTAssertEqual(progress.completed, 2)
        XCTAssertEqual(progress.total, 4)
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 1e-9)
    }

    func test_planProgressFromSteps_allCompletePopulatesTotal() throws {
        let steps = (0..<3).map { PlanStep(id: "\($0)", text: "t\($0)", isComplete: true) }
        let progress = try XCTUnwrap(PlanProgress.from(steps: steps))
        XCTAssertEqual(progress.completed, 3)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 1e-9)
    }
}
