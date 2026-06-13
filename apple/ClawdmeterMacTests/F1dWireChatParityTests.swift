import XCTest
import Combine
import ClawdmeterShared
@testable import Clawdmeter

/// F1d-wire AppModel parity tests: prove the Cursor analytics consumer
/// in `AppModel.consume(_:)` produces the same `.usage` value regardless
/// of whether `FeatureFlags.useCursorAdapter` is on or off.
///
/// **Why this matters.** Cursor is the period-summary provider — no
/// JSONL, no per-turn token stream. With the flag off, `AppModel`
/// stores the polled `UsageData` directly on `.usage`. With the flag
/// on, it routes through
/// `CursorAdapterUsageBridge.project(usage:sessionId:sequenceNumber:)`,
/// which runs `CursorAdapter.translate(...)` → canonical
/// `.sessionStarted` event → re-projects back to `UsageData`. The
/// strangler-fig contract: the value rendered on `.usage` MUST be
/// identical across the flag.
///
/// **Coverage.** Pumps `UsagePoller.Event.usage(...)` events through a
/// real `AppModel` configured with a stub `AISource` so the production
/// `consume(_:)` path runs end-to-end. Drives the model via `start()`
/// + Combine subscription to deterministically wait for `.usage` to
/// land. Asserts:
///   - Same `UsageData` field-for-field across flag states.
///   - Sequence cursor advances per poll under flag-on (canonical
///     event ids stay unique).
///   - Sequence cursor resets on period-epoch change.
///   - Non-Cursor providers (Claude config) are untouched by the flag.
///
/// **Plan:** F1d-wire (Phase 1; D23 strangler-fig).
@MainActor
final class F1dWireChatParityTests: XCTestCase {

    // MARK: - Setup

    override func tearDown() {
        super.tearDown()
        FeatureFlags.useCursorAdapterOverride = nil
    }

    // MARK: - Stub source

    /// Stub AISource that returns whatever `UsageData` the test queues.
    /// Each call to `poll()` pops the next value; running out throws so
    /// the poll loop backs off (but the model has already published the
    /// first event by then).
    private final class StubCursorSource: AISource, @unchecked Sendable {
        let providerID = "cursor"
        let displayName = "Cursor"
        let queueLock = NSLock()
        private var _queued: [UsageData] = []
        var queued: [UsageData] {
            get { queueLock.lock(); defer { queueLock.unlock() }; return _queued }
            set { queueLock.lock(); defer { queueLock.unlock() }; _queued = newValue }
        }
        var isAuthenticated: Bool { true }
        func refreshCredentialsIfNeeded() async throws -> Bool { false }
        func poll() async throws -> UsageData {
            try queueLock.withLock {
                guard !_queued.isEmpty else {
                    throw AISourceError.malformedResponse(detail: "queue empty")
                }
                return _queued.removeFirst()
            }
        }
    }

    private final class StubTokenProvider: TokenProvider {
        var hasToken: Bool { true }
        var currentAccessToken: String? { "token" }
        func refreshIfNeeded() async throws -> Bool { false }
    }

    private func makeUsage(
        sessionPct: Int = 42,
        sessionResetMins: Int = 1234,
        sessionEpoch: Int = 1_715_999_999,
        organizationID: String? = "200 included / period",
        status: UsageData.Status = .allowed,
        updatedAt: Date = Date(timeIntervalSince1970: 1_715_000_000)
    ) -> UsageData {
        UsageData(
            sessionPct: sessionPct,
            sessionResetMins: sessionResetMins,
            sessionEpoch: sessionEpoch,
            weeklyPct: sessionPct,
            weeklyResetMins: sessionResetMins,
            weeklyEpoch: sessionEpoch,
            status: status,
            representativeClaim: .fiveHour,
            updatedAt: updatedAt,
            organizationID: organizationID
        )
    }

