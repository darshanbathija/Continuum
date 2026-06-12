import AppKit
import ClawdmeterShared
import CoreGraphics
import Foundation

/// Listens for Fn gestures via a session-wide CGEvent tap.
public final class GlobalHotkeyManager {
    public var onGestureOutput: ((HotkeyGestureController.Output) -> Void)?

    private var gestureController: HotkeyGestureController
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<GlobalHotkeyManager>?
    private var installedRunLoop: CFRunLoop?
    private var fnWasPressed = false
    private var suppressFnDelivery = false
    private var secondTapTimer: DispatchWorkItem?
    private var startupTimer: DispatchWorkItem?
    private var holdTimer: DispatchWorkItem?

    public init(gestureController: HotkeyGestureController = HotkeyGestureController()) {
        self.gestureController = gestureController
    }

    deinit {
        stop()
    }

    public func configure(mode: FnGestureMode) {
        stop()
        gestureController = HotkeyGestureController(mode: mode)
    }

    public func setSuppressFnDelivery(_ suppress: Bool) {
        suppressFnDelivery = suppress
    }

    @discardableResult
    public func start() -> Bool {
        stopListeningOnly()

        var eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        eventMask |= CGEventMask(1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: {
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        ) else {
            retainedSelf?.release()
            retainedSelf = nil
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetMain()
        installedRunLoop = runLoop
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        stopListeningOnly()
        gestureController.reset()
    }

    private func stopListeningOnly() {
        cancelAllTimers()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        fnWasPressed = false
        suppressFnDelivery = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let fnPressed = FnKeyDetector.isPressed(in: flags)
        let timestampMs = Self.timestampMs(for: event)
        var outputs: [HotkeyGestureController.Output] = []

        if fnPressed && !fnWasPressed {
            fnWasPressed = true
            outputs = gestureController.triggerPressed(timestampMs: timestampMs)
        } else if !fnPressed && fnWasPressed {
            fnWasPressed = false
            outputs = gestureController.triggerReleased(timestampMs: timestampMs)
        }

        emit(outputs)
        reconcileTimers(for: outputs)
        return shouldSwallowFnEvent(outputs: outputs) ? nil : Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == 53 {
            if gestureController.isCapturingFnGesture || suppressFnDelivery {
                let outputs = gestureController.escapePressed()
                emit(outputs)
                reconcileTimers(for: outputs)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if FnKeyDetector.isFnKeyCode(keyCode), shouldSwallowFnEvent(outputs: []) {
            return nil
        }

        if gestureController.isCapturingFnGesture && !suppressFnDelivery {
            let outputs = gestureController.interrupted() + gestureController.secondTapWindowExpired()
            emit(outputs)
            reconcileTimers(for: outputs)
        }

        return Unmanaged.passUnretained(event)
    }

    private func shouldSwallowFnEvent(outputs: [HotkeyGestureController.Output]) -> Bool {
        if suppressFnDelivery { return true }
        if gestureController.isCapturingFnGesture { return true }
        return outputs.contains {
            switch $0 {
            case .startRecording, .stopRecording, .cancelRecording:
                return true
            default:
                return false
            }
        }
    }

    private func reconcileTimers(for outputs: [HotkeyGestureController.Output]) {
        for output in outputs {
            switch output {
            case .showReadyForSecondTap:
                scheduleSecondTapTimer()
            case .scheduleStartupDebounce(let ms):
                scheduleStartupTimer(after: ms)
            case .scheduleHoldWindow(let ms):
                scheduleHoldTimer(after: ms)
            case .cancelTimers:
                cancelStartupAndHoldTimers()
            case .startRecording, .stopRecording, .cancelRecording, .gestureTimedOut:
                cancelAllTimers()
            }
        }
    }

    private func scheduleSecondTapTimer() {
        cancelSecondTapTimer()
        let thresholdMs = gestureController.tapThresholdMs
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let outputs = self.gestureController.secondTapWindowExpired()
            self.emit(outputs)
            self.reconcileTimers(for: outputs)
        }
        secondTapTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(thresholdMs), execute: timer)
    }

    private func scheduleStartupTimer(after milliseconds: Int) {
        startupTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let outputs = self.gestureController.startupDebounceElapsed()
            self.emit(outputs)
            self.reconcileTimers(for: outputs)
        }
        startupTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: timer)
    }

    private func scheduleHoldTimer(after milliseconds: Int) {
        holdTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let outputs = self.gestureController.holdWindowElapsed()
            self.emit(outputs)
            self.reconcileTimers(for: outputs)
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: timer)
    }

    private func cancelSecondTapTimer() {
        secondTapTimer?.cancel()
        secondTapTimer = nil
    }

    private func cancelStartupAndHoldTimers() {
        startupTimer?.cancel()
        startupTimer = nil
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func cancelAllTimers() {
        cancelSecondTapTimer()
        cancelStartupAndHoldTimers()
    }

    private func emit(_ outputs: [HotkeyGestureController.Output]) {
        guard let onGestureOutput else { return }
        for output in outputs {
            onGestureOutput(output)
        }
    }

    private static func timestampMs(for event: CGEvent) -> UInt64 {
        UInt64(event.timestamp / 1_000_000)
    }
}
