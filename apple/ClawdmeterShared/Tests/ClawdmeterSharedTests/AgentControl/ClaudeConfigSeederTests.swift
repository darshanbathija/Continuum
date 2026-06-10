import XCTest
@testable import ClawdmeterShared

/// Tests for `ClaudeConfigSeeder` — onboarding-flag seeding for fresh
/// per-instance `CLAUDE_CONFIG_DIR` roots (multi-account Phase 2).
final class ClaudeConfigSeederTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeConfigSeederTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSeedCreatesDirAndOnboardingFlags() throws {
        let root = tempDir.appendingPathComponent("claude-work", isDirectory: true)
        XCTAssertTrue(ClaudeConfigSeeder.seed(at: root))

        let configFile = root.appendingPathComponent(".claude.json")
        let data = try Data(contentsOf: configFile)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["hasCompletedOnboarding"] as? Bool, true)
    }

    func testSeedNeverOverwritesExistingConfig() throws {
        let root = tempDir.appendingPathComponent("claude-work", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configFile = root.appendingPathComponent(".claude.json")
        let userBytes = Data(#"{"hasCompletedOnboarding": true, "userManaged": 42}"#.utf8)
        try userBytes.write(to: configFile)

        XCTAssertTrue(ClaudeConfigSeeder.seed(at: root))

        // The CLI-or-user-owned file must be byte-identical.
        XCTAssertEqual(try Data(contentsOf: configFile), userBytes)
    }

    func testSeedIsIdempotent() throws {
        let root = tempDir.appendingPathComponent("claude-work", isDirectory: true)
        XCTAssertTrue(ClaudeConfigSeeder.seed(at: root))
        let first = try Data(contentsOf: root.appendingPathComponent(".claude.json"))
        XCTAssertTrue(ClaudeConfigSeeder.seed(at: root))
        let second = try Data(contentsOf: root.appendingPathComponent(".claude.json"))
        XCTAssertEqual(first, second)
    }
}
