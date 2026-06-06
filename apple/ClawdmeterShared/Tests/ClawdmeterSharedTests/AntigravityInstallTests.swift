#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Probes the `AntigravityInstall.detect` + `checkOAuthValidity`
/// implementations by handing them a synthetic filesystem layout under a
/// tempdir. Never touches the real `/Applications/Antigravity.app/` or
/// `~/.gemini/antigravity/` — every entry point accepts `homeDirectory` +
/// `applicationsRoot` for exactly this reason.
///
/// v0.8.0 agy-migration: agyNode → languageServerURL field rename +
/// multi-path probe + OAuth credential check.
final class AntigravityInstallTests: XCTestCase {

    // MARK: - Fixture helpers

    private struct Fixture {
        let homeDir: URL
        let appsRoot: URL
        let appBundle: URL
        let appData: URL
        /// Path to the language_server inside the bundle for the canonical
        /// `Contents/Resources/bin/language_server` location.
        let lsBinary: URL
        /// `~/.gemini/oauth_creds.json`
        let oauthCreds: URL
    }

    private func makeFixture(file: StaticString = #file, line: UInt = #line) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-install-test-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let appBundle = apps.appendingPathComponent("Antigravity.app", isDirectory: true)
        let appData = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let lsBinary = appBundle.appendingPathComponent(
            "Contents/Resources/bin/language_server",
            isDirectory: false
        )
        let oauthCreds = home.appendingPathComponent(".gemini/oauth_creds.json", isDirectory: false)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(
            homeDir: home,
            appsRoot: apps,
            appBundle: appBundle,
            appData: appData,
            lsBinary: lsBinary,
            oauthCreds: oauthCreds
        )
    }

    private func touch(_ url: URL, contents: String = "") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - detect

    func test_detect_absentWhenAllAnchorsMissing() throws {
        let fx = try makeFixture()
        let result = AntigravityInstall.detect(
            homeDirectory: fx.homeDir,
            applicationsRoot: fx.appsRoot
        )
        XCTAssertEqual(result, .absent)
    }

    func test_detect_absentWhenAppBundleMissing() throws {
        // Only the data dir exists; app bundle (and lsBinary inside it) absent.
        let fx = try makeFixture()
        try makeDir(fx.appData)
        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        XCTAssertEqual(result, .absent, "Missing /Applications/Antigravity.app must report absent")
    }

    func test_detect_absentWhenDataDirMissing() throws {
        // Bundle + lsBinary exist, but no ~/.gemini/antigravity/.
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try touch(fx.lsBinary)
        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        XCTAssertEqual(result, .absent, "Missing ~/.gemini/antigravity must report absent")
    }