    /// Drive `n` polls through a fresh `AppModel(config:)` with the
    /// given queued usage values. Subscribes to `.$usage` to
    /// deterministically wait for `.usage` to update, instead of
    /// blind-sleeping. Returns the captured `.usage` snapshots in
    /// order.
    ///
    /// `start()` wires the poller's `onEvent` → `RunLoop.main.perform
    /// → consume(_:)` path, which is the production wire. Without
    /// `start()`, `forcePoll()` runs the tick but the onEvent
    /// callback is never set and `.usage` never updates. Subsequent
    /// polls are driven via `forcePoll()` because the default
    /// foreground interval (60s) is too long for a unit test.
    private func consumeAll(
        config: ProviderConfig,
        usages: [UsageData]
    ) async -> [UsageData] {
        let stub = StubCursorSource()
        stub.queued = usages
        let model = AppModel(
            config: config,
            source: stub,
            tokenProvider: StubTokenProvider()
        )
        var captured: [UsageData] = []
        let expectation = XCTestExpectation(description: "Captured \(usages.count) usage values")
        let token = model.$usage.compactMap { $0 }.sink { value in
            // De-duplicate identical consecutive emissions — the
            // shouldReplace(with:) gate in UsagePoller swallows
            // duplicates with the same (epoch, updatedAt), so each
            // queued usage with distinct fields should publish once.
            if captured.last != value {
                captured.append(value)
                if captured.count == usages.count {
                    expectation.fulfill()
                }
            }
        }
        defer { token.cancel() }

        model.start()
        // start() fires the initial tick. To drain the rest of the
        // queue within the test timeout, force additional polls. The
        // 50ms inter-poll delay gives the RunLoop.main.perform hop
        // time to land before the next forcePoll fires.
        for _ in 1..<usages.count {
            try? await Task.sleep(nanoseconds: 50_000_000)
            model.forcePoll()
        }
        await fulfillment(of: [expectation], timeout: 5.0)
        return captured
    }

    /// Convenience for single-poll tests.
    private func consumeOne(config: ProviderConfig, usage: UsageData) async -> UsageData? {
        let captured = await consumeAll(config: config, usages: [usage])
        return captured.first
    }

    // MARK: - Parity: flag off vs flag on

    func test_parity_happyPath_flagOffEqualsFlagOn() async {
        let polled = makeUsage()

        FeatureFlags.useCursorAdapterOverride = false
        let off = await consumeOne(config: .cursor, usage: polled)
        XCTAssertNotNil(off, "Flag off: AppModel.usage must be set after poll")

        FeatureFlags.useCursorAdapterOverride = true
        let on = await consumeOne(config: .cursor, usage: polled)
        XCTAssertNotNil(on, "Flag on: AppModel.usage must be set after poll")

        XCTAssertEqual(off?.sessionPct, on?.sessionPct)
        XCTAssertEqual(off?.sessionResetMins, on?.sessionResetMins)
        XCTAssertEqual(off?.sessionEpoch, on?.sessionEpoch)
        XCTAssertEqual(off?.weeklyPct, on?.weeklyPct)
        XCTAssertEqual(off?.weeklyResetMins, on?.weeklyResetMins)
        XCTAssertEqual(off?.weeklyEpoch, on?.weeklyEpoch)
        XCTAssertEqual(off?.status, on?.status)
        XCTAssertEqual(off?.representativeClaim, on?.representativeClaim)
        XCTAssertEqual(off?.organizationID, on?.organizationID)
    }

    func test_parity_noOrganizationID_flagOffEqualsFlagOn() async {
        let polled = makeUsage(organizationID: nil)

        FeatureFlags.useCursorAdapterOverride = false
        let off = await consumeOne(config: .cursor, usage: polled)

        FeatureFlags.useCursorAdapterOverride = true
        let on = await consumeOne(config: .cursor, usage: polled)

        XCTAssertEqual(off?.organizationID, on?.organizationID)
        XCTAssertNil(off?.organizationID)
        XCTAssertNil(on?.organizationID)
    }

