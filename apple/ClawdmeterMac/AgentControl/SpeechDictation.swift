import Foundation
import Speech
import AVFoundation
import OSLog

private let dictationLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SpeechDictation")

/// G11: voice dictation for the agent composer. SFSpeechRecognizer (on-device
/// where supported) + AVAudioEngine for the microphone tap.
///
/// Lifecycle: `start()` requests permissions if needed, opens the mic, begins
/// streaming partial transcripts via `onTranscript`. `stop()` ends the
/// session and emits the final result.
@MainActor
public final class SpeechDictation: ObservableObject {

    public enum State: Equatable {
        case idle
        case requestingPermission
        case denied(reason: String)
        case unavailable(reason: String)
        case recording
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var partialTranscript: String = ""

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Fires with each interim transcript update. Hosts replace any text
    /// inserted by the previous fire — partial → final delivers strictly
    /// monotonic prefixes per session.
    public var onTranscript: ((String, Bool) -> Void)?

    public init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        if recognizer == nil {
            state = .unavailable(reason: "Speech recognizer unavailable for locale.")
        } else if recognizer?.isAvailable == false {
            state = .unavailable(reason: "Speech recognizer is offline. Try again later.")
        }
    }

    /// Toggle dictation. Returns the next state for the caller's UI to react.
    public func toggle() async {
        switch state {
        case .recording:
            stop()
        case .idle, .denied, .unavailable:
            await start()
        case .requestingPermission:
            break
        }
    }

    public func start() async {
        guard state != .recording, state != .requestingPermission else { return }
        state = .requestingPermission

        // Step 1: speech-recognition permission.
        let speechAuth = await Self.requestSpeechAuthorization()
        guard speechAuth == .authorized else {
            state = .denied(reason: "Speech recognition permission denied. Enable in System Settings → Privacy & Security.")
            return
        }

        // Step 2: microphone permission.
        let micAuth = await Self.requestMicrophoneAccess()
        guard micAuth else {
            state = .denied(reason: "Microphone permission denied. Enable in System Settings → Privacy & Security.")
            return
        }

        // Step 3: spin up the audio engine + recognition request.
        do {
            try beginCapture()
            state = .recording
        } catch {
            state = .unavailable(reason: "Could not start audio capture: \(error.localizedDescription)")
            dictationLogger.error("beginCapture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        guard state == .recording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        state = .idle
    }

    // MARK: - Implementation

    private func beginCapture() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "SpeechDictation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Recognizer unavailable"]
            )
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            // Prefer on-device when supported — quieter privacy story.
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    self.onTranscript?(text, result.isFinal)
                }
                if let error {
                    dictationLogger.warning("Recognition error: \(error.localizedDescription, privacy: .public)")
                    self.stop()
                }
            }
        }
    }

    // MARK: - Permissions

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
