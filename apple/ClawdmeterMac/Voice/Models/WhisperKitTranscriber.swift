import AVFoundation
import Combine
import Foundation
import WhisperKit

@MainActor
public final class WhisperKitTranscriber: STTTranscribing {
    private let modelID: String
    private let appSupportDirectory: URL
    private let languageCode: String?

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var latestTranscript = ""
    private var partialSubject = CurrentValueSubject<String, Never>("")
    private var audioLevelSubject = CurrentValueSubject<Float, Never>(0)
    private var recording = false

    public var partialTranscriptPublisher: AnyPublisher<String, Never> {
        partialSubject.eraseToAnyPublisher()
    }

    public var audioLevelPublisher: AnyPublisher<Float, Never> {
        audioLevelSubject.eraseToAnyPublisher()
    }

    public var isRecording: Bool {
        recording
    }

    public init(
        modelID: String,
        appSupportDirectory: URL,
        languageCode: String? = nil
    ) {
        self.modelID = modelID
        self.appSupportDirectory = appSupportDirectory
        self.languageCode = languageCode
    }

    public func start(locale: Locale) async throws {
        guard !recording else { return }
        guard let descriptor = STTModelCatalog.model(forID: modelID) else {
            throw WhisperKitTranscriberError.unknownModel(modelID)
        }

        let modelDirectory = STTModelCatalog.modelDirectory(
            appSupportDirectory: appSupportDirectory,
            modelID: modelID
        )
        guard STTModelCatalog.isModelInstalled(at: modelDirectory) else {
            throw WhisperKitTranscriberError.modelNotInstalled(modelID)
        }

        let micGranted = await Self.requestMicrophoneAccess()
        guard micGranted else {
            throw WhisperKitTranscriberError.microphoneDenied
        }

        partialSubject.send("")
        audioLevelSubject.send(0)
        latestTranscript = ""

        let resolvedLanguage = languageCode ?? Self.whisperLanguageCode(from: locale)
        var decodingOptions = DecodingOptions()
        if let resolvedLanguage {
            decodingOptions.language = resolvedLanguage
            decodingOptions.detectLanguage = false
        } else {
            decodingOptions.detectLanguage = true
        }

        let config = WhisperKitConfig(
            model: descriptor.whisperModelName,
            downloadBase: STTModelCatalog.voiceModelsRoot(appSupportDirectory: appSupportDirectory),
            modelFolder: modelDirectory.path,
            load: true,
            download: false
        )

        let whisperKit = try await WhisperKit(config)
        guard let tokenizer = whisperKit.tokenizer else {
            throw WhisperKitTranscriberError.tokenizerUnavailable
        }

        let streamTranscriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: decodingOptions
        ) { [weak self] _, newState in
            Task { @MainActor in
                self?.handleStreamState(newState)
            }
        }

        self.whisperKit = whisperKit
        self.streamTranscriber = streamTranscriber

        try await streamTranscriber.startStreamTranscription()
        recording = true
    }

    public func stop() async -> String {
        guard recording else { return "" }
        await streamTranscriber?.stopStreamTranscription()
        let transcript = latestTranscript
        cleanupSession()
        return transcript
    }

    public func cancel() {
        guard recording else { return }
        Task {
            await streamTranscriber?.stopStreamTranscription()
            await MainActor.run {
                cleanupSession()
            }
        }
    }

    private func handleStreamState(_ state: AudioStreamTranscriber.State) {
        latestTranscript = Self.transcript(from: state)
        partialSubject.send(latestTranscript)
        let level = state.bufferEnergy.last ?? 0
        audioLevelSubject.send(min(max(level, 0), 1))
    }

    private func cleanupSession() {
        recording = false
        streamTranscriber = nil
        whisperKit = nil
        latestTranscript = ""
        partialSubject.send("")
        audioLevelSubject.send(0)
    }

    private static func transcript(from state: AudioStreamTranscriber.State) -> String {
        var parts: [String] = state.confirmedSegments.map(\.text)
        parts.append(contentsOf: state.unconfirmedSegments.map(\.text))
        if !state.currentText.isEmpty, state.currentText != "Waiting for speech..." {
            parts.append(state.currentText)
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func whisperLanguageCode(from locale: Locale) -> String? {
        locale.language.languageCode?.identifier
    }

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

public enum WhisperKitTranscriberError: LocalizedError {
    case unknownModel(String)
    case modelNotInstalled(String)
    case microphoneDenied
    case tokenizerUnavailable

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let modelID):
            return "Unknown Whisper model \"\(modelID)\"."
        case .modelNotInstalled(let modelID):
            return "Whisper model \"\(modelID)\" is not downloaded."
        case .microphoneDenied:
            return "Microphone permission denied. Enable in System Settings → Privacy & Security."
        case .tokenizerUnavailable:
            return "Whisper tokenizer could not be loaded."
        }
    }
}
