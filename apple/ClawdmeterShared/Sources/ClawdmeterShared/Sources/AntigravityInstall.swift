// Probes the local filesystem for Google Antigravity 2 install + data.
//
// v0.7 ETA (pre-Phase 0): we checked for `/Applications/Antigravity.app/`,
// `~/.gemini/antigravity/`, and `~/Library/Application Support/Antigravity/bin/agy-node`.
// `agy-node` was misread as the agent CLI — Phase 0 proved it's a 152-byte
// shim that runs Antigravity's bundled Node runtime, NOT an agent CLI.
//
// v0.8.x agy-migration: we drop the agy-node anchor and add three new
// concerns the agentapi spawn path needs:
//
//   1. Locate the `language_server` binary across known install layouts
//      (Antigravity has moved it before; defensive multi-path probe).
//   2. Check OAuth credential validity via `~/.gemini/oauth_creds.json`
//      (no OAuth → every agentapi RPC fails with `not logged into Antigravity`).
//   3. `preflight(forRepoKey:)` composes install + OAuth + LS liveness +
//      project resolution into a single `InstallStatus` the spawn path
//      consumes verbatim.
//
// LS liveness + project resolution are dependencies; this module accepts
// them as injected closures so the shared package stays Mac-process-free
// (no pgrep/lsof here — those live in LanguageServerClient).
//
// Mac-only: Antigravity Electron, `~/.gemini/antigravity/`, and the
// language_server binary only exist on macOS. iOS reads Plan data via
// the AgentControl daemon over Tailscale; it never touches these paths
// directly.

#if os(macOS)
import Foundation

/// Result of an `AntigravityInstall.detect()` probe — pure filesystem
/// presence check. Composes into `InstallStatus` via `preflight`.
public enum AntigravityInstall: Equatable, Sendable {
    /// Antigravity 2 is installed. All core anchors exist.
    case installed(Installed)
    /// Antigravity is not installed (or the install is missing core files).
    case absent

    /// Per-instance details for an installed app. Returned by `.installed(_:)`.
    public struct Installed: Equatable, Sendable {
        /// `/Applications/Antigravity.app/` (the Electron container).
        public let appBundleURL: URL
        /// `~/.gemini/antigravity/` (data root: brain, conversations, state).
        public let appDataDir: URL
        /// Absolute path to the discovered `language_server` Mach-O binary.
        /// v0.8 expects this at `Contents/Resources/bin/language_server`
        /// but `locateLanguageServer()` probes 4 candidate paths.
        public let languageServerURL: URL
        /// Best-effort: "is the Electron app running right now?" — true when
        /// the transient `logs/<TS>/ls-main.log` dir exists. Authoritative
        /// liveness is `LanguageServerClient.discoverLive()` (Mac daemon).
        public let hasRunningServer: Bool
        /// Version string read from `Contents/Info.plist`. Nil on read fail.
        public let appVersion: String?

        public init(
            appBundleURL: URL,
            appDataDir: URL,
            languageServerURL: URL,
            hasRunningServer: Bool,
            appVersion: String?
        ) {
            self.appBundleURL = appBundleURL
            self.appDataDir = appDataDir
            self.languageServerURL = languageServerURL
            self.hasRunningServer = hasRunningServer
            self.appVersion = appVersion
        }
    }
}

// MARK: - OAuth credential check (D5)

/// Result of probing `~/.gemini/oauth_creds.json` for an Antigravity-scoped
/// credential. Drives the "Sign into Antigravity 2 first" CTA on the
/// composer when the user has the app installed but never signed in.
public enum AntigravityOAuthStatus: Equatable, Sendable {
    /// File exists + parses + carries the Antigravity OAuth token shape.
    case valid
    /// File missing or empty — user has never signed in.
    case missing
    /// File exists but parse failed or required claims absent. Treat as
    /// not-signed-in; surfaces same CTA as `.missing` but logs the
    /// distinction in OSLog for triage.
    case malformed
}

// MARK: - Preflight composition (D7)

/// Composed runtime status for `agent: .gemini` spawn. The spawn dispatch
/// in `SessionsView` switches on this to decide:
///
///   - `.ready` → spawn `agentapi new-conversation` via the resolved
///     project_id + live LS env.
///   - `.appOnlyNotRunning` → surface "Open Antigravity 2 to start" CTA
///     with launch button (D4 hard-stop: no v0.42 chat fallback).
///   - `.installedNotSignedIn` → "Sign into Antigravity 2 first" CTA.
///   - `.noProjectForRepo` → "Open this repo in Antigravity 2 first" CTA.
///   - `.absent` → "Install Antigravity 2 from antigravity.google" CTA.
public enum AntigravityInstallStatus: Equatable, Sendable {
    /// Everything reachable + project mapped. Spawn proceeds.
    case ready(
        install: AntigravityInstall.Installed,
        projectId: String
    )
    /// App installed + signed in, but `language_server` process is not
    /// running. User clicks "Open Antigravity" CTA.
    case appOnlyNotRunning(install: AntigravityInstall.Installed)
    /// App installed but no Antigravity OAuth credential found. Most
    /// common first-time state. CTA: "Sign in to Antigravity 2".
    case installedNotSignedIn(install: AntigravityInstall.Installed)
    /// App running + signed in, but no Antigravity project matches this
    /// `session.repoKey`. CTA: "Open this repo in Antigravity 2 first".
    case noProjectForRepo(install: AntigravityInstall.Installed)
    /// No Antigravity install at all. CTA: install from antigravity.google.
    case absent
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

