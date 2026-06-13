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

    func testFallsBackToAppleSpeechWhenParakeetModelMissing() {
        var preferences = VoicePresentationPreferences()
        preferences.sttEngine = .parakeet
        preferences.whisperModelID = "parakeet-v3"

        let transcriber = STTTranscriberFactory.makeTranscriber(
            preferences: preferences,
            appSupportDirectory: temporaryAppSupportDirectory()
        )
        XCTAssertTrue(transcriber is AppleSpeechTranscriber)
    }

    func testFallsBackToAppleSpeechWhenParakeetIDPointsAtWhisperModel() {
        var preferences = VoicePresentationPreferences()
        preferences.sttEngine = .parakeet
        preferences.whisperModelID = "base" // a Whisper model under the Parakeet engine

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
