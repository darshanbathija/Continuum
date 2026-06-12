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

    func testResolvedModelDirectoryFindsNestedWhisperKitDownload() throws {
        let root = temporaryAppSupportDirectory()
            .appendingPathComponent("VoiceModels/base", isDirectory: true)
        let nested = root
            .appendingPathComponent("models/openai_whisper-base", isDirectory: true)
        try createWhisperModelArtifacts(in: nested)

        XCTAssertEqual(
            STTModelCatalog.resolvedModelDirectory(in: root)?.resolvingSymlinksInPath().path,
            nested.resolvingSymlinksInPath().path
        )
        XCTAssertTrue(STTModelCatalog.isModelInstalled(at: root))
    }

    func testResolvedModelDirectoryRejectsIncompleteDownload() throws {
        let root = temporaryAppSupportDirectory()
            .appendingPathComponent("VoiceModels/base", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("models/openai_whisper-base", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertNil(STTModelCatalog.resolvedModelDirectory(in: root))
        XCTAssertFalse(STTModelCatalog.isModelInstalled(at: root))
    }

    private func temporaryAppSupportDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuumDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createWhisperModelArtifacts(in directory: URL) throws {
        for name in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
