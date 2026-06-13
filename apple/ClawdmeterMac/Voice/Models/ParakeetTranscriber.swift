import AVFoundation
import Combine
import FluidAudio
import Foundation

/// Local dictation backed by NVIDIA Parakeet TDT (FluidAudio CoreML, Apple
/// Neural Engine). FluidAudio's batch `transcribe` is so fast (~190x realtime
/// on M-series) that we drive live partials by periodically re-transcribing the
/// growing mic buffer rather than wiring its lower-level streaming actor — far
/// less surface, and inaudible cost for dictation-length utterances.
@MainActor
public final class ParakeetTranscriber: STTTranscribing {
    private let modelID: String
    private let appSupportDirectory: URL

    private let audioEngine = AVAudioEngine()
    private var asrManager: AsrManager?
    private var samples: [Float] = []
    private var partialTask: Task<Void, Never>?
    private var transcribing = false
    private var recording = false

    private var partialSubject = CurrentValueSubject<String, Never>("")
    private var audioLevelSubject = CurrentValueSubject<Float, Never>(0)
    private var latestTranscript = ""

    public var partialTranscriptPublisher: AnyPublisher<String, Never> {
        partialSubject.eraseToAnyPublisher()
    }

    public var audioLevelPublisher: AnyPublisher<Float, Never> {
        audioLevelSubject.eraseToAnyPublisher()
    }

    public var isRecording: Bool { recording }

    public init(modelID: String, appSupportDirectory: URL) {
        self.modelID = modelID
        self.appSupportDirectory = appSupportDirectory
    }

    public func start(locale: Locale) async throws {
        guard !recording else { return }
        guard let descriptor = STTModelCatalog.model(forID: modelID),
              descriptor.engine == .parakeet else {
            throw ParakeetTranscriberError.unknownModel(modelID)
        }

        let modelDirectory = STTModelCatalog.modelDirectory(
            appSupportDirectory: appSupportDirectory,
            modelID: modelID
        )
        let version = STTModelDownloadManager.parakeetVersion(forKey: descriptor.parakeetVersionKey)
        guard AsrModels.modelsExist(at: modelDirectory, version: version) else {
            throw ParakeetTranscriberError.modelNotInstalled(modelID)
        }

        let micGranted = await Self.requestMicrophoneAccess()
        guard micGranted else { throw ParakeetTranscriberError.microphoneDenied }

        // Models are already on disk — downloadAndLoad finds them and only loads.
        let models = try await AsrModels.downloadAndLoad(to: modelDirectory, version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager

        partialSubject.send("")
        audioLevelSubject.send(0)
        latestTranscript = ""
        samples = []

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Each tap fires on a realtime audio thread. Convert with a captured
        // (thread-local) converter and hop to the main actor with only the
        // resulting 16kHz mono Float32 samples — never touch isolated state here.
        let tapConverter = AudioConverter()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let chunk = try? tapConverter.resampleBuffer(buffer), !chunk.isEmpty else { return }
            let level = Self.rms(chunk)
            Task { @MainActor [weak self] in
                guard let self, self.recording else { return }
                self.samples.append(contentsOf: chunk)
                self.audioLevelSubject.send(level)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        recording = true
        startPartialLoop()
    }

    public func stop() async -> String {
        guard recording else { return "" }
        teardownAudio()
        let transcript = await transcribeFinal()
        if let manager = asrManager { await manager.cleanup() }
        asrManager = nil
        resetState()
        return transcript
    }

    public func cancel() {
        guard recording else { return }
        teardownAudio()
        let manager = asrManager
        asrManager = nil
        resetState()
        if let manager { Task { await manager.cleanup() } }
    }

    // MARK: - Capture

    private func startPartialLoop() {
        partialTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, self.recording else { return }
                await self.transcribePartial()
            }
        }
    }

    private func transcribePartial() async {
        guard !transcribing, !samples.isEmpty, let manager = asrManager else { return }
        transcribing = true
        defer { transcribing = false }
        if let text = await transcribe(samples: samples, manager: manager), !text.isEmpty {
            latestTranscript = text
            partialSubject.send(text)
        }
    }

    private func transcribeFinal() async -> String {
        guard !samples.isEmpty, let manager = asrManager else { return latestTranscript }
        if let text = await transcribe(samples: samples, manager: manager), !text.isEmpty {
            latestTranscript = text
        }
        return latestTranscript
    }

    private func transcribe(samples: [Float], manager: AsrManager) async -> String? {
        do {
            // Fresh decoder state each pass — we re-transcribe the whole buffer,
            // so state must not carry over between passes.
            let layers = await manager.decoderLayerCount
            var state = try TdtDecoderState(decoderLayers: layers)
            let result = try await manager.transcribe(samples, decoderState: &state)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Teardown

    private func teardownAudio() {
        partialTask?.cancel()
        partialTask = nil
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        recording = false
    }

    private func resetState() {
        samples = []
        latestTranscript = ""
        partialSubject.send("")
        audioLevelSubject.send(0)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let mean = sumSquares / Float(samples.count)
        return min(max(mean.squareRoot() * 4, 0), 1)
    }

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

public enum ParakeetTranscriberError: LocalizedError {
    case unknownModel(String)
    case modelNotInstalled(String)
    case microphoneDenied

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let modelID):
            return "Unknown Parakeet model \"\(modelID)\"."
        case .modelNotInstalled(let modelID):
            return "Parakeet model \"\(modelID)\" is not downloaded."
        case .microphoneDenied:
            return "Microphone permission denied. Enable in System Settings → Privacy & Security."
        }
    }
}
