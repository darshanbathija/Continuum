import XCTest
@testable import ClawdmeterShared

final class VoicePresentationPreferencesTests: XCTestCase {
    func testDefaultsMatchProductDecisions() {
        let preferences = VoicePresentationPreferences()
        XCTAssertFalse(preferences.systemWideDictationEnabled)
        XCTAssertTrue(preferences.allowControlMShortcut)
        XCTAssertEqual(preferences.sttEngine, .appleSpeech)
        XCTAssertEqual(preferences.whisperModelID, "base")
        XCTAssertEqual(preferences.fnGestureMode, .doubleTapOnly)
        XCTAssertNil(preferences.recognitionLocaleIdentifier)
    }

    func testDecodesLegacyPayloadWithDefaults() throws {
        let data = Data(
            #"{"systemWideDictationEnabled":true,"allowControlMShortcut":false}"#.utf8
        )
        let decoded = try JSONDecoder().decode(VoicePresentationPreferences.self, from: data)

        XCTAssertTrue(decoded.systemWideDictationEnabled)
        XCTAssertFalse(decoded.allowControlMShortcut)
        XCTAssertEqual(decoded.sttEngine, .appleSpeech)
        XCTAssertEqual(decoded.whisperModelID, "base")
        XCTAssertEqual(decoded.fnGestureMode, .doubleTapOnly)
        XCTAssertNil(decoded.recognitionLocaleIdentifier)
    }

    func testRoundTripsWhisperKitPreferences() throws {
        let original = VoicePresentationPreferences(
            systemWideDictationEnabled: true,
            allowControlMShortcut: true,
            sttEngine: .whisperKit,
            whisperModelID: "small",
            fnGestureMode: .doubleTapOnly,
            recognitionLocaleIdentifier: "en_US"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VoicePresentationPreferences.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSTTEngineRawValuesAreStable() {
        XCTAssertEqual(STTEngine.appleSpeech.rawValue, "appleSpeech")
        XCTAssertEqual(STTEngine.whisperKit.rawValue, "whisperKit")
    }

    func testFnGestureModeRawValueIsStable() {
        XCTAssertEqual(FnGestureMode.doubleTapOnly.rawValue, "doubleTapOnly")
    }

    func testSpeechRecognitionLocaleCatalogIncludesSystemDefault() {
        let options = SpeechRecognitionLocaleCatalog.options(systemLocale: Locale(identifier: "en_US"))
        XCTAssertEqual(options.first?.identifier, nil)
        XCTAssertTrue(options.first?.label.contains("System default") == true)
        XCTAssertTrue(options.contains(where: { $0.identifier == "en_GB" }))
    }
}
