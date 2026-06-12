import Combine
import Foundation

@MainActor
public protocol STTTranscribing: AnyObject {
    var partialTranscriptPublisher: AnyPublisher<String, Never> { get }
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }
    var isRecording: Bool { get }
    func start(locale: Locale) async throws
    func stop() async -> String
    func cancel()
}

@MainActor
public final class AppleSpeechTranscriber: STTTranscribing {
    private let engine: SpeechDictation
    private var partialSubject = CurrentValueSubject<String, Never>("")
    private var audioLevelSubject = CurrentValueSubject<Float, Never>(0)

    public var partialTranscriptPublisher: AnyPublisher<String, Never> {
        partialSubject.eraseToAnyPublisher()
    }

    public var audioLevelPublisher: AnyPublisher<Float, Never> {
        audioLevelSubject.eraseToAnyPublisher()
    }

    public var isRecording: Bool {
        if case .recording = engine.state { return true }
        return false
    }

    public init(locale: Locale = .current) {
        self.engine = SpeechDictation(locale: locale)
        engine.onTranscript = { [weak self] text, _ in
            Task { @MainActor in
                self?.partialSubject.send(text)
            }
        }
        engine.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.audioLevelSubject.send(level)
            }
        }
    }

    public func start(locale: Locale) async throws {
        partialSubject.send("")
        await engine.start()
        switch engine.state {
        case .recording:
            return
        case .denied(let reason):
            throw NSError(domain: "AppleSpeechTranscriber", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        case .unavailable(let reason):
            throw NSError(domain: "AppleSpeechTranscriber", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
        default:
            throw NSError(domain: "AppleSpeechTranscriber", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not start dictation."])
        }
    }

    public func stop() async -> String {
        let finalText = engine.partialTranscript
        engine.stop()
        partialSubject.send("")
        audioLevelSubject.send(0)
        return finalText
    }

    public func cancel() {
        engine.stop()
        partialSubject.send("")
        audioLevelSubject.send(0)
    }
}
