import ClawdmeterShared
import FluidAudio
import Foundation

@MainActor
public enum STTTranscriberFactory {
    public static func makeTranscriber(
        preferences: VoicePresentationPreferences,
        appSupportDirectory: URL
    ) -> STTTranscribing {
        let locale = locale(from: preferences)

        switch preferences.sttEngine {
        case .appleSpeech:
            return AppleSpeechTranscriber(locale: locale)
        case .whisperKit:
            guard let descriptor = STTModelCatalog.model(forID: preferences.whisperModelID),
                  descriptor.engine == .whisperKit else {
                return AppleSpeechTranscriber(locale: locale)
            }
            let modelDirectory = STTModelCatalog.modelDirectory(
                appSupportDirectory: appSupportDirectory,
                modelID: preferences.whisperModelID
            )
            guard STTModelCatalog.isModelInstalled(at: modelDirectory) else {
                return AppleSpeechTranscriber(locale: locale)
            }
            return WhisperKitTranscriber(
                modelID: preferences.whisperModelID,
                appSupportDirectory: appSupportDirectory,
                languageCode: whisperLanguageCode(from: preferences)
            )
        case .parakeet:
            guard let descriptor = STTModelCatalog.model(forID: preferences.whisperModelID),
                  descriptor.engine == .parakeet,
                  STTModelCatalog.isSupportedOnThisDevice(descriptor) else {
                return AppleSpeechTranscriber(locale: locale)
            }
            let version = STTModelDownloadManager.parakeetVersion(forKey: descriptor.parakeetVersionKey)
            let modelDirectory = STTModelCatalog.modelDirectory(
                appSupportDirectory: appSupportDirectory,
                modelID: preferences.whisperModelID
            )
            guard AsrModels.modelsExist(at: modelDirectory, version: version) else {
                return AppleSpeechTranscriber(locale: locale)
            }
            return ParakeetTranscriber(
                modelID: preferences.whisperModelID,
                appSupportDirectory: appSupportDirectory
            )
        }
    }

    private static func locale(from preferences: VoicePresentationPreferences) -> Locale {
        if let identifier = preferences.recognitionLocaleIdentifier {
            return Locale(identifier: identifier)
        }
        return .current
    }

    private static func whisperLanguageCode(from preferences: VoicePresentationPreferences) -> String? {
        guard let identifier = preferences.recognitionLocaleIdentifier else { return nil }
        return Locale(identifier: identifier).language.languageCode?.identifier
    }
}
