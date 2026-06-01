import XCTest
@testable import Clawdmeter

/// Covers the spawn-PATH enrichment that fixes "node: command not found" in
/// agent panes. The GUI app inherits launchd's minimal PATH; spawned panes
/// must get the user's real PATH (or at least the Homebrew backstop) so the
/// agent's node-based hooks resolve.
final class SpawnPathResolverTests: XCTestCase {

    func test_compute_loginShellFirst_backstopsFolded_dedup() {
        let path = SpawnPathResolver.compute(
            loginShell: "/opt/homebrew/bin:/usr/bin",
            processPATH: "/usr/bin:/bin"
        )
        let dirs = path.split(separator: ":").map(String.init)
        // Homebrew (where node lives) is present.
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
        // Backstop /usr/local/bin folded in even though neither input had it.
        XCTAssertTrue(dirs.contains("/usr/local/bin"))
        // Login-shell entry comes before the process-only entry.
        XCTAssertLessThan(dirs.firstIndex(of: "/opt/homebrew/bin")!, dirs.firstIndex(of: "/bin")!)
        // No duplicates (/usr/bin appeared in both inputs).
        XCTAssertEqual(dirs.count, Set(dirs).count)
    }

    func test_compute_noLoginShell_backstopStillProvidesNode() {
        // The regression case: login shell unreadable, process PATH is the
        // minimal launchd set. The Homebrew backstop must still appear.
        let path = SpawnPathResolver.compute(
            loginShell: nil,
            processPATH: "/usr/bin:/bin:/usr/sbin:/sbin"
        )
        XCTAssertTrue(path.split(separator: ":").map(String.init).contains("/opt/homebrew/bin"))
    }

    func test_merge_emptyEnv_setsEnrichedPATH() {
        let env = SpawnPathResolver.merge(env: [:], enriched: "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin")
    }

    func test_merge_callerPATHWins_enrichedAppended() {
        let env = SpawnPathResolver.merge(
            env: ["PATH": "/custom/bin", "FOO": "bar"],
            enriched: "/opt/homebrew/bin:/custom/bin"
        )
        let dirs = env["PATH"]!.split(separator: ":").map(String.init)
        // Caller's dir stays first (precedence for shadowed binaries).
        XCTAssertEqual(dirs.first, "/custom/bin")
        // Enriched dir is appended so node remains discoverable.
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
        // /custom/bin not duplicated.
        XCTAssertEqual(dirs.filter { $0 == "/custom/bin" }.count, 1)
        // Other env keys preserved.
        XCTAssertEqual(env["FOO"], "bar")
    }
}
