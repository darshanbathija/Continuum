// Probes the local filesystem for Google Antigravity 2.0.0 install + data.
//
// Three things we care about at runtime:
//
//   1. Is the Antigravity Electron app installed?  → `/Applications/Antigravity.app/`
//   2. Where is the agent data dir?               → `~/.gemini/antigravity/`
//   3. Where is the `agy-node` shim that spawns agents?
//                                                  → `~/Library/Application Support/Antigravity/bin/agy-node`
//
// Plus a coarse "is the Electron app running right now" signal via the
// transient `~/.gemini/antigravity/logs/<TS>/ls-main.log` directory. That
// log dir is only present while the Antigravity language_server is up; a
// fresher log is a strong proxy for "Antigravity launched". For the
// authoritative liveness check (kill -0 + lsof on the actual port), see
// `LanguageServerClient.discoverLive()` in ClawdmeterMac (Commit 8).
//
// This file ships in v0.6.0 Commit 1 as a pure probe with no behavior
// change — callers wire up later commits.
//
// Mac-only: Antigravity Electron, `~/.gemini/antigravity/`, and `agy-node`
// only exist on macOS. iOS reads Plan data via the AgentControl daemon
// over Tailscale; it never touches these paths directly.

#if os(macOS)
import Foundation

/// Result of an `AntigravityInstall.detect()` probe.
public enum AntigravityInstall: Equatable, Sendable {
    /// Antigravity 2 is installed. All four anchor paths exist.
    case installed(Installed)
    /// Antigravity is not installed (or the install is missing core files).
    case absent

    /// Per-instance details for an installed app. Returned by `.installed(_:)`.
    public struct Installed: Equatable, Sendable {
        /// `/Applications/Antigravity.app/` (the Electron container).
        public let appBundleURL: URL
        /// `~/.gemini/antigravity/` (data root: brain, conversations, state).
        public let appDataDir: URL
        /// `~/Library/Application Support/Antigravity/bin/agy-node` — the
        /// 152-byte shell shim that invokes the Electron Helper with
        /// `ELECTRON_RUN_AS_NODE=1`. v0.6.0 spawns agents via this path
        /// (see `AntigravityArgvBuilder` in Commit 7).
        public let agyNodePath: URL
        /// Best-effort: "is the Electron app running right now?" — true when
        /// the transient `logs/<TS>/ls-main.log` dir exists. Authoritative
        /// liveness is `LanguageServerClient.discoverLive()` (Commit 8).
        public let hasRunningServer: Bool
        /// Version string read from `/Applications/Antigravity.app/Contents/Info.plist`
        /// `CFBundleShortVersionString` key. Nil if the plist is missing
        /// or malformed.
        public let appVersion: String?

        public init(
            appBundleURL: URL,
            appDataDir: URL,
            agyNodePath: URL,
            hasRunningServer: Bool,
            appVersion: String?
        ) {
            self.appBundleURL = appBundleURL
            self.appDataDir = appDataDir
            self.agyNodePath = agyNodePath
            self.hasRunningServer = hasRunningServer
            self.appVersion = appVersion
        }
    }
}

extension AntigravityInstall {
    /// Probes the standard install locations and returns either `.installed`
    /// (with details) or `.absent`. Pure I/O — uses `FileManager.default`
    /// only and never blocks more than a single `URL` existence check per
    /// path.
    ///
    /// `homeDirectory` is injectable for tests; defaults to the real home.
    /// `fileManager` is injectable for tests.
    public static func detect(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsRoot: URL = URL(fileURLWithPath: "/Applications"),
        fileManager: FileManager = .default
    ) -> AntigravityInstall {
        let appBundle = applicationsRoot.appendingPathComponent("Antigravity.app", isDirectory: true)
        let appData = homeDirectory.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let agyNode = homeDirectory.appendingPathComponent(
            "Library/Application Support/Antigravity/bin/agy-node",
            isDirectory: false
        )

        // All three anchors must exist for the install to count as present.
        // Partial installs (Electron app but no data dir, or data dir but
        // no `agy-node`) are reported as absent — caller can render a
        // recovery CTA without us silently doing the wrong thing.
        let appExists = fileManager.fileExists(atPath: appBundle.path)
        let dataExists = fileManager.fileExists(atPath: appData.path)
        let agyExists = fileManager.fileExists(atPath: agyNode.path)
        guard appExists && dataExists && agyExists else { return .absent }

        let hasRunningServer = detectRunningServer(appDataDir: appData, fileManager: fileManager)
        let version = readAppVersion(appBundleURL: appBundle, fileManager: fileManager)

        return .installed(.init(
            appBundleURL: appBundle,
            appDataDir: appData,
            agyNodePath: agyNode,
            hasRunningServer: hasRunningServer,
            appVersion: version
        ))
    }

    /// Coarse running-server proxy: true if `appDataDir/logs/` contains at
    /// least one subdirectory with an `ls-main.log` file. Antigravity
    /// creates a fresh `logs/<UNIXTS>/` subdir on every launch and writes
    /// `ls-main.log` immediately. The dir persists after quit (Antigravity
    /// doesn't sweep), so this is a "has-been-launched" signal more than
    /// "currently running" — for the latter, use `LanguageServerClient`.
    static func detectRunningServer(appDataDir: URL, fileManager: FileManager) -> Bool {
        let logsDir = appDataDir.appendingPathComponent("logs", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else {
            return false
        }
        for entry in entries {
            let lsMain = entry.appendingPathComponent("ls-main.log", isDirectory: false)
            if fileManager.fileExists(atPath: lsMain.path) {
                return true
            }
        }
        return false
    }

    /// Pulls `CFBundleShortVersionString` out of the Antigravity app's
    /// `Info.plist`. Returns nil on any read or parse failure — the caller
    /// renders a degraded subtitle ("Antigravity · gemini-3.5-flash") in
    /// that case rather than spinning on a missing dot.
    static func readAppVersion(appBundleURL: URL, fileManager: FileManager) -> String? {
        let plistURL = appBundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        guard let dict = plist as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }
}
#endif // os(macOS)
