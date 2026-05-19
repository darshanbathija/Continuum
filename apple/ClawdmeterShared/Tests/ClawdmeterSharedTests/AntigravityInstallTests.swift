#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Probes the `AntigravityInstall.detect` implementation by handing it a
/// synthetic filesystem layout under a tempdir. We never touch the real
/// `/Applications/Antigravity.app/` or `~/.gemini/antigravity/` here —
/// `detect` is parameterized on `homeDirectory` + `applicationsRoot` for
/// exactly this reason.
final class AntigravityInstallTests: XCTestCase {

    // MARK: - Fixture helpers

    private struct Fixture {
        let homeDir: URL
        let appsRoot: URL
        let appBundle: URL
        let appData: URL
        let agyNode: URL
    }

    private func makeFixture(file: StaticString = #file, line: UInt = #line) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-install-test-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let appBundle = apps.appendingPathComponent("Antigravity.app", isDirectory: true)
        let appData = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let agyDir = home.appendingPathComponent(
            "Library/Application Support/Antigravity/bin",
            isDirectory: true
        )
        let agyNode = agyDir.appendingPathComponent("agy-node", isDirectory: false)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(homeDir: home, appsRoot: apps, appBundle: appBundle, appData: appData, agyNode: agyNode)
    }

    private func touch(_ url: URL, contents: String = "") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Detect

    func test_detect_absentWhenAllAnchorsMissing() throws {
        let fx = try makeFixture()
        let result = AntigravityInstall.detect(
            homeDirectory: fx.homeDir,
            applicationsRoot: fx.appsRoot
        )
        XCTAssertEqual(result, .absent)
    }

    func test_detect_absentWhenAppBundleMissing() throws {
        let fx = try makeFixture()
        try makeDir(fx.appData)
        try touch(fx.agyNode)
        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        XCTAssertEqual(result, .absent, "Missing /Applications/Antigravity.app must report absent")
    }

    func test_detect_absentWhenDataDirMissing() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try touch(fx.agyNode)
        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        XCTAssertEqual(result, .absent, "Missing ~/.gemini/antigravity must report absent")
    }

    func test_detect_absentWhenAgyNodeMissing() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        XCTAssertEqual(result, .absent, "Missing agy-node must report absent")
    }

    func test_detect_installedWhenAllAnchorsPresent_serverNotRunning() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        try touch(fx.agyNode, contents: "#!/bin/sh\nexit 0\n")
        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        guard case let .installed(installed) = result else {
            return XCTFail("Expected .installed; got \(result)")
        }
        XCTAssertEqual(installed.appBundleURL, fx.appBundle)
        XCTAssertEqual(installed.appDataDir, fx.appData)
        XCTAssertEqual(installed.agyNodePath, fx.agyNode)
        XCTAssertFalse(installed.hasRunningServer, "No logs/ subdir means hasRunningServer = false")
        XCTAssertNil(installed.appVersion, "No Info.plist means appVersion = nil")
    }

    func test_detect_serverRunningWhenLsMainLogPresent() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        try touch(fx.agyNode)
        // Antigravity creates `logs/<UNIXTS>/ls-main.log` on every launch.
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
        try touch(fx.agyNode)
        // Minimal valid binary plist with CFBundleShortVersionString = "2.0.0".
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.0.0"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let plistURL = fx.appBundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        try makeDir(plistURL.deletingLastPathComponent())
        try plistData.write(to: plistURL)

        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        guard case let .installed(installed) = result else {
            return XCTFail("Expected .installed; got \(result)")
        }
        XCTAssertEqual(installed.appVersion, "2.0.0")
    }

    func test_detect_appVersionNilOnMalformedPlist() throws {
        let fx = try makeFixture()
        try makeDir(fx.appBundle)
        try makeDir(fx.appData)
        try touch(fx.agyNode)
        // Write garbage to Info.plist — the parser should NOT throw, just return nil.
        let plistURL = fx.appBundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        try makeDir(plistURL.deletingLastPathComponent())
        try "this is not a plist".write(to: plistURL, atomically: true, encoding: .utf8)

        let result = AntigravityInstall.detect(homeDirectory: fx.homeDir, applicationsRoot: fx.appsRoot)
        guard case let .installed(installed) = result else {
            return XCTFail("Expected .installed; got \(result)")
        }
        XCTAssertNil(installed.appVersion)
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
        // No ls-main.log inside the subdir.
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
