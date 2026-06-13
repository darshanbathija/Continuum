import AppKit
import Combine
import SwiftUI

/// Non-activating floating pill shown during global dictation (Fn double-tap).
@MainActor
final class DictationOverlayController {
    private let coordinator: GlobalDictationCoordinator
    private let panel: NSPanel
    private let hostingView: NSHostingView<DictationOverlayView>
    private var cancellables = Set<AnyCancellable>()

    init(coordinator: GlobalDictationCoordinator) {
        self.coordinator = coordinator
        self.hostingView = NSHostingView(
            rootView: DictationOverlayView(
                phase: .idle,
                audioLevel: 0,
                partialTranscript: "",
                onCancel: {}
            )
        )
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView

        coordinator.$phase
            .combineLatest(coordinator.$audioLevel, coordinator.$partialTranscript)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, level, partial in
                self?.render(phase: phase, audioLevel: level, partialTranscript: partial)
            }
            .store(in: &cancellables)
    }

    private func render(
        phase: GlobalDictationCoordinator.Phase,
        audioLevel: Float,
        partialTranscript: String
    ) {
        hostingView.rootView = DictationOverlayView(
            phase: phase,
            audioLevel: audioLevel,
            partialTranscript: partialTranscript,
            onCancel: { [weak coordinator] in
                coordinator?.cancelActiveSession()
            }
        )

        switch phase {
        case .idle:
            panel.orderOut(nil)
        case .ready, .recording, .processing, .success, .error:
            repositionPanel(for: phase)
            panel.orderFrontRegardless()
        }
    }

    private func repositionPanel(for phase: GlobalDictationCoordinator.Phase) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let width = max(size.width, phaseWidthHint(for: phase))
        let height = max(size.height, 36)
        let originX = frame.midX - (width / 2)
        let originY = frame.minY + 14
        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
    }

    private func phaseWidthHint(for phase: GlobalDictationCoordinator.Phase) -> CGFloat {
        switch phase {
        case .ready: return 148
        case .recording: return 240
        case .processing: return 148
        case .success: return 112
        case .error: return 260
        case .idle: return 0
        }
    }
}
