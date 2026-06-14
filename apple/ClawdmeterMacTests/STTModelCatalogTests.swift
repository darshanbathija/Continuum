import ClawdmeterShared
import XCTest
@testable import Clawdmeter

final class STTModelCatalogTests: XCTestCase {
    func testCatalogIncludesWhisperAndParakeetEngines() {
        let whisperIDs = STTModelCatalog.models(for: .whisperKit).map(\.id)
        // The original four plus the larger / distilled variants.
        XCTAssertTrue(whisperIDs.starts(with: ["tiny", "base", "small", "medium"]))
        XCTAssertTrue(whisperIDs.contains("large-v3-turbo"))
        XCTAssertTrue(whisperIDs.contains("large-v3"))
        XCTAssertTrue(whisperIDs.contains("distil-large-v3"))

        let parakeetIDs = STTModelCatalog.models(for: .parakeet).map(\.id)
        XCTAssertEqual(parakeetIDs, ["parakeet-v3", "parakeet-v2"])
    }

    func testAppleSpeechLeadsTheUnifiedModelList() {
        // The picker abstracts the engine away: Apple Speech is the first
        // selectable model so it reads as the default the moment settings open.
        XCTAssertEqual(STTModelCatalog.models.first?.id, STTModelCatalog.appleSpeechModelID)
        XCTAssertEqual(STTModelCatalog.appleSpeech.engine, .appleSpeech)
        XCTAssertEqual(STTModelCatalog.model(forID: STTModelCatalog.appleSpeechModelID)?.engine, .appleSpeech)
        // Apple Speech is the built-in; it must not appear in the downloadables.
        XCTAssertFalse(STTModelCatalog.downloadableModels.contains { $0.engine == .appleSpeech })
    }

    func testActiveModelIDFollowsTheEngine() {
        // Fresh defaults (engine = Apple Speech, whisperModelID = "base") must
        // resolve to Apple Speech, not "base".
        XCTAssertEqual(
            STTModelCatalog.activeModelID(for: VoicePresentationPreferences()),
            STTModelCatalog.appleSpeechModelID
        )
        var local = VoicePresentationPreferences()
        local.sttEngine = .whisperKit
        local.whisperModelID = "small"
        XCTAssertEqual(STTModelCatalog.activeModelID(for: local), "small")
    }

    func testEveryDownloadableModelDeclaresItsEngine() {
        for model in STTModelCatalog.downloadableModels {
            if model.engine == .parakeet {
                XCTAssertNotNil(model.parakeetVersionKey)
                XCTAssertTrue(model.whisperModelName.isEmpty)
                XCTAssertTrue(model.requiresAppleSilicon)
            } else {
                XCTAssertEqual(model.engine, .whisperKit)
                XCTAssertFalse(model.whisperModelName.isEmpty)
                XCTAssertNil(model.parakeetVersionKey)
            }
        }
    }

    func testTradeoffRatingsAreInRange() {
        for model in STTModelCatalog.models {
            XCTAssertTrue((1...5).contains(model.quality), "\(model.id) quality out of range")
            XCTAssertTrue((1...5).contains(model.speed), "\(model.id) speed out of range")
            XCTAssertFalse(model.tagline.isEmpty, "\(model.id) missing tagline")
        }
    }

    func testModelLookupReturnsDescriptor() {
        let base = STTModelCatalog.model(forID: "base")
        XCTAssertEqual(base?.displayName, "Base")
        XCTAssertEqual(base?.whisperModelName, "base")
        XCTAssertEqual(base?.sizeLabel, "~74 MB")
        XCTAssertEqual(base?.engine, .whisperKit)
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
