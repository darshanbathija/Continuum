import Foundation
import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class SessionSchedulerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdmeter-session-scheduler-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func test_unavailableFollowUpReleasesClaimAndRetries() async throws {
        let registry = AgentSessionRegistry(storeURL: tempDir.appendingPathComponent("sessions.json"))
        let session = try await registry.create(
            repoKey: tempDir.path,
            repoDisplayName: "Scheduler",
            agent: .claude,
            model: "sonnet",
            goal: "Retry follow-up",
            worktreePath: tempDir.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let followUp = ScheduledFollowUp(
            fireAt: Date().addingTimeInterval(-1),
            prompt: "retry after unavailable"
        )
        try await registry.addScheduledFollowUp(sessionId: session.id, followUp: followUp)

        let delivered = expectation(description: "follow-up retried and delivered")
        var attempts = 0
        let scheduler = SessionScheduler(
            registry: registry,
            deliverer: { _, _ in
                attempts += 1
                if attempts == 1 {
                    return .unavailable(reason: "runtime_not_live")
                }
                delivered.fulfill()
                return .delivered
            },
            unavailableRetryInterval: 0.05
        )
        scheduler.start()
        await fulfillment(of: [delivered], timeout: 2)

        for _ in 0..<20 {
            if registry.session(id: session.id)?.scheduledFollowUps.first?.firedAt != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        scheduler.stop()
        XCTAssertGreaterThanOrEqual(attempts, 2)
        XCTAssertNotNil(registry.session(id: session.id)?.scheduledFollowUps.first?.firedAt)
    }

    func test_retiredFollowUpIsRemovedWithoutRetryOrDegrade() async throws {
        let registry = AgentSessionRegistry(storeURL: tempDir.appendingPathComponent("sessions.json"))
        let session = try await registry.create(
            repoKey: tempDir.path,
            repoDisplayName: "Scheduler",
            agent: .claude,
            model: "sonnet",
            goal: "Retire follow-up",
            worktreePath: tempDir.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let followUp = ScheduledFollowUp(
            fireAt: Date().addingTimeInterval(-1),
            prompt: "do not retry retired runtime"
        )
        try await registry.addScheduledFollowUp(sessionId: session.id, followUp: followUp)

        let retired = expectation(description: "follow-up retired")
        var attempts = 0
        let scheduler = SessionScheduler(
            registry: registry,
            deliverer: { _, _ in
                attempts += 1
                retired.fulfill()
                return .retired(reason: "legacy_session_retired")
            },
            unavailableRetryInterval: 0.01
        )
        scheduler.start()
        await fulfillment(of: [retired], timeout: 2)

        for _ in 0..<20 {
            if registry.session(id: session.id)?.scheduledFollowUps.isEmpty == true {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        scheduler.stop()
        let reloaded = try XCTUnwrap(registry.session(id: session.id))
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(reloaded.scheduledFollowUps.isEmpty)
        XCTAssertEqual(reloaded.status, .running)
    }
}
