import XCTest
@testable import Clawdmeter
@testable import ClawdmeterShared

/// Track A T8: the idle-suspend DECISION. The riskiest rule is "never mid-turn"
/// (a long silent tool call must NOT be swept), so that gets explicit coverage.
final class IdleSessionSweeperTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private func later(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testSuspendsIdleNonStreamingClaudeWithLiveHost() {
        XCTAssertTrue(IdleSessionSweeper.shouldSuspend(
            agent: .claude, hasLiveHost: true, isStreaming: false,
            lastEventAt: t0, now: later(301), idleSeconds: 300))
    }

    func testDoesNotSuspendWhileStreaming() {
        // The load-bearing rule: a long silent tool call keeps the turn live.
        XCTAssertFalse(IdleSessionSweeper.shouldSuspend(
            agent: .claude, hasLiveHost: true, isStreaming: true,
            lastEventAt: t0, now: later(9999), idleSeconds: 300),
            "must never suspend mid-turn, however long lastEventAt is")
    }

    func testDoesNotSuspendBeforeIdleWindow() {
        XCTAssertFalse(IdleSessionSweeper.shouldSuspend(
            agent: .claude, hasLiveHost: true, isStreaming: false,
            lastEventAt: t0, now: later(120), idleSeconds: 300))
    }

    func testDoesNotSuspendWithoutLiveHost() {
        XCTAssertFalse(IdleSessionSweeper.shouldSuspend(
            agent: .claude, hasLiveHost: false, isStreaming: false,
            lastEventAt: t0, now: later(301), idleSeconds: 300))
    }

    func testDoesNotSuspendNonClaude() {
        XCTAssertFalse(IdleSessionSweeper.shouldSuspend(
            agent: .codex, hasLiveHost: true, isStreaming: false,
            lastEventAt: t0, now: later(301), idleSeconds: 300))
    }

    func testBoundaryExactlyAtIdleSeconds() {
        XCTAssertTrue(IdleSessionSweeper.shouldSuspend(
            agent: .claude, hasLiveHost: true, isStreaming: false,
            lastEventAt: t0, now: later(300), idleSeconds: 300),
            ">= idleSeconds suspends")
    }
}
