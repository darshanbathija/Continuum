import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Covers the reaper's file I/O + reset behavior with a temp pidfile (no real
/// processes are signalled — the pure kill decision is covered in
/// HarnessOrphanReaperTests). Uses dedicated instances, never the production
/// `.shared` singleton or the real ~/.clawdmeter file.
@MainActor
final class HarnessProcessReaperTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reaper-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func test_recordThenRemove_persistsToFile() throws {
        let reaper = HarnessProcessReaper(fileURL: tmp, ownerPid: 12345)
        let s1 = UUID(); let s2 = UUID()
        reaper.record(sessionId: s1, pid: 111, binary: "codex")
        reaper.record(sessionId: s2, pid: 222, binary: "grok")

        var list = try decodeFile()
        XCTAssertEqual(Set(list.map(\.sessionId)), [s1, s2])
        XCTAssertEqual(list.first(where: { $0.sessionId == s1 })?.ownerPid, 12345)
        XCTAssertEqual(list.first(where: { $0.sessionId == s2 })?.binary, "grok")

        reaper.remove(sessionId: s1)
        list = try decodeFile()
        XCTAssertEqual(list.map(\.sessionId), [s2])
    }

    func test_reapOrphans_resetsThePidFile() throws {
        // Seed a record for pid 1 (launchd): owned by root, so kill(1,0) is EPERM
        // → processAlive == false → it is skipped (never signalled). reapOrphans
        // must still reset the file to this daemon's empty state.
        let seed = HarnessProcessReaper(fileURL: tmp, ownerPid: 999_999)
        seed.record(sessionId: UUID(), pid: 1, binary: "codex")
        XCTAssertEqual(try decodeFile().count, 1)

        let reaper = HarnessProcessReaper(fileURL: tmp, ownerPid: 888_888)
        reaper.reapOrphans()
        XCTAssertTrue(try decodeFile().isEmpty,
                      "reapOrphans must reset the pidfile to this daemon's empty state")
    }

    private func decodeFile() throws -> [HarnessPidRecord] {
        let data = try Data(contentsOf: tmp)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode([HarnessPidRecord].self, from: data)
    }
}
