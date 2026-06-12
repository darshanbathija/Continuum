import ClawdmeterShared
import Foundation
import PostHog

/// One-shot PostHog SDK bootstrap shared by the Mac and iOS app targets.
enum PostHogSetup {
    private static let once = FireOnce()
    private(set) static var isConfigured = false

    static func configureIfNeeded() {
        once.run {
            guard let token = Bundle.main.postHogProjectToken else { return }

            let host = Bundle.main.postHogHost ?? "https://us.i.posthog.com"
            let config = PostHogConfig(projectToken: token, host: host)
            config.captureApplicationLifecycleEvents = true
            // SwiftUI: automatic screen swizzling yields opaque internal view
            // names — use PostHogScreenTracking.screen(_:) on tab changes instead.
            config.captureScreenViews = false
            config.personProfiles = .identifiedOnly
            #if DEBUG
            config.debug = true
            #endif
            PostHogSDK.shared.setup(config)
            isConfigured = true
            ContinuumAnalytics.buttonTapped = { name, screen in
                PostHogButtonTracking.tap(name, screen: screen)
            }
            PostHogIdentity.configureOnLaunch()
        }
    }
}

/// Stable per-install identity + pairing-aware `identify()` calls.
/// With `personProfiles = .identifiedOnly`, events only attach to a person
/// profile after `identify()` — call on launch and whenever pairing changes.
enum PostHogIdentity {
    private static let deviceIdKey = "clawdmeter.telemetry.deviceId"

    static func configureOnLaunch() {
        guard PostHogSetup.isConfigured else { return }
        registerSuperProperties()
        refreshFromCurrentState()
    }

    static func onRelayPairingCompleted(record: RelayPairingRecord) {
        guard PostHogSetup.isConfigured else { return }
        let prefix = String(record.sid.prefix(8))
        identify(paired: true, sessionPrefix: prefix, transport: "relay")
        PostHogSDK.shared.capture(
            "device_paired",
            properties: ["transport": "relay", "pairing_session_prefix": prefix]
        )
    }

    static func onDirectPairingCompleted() {
        guard PostHogSetup.isConfigured else { return }
        identify(paired: true, sessionPrefix: nil, transport: "direct")
        PostHogSDK.shared.capture("device_paired", properties: ["transport": "direct"])
    }

    /// Re-read relay + direct pairing state after a forget/reset.
    static func refreshFromCurrentState() {
        guard PostHogSetup.isConfigured else { return }
        if let record = RelayPairingStore.shared.loadRecord() {
            identify(
                paired: true,
                sessionPrefix: String(record.sid.prefix(8)),
                transport: "relay"
            )
        } else if hasDirectPairing() {
            identify(paired: true, sessionPrefix: nil, transport: "direct")
        } else {
            identify(paired: false, sessionPrefix: nil, transport: nil)
        }
    }

    private static func registerSuperProperties() {
        var props: [String: Any] = ["platform": platformName]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            props["app_version"] = version
        }
        PostHogSDK.shared.register(props)
    }

    private static func identify(
        paired: Bool,
        sessionPrefix: String?,
        transport: String?
    ) {
        var userProperties: [String: Any] = ["paired": paired]
        if let transport { userProperties["pairing_transport"] = transport }
        if let sessionPrefix { userProperties["pairing_session_prefix"] = sessionPrefix }
        PostHogSDK.shared.identify(deviceId(), userProperties: userProperties)
    }

    private static func deviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIdKey)
        return fresh
    }

    private static func hasDirectPairing() -> Bool {
        let host = UserDefaults.standard.string(forKey: AgentControlClient.hostKey)
        let token = UserDefaults.standard.string(forKey: AgentControlClient.tokenKey)
        return host != nil && token != nil
    }

    private static var platformName: String {
        #if os(macOS)
        return "mac"
        #elseif os(iOS)
        return "ios"
        #else
        return "unknown"
        #endif
    }
}

/// Manual `$screen` events for SwiftUI tab / push navigation.
enum PostHogScreenTracking {
    static func screen(_ name: String, properties: [String: Any]? = nil) {
        guard PostHogSetup.isConfigured else { return }
        PostHogSDK.shared.screen(name, properties: properties)
    }
}

private extension Bundle {
    var postHogProjectToken: String? {
        guard let raw = object(forInfoDictionaryKey: "POSTHOG_PROJECT_TOKEN") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var postHogHost: String? {
        guard let raw = object(forInfoDictionaryKey: "POSTHOG_HOST") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
