import XCTest
@testable import ClawdmeterShared

/// Track B — B4 / CB-P2a: brute-force lockout for the fail-closed peer gate.
final class RelayAuthLockoutTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_locksOutAfterMaxFailures() {
        let lo = RelayAuthLockout(maxFailures: 3, failureWindow: 60, banDuration: 300)
        XCTAssertFalse(lo.isLockedOut("1.2.3.4", now: t0))
        lo.recordFailure("1.2.3.4", now: t0)
        lo.recordFailure("1.2.3.4", now: t0)
        XCTAssertFalse(lo.isLockedOut("1.2.3.4", now: t0), "below threshold")
        lo.recordFailure("1.2.3.4", now: t0)   // 3rd → trip
        XCTAssertTrue(lo.isLockedOut("1.2.3.4", now: t0), "threshold reached → banned")
    }

    func test_banExpiresAfterDuration() {
        let lo = RelayAuthLockout(maxFailures: 2, failureWindow: 60, banDuration: 300)
        lo.recordFailure("ip", now: t0); lo.recordFailure("ip", now: t0)
        XCTAssertTrue(lo.isLockedOut("ip", now: t0))
        XCTAssertTrue(lo.isLockedOut("ip", now: t0.addingTimeInterval(299)))
        XCTAssertFalse(lo.isLockedOut("ip", now: t0.addingTimeInterval(301)), "ban lifts after the window")
    }

    func test_successResetsStrikes() {
        let lo = RelayAuthLockout(maxFailures: 3, failureWindow: 60, banDuration: 300)
        lo.recordFailure("ip", now: t0); lo.recordFailure("ip", now: t0)
        lo.recordSuccess("ip")
        lo.recordFailure("ip", now: t0); lo.recordFailure("ip", now: t0)
        XCTAssertFalse(lo.isLockedOut("ip", now: t0), "success cleared the prior strikes")
    }

    func test_windowRollOverResetsCount() {
        let lo = RelayAuthLockout(maxFailures: 3, failureWindow: 60, banDuration: 300)
        lo.recordFailure("ip", now: t0); lo.recordFailure("ip", now: t0)
        // Next failure is outside the 60s window → counter resets, no ban.
        lo.recordFailure("ip", now: t0.addingTimeInterval(120))
        XCTAssertFalse(lo.isLockedOut("ip", now: t0.addingTimeInterval(120)))
    }

    func test_perSourceIsolation() {
        let lo = RelayAuthLockout(maxFailures: 2, failureWindow: 60, banDuration: 300)
        lo.recordFailure("attacker", now: t0); lo.recordFailure("attacker", now: t0)
        XCTAssertTrue(lo.isLockedOut("attacker", now: t0))
        XCTAssertFalse(lo.isLockedOut("legit", now: t0), "one source's ban must not affect another")
    }

    func test_prune() {
        let lo = RelayAuthLockout(maxFailures: 5, failureWindow: 10, banDuration: 30)
        lo.recordFailure("ip", now: t0)
        XCTAssertEqual(lo.trackedSourceCount, 1)
        lo.prune(now: t0.addingTimeInterval(11))
        XCTAssertEqual(lo.trackedSourceCount, 0)
    }
}
