import XCTest
@testable import Clawdmeter

@MainActor
final class STTModelDownloadManagerTests: XCTestCase {
    func testCancelDownloadWithoutActiveTaskIsNoOp() {
        let manager = STTModelDownloadManager(appSupportDirectory: temporaryAppSupportDirectory())
        manager.cancelDownload()
        XCTAssertEqual(manager.downloadState, .idle)
        XCTAssertNil(manager.resumableModelID)
        XCTAssertFalse(manager.canResumeDownload(for: "base"))
    }

    private func temporaryAppSupportDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuumDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
