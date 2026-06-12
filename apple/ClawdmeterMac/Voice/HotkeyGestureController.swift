import ClawdmeterShared
import Foundation

/// Gesture semantics for the global Fn trigger.
public final class HotkeyGestureController {
    public enum Output: Equatable, Sendable {
        case startRecording(mode: FnKeyStateMachine.RecordingMode)
        case stopRecording
        case cancelRecording
        case showReadyForSecondTap
        case gestureTimedOut
        case scheduleStartupDebounce(milliseconds: Int)
        case scheduleHoldWindow(milliseconds: Int)
        case cancelTimers
    }

    public let tapThresholdMs: Int
    public let startupDebounceMs: Int
    private let mode: FnGestureMode
    private let stateMachine: FnKeyStateMachine

    private enum HoldOnlyState: Equatable {
        case idle
        case recording
    }

    private var holdOnlyState: HoldOnlyState = .idle

    public init(
        mode: FnGestureMode = .doubleTapOnly,
        tapThresholdMs: Int = FnKeyStateMachine.defaultTapThresholdMs,
        startupDebounceMs: Int = FnKeyStateMachine.defaultStartupDebounceMs
    ) {
        self.mode = mode
        self.tapThresholdMs = FnKeyStateMachine.clampTapThresholdMs(tapThresholdMs)
        self.startupDebounceMs = min(self.tapThresholdMs, max(0, startupDebounceMs))
        self.stateMachine = FnKeyStateMachine(tapThresholdMs: self.tapThresholdMs)
    }

    public var isCapturingFnGesture: Bool {
        switch mode {
        case .holdOnly:
            return holdOnlyState == .recording
        case .doubleTapOnly, .doubleTapAndHold:
            switch stateMachine.state {
            case .waitingForSecondTap, .persistent, .holdToTalk:
                return true
            case .idle, .cancelWindow, .blocked:
                return false
            }
        }
    }

    public func triggerPressed(timestampMs: UInt64) -> [Output] {
        switch mode {
        case .holdOnly:
            guard holdOnlyState == .idle else { return [] }
            holdOnlyState = .recording
            return [.startRecording(mode: .holdToTalk)]
        case .doubleTapOnly:
            return outputs(for: stateMachine.fnDown(timestampMs: timestampMs))
        case .doubleTapAndHold:
            let action = stateMachine.fnDown(timestampMs: timestampMs)
            var results = outputs(for: action)
            if action == .none, stateMachine.state == .waitingForSecondTap {
                results.append(.scheduleStartupDebounce(milliseconds: startupDebounceMs))
                results.append(.scheduleHoldWindow(milliseconds: tapThresholdMs))
            }
            return results
        }
    }

    public func triggerReleased(timestampMs: UInt64) -> [Output] {
        switch mode {
        case .holdOnly:
            guard holdOnlyState == .recording else { return [] }
            holdOnlyState = .idle
            return [.stopRecording]
        case .doubleTapOnly:
            _ = stateMachine.fnUp(timestampMs: timestampMs)
            if stateMachine.state == .waitingForSecondTap {
                return [.showReadyForSecondTap]
            }
            return []
        case .doubleTapAndHold:
            var results: [Output] = [.cancelTimers]
            let action = stateMachine.fnUp(timestampMs: timestampMs)
            results.append(contentsOf: outputs(for: action))
            if action == .none, stateMachine.state == .waitingForSecondTap {
                results.append(.showReadyForSecondTap)
            }
            return results
        }
    }

    public func startupDebounceElapsed() -> [Output] {
        guard mode == .doubleTapAndHold else { return [] }
        return outputs(for: stateMachine.startupTimerFired())
    }

    public func holdWindowElapsed() -> [Output] {
        guard mode == .doubleTapAndHold else { return [] }
        return outputs(for: stateMachine.holdTimerFired())
    }

    public func escapePressed() -> [Output] {
        switch mode {
        case .holdOnly:
            guard holdOnlyState == .recording else { return [] }
            holdOnlyState = .idle
            return [.cancelRecording]
        case .doubleTapOnly, .doubleTapAndHold:
            var results: [Output] = [.cancelTimers]
            results.append(contentsOf: outputs(for: stateMachine.escapePressed()))
            return results
        }
    }

    public func interrupted() -> [Output] {
        guard mode == .doubleTapAndHold else { return [] }
        var results: [Output] = [.cancelTimers]
        results.append(contentsOf: outputs(for: stateMachine.interruptWaitingForSecondTap()))
        return results
    }

    @discardableResult
    public func secondTapWindowExpired() -> [Output] {
        guard mode == .doubleTapOnly || mode == .doubleTapAndHold else { return [] }
        guard stateMachine.state == .waitingForSecondTap else { return [] }
        stateMachine.reset()
        return [.gestureTimedOut, .cancelTimers]
    }

    public func reset() {
        holdOnlyState = .idle
        stateMachine.reset()
    }

    private func outputs(for action: FnKeyStateMachine.Action) -> [Output] {
        switch action {
        case .none:
            return []
        case .startRecording(let mode):
            return [.startRecording(mode: mode), .cancelTimers]
        case .stopRecording:
            return [.stopRecording, .cancelTimers]
        case .cancelRecording:
            return [.cancelRecording, .cancelTimers]
        case .discardRecording:
            return [.cancelRecording, .cancelTimers]
        }
    }
}