    func test_parity_limitedStatus_flagOffEqualsFlagOn() async {
        let polled = makeUsage(sessionPct: 100, sessionResetMins: 60, status: .limited)

        FeatureFlags.useCursorAdapterOverride = false
        let off = await consumeOne(config: .cursor, usage: polled)

        FeatureFlags.useCursorAdapterOverride = true
        let on = await consumeOne(config: .cursor, usage: polled)

        XCTAssertEqual(off?.status, .limited)
        XCTAssertEqual(on?.status, .limited)
    }

    func test_parity_notStartedStatus_flagOffEqualsFlagOn() async {
        let polled = makeUsage(sessionEpoch: 1_714_000_000, status: .notStarted)

        FeatureFlags.useCursorAdapterOverride = false
        let off = await consumeOne(config: .cursor, usage: polled)

        FeatureFlags.useCursorAdapterOverride = true
        let on = await consumeOne(config: .cursor, usage: polled)

        XCTAssertEqual(off?.status, .notStarted)
        XCTAssertEqual(on?.status, .notStarted)
    }

    func test_parity_boundaryReset_flagOffEqualsFlagOn() async {
        let polled = makeUsage(sessionPct: 73, sessionResetMins: 0)

        FeatureFlags.useCursorAdapterOverride = false
        let off = await consumeOne(config: .cursor, usage: polled)

        FeatureFlags.useCursorAdapterOverride = true
        let on = await consumeOne(config: .cursor, usage: polled)

        XCTAssertEqual(off?.sessionResetMins, 0)
        XCTAssertEqual(on?.sessionResetMins, 0)
    }

    // MARK: - Dedup invariant within an AppModel

