import XCTest
@testable import ClawdmeterShared

/// The subscription-billing invariant lives or dies here: after sanitize, the
/// child env must never carry ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN.
final class ClaudeSpawnEnvTests: XCTestCase {

    func testStripsApiKey() {
        let base = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-ant-leak"]
        let out = ClaudeSpawnEnv.sanitized(base: base)
        XCTAssertNil(out["ANTHROPIC_API_KEY"], "API key must be stripped")
        XCTAssertEqual(out["PATH"], "/usr/bin", "unrelated vars preserved")
    }

    func testStripsAuthToken() {
        let out = ClaudeSpawnEnv.sanitized(base: ["ANTHROPIC_AUTH_TOKEN": "tok"])
        XCTAssertNil(out["ANTHROPIC_AUTH_TOKEN"], "auth token must be stripped")
    }

    func testStripsBothEvenWhenBothPresent() {
        let base = ["ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "HOME": "/Users/x"]
        let out = ClaudeSpawnEnv.sanitized(base: base)
        XCTAssertFalse(ClaudeSpawnEnv.leaksAPICredential(out), "no credential may survive")
        XCTAssertEqual(out["HOME"], "/Users/x")
    }

    func testCleanEnvUnchangedAndDoesNotLeak() {
        let base = ["PATH": "/bin", "LANG": "en_US.UTF-8"]
        let out = ClaudeSpawnEnv.sanitized(base: base)
        XCTAssertEqual(out, base)
        XCTAssertFalse(ClaudeSpawnEnv.leaksAPICredential(out))
    }

    func testLeakDetectorIgnoresEmptyValues() {
        // An empty-string key is not a usable credential.
        XCTAssertFalse(ClaudeSpawnEnv.leaksAPICredential(["ANTHROPIC_API_KEY": ""]))
        XCTAssertTrue(ClaudeSpawnEnv.leaksAPICredential(["ANTHROPIC_API_KEY": "x"]))
    }
}
