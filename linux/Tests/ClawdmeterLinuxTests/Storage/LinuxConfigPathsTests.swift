import XCTest
@testable import ClawdmeterLinux

final class LinuxConfigPathsTests: XCTestCase {

    func testDataHomeRespectsXDG() {
        // Save+restore env so tests don't pollute.
        let key = "XDG_DATA_HOME"
        let prev = ProcessInfo.processInfo.environment[key]
        defer { setenv(key, prev ?? "", 1) }
        setenv(key, "/tmp/test-xdg-data", 1)

        let url = LinuxConfigPaths.dataHome
        XCTAssertEqual(url.path, "/tmp/test-xdg-data/clawdmeter")
    }

    func testDataHomeFallback() {
        let key = "XDG_DATA_HOME"
        let prev = ProcessInfo.processInfo.environment[key]
        defer { setenv(key, prev ?? "", 1) }
        unsetenv(key)

        let url = LinuxConfigPaths.dataHome
        XCTAssertTrue(url.path.hasSuffix("/.local/share/clawdmeter"))
    }

    func testConfigHomeRespectsXDG() {
        let key = "XDG_CONFIG_HOME"
        let prev = ProcessInfo.processInfo.environment[key]
        defer { setenv(key, prev ?? "", 1) }
        setenv(key, "/tmp/test-xdg-config", 1)

        XCTAssertEqual(LinuxConfigPaths.configHome.path, "/tmp/test-xdg-config/clawdmeter")
    }

    func testRuntimeDirRespectsXDG() {
        let key = "XDG_RUNTIME_DIR"
        let prev = ProcessInfo.processInfo.environment[key]
        defer { setenv(key, prev ?? "", 1) }
        setenv(key, "/run/user/1000", 1)

        XCTAssertEqual(LinuxConfigPaths.runtimeDir.path, "/run/user/1000/clawdmeter")
    }

    func testRuntimeDirTmpFallback() {
        let key = "XDG_RUNTIME_DIR"
        let prev = ProcessInfo.processInfo.environment[key]
        defer { setenv(key, prev ?? "", 1) }
        unsetenv(key)

        let url = LinuxConfigPaths.runtimeDir
        XCTAssertTrue(url.path.hasPrefix("/tmp/clawdmeter-"))
    }

    func testConvenienceFiles() {
        // Just verify these don't crash + produce sensible paths.
        XCTAssertTrue(LinuxConfigPaths.usageStoreFile.path.hasSuffix("/usage-store.json"))
        XCTAssertTrue(LinuxConfigPaths.bearerTokenFile.path.hasSuffix("/.token"))
        XCTAssertTrue(LinuxConfigPaths.gaugePNGDir.path.hasSuffix("/gauge"))
        XCTAssertTrue(LinuxConfigPaths.auditLogDir.path.hasSuffix("/audit"))
    }

    func testEnsureDirectoryCreates() throws {
        let temp = URL(fileURLWithPath: "/tmp/clawdmeter-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        try LinuxConfigPaths.ensureDirectory(temp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))

        // Idempotent: second call doesn't throw.
        XCTAssertNoThrow(try LinuxConfigPaths.ensureDirectory(temp))
    }
}