        // App + data dir are the two filesystem anchors. language_server
        // discovery may fall through several candidate paths.
        guard fileManager.fileExists(atPath: appBundle.path),
              fileManager.fileExists(atPath: appData.path),
              let lsURL = locateLanguageServer(in: appBundle, fileManager: fileManager)
        else {
            return .absent
        }

        let hasRunningServer = detectRunningServer(appDataDir: appData, fileManager: fileManager)
        let version = readAppVersion(appBundleURL: appBundle, fileManager: fileManager)

        return .installed(.init(
            appBundleURL: appBundle,
            appDataDir: appData,
            languageServerURL: lsURL,
            hasRunningServer: hasRunningServer,
            appVersion: version
        ))
    }

    /// Multi-path probe for the `language_server` Mach-O binary inside
    /// the Antigravity.app bundle. Per D6 (eng review):
    ///
    ///   1. `Contents/Resources/bin/language_server` (current 2.0.x)
    ///   2. `Contents/MacOS/language_server` (defensive)
    ///   3. `Contents/Helpers/language_server` (defensive)
    ///   4. `Contents/Frameworks/Antigravity Helper.app/Contents/Resources/bin/language_server`
    ///      (defensive — Antigravity has moved binaries into the Helper
    ///      bundle before)
    ///
    /// Returns the first hit. Nil when all four miss (treat as `.absent`).
    public static func locateLanguageServer(
        in appBundle: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates: [String] = [
            "Contents/Resources/bin/language_server",
            "Contents/MacOS/language_server",
            "Contents/Helpers/language_server",
            "Contents/Frameworks/Antigravity Helper.app/Contents/Resources/bin/language_server",
        ]
        for relative in candidates {
            let url = appBundle.appendingPathComponent(relative, isDirectory: false)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir),
               !isDir.boolValue {
                return url
            }
        }
        return nil
    }

    /// Reads `~/.gemini/oauth_creds.json` and reports whether the user has
    /// signed in to Antigravity 2. Pure filesystem probe; doesn't validate
    /// against the server (Antigravity rotates internally on each app
    /// launch). A token may be revoked server-side but still present on
    /// disk — the agentapi RPC will surface that as `not logged into
    /// Antigravity` at runtime, which spawn dispatch turns into the
    /// `.installedNotSignedIn` banner via D5's secondary check.
    ///
    /// Schema (Phase 0): JSON object with `access_token` + `refresh_token`
    /// + `expiry` keys (and possibly more). v0.7's GeminiTokenProvider
    /// parses the same file with the same keys, but expects gemini-CLI
    /// shape; the Antigravity-scoped shape differs subtly in `scope`
    /// claims. We accept any non-empty `access_token` field as "signed
    /// in" — Antigravity vs v0.42 token differentiation happens at
    /// runtime via the agentapi call's success/failure.
    public static func checkOAuthValidity(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> AntigravityOAuthStatus {
        let url = homeDirectory.appendingPathComponent(".gemini/oauth_creds.json", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .missing }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        if let token = json["access_token"] as? String, !token.isEmpty {
            return .valid
        }
        return .malformed
    }

    /// Composed preflight check for a Gemini spawn. Combines install
    /// detection, OAuth credential presence, language_server liveness,
    /// and Antigravity-project lookup for the session's repoKey.
    ///
    /// Dependencies are injected as closures so the shared package stays
    /// Mac-process-free:
    ///   - `isLanguageServerLive` — typically wraps
    ///     `LanguageServerClient.discoverLive() != nil`. Tests pass a
    ///     stub.
    ///   - `resolveProject` — typically wraps
    ///     `AntigravityProjectResolver.shared.resolve(forRepoKey:)`.
    public static func preflight(
        forRepoKey repoKey: String,
        isLanguageServerLive: () async -> Bool,
        resolveProject: (String) async -> String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsRoot: URL = URL(fileURLWithPath: "/Applications"),
        fileManager: FileManager = .default
    ) async -> AntigravityInstallStatus {
        // Step 1: app must be on disk at all.
        let install = detect(
            homeDirectory: homeDirectory,
            applicationsRoot: applicationsRoot,
            fileManager: fileManager
        )
        guard case .installed(let installed) = install else {
            return .absent
        }

        // Step 2: OAuth must be present (best-effort; rotation invalidates
        // on the server side but we'd see that as an RPC error later).
        let oauth = checkOAuthValidity(homeDirectory: homeDirectory, fileManager: fileManager)
        guard oauth == .valid else {
            return .installedNotSignedIn(install: installed)
        }

        // Step 3: language_server must be running (Antigravity.app open).
        // D4 hard-stop: no v0.42 chat fallback when LS isn't live.
        guard await isLanguageServerLive() else {
            return .appOnlyNotRunning(install: installed)
        }

        // Step 4: an Antigravity project must map to session.repoKey.
        guard let projectId = await resolveProject(repoKey) else {
            return .noProjectForRepo(install: installed)
        }

        return .ready(install: installed, projectId: projectId)
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
