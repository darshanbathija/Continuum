import XCTest
@testable import ClawdmeterShared

final class UsageDataTests: XCTestCase {

    private func make(
        session: Int = 50,
        weekly: Int = 25,
        sessionEpoch: Int = 1_778_756_400,
        weeklyEpoch: Int = 1_779_238_800,
        updatedAt: Date = Date(timeIntervalSince1970: 1_778_744_430)
    ) -> UsageData {
        UsageData(
            sessionPct: session,
            sessionResetMins: 60,
            sessionEpoch: sessionEpoch,
            weeklyPct: weekly,
            weeklyResetMins: 600,
            weeklyEpoch: weeklyEpoch,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: updatedAt
        )
    }

    func test_codableRoundTrip() throws {
        let original = make()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageData.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_cursorQuota_codableRoundTrip() throws {
        let original = UsageData(
            sessionPct: 48,
            sessionResetMins: 26_400,
            sessionEpoch: 1_782_259_911,
            weeklyPct: 48,
            weeklyResetMins: 26_400,
            weeklyEpoch: 1_782_259_911,
            status: .allowed,
            representativeClaim: .unknown,
            updatedAt: Date(timeIntervalSince1970: 1_779_582_000),
            organizationID: "400 included / period",
            cursorQuota: UsageData.CursorQuota(
                totalPct: 48,
                autoPct: 25,
                apiPct: 95,
                resetMins: 26_400,
                resetEpoch: 1_782_259_911,
                includedUsageLabel: "400 included / period",
                extraUsageLabel: "Free extra usage may vary."
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageData.self, from: data)
        XCTAssertEqual(decoded.cursorQuota?.totalPct, 48)
        XCTAssertEqual(decoded.cursorQuota?.autoPct, 25)
        XCTAssertEqual(decoded.cursorQuota?.apiPct, 95)
        XCTAssertEqual(decoded.cursorQuota?.extraUsageLabel, "Free extra usage may vary.")
        XCTAssertEqual(original, decoded)
    }

    func test_moodMapping() {
        XCTAssertEqual(make(session: 0).mood, .idle)
        XCTAssertEqual(make(session: 29).mood, .idle)
        XCTAssertEqual(make(session: 30).mood, .active)
        XCTAssertEqual(make(session: 74).mood, .active)
        XCTAssertEqual(make(session: 75).mood, .redLine)
        XCTAssertEqual(make(session: 100).mood, .redLine)
    }

    func test_isStale_thresholdDefault90s() {
        let snapshot = make(updatedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertFalse(snapshot.isStale(referenceTime: Date(timeIntervalSince1970: 1089)))
        XCTAssertTrue(snapshot.isStale(referenceTime: Date(timeIntervalSince1970: 1091)))
    }

    // Plan E3 + E14: ordering uses (epoch, updatedAt)

    func test_shouldReplace_newerEpochAlwaysWins_evenWithOlderUpdatedAt() {
        // Stale-pre-reset: older epoch but newer updatedAt
        let stalePre = make(sessionEpoch: 1000, updatedAt: Date(timeIntervalSince1970: 2000))
        // Fresh-post-reset: newer epoch but slightly older updatedAt (clock drift simulation)
        let freshPost = make(sessionEpoch: 2000, updatedAt: Date(timeIntervalSince1970: 1999))

        XCTAssertTrue(stalePre.shouldReplace(with: freshPost),
                      "Newer session epoch must always win regardless of updatedAt drift")
    }

    func test_shouldReplace_sameEpoch_newerUpdatedAtWins() {
        let earlier = make(sessionEpoch: 1000, updatedAt: Date(timeIntervalSince1970: 1500))
        let later = make(sessionEpoch: 1000, updatedAt: Date(timeIntervalSince1970: 1600))
        XCTAssertTrue(earlier.shouldReplace(with: later))
        XCTAssertFalse(later.shouldReplace(with: earlier))
    }

    func test_shouldReplace_olderEpochNeverReplacesNewerEpoch() {
        let newer = make(sessionEpoch: 2000, updatedAt: Date(timeIntervalSince1970: 1000))
        let older = make(sessionEpoch: 1000, updatedAt: Date(timeIntervalSince1970: 5000))
        XCTAssertFalse(newer.shouldReplace(with: older))
    }
}
