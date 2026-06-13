import ClawdmeterShared
import XCTest
@testable import Clawdmeter

@MainActor
final class STTTranscriberFactoryTests: XCTestCase {
    func testUsesAppleSpeechByDefault() {
        let transcriber = STTTranscriberFactory.makeTranscriber(
            preferences: VoicePresentationPreferences(),
            appSupportDirectory: temporaryAppSupportDirectory()
        )
        XCTAssertTrue(transcriber is AppleSpeechTranscriber)
    }

    func testFallsBackToAppleSpeechWhenWhisperModelMissing() {
        var preferences = VoicePresentationPreferences()
        preferences.sttEngine = .whisperKit
        preferences.whisperModelID = "base"

        let transcriber = STTTranscriberFactory.makeTranscriber(
            preferences: preferences,
            appSupportDirectory: temporaryAppSupportDirectory()
        )
        XCTAssertTrue(transcriber is AppleSpeechTranscriber)
    }

    func testFallsBackToAppleSpeechForUnknownWhisperModelID() {
        var preferences = VoicePresentationPreferences()
        preferences.sttEngine = .whisperKit
        preferences.whisperModelID = "unknown-model"

        let transcriber = STTTranscriberFactory.makeTranscriber(
            preferences: preferences,
            appSupportDirectory: temporaryAppSupportDirectory()
        )
        XCTAssertTrue(transcriber is AppleSpeechTranscriber)
    }

    private func temporaryAppSupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuumVoiceTests-\(UUID().uuidString)", isDirectory: true)
    }
}
