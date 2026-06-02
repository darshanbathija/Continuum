import XCTest
@testable import ClawdmeterShared

/// The reaper kills processes, so its decision is unit-locked here: it must only
/// reap a recorded child when the spawning daemon is gone AND the live pid still
/// runs the recorded binary (PID-reuse fail-safe).
final class HarnessOrphanReaperTests: XCTestCase {

    private func rec(_ binary: String, owner: Int32 = 999_999) -> HarnessPidRecord {
        HarnessPidRecord(
            sessionId: UUID(), pid: 4242, binary: binary,
            ownerPid: owner, startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func test_reaps_whenOwnerDead_andCommMatches() {
        XCTAssertTrue(HarnessOrphanReaper.shouldReap(
            record: rec("codex"), liveComm: "/opt/homebrew/bin/codex", ownerAlive: false))
        XCTAssertTrue(HarnessOrphanReaper.shouldReap(
            record: rec("cursor-agent"), liveComm: "cursor-agent", ownerAlive: false))
        XCTAssertTrue(HarnessOrphanReaper.shouldReap(
            record: rec("grok"), liveComm: "/usr/local/bin/grok", ownerAlive: false))
    }

    func test_spares_whenOwnerAlive() {
        // A live daemon (second instance / test host) still owns its children.
        XCTAssertFalse(HarnessOrphanReaper.shouldReap(
            record: rec("codex"), liveComm: "/opt/homebrew/bin/codex", ownerAlive: true))
    }

    func test_spares_whenPidDead() {
        XCTAssertFalse(HarnessOrphanReaper.shouldReap(
            record: rec("codex"), liveComm: nil, ownerAlive: false))
        XCTAssertFalse(HarnessOrphanReaper.shouldReap(
            record: rec("codex"), liveComm: "", ownerAlive: false))
    }

    func test_spares_onPidReuse_differentBinary() {
        // The recorded pid was recycled into an unrelated process → spared.
        XCTAssertFalse(HarnessOrphanReaper.shouldReap(
            record: rec("grok"), liveComm: "/Applications/Safari.app/Contents/MacOS/Safari", ownerAlive: false))
        XCTAssertFalse(HarnessOrphanReaper.shouldReap(
            record: rec("codex"), liveComm: "/sbin/launchd", ownerAlive: false))
    }

    func test_truncatedComm_matchesByPrefix() {
        // BSD `comm` can truncate; a prefix relationship still counts.
        XCTAssertTrue(HarnessOrphanReaper.shouldReap(
            record: rec("codex-app-server-helper"), liveComm: "codex-app-server", ownerAlive: false))
    }

    func test_record_roundTripsCodable() throws {
        let r = rec("grok")
        let data = try JSONEncoder().encode([r])
        let back = try JSONDecoder().decode([HarnessPidRecord].self, from: data)
        XCTAssertEqual(back, [r])
    }
}
