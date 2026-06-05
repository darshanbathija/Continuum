import Foundation
import OSLog

private let settingsLogger = Logger(subsystem: "com.clawdmeter.mac", category: "APNSGatewaySettings")

/// E6: user-facing settings for the APNS push triggers.
///
/// Default-on for the three E6 surfaces (plan approval, session done,
/// permission prompt). Users can toggle individual surfaces or kill the
/// whole gateway path if they prefer the legacy BG-refresh polling.
///
/// Storage: `UserDefaults.standard` under the `clawdmeter.apns.gateway.*`
/// keyspace so the values persist across daemon restarts.
public final class APNSGatewaySettings: @unchecked Sendable {

    public static let shared = APNSGatewaySettings()

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.clawdmeter.mac.APNSGatewaySettings", qos: .utility)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Master toggle

    /// Master kill switch. When false, the Mac NEVER posts to the gateway
    /// regardless of the per-surface toggles. Used by privacy-sensitive
    /// users who prefer the legacy BG-refresh path.
    public var pushEnabled: Bool {
        get { read(key: Self.keyPushEnabled, default: true) }
        set { write(key: Self.keyPushEnabled, value: newValue) }
    }

    // MARK: - Per-surface toggles

    /// Fire a push when the Mac detects an `ExitPlanMode` event.
    public var notifyOnPlanApproval: Bool {
        get { read(key: Self.keyPlanApproval, default: true) }
        set { write(key: Self.keyPlanApproval, value: newValue) }
    }

    /// Fire a push when a session's `DoneDetector` reports completion.
    /// Only effective when the session has been running >60s (per spec).
    public var notifyOnSessionDone: Bool {
        get { read(key: Self.keySessionDone, default: true) }
        set { write(key: Self.keySessionDone, value: newValue) }
    }

    /// Fire a push when a CLI permission prompt is surfaced.
    public var notifyOnPermissionPrompt: Bool {
        get { read(key: Self.keyPermissionPrompt, default: true) }
        set { write(key: Self.keyPermissionPrompt, value: newValue) }
    }

    /// Fire a push on any session status transition (idle→running→done, …).
    /// The noisiest surface — fires multiple times per turn — so treat it as a
    /// deliberate opt-in. Coalesced per session by `statusChangedMinIntervalSeconds`.
    public var notifyOnStatusChanged: Bool {
        get { read(key: Self.keyStatusChanged, default: true) }
        set { write(key: Self.keyStatusChanged, value: newValue) }
    }

    // MARK: - Threshold

    /// Sessions shorter than this are considered "trivial" and skip the
    /// `sessionDone` push. Default 60 seconds per the E6 spec.
    public var sessionDoneMinimumRuntimeSeconds: Int {
        get { read(key: Self.keySessionDoneMinRuntime, default: 60) }
        set { write(key: Self.keySessionDoneMinRuntime, value: newValue) }
    }

    /// Minimum gap between status-change pushes for the SAME session, so the
    /// noisiest surface can't flood. Default 30s.
    public var statusChangedMinIntervalSeconds: Int {
        get { read(key: Self.keyStatusChangedMinInterval, default: 30) }
        set { write(key: Self.keyStatusChangedMinInterval, value: newValue) }
    }

    // MARK: - Resolution helper

    /// Resolved per-surface toggle. Combines the master `pushEnabled` with
    /// the per-surface flag — the call site doesn't have to remember to
    /// check both.
    public func isEnabled(surface: Surface) -> Bool {
        guard pushEnabled else { return false }
        switch surface {
        case .planApproval:     return notifyOnPlanApproval
        case .sessionDone:      return notifyOnSessionDone
        case .permissionPrompt: return notifyOnPermissionPrompt
        case .statusChanged:    return notifyOnStatusChanged
        }
    }

    public enum Surface: String, Sendable {
        case planApproval
        case sessionDone
        case permissionPrompt
        case statusChanged
    }

    // MARK: - Keys

    private static let keyPushEnabled       = "clawdmeter.apns.gateway.enabled"
    private static let keyPlanApproval      = "clawdmeter.apns.gateway.notify.planApproval"
    private static let keySessionDone       = "clawdmeter.apns.gateway.notify.sessionDone"
    private static let keyPermissionPrompt  = "clawdmeter.apns.gateway.notify.permissionPrompt"
    private static let keyStatusChanged     = "clawdmeter.apns.gateway.notify.statusChanged"
    private static let keySessionDoneMinRuntime = "clawdmeter.apns.gateway.sessionDoneMinRuntimeSeconds"
    private static let keyStatusChangedMinInterval = "clawdmeter.apns.gateway.statusChangedMinIntervalSeconds"

    private func read(key: String, default fallback: Bool) -> Bool {
        queue.sync {
            if defaults.object(forKey: key) == nil { return fallback }
            return defaults.bool(forKey: key)
        }
    }

    private func read(key: String, default fallback: Int) -> Int {
        queue.sync {
            if defaults.object(forKey: key) == nil { return fallback }
            return defaults.integer(forKey: key)
        }
    }

    private func write(key: String, value: Bool) {
        queue.sync {
            defaults.set(value, forKey: key)
            settingsLogger.info("Set APNS gateway setting \(key, privacy: .public) = \(value)")
        }
    }

    private func write(key: String, value: Int) {
        queue.sync {
            defaults.set(value, forKey: key)
            settingsLogger.info("Set APNS gateway setting \(key, privacy: .public) = \(value)")
        }
    }
}
