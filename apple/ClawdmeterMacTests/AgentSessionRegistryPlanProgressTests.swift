import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Coverage for the daemon-side wire field `AgentSession.planProgress`
/// and the registry's lifecycle hooks:
///
/// - `setPlanProgress(id:progress:)` is idempotent (no event-seq churn
///   when the value matches).
/// - `markPlanApproved(id:)` clears any stale `planProgress` AND seeds an
///   initial 0/N value so the sidebar bar shows immediately.
/// - `approvedAt(for:)` is recorded on approval (so the
///   `PlanProgressTracker`'s post-approval message filter has a
///   real reference point).
@MainActor
final class AgentSessionRegistryPlanProgressTests: XCTestCase {

    private var tempStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-planprogress-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempStoreURL = dir.appendingPathComponent("sessions.json")
    }

    override func tearDown() async throws {
        if let dir = tempStoreURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func registry() -> AgentSessionRegistry {
        AgentSessionRegistry(storeURL: tempStoreURL)
    }

    private func makeApprovedSession(in reg: AgentSessionRegistry, plan: String) throws -> AgentSession {
        let session = reg.create(
            repoKey: "/tmp/test-repo",
            repoDisplayName: "test-repo",
            agent: .claude,
            model: "sonnet",
            goal: nil,
            worktreePath: "/tmp/test-repo",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            planMode: true,
            mode: .worktree
        )
        reg.setPlanText(id: session.id, planText: plan)
        reg.markPlanApproved(id: session.id)
        return try XCTUnwrap(reg.session(id: session.id))
    }

    // MARK: - markPlanApproved seeds + clears

    func test_markPlanApproved_seedsInitialZeroOfN() throws {
        let reg = registry()
        let plan = """
        1. Add the wire field.
        2. Wire the daemon.
        3. Render the bar.
        """
        let approved = try makeApprovedSession(in: reg, plan: plan)
        let progress = try XCTUnwrap(approved.planProgress,
            "markPlanApproved should seed a 0/N planProgress so the bar appears immediately.")
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.completed, 0)
        XCTAssertNotNil(reg.approvedAt(for: approved.id),
            "approvedAt must be stamped so the tracker's timestamp filter has a reference.")
    }

    func test_markPlanApproved_clearsStalePlanProgress() throws {
        let reg = registry()
        let plan = """
        1. Add field.
        2. Wire it.
        """
        let approved = try makeApprovedSession(in: reg, plan: plan)
        // Simulate the tracker writing a mid-run value.
        let mid = PlanProgress(completed: 1, total: 2, lastComputedAt: Date())
        reg.setPlanProgress(id: approved.id, progress: mid)
        XCTAssertEqual(reg.session(id: approved.id)?.planProgress?.completed, 1)

        // Re-approving (e.g. the user iterates on the plan and re-approves)
        // should drop back to a fresh 0/N seed, not keep the stale mid value.
        reg.setPlanText(id: approved.id, planText: plan + "\n3. Add a third step.")
        reg.markPlanApproved(id: approved.id)
        let reseeded = try XCTUnwrap(reg.session(id: approved.id)?.planProgress)
        XCTAssertEqual(reseeded.total, 3)
        XCTAssertEqual(reseeded.completed, 0)
    }

    // MARK: - setPlanProgress idempotency

    func test_setPlanProgress_idempotentOnEquality() throws {
        let reg = registry()
        let approved = try makeApprovedSession(in: reg, plan: "1. step a\n2. step b")
        let baseSeq = approved.lastEventSeq

        // Re-set with the IDENTICAL value (same completed/total/lastComputedAt).
        // Should be a no-op — no lastEventSeq bump.
        let current = try XCTUnwrap(approved.planProgress)
        reg.setPlanProgress(id: approved.id, progress: current)
        XCTAssertEqual(reg.session(id: approved.id)?.lastEventSeq, baseSeq,
            "Re-setting an unchanged planProgress must not bump lastEventSeq.")

        // Set with a different value — should bump.
        let updated = PlanProgress(completed: 1, total: 2, lastComputedAt: Date().addingTimeInterval(60))
        reg.setPlanProgress(id: approved.id, progress: updated)
        XCTAssertGreaterThan(reg.session(id: approved.id)?.lastEventSeq ?? 0, baseSeq,
            "A real value change must bump lastEventSeq so subscribers see the update.")
    }

    func test_setPlanProgress_nilClearsField() throws {
        let reg = registry()
        let approved = try makeApprovedSession(in: reg, plan: "1. step a")
        XCTAssertNotNil(approved.planProgress)
        reg.setPlanProgress(id: approved.id, progress: nil)
        XCTAssertNil(reg.session(id: approved.id)?.planProgress)
    }

    // MARK: - Empty-plan edge

    func test_markPlanApproved_prosePlan_doesNotSeedProgress() throws {
        let reg = registry()
        let session = reg.create(
            repoKey: "/tmp/r",
            repoDisplayName: "r",
            agent: .claude,
            model: "sonnet",
            goal: nil,
            worktreePath: "/tmp/r",
            tmuxWindowId: "@2",
            tmuxPaneId: "%2",
            planMode: true,
            mode: .worktree
        )
        // Whitespace-only "plan" — TahoePlanParser.steps returns empty.
        reg.setPlanText(id: session.id, planText: "   \n\n   ")
        reg.markPlanApproved(id: session.id)
        // approvedPlanText falls back to existing approvedPlanText (nil)
        // because reviewableApprovedPlanText returns nil for whitespace-
        // only input — so this session never crosses the
        // "approvedPlanText != nil" gate.
        XCTAssertNil(reg.session(id: session.id)?.planProgress)
    }
}
