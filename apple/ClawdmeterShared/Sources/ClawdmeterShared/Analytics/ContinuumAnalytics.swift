import Foundation

/// App-target analytics bridge. ContinuumTelemetry wires this to PostHog on launch.
public enum ContinuumAnalytics {
    public static var buttonTapped: ((_ name: String, _ screen: String?) -> Void)?
    public static var currentScreen: String?

    public static func wrapButton(
        _ name: String,
        screen: String? = nil,
        _ action: @escaping () -> Void
    ) -> () -> Void {
        {
            buttonTapped?(name, screen ?? currentScreen)
            action()
        }
    }

    public static func trackButton(_ name: String, screen: String? = nil) {
        buttonTapped?(name, screen ?? currentScreen)
    }
}
