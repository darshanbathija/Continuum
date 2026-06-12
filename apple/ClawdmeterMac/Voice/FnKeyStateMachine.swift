import Foundation

/// Pure state machine for Fn key gesture detection (double-tap, hold-to-talk, cancel).
public final class FnKeyStateMachine {
    public enum State: Equatable, Sendable {
        case idle
        case waitingForSecondTap
        case persistent
        case holdToTalk
        case cancelWindow
        case blocked
    }

    public enum Action: Equatable, Sendable {
        case none
        case startRecording(mode: RecordingMode)
        case stopRecording
        case cancelRecording
        case discardRecording(showReadyPill: Bool)
    }

    public enum RecordingMode: Equatable, Sendable {
        case persistent
        case holdToTalk
    }

    public static let defaultTapThresholdMs: Int = 400
    public static let minimumTapThresholdMs: Int = 50
    public static let maximumTapThresholdMs: Int = 500
    public static let defaultStartupDebounceMs: Int = 100

    public private(set) var state: State = .idle
    public let tapThresholdMs: Int
    private var fnDownTimestamp: UInt64 = 0
    private var firstTapTimestamp: UInt64 = 0
    private var hasActiveProvisionalRecording = false

    public init(tapThresholdMs: Int = defaultTapThresholdMs) {
        self.tapThresholdMs = Self.clampTapThresholdMs(tapThresholdMs)
    }

    public static func clampTapThresholdMs(_ value: Int) -> Int {
        min(max(value, minimumTapThresholdMs), maximumTapThresholdMs)
    }

    public func fnDown(timestampMs: UInt64) -> Action {
        switch state {
        case .idle:
            fnDownTimestamp = timestampMs
            state = .waitingForSecondTap
            hasActiveProvisionalRecording = false
            return .none
        case .waitingForSecondTap:
            let elapsed = timestampMs - firstTapTimestamp
            if elapsed <= UInt64(tapThresholdMs) {
                state = .persistent
                hasActiveProvisionalRecording = false
                return .startRecording(mode: .persistent)
            }
            fnDownTimestamp = timestampMs
            hasActiveProvisionalRecording = false
            return .none
        case .persistent:
            state = .idle
            hasActiveProvisionalRecording = false
            return .stopRecording
        case .holdToTalk, .cancelWindow, .blocked:
            return .none
        }
    }

    public func fnUp(timestampMs: UInt64) -> Action {
        switch state {
        case .waitingForSecondTap:
            let holdDuration = timestampMs - fnDownTimestamp
            if holdDuration >= UInt64(tapThresholdMs) {
                state = .idle
                let shouldStop = hasActiveProvisionalRecording
                hasActiveProvisionalRecording = false
                return shouldStop ? .stopRecording : .none
            }
            firstTapTimestamp = timestampMs
            let shouldDiscard = hasActiveProvisionalRecording
            hasActiveProvisionalRecording = false
            return shouldDiscard ? .discardRecording(showReadyPill: true) : .none
        case .holdToTalk:
            state = .idle
            hasActiveProvisionalRecording = false
            return .stopRecording
        case .blocked:
            state = .cancelWindow
            return .none
        default:
            return .none
        }
    }

    public func startupTimerFired() -> Action {
        guard state == .waitingForSecondTap, !hasActiveProvisionalRecording else { return .none }
        hasActiveProvisionalRecording = true
        return .startRecording(mode: .holdToTalk)
    }

    public func holdTimerFired() -> Action {
        switch state {
        case .waitingForSecondTap:
            state = .holdToTalk
            if hasActiveProvisionalRecording {
                hasActiveProvisionalRecording = false
                return .none
            }
            return .startRecording(mode: .holdToTalk)
        default:
            return .none
        }
    }

    public func interruptWaitingForSecondTap() -> Action {
        guard state == .waitingForSecondTap else { return .none }
        state = .idle
        fnDownTimestamp = 0
        firstTapTimestamp = 0
        let shouldDiscard = hasActiveProvisionalRecording
        hasActiveProvisionalRecording = false
        return shouldDiscard ? .discardRecording(showReadyPill: false) : .none
    }

    public func escapePressed() -> Action {
        switch state {
        case .waitingForSecondTap where hasActiveProvisionalRecording:
            state = .idle
            hasActiveProvisionalRecording = false
            return .cancelRecording
        case .persistent, .holdToTalk:
            state = .idle
            hasActiveProvisionalRecording = false
            return .cancelRecording
        default:
            return .none
        }
    }

    public func reset() {
        state = .idle
        fnDownTimestamp = 0
        firstTapTimestamp = 0
        hasActiveProvisionalRecording = false
    }
}
