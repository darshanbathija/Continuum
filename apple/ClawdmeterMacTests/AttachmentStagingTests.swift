import XCTest
@testable import Clawdmeter

final class AttachmentStagingTests: XCTestCase {

    func test_cleanupPendingStagingDirRemovesPendingChild() throws {
        let dir = try AttachmentStaging.makePendingStagingDir()
        let file = dir.appendingPathComponent("probe.txt")
        try "probe".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        AttachmentStaging.cleanupPendingStagingDir(dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
