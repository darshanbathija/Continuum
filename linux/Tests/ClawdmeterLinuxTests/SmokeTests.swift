import XCTest

final class SmokeTests: XCTestCase {

    /// Phase 0 acceptance: the test target compiles and at least one
    /// XCTest assertion runs. Real tests land in Phases 3+.
    func testFrameworkLoads() {
        XCTAssertEqual(2 + 2, 4)
    }

    /// Sanity check that we can read Foundation env vars — XDG basedir
    /// resolution in Phase 3 depends on this working on Linux + macOS.
    func testEnvironmentReadable() {
        let home = ProcessInfo.processInfo.environment["HOME"]
        XCTAssertNotNil(home, "HOME must be set on every POSIX platform")
    }
}
