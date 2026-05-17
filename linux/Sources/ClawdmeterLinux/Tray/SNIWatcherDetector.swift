import Foundation

/// Detects whether `org.kde.StatusNotifierWatcher` is registered on the
/// session D-Bus. GNOME 40+ doesn't ship native tray support — users need
/// the `appindicatorsupport@rgcjonas.gmail.com` shell extension. ZorinOS
/// preinstalls it; stock Ubuntu sometimes doesn't (depends on flavor).
///
/// Without the extension, our `app_indicator_new(...)` calls succeed
/// silently and the icon never appears. The first-run dialog at
/// `MissingTraySupportDialog` keys off this detector.
///
/// **Detection method.** Call `ListNames` on the session bus and search
/// the result list for `org.kde.StatusNotifierWatcher`. One synchronous
/// D-Bus call; ~5ms.
///
/// Phase 4 build-out: actual `libdbus-1` calls under `#if os(Linux)`.
public enum SNIWatcherDetector {

    public enum Status: Sendable {
        /// SNI watcher is registered; tray will work.
        case available
        /// SNI watcher absent (stock GNOME without extension). First-run
        /// dialog should appear.
        case missing
        /// Couldn't reach session bus at all (no D-Bus daemon, headless
        /// install). Same UI as `.missing` but log indicates root cause.
        case dbusUnavailable
    }

    /// One-shot synchronous probe. Returns within ~5ms on a healthy session.
    public static func detect() -> Status {
        #if os(Linux)
        // TODO(Phase 4): libdbus call
        //   let conn = dbus_bus_get(DBUS_BUS_SESSION, &error)
        //   guard conn != nil else { return .dbusUnavailable }
        //   defer { dbus_connection_unref(conn) }
        //   let reply = dbus_g_proxy_call(...) // ListNames
        //   guard let names = parseStringArray(reply) else { return .dbusUnavailable }
        //   return names.contains("org.kde.StatusNotifierWatcher")
        //       ? .available : .missing
        return .missing
        #else
        // macOS dev: pretend available so we can wire UI flow.
        return .available
        #endif
    }

    /// Has the user opted into "continue without menu bar" already?
    /// Read from `$XDG_CONFIG_HOME/clawdmeter/prefs.json`.
    public static func userOptedOut() -> Bool {
        let prefsURL = LinuxConfigPaths.configHome.appendingPathComponent("prefs.json")
        guard let data = try? Data(contentsOf: prefsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (dict["dismissedTrayMissingPrompt"] as? Bool) == true
    }

    /// Persist the user's "Continue without menu bar" choice.
    public static func setUserOptedOut(_ opted: Bool) {
        let prefsURL = LinuxConfigPaths.configHome.appendingPathComponent("prefs.json")
        var dict: [String: Any] = [:]
        if let existing = try? Data(contentsOf: prefsURL),
           let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            dict = decoded
        }
        dict["dismissedTrayMissingPrompt"] = opted
        try? LinuxConfigPaths.ensureDirectory(LinuxConfigPaths.configHome)
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: prefsURL, options: .atomic)
        }
    }
}
