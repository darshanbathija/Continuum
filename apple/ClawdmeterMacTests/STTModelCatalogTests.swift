import XCTest
@testable import Clawdmeter

final class STTModelCatalogTests: XCTestCase {
    func testCatalogContainsExpectedModelsInSizeOrder() {
        let ids = STTModelCatalog.models.map(\.id)
        XCTAssertEqual(ids, ["tiny", "base", "small", "medium"])
    }

    func testModelLookupReturnsDescriptor() {
        let base = STTModelCatalog.model(forID: "base")
        XCTAssertEqual(base?.displayName, "Base")
        XCTAssertEqual(base?.whisperModelName, "base")
        XCTAssertEqual(base?.sizeLabel, "~74 MB")
    }

    func testModelLookupReturnsNilForUnknownID() {
        XCTAssertNil(STTModelCatalog.model(forID: "xlarge"))
    }

    func testVoiceModelsRootUsesContinuumVoiceModelsDirectory() {
        let appSupport = URL(fileURLWithPath: "/tmp/Continuum", isDirectory: true)
        let root = STTModelCatalog.voiceModelsRoot(appSupportDirectory: appSupport)
        XCTAssertEqual(root.lastPathComponent, STTModelCatalog.voiceModelsDirectoryName)
        XCTAssertTrue(root.path.hasSuffix("Continuum/VoiceModels"))
    }

    func testModelDirectoryUsesModelIDSubfolder() {
        let appSupport = URL(fileURLWithPath: "/tmp/Continuum", isDirectory: true)
        let directory = STTModelCatalog.modelDirectory(appSupportDirectory: appSupport, modelID: "small")
        XCTAssertTrue(directory.path.hasSuffix("VoiceModels/small"))
    }

    func testDefaultModelIDIsBase() {
        XCTAssertEqual(STTModelCatalog.defaultModelID, "base")
    }

    func testLargeDownloadWarningThresholdIs500MB() {
        XCTAssertEqual(STTModelCatalog.largeDownloadWarningBytes, 500_000_000)
        XCTAssertGreaterThanOrEqual(
            STTModelCatalog.model(forID: "medium")?.approximateBytes ?? 0,
            STTModelCatalog.largeDownloadWarningBytes
        )
    }
}
