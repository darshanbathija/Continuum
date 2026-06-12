import AppKit
import ClawdmeterShared
import Combine
import Foundation

@MainActor
public protocol GlobalDictationContextProviding: AnyObject {
    var continuumBundleID: String { get }
    var appSupportDirectory: URL { get }
    func voicePreferences() -> VoicePresentationPreferences
    func resolveComposerTarget() -> DictationRouteResolution
    func prepareComposerRoute(for target: DictationComposerTarget)
    func applyComposerText(_ text: String, target: DictationComposerTarget, phase: GlobalDictationNotification.Phase)
    func showInfoToast(title: String, detail: String?)
    func showFailureToast(title: String, detail: String?)
}

/// Orchestrates Fn double-tap dictation for in-app composers and system-wide paste.
@MainActor
public final class GlobalDictationCoordinator: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case ready
        case recording
        case processing
        case success
        case error(String)
    }

    private enum SessionScope: Equatable {
        case composer(DictationComposerTarget)
        case externalPaste
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var isFnListenerActive: Bool = false
    @Published public private(set) var partialTranscript: String = ""
    @Published public private(set) var audioLevel: Float = 0

    private weak var context: GlobalDictationContextProviding?
    private var transcriber: STTTranscribing?
    private let pasteService: AccessibilityPasteService
    private let hotkeyManager: GlobalHotkeyManager
    private let historyStore: DictationHistoryStore
    private var partialCancellable: AnyCancellable?
    private var audioLevelCancellable: AnyCancellable?
    private var sessionScope: SessionScope?
    private var composerBaseText: String = ""
    private var configuredGestureMode: FnGestureMode = .doubleTapOnly

    public init(
        pasteService: AccessibilityPasteService = AccessibilityPasteService(),
        hotkeyManager: GlobalHotkeyManager = GlobalHotkeyManager(),
        historyStore: DictationHistoryStore? = nil
    ) {
        self.pasteService = pasteService
        self.hotkeyManager = hotkeyManager
        self.historyStore = historyStore ?? DictationHistoryStore(
            appSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        )
        self.hotkeyManager.onGestureOutput = { [weak self] output in
            Task { @MainActor in
                await self?.handleGestureOutput(output)
            }
        }
    }

    public var dictationHistory: [DictationHistoryEntry] {
        historyStore.entries
    }

    public func bind(context: GlobalDictationContextProviding) {
        self.context = context
    }

    public func refreshHotkeyInstallation() {
        guard pasteService.isTrusted else {
            hotkeyManager.stop()
            isFnListenerActive = false
            _ = pasteService.requestTrust(prompt: false)
            return
        }

        let mode = context?.voicePreferences().fnGestureMode ?? .doubleTapOnly
        if mode != configuredGestureMode {
            hotkeyManager.configure(mode: mode)
            configuredGestureMode = mode
        }

        isFnListenerActive = hotkeyManager.start()
    }

    public func requestAccessibilityPermission() {
        _ = pasteService.requestTrust(prompt: true)
        refreshHotkeyInstallation()
    }

    public var isAccessibilityTrusted: Bool {
        pasteService.isTrusted
    }

    public func cancelActiveSession() {
        Task { @MainActor in
            await cancelRecording()
        }
    }

    /// Toggles dictation for the in-app composer path (⌃M, mic button, command palette).
    public func toggleComposerDictation() {
        Task { @MainActor in
            switch phase {
            case .recording:
                await stopRecording()
            case .ready:
                await cancelRecording()
            case .processing:
                break
            case .idle, .success, .error:
                if case .error = phase {
                    phase = .idle
                }
                await startRecording()
            }
        }
    }

    private func handleGestureOutput(_ output: HotkeyGestureController.Output) async {
        switch output {
        case .startRecording:
            await startRecording()
        case .stopRecording:
            await stopRecording()
        case .cancelRecording:
            await cancelRecording()
        case .showReadyForSecondTap:
            showReadyForSecondTap()
        case .gestureTimedOut:
            dismissReadyOverlay()
        case .scheduleStartupDebounce, .scheduleHoldWindow, .cancelTimers:
            break
        }
    }

    private func showReadyForSecondTap() {
        guard phase == .idle else { return }
        phase = .ready
    }

    private func dismissReadyOverlay() {
        guard phase == .ready else { return }
        phase = .idle
    }

    private func makeTranscriber() throws -> STTTranscribing {
        guard let context else {
            throw NSError(domain: "GlobalDictationCoordinator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Dictation context unavailable.",
            ])
        }
        return STTTranscriberFactory.makeTranscriber(
            preferences: context.voicePreferences(),
            appSupportDirectory: context.appSupportDirectory
        )
    }

    private func startRecording() async {
        dismissReadyOverlay()
        guard phase == .idle || phase == .ready else { return }
        guard let context else { return }

        if DictationRouting.shared.globalSessionActive {
            await stopRecording()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isContinuumFocused = frontmost == context.continuumBundleID
        let systemWideEnabled = context.voicePreferences().systemWideDictationEnabled

        if isContinuumFocused {
            let resolution = context.resolveComposerTarget()
            switch resolution {
            case .unavailableReadOnlyChat:
                phase = .error("Dictation unavailable for archived transcripts")
                scheduleErrorDismiss()
                return
            case .route(let target):
                sessionScope = .composer(target)
                context.prepareComposerRoute(for: target)
                DictationRouting.shared.setGlobalSession(active: true, target: target)
                NotificationCenter.default.post(
                    name: .globalDictationSessionStarted,
                    object: nil,
                    userInfo: DictationToggleNotification.userInfo(for: target)
                )
            }
        } else if systemWideEnabled {
            sessionScope = .externalPaste
            DictationRouting.shared.setGlobalSession(active: true, target: nil)
        } else {
            phase = .error("Enable system-wide dictation in Voice settings")
            scheduleErrorDismiss()
            return
        }

        partialTranscript = ""

        do {
            let engine = try makeTranscriber()
            transcriber = engine
            subscribeToTranscriber(engine)
            let locale = locale(from: context.voicePreferences())
            try await engine.start(locale: locale)
            phase = .recording
            hotkeyManager.setSuppressFnDelivery(true)
        } catch {
            cleanupSession()
            phase = .error(error.localizedDescription)
            scheduleErrorDismiss()
        }
    }

    private func locale(from preferences: VoicePresentationPreferences) -> Locale {
        if let identifier = preferences.recognitionLocaleIdentifier {
            return Locale(identifier: identifier)
        }
        return .current
    }

    private func subscribeToTranscriber(_ engine: STTTranscribing) {
        partialCancellable = engine.partialTranscriptPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] partial in
                Task { @MainActor in
                    self?.handlePartial(partial)
                }
            }
        audioLevelCancellable = engine.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
    }

    private func handlePartial(_ partial: String) {
        guard phase == .recording, let context else { return }
        partialTranscript = partial
        guard case .composer(let target) = sessionScope else { return }
        guard shouldStreamPartialToComposer(context: context) else { return }
        let merged = DictationTextMerge.mergedText(baseBeforeSession: composerBaseText, sessionPartial: partial)
        context.applyComposerText(merged, target: target, phase: .partial)
    }

    private func shouldStreamPartialToComposer(context: GlobalDictationContextProviding) -> Bool {
        guard case .composer = sessionScope else { return false }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return frontmost == context.continuumBundleID
    }

    private func resolveStopDelivery(context: GlobalDictationContextProviding) -> GlobalDictationStopDelivery {
        GlobalDictationStopDeliveryResolver.resolve(
            continuumBundleID: context.continuumBundleID,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            systemWideEnabled: context.voicePreferences().systemWideDictationEnabled,
            composerResolution: context.resolveComposerTarget()
        )
    }

    private func revertComposerPreviewIfNeeded(
        context: GlobalDictationContextProviding,
        stopDelivery: GlobalDictationStopDelivery
    ) {
        guard case .composer(let originalTarget) = sessionScope else { return }
        switch stopDelivery {
        case .externalPaste, .unavailable:
            context.applyComposerText(composerBaseText, target: originalTarget, phase: .final)
        case .composer(let target) where target != originalTarget:
            context.applyComposerText(composerBaseText, target: originalTarget, phase: .final)
        default:
            break
        }
    }

    private func deliverFinalTranscript(
        _ trimmed: String,
        context: GlobalDictationContextProviding,
        stopDelivery: GlobalDictationStopDelivery
    ) {
        switch stopDelivery {
        case .composer(let target):
            context.prepareComposerRoute(for: target)
            let merged = DictationTextMerge.mergedText(baseBeforeSession: composerBaseText, sessionPartial: trimmed)
            context.applyComposerText(merged, target: target, phase: .final)
        case .externalPaste:
            switch pasteService.paste(trimmed) {
            case .success:
                break
            case .failure(let error):
                pasteService.copyToPasteboard(trimmed)
                context.showFailureToast(
                    title: "Could not paste — copied to clipboard",
                    detail: error.localizedDescription
                )
            }
        case .unavailable(let message):
            pasteService.copyToPasteboard(trimmed)
            context.showFailureToast(
                title: message,
                detail: "Transcript copied to clipboard."
            )
        }
    }

    private func stopRecording() async {
        guard phase == .recording || transcriber?.isRecording == true else {
            cleanupSession()
            return
        }
        guard let context else {
            cleanupSession()
            return
        }

        phase = .processing
        hotkeyManager.setSuppressFnDelivery(false)
        let transcript = await transcriber?.stop() ?? ""
        partialCancellable?.cancel()
        partialCancellable = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        audioLevel = 0
        transcriber = nil

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        partialTranscript = trimmed
        guard !trimmed.isEmpty else {
            cleanupSession()
            return
        }

        historyStore.append(trimmed)

        let stopDelivery = resolveStopDelivery(context: context)
        revertComposerPreviewIfNeeded(context: context, stopDelivery: stopDelivery)
        deliverFinalTranscript(trimmed, context: context, stopDelivery: stopDelivery)

        phase = .success
        try? await Task.sleep(for: .milliseconds(650))
        cleanupSession()
    }

    private func cancelRecording() async {
        guard phase == .recording || phase == .ready || transcriber?.isRecording == true else {
            dismissReadyOverlay()
            return
        }
        transcriber?.cancel()
        cleanupSession()
    }

    private func cleanupSession() {
        transcriber?.cancel()
        transcriber = nil
        partialCancellable?.cancel()
        partialCancellable = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        sessionScope = nil
        composerBaseText = ""
        partialTranscript = ""
        audioLevel = 0
        if case .error = phase {
            // Keep error visible until timer fires.
        } else {
            phase = .idle
        }
        hotkeyManager.setSuppressFnDelivery(false)
        DictationRouting.shared.setGlobalSession(active: false)
        NotificationCenter.default.post(name: .globalDictationSessionEnded, object: nil)
    }

    private func scheduleErrorDismiss() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2_500))
            if case .error = phase {
                phase = .idle
            }
        }
    }

    public func noteComposerBaseText(_ text: String) {
        composerBaseText = text
    }
}
