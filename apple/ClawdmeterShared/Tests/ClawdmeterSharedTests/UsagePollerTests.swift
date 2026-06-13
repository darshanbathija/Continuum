import XCTest
@testable import ClawdmeterShared

/// Tests `UsagePoller`'s orchestration: error handling, epoch-aware merge,
/// rate-limit backoff, and predictor wiring.
final class UsagePollerTests: XCTestCase {

    // MARK: - Inter-poll jitter (multi-account desync)

    func test_nextDelay_zeroJitterIsDeterministic() {
        // jitter=0 must return exactly base — the documented test seam.
        XCTAssertEqual(UsagePoller.nextDelay(base: 60, jitterCap: 0), 60, accuracy: 0.0)
    }

    func test_nextDelay_negativeJitterCapClampsToBase() {
        XCTAssertEqual(UsagePoller.nextDelay(base: 60, jitterCap: -5), 60, accuracy: 0.0)
    }

    func test_nextDelay_staysWithinBaseAndCap() {
        // Sample many times — every draw must land in [base, base+cap].
        for _ in 0..<500 {
            let d = UsagePoller.nextDelay(base: 60, jitterCap: 8)
            XCTAssertGreaterThanOrEqual(d, 60)
            XCTAssertLessThanOrEqual(d, 68)
        }
    }

    func test_defaultConfiguration_hasNonZeroJitter() {
        // Production default must desync concurrent same-provider pollers.
        XCTAssertGreaterThan(UsagePoller.Configuration().intervalJitterSeconds, 0)
    }

    func test_singleSuccessfulPoll_emitsUsageEvent() async {
        let source = ScriptedSource(steps: [.succeed(makeUsage(session: 50, epoch: 1000))])
        let poller = UsagePoller(source: source)
        let event = await poller.forcePoll()
        if case .usage(let usage) = event {
            XCTAssertEqual(usage.sessionPct, 50)
            XCTAssertEqual(usage.sessionEpoch, 1000)
        } else {
            XCTFail("Expected .usage, got \(event)")
        }
        XCTAssertEqual(poller.currentUsage?.sessionEpoch, 1000)
    }

    // Plan E14: epoch ordering. Newer epoch must always beat older epoch even
    // if `updatedAt` drifts backward (clock skew between devices).
    func test_olderEpochAfterNewerEpoch_doesNotOverride() async {
        let newer = makeUsage(session: 5, epoch: 2000, updatedAt: 1500)
        let older = makeUsage(session: 95, epoch: 1000, updatedAt: 1600) // newer time, older window
        let source = ScriptedSource(steps: [
            .succeed(newer),
            .succeed(older),
        ])
        let poller = UsagePoller(source: source)
        _ = await poller.forcePoll()
        _ = await poller.forcePoll()
        XCTAssertEqual(poller.currentUsage?.sessionEpoch, 2000,
                       "Stale-pre-reset payload (older epoch) must not override fresh-post-reset (newer epoch)")
    }

    func test_unauthenticatedThenAuthExpired_emitsReauthEvent() async {
        let source = AlwaysUnauthenticatedSource()
        let poller = UsagePoller(source: source)

        // 1st poll triggers refresh (consumes attempt 1)
        _ = await poller.forcePoll()
        // 2nd poll triggers refresh (consumes attempt 2)
        _ = await poller.forcePoll()
        // 3rd poll: refresh-bound exhausted (E7)
        let event = await poller.forcePoll()
        if case .unauthenticatedNeedsReauth = event {
            // expected
        } else {
            XCTFail("Expected reauth event after E7 bound, got \(event)")
        }
    }

    func test_rateLimited_setsBackoffFromRetryAfter() async {
        let source = ScriptedSource(steps: [.fail(.rateLimited(retryAfter: 120))])
        let poller = UsagePoller(source: source)
        let event = await poller.forcePoll()
        if case .error(let err) = event {
            if case .rateLimited(let retry) = err {
                XCTAssertEqual(retry, 120)
            } else {
                XCTFail("Wrong error: \(err)")
            }
        } else {
            XCTFail("Expected .error, got \(event)")
        }
    }

    func test_predictorIntegration_resetsOnEpochChange() async {
        // Drive several samples in one window
        var steps: [ScriptedSource.Step] = []
        for i in 0..<6 {
            steps.append(.succeed(makeUsage(session: 50 + i * 5, epoch: 1000, updatedAt: Double(i) * 60)))
        }
        // Then a new window starts
        steps.append(.succeed(makeUsage(session: 5, epoch: 2000, updatedAt: 360 + 60)))

        let predictor = BurnRatePredictor()
        let source = ScriptedSource(steps: steps)
        let poller = UsagePoller(source: source, predictor: predictor)

        for _ in 0..<steps.count { _ = await poller.forcePoll() }

        XCTAssertEqual(predictor.sampleCount, 1,
                       "Plan E14: predictor must reset on session-epoch change")
    }

    // Helpers

    private func makeUsage(session: Int = 50, epoch: Int = 1000, updatedAt: TimeInterval = 1500) -> UsageData {
        UsageData(
            sessionPct: session,
            sessionResetMins: 60,
            sessionEpoch: epoch,
            weeklyPct: 0,
            weeklyResetMins: 600,
            weeklyEpoch: 100_000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private final class ScriptedSource: AISource, @unchecked Sendable {
        enum Step {
            case succeed(UsageData)
            case fail(AISourceError)
        }
        private var steps: [Step]
        let providerID = "test"
        let displayName = "Test"

        init(steps: [Step]) { self.steps = steps }
        var isAuthenticated: Bool { true }
        func poll() async throws -> UsageData {
            guard !steps.isEmpty else { throw AISourceError.networkFailure(underlying: nil) }
            let step = steps.removeFirst()
            switch step {
            case .succeed(let u): return u
            case .fail(let e): throw e
            }
        }
        func refreshCredentialsIfNeeded() async throws -> Bool { false }
    }

    private final class AlwaysUnauthenticatedSource: AISource, @unchecked Sendable {
        let providerID = "test-401"
        let displayName = "Test 401"
        var isAuthenticated: Bool { true }
        var refreshCallCount = 0
        let maxRefreshes = 2
        func poll() async throws -> UsageData {
            throw AISourceError.unauthenticated
        }
        func refreshCredentialsIfNeeded() async throws -> Bool {
            refreshCallCount += 1
            if refreshCallCount > maxRefreshes {
                throw AISourceError.authExpired
            }
            return true
        }
    }
}