    /// With the flag on, repeated polls of the same billing period
    /// must surface unique canonical event ids in the underlying
    /// adapter call. We can't observe the canonical event stream
    /// directly from AppModel (it doesn't expose it yet — F2 will),
    /// but we verify the strangler-fig invariant indirectly: each
    /// polled value lands on `.usage` exactly once and the values
    /// flow through in order.
    ///
    /// Operationally this means F2's orchestration store, when it
    /// subscribes to the canonical stream, will dedup correctly —
    /// no double-counting per poll.
    func test_dedup_sequenceAdvancesPerPoll_sameModelInstance() async {
        FeatureFlags.useCursorAdapterOverride = true
        defer { FeatureFlags.useCursorAdapterOverride = nil }

        // Three polls of the same billing period (same sessionEpoch)
        // but distinct sessionPct so we can identify each one in the
        // captured stream. The wire produces one canonical
        // .sessionStarted event per poll with sequence numbers 0, 1,
        // 2 — downstream consumers dedup on event id, no
        // double-counting.
        //
        // UsagePoller's shouldReplace(with:) filters on
        // (sessionEpoch, updatedAt); we bump updatedAt per poll so
        // each one passes the filter.
        let base = Date(timeIntervalSince1970: 1_715_000_000)
        let polled1 = makeUsage(sessionPct: 10, updatedAt: base)
        let polled2 = makeUsage(sessionPct: 20, updatedAt: base.addingTimeInterval(1))
        let polled3 = makeUsage(sessionPct: 30, updatedAt: base.addingTimeInterval(2))

        let captured = await consumeAll(
            config: .cursor,
            usages: [polled1, polled2, polled3]
        )
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured[0].sessionPct, 10)
        XCTAssertEqual(captured[1].sessionPct, 20)
        XCTAssertEqual(captured[2].sessionPct, 30)
    }

    /// A new billing period (different `sessionEpoch`) must reset the
    /// per-model sequence cursor. The adapter's event id space then
    /// restarts at 0 for the new period — F2 sees this as a new
    /// canonical session, exactly as Cursor's billing model intends.
    /// This test verifies the wire renders both periods correctly
    /// through `.usage`; the canonical-event id reset is verified at
    /// the bridge level in `F1dParityTests`.
    func test_dedup_periodEpochChange_doesNotCorruptRender() async {
        FeatureFlags.useCursorAdapterOverride = true
        defer { FeatureFlags.useCursorAdapterOverride = nil }

        let oldPeriod = makeUsage(sessionPct: 50, sessionEpoch: 1_715_999_999)
        let newPeriod = makeUsage(sessionPct: 0, sessionEpoch: 1_716_999_999)

        let captured = await consumeAll(
            config: .cursor,
            usages: [oldPeriod, newPeriod]
        )
        XCTAssertEqual(captured.count, 2, "Both period values must render through .usage")
        XCTAssertEqual(captured[0].sessionEpoch, 1_715_999_999)
        XCTAssertEqual(captured[0].sessionPct, 50)
        XCTAssertEqual(captured[1].sessionEpoch, 1_716_999_999)
        XCTAssertEqual(captured[1].sessionPct, 0)
    }

    // MARK: - Non-Cursor providers untouched

    /// The wire MUST only affect `config.id == "cursor"`. A Claude or
    /// Codex AppModel with the Cursor flag flipped on must render the
    /// polled UsageData unchanged — no accidental cross-provider
    /// routing.
    func test_nonCursorProvider_untouchedByFlag() async {
        FeatureFlags.useCursorAdapterOverride = true
        defer { FeatureFlags.useCursorAdapterOverride = nil }

        // Build a Claude-config AppModel with the Cursor stub source
        // (the stub doesn't care about the providerID — it just
        // returns whatever's queued). The wire branch checks
        // `config.id == "cursor"`, which is false for `.claude`.
        let polled = makeUsage(sessionPct: 77)
        let captured = await consumeOne(config: .claude, usage: polled)

        // Polled value should reach .usage unchanged. The Claude
        // consumer never went through the Cursor bridge.
        XCTAssertEqual(captured?.sessionPct, 77)
        XCTAssertEqual(captured?.sessionEpoch, polled.sessionEpoch)
    }

    // MARK: - Multi-account secondary gauges

    /// Secondary account columns call `forcePoll()` on appear; the model
    /// may not have been `start()`-ed yet (provider was off at add time,
    /// or boot replay registered the instance before the Usage tab opened).
    /// forcePoll must still land a non-nil `.usage` with a real reset timer.
    func test_forcePoll_withoutPriorStart_populatesUsage() async {
        let stub = StubCursorSource()
        stub.queued = [makeUsage(sessionPct: 33, sessionResetMins: 90)]
        let model = AppModel(
            config: .claude,
            source: stub,
            tokenProvider: StubTokenProvider()
        )

        var captured: UsageData?
        let expectation = XCTestExpectation(description: "usage landed")
        let token = model.$usage.compactMap { $0 }.sink { value in
            captured = value
            expectation.fulfill()
        }
        defer { token.cancel() }

        model.forcePoll()
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertEqual(captured?.sessionPct, 33)
        XCTAssertGreaterThan(captured?.sessionResetMins ?? 0, 0)
        let row = AppRuntime.makeTahoeRow(model: model, provider: .claude)
        XCTAssertNotEqual(row.sessionResetIn, "\u{2014}")
    }

    /// forcePoll consumes exactly once — the matching onEvent publish from
    /// the same tick must not double-fire into `consume(_:)`.
    func test_forcePoll_doesNotDoubleConsume() async {
        let stub = StubCursorSource()
        stub.queued = [makeUsage(sessionPct: 55, sessionResetMins: 120)]
        let model = AppModel(
            config: .claude,
            source: stub,
            tokenProvider: StubTokenProvider()
        )

        var captureCount = 0
        let expectation = XCTestExpectation(description: "single usage emission")
        let token = model.$usage.compactMap { $0 }.sink { _ in
            captureCount += 1
            if captureCount == 1 { expectation.fulfill() }
        }
        defer { token.cancel() }

        model.forcePoll()
        try? await Task.sleep(nanoseconds: 200_000_000)
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertEqual(captureCount, 1)
    }
}
