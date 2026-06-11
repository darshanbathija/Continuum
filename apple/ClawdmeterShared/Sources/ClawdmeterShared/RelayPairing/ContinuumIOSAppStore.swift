// App Store URL for the Continuum Console iPhone companion. The Mac pairing
// flow shows a download QR first, then the relay auth QR after the user
// confirms they installed the app.

import Foundation

public enum ContinuumIOSAppStore {
    /// Public App Store listing for Continuum Console on iPhone.
    public static let downloadURL =
        "https://apps.apple.com/in/app/continuum-console/id6776332528"

    private static let confirmedInstallKey = "continuum.pairing.iosAppInstallConfirmed"

    /// True once the user has confirmed they installed the iPhone app on this Mac.
    public static var hasConfirmedInstall: Bool {
        UserDefaults.standard.bool(forKey: confirmedInstallKey)
    }

    public static func markInstallConfirmed() {
        UserDefaults.standard.set(true, forKey: confirmedInstallKey)
    }
}