    func test_detect_absentWhenLanguageServerMissing() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        XCTAssertEqual(result, .absent, "Missing language_server binary must report absent")
    }

    func test_detect_installedWhenAllAnchorsPresent_serverNotRunning() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        try touch(fx.lsBinary, contents: "fake mach-o\n")
        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        guard case let .installed(installed) = result else {
            return XCTFail("Expected .installed; got \(result)")
        }
        XCTAssertEqual(installed.appBundleURL, fx.appBundle)
        XCTAssertEqual(installed.appDataDir, fx.appData)
        XCTAssertEqual(installed.languageServerURL, fx.lsBinary)
        XCTAssertFalse(installed.hasRunningServer, "No logs/ subdir means hasRunningServer = false")
        XCTAssertNil(installed.appVersion, "No Info.plist means appVersion = nil")
    }

    func test_detect_serverRunningWhenLsMainLogPresent() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        try touch(fx.lsBinary)
        let logsTs = fx.appData.appendingPathComponent("logs/1779219825", isDirectory: true)
        try touch(logsTs.appendingPathComponent("ls-main.log"), contents: "starting language_server\n")

        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        guard case let .installed(installed) = result else {
            return XCTFail("Expected .installed; got \(result)")
        }
        XCTAssertTrue(installed.hasRunningServer)
    }

    func test_detect_reportsBundleVersionFromInfoPlist() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        try touch(fx.lsBinary)
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.0.1"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let plistURL = fx.appBundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        try makeDir(plistURL.deletingLastPathComponent())
        try plistData.write(to: plistURL)

        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        guard case let .installed(installed) = result else {
            return XCTFail("Expected .installed; got \(result)")
        }
        XCTAssertEqual(installed.appVersion, "2.0.1")
    }

    func test_detect_appVersionNilOnMalformedPlist() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        try touch(fx.lsBinary)
        let plistURL = fx.appBundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        try makeDir(plistURL.deletingLastPathComponent())
        try "this is not a plist".write(to: plistURL, atomically: true, encoding: .utf8)

        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        guard case let .installed(installed) = result else {
            return XCTFail("Expected .installed; got \(result)")
        }
        XCTAssertNil(installed.appVersion)
    }

    // MARK: - locateLanguageServer (multi-path probe, D6)

    func test_locate_findsCanonicalResourcesBinPath() throws {
        let fx = try makeFixture()
        try touch(fx.lsBinary)
        let url = AntigravityInstall.locateLanguageServer(in: fx.appBundle)
        XCTAssertEqual(url, fx.lsBinary)
    }

    func test_locate_findsMacOSFallbackPath() throws {
        let fx = try makeFixture()
        let macos = fx.appBundle.appendingPathComponent("Contents/MacOS/language_server", isDirectory: false)
        try touch(macos)
        let url = AntigravityInstall.locateLanguageServer(in: fx.appBundle)
        XCTAssertEqual(url, macos)
    }

    func test_locate_findsHelperBundleFallbackPath() throws {
        let fx = try makeFixture()
        let helper = fx.appBundle.appendingPathComponent(
            "Contents/Frameworks/Antigravity Helper.app/Contents/Resources/bin/language_server",
            isDirectory: false
        )
        try touch(helper)
        let url = AntigravityInstall.locateLanguageServer(in: fx.appBundle)
        XCTAssertEqual(url, helper)
    }

    func test_locate_returnsNilWhenAllCandidatesMiss() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        let url = AntigravityInstall.locateLanguageServer(in: fx.appBundle)
        XCTAssertNil(url)
    }

    func test_locate_picksFirstHitInPriorityOrder() throws {
        let fx = try makeFixture()
        // Canonical (Contents/Resources/bin/) AND MacOS path both present.
        // Canonical wins.
        try touch(fx.lsBinary)
        try touch(fx.appBundle.appendingPathComponent("Contents/MacOS/language_server", isDirectory: false))
        let url = AntigravityInstall.locateLanguageServer(in: fx.appBundle)
        XCTAssertEqual(url, fx.lsBinary)
    }

    func test_locate_skipsDirectoryWithSameName() throws {
        let fx = try makeFixture()
        // Create a directory named "language_server" at canonical path
        // (could happen with an unpacked archive). Skip it, try next path.
        let dirAsLS = fx.appBundle.appendingPathComponent("Contents/Resources/bin/language_server", isDirectory: true)
        try makeDir(dirAsLS)
        let macos = fx.appBundle.appendingPathComponent("Contents/MacOS/language_server", isDirectory: false)
        try touch(macos)
        let url = AntigravityInstall.locateLanguageServer(in: fx.appBundle)
        XCTAssertEqual(url, macos, "Directory at canonical path should be skipped; MacOS file wins")
    }

    // MARK: - checkOAuthValidity (D5)

    func test_oauth_missingFileReturnsMissing() throws {
        let fx = try makeFixture()
        let result = AntigravityInstall.checkOAuthValidity(homeDirectory: fx.homeDir)
        XCTAssertEqual(result, .missing)
    }

    func test_oauth_emptyFileReturnsMissing() throws {
        let fx = try makeFixture()
        try touch(fx.oauthCreds, contents: "")
        let result = AntigravityInstall.checkOAuthValidity(homeDirectory: fx.homeDir)
        XCTAssertEqual(result, .missing)
    }

    func test_oauth_malformedJSONReturnsMalformed() throws {
        let fx = try makeFixture()
        try touch(fx.oauthCreds, contents: "{ not valid json")
        let result = AntigravityInstall.checkOAuthValidity(homeDirectory: fx.homeDir)
        XCTAssertEqual(result, .malformed)
    }

    func test_oauth_validJSONWithoutAccessTokenReturnsMalformed() throws {
        let fx = try makeFixture()
        try touch(fx.oauthCreds, contents: #"{ "refresh_token": "x" }"#)
        let result = AntigravityInstall.checkOAuthValidity(homeDirectory: fx.homeDir)
        XCTAssertEqual(result, .malformed)
    }

    func test_oauth_validJSONWithAccessTokenReturnsValid() throws {
        let fx = try makeFixture()
        try touch(fx.oauthCreds, contents: #"{ "access_token": "ya29.AAAA", "expiry": "2026-12-31T23:59:59Z" }"#)
        let result = AntigravityInstall.checkOAuthValidity(homeDirectory: fx.homeDir)
        XCTAssertEqual(result, .valid)
    }

    func test_oauth_emptyAccessTokenReturnsMalformed() throws {
        let fx = try makeFixture()
        try touch(fx.oauthCreds, contents: #"{ "access_token": "" }"#)
        let result = AntigravityInstall.checkOAuthValidity(homeDirectory: fx.homeDir)
        XCTAssertEqual(result, .malformed)
    }

    // MARK: - detectRunningServer subhelper

    func test_detectRunningServer_falseWhenLogsDirMissing() throws {
        let fx = try makeFixture()
        try makeDir(fx.appData)
        let running = AntigravityInstall.detectRunningServer(appDataDir: fx.appData, fileManager: .default)
        XCTAssertFalse(running)
    }

    func test_detectRunningServer_falseWhenLogsSubdirHasNoMainLog() throws {
        let fx = try makeFixture()
        try makeDir(fx.appData.appendingPathComponent("logs/1779219825", isDirectory: true))
        let running = AntigravityInstall.detectRunningServer(appDataDir: fx.appData, fileManager: .default)
        XCTAssertFalse(running)
    }

    func test_detectRunningServer_trueWithOneRunningLog() throws {
        let fx = try makeFixture()
        let ts = fx.appData.appendingPathComponent("logs/1779219825", isDirectory: true)
        try touch(ts.appendingPathComponent("ls-main.log"))
        let running = AntigravityInstall.detectRunningServer(appDataDir: fx.appData, fileManager: .default)
        XCTAssertTrue(running)
    }
}
#endif // os(macOS)
