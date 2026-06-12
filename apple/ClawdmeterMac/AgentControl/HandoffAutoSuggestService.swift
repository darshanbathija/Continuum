import Foundation
import IOKit.ps
import Combine
import AppKit

/// Suggests session handoff when the Mac is on low battery or about to sleep (R1 1D auto-trigger).
@MainActor
public final class HandoffAutoSuggestService: ObservableObject {
    public static let shared = HandoffAutoSuggestService()

    @Published public private(set) var shouldSuggestHandoff = false
    @Published public private(set) var batteryPercent: Int?
    @Published public private(set) var triggerReason: TriggerReason?

    public enum TriggerReason: String, Sendable {
        case lowBattery
        case willSleep
    }

    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?

    public func startMonitoring(thresholdPercent: Int = 20) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(thresholdPercent: thresholdPercent) }
        }
        installSleepObserver()
        refresh(thresholdPercent: thresholdPercent)
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
    }

    public func refresh(thresholdPercent: Int = 20) {
        guard triggerReason != .willSleep else {
            shouldSuggestHandoff = true
            return
        }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int,
              max > 0
        else {
            batteryPercent = nil
            shouldSuggestHandoff = false
            triggerReason = nil
            return
        }
        let percent = (current * 100) / max
        batteryPercent = percent
        let onBattery = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        if onBattery && percent <= thresholdPercent {
            shouldSuggestHandoff = true
            triggerReason = .lowBattery
        } else {
            shouldSuggestHandoff = false
            triggerReason = nil
        }
    }

    public func dismissSuggestion() {
        shouldSuggestHandoff = false
        triggerReason = nil
    }

    private func installSleepObserver() {
        guard sleepObserver == nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.triggerReason = .willSleep
                self?.shouldSuggestHandoff = true
            }
        }
    }
}
