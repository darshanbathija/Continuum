import Foundation

/// First-run dialog shown when `SNIWatcherDetector.detect() == .missing`
/// (and the user hasn't opted out previously).
///
/// Per **D5**: closes the silent-failure path on stock GNOME without the
/// AppIndicator extension. User gets a clear next step: open the GNOME
/// Extensions site to install the extension, OR continue without the
/// menu bar and use the dashboard window as the primary surface.
///
/// Built on `LinuxUIWidget` primitives so the actual UI is binding-agnostic
/// (D3). The opening-the-URL step uses xdg-open.
public enum MissingTraySupportDialog {

    /// Action the user took.
    public enum Outcome: Sendable {
        case openExtensionsSite       // launched xdg-open + dialog dismissed
        case continueWithoutMenuBar   // dismissed, opt-out persisted
    }

    public static func presentIfNeeded(over parent: LinuxWindow?) -> Outcome? {
        // Already dismissed previously — don't re-prompt.
        if SNIWatcherDetector.userOptedOut() {
            return nil
        }

        let status = SNIWatcherDetector.detect()
        guard status == .missing || status == .dbusUnavailable else {
            // Tray works; no dialog needed.
            return nil
        }

        // Wire the dialog. Outcome is collected via primary/secondary action
        // closures; presenter handles persisting opt-out.
        nonisolated(unsafe) var outcome: Outcome?
        let dialog = LinuxUI.alertDialog(
            title: "Menu-bar icon needs the AppIndicator extension",
            message: """
            Clawdmeter shows your Claude / Codex usage in the GNOME top bar.
            On stock GNOME, this requires the AppIndicator shell extension. \
            ZorinOS ships with it; some Ubuntu flavors don't.

            Continue without the menu bar — the dashboard window stays \
            accessible from your app launcher.
            """,
            actions: [
                (label: "Install extension", isPrimary: true, handler: {
                    openExtensionsSite()
                    outcome = .openExtensionsSite
                }),
                (label: "Continue without menu bar", isPrimary: false, handler: {
                    SNIWatcherDetector.setUserOptedOut(true)
                    outcome = .continueWithoutMenuBar
                })
            ]
        )
        dialog.present(over: parent)
        return outcome
    }

    private static func openExtensionsSite() {
        let url = "https://extensions.gnome.org/extension/615/appindicator-support/"
        #if os(Linux)
        // xdg-open <url> via Foundation Process
        let process = Process()
        process.launchPath = "/usr/bin/xdg-open"
        process.arguments = [url]
        try? process.run()
        #else
        // macOS dev: log and continue
        print("MissingTraySupportDialog: would open \(url)")
        #endif
    }
}
