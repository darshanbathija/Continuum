import XCTest
@testable import ClawdmeterShared

/// Exercises AgyConversationReader against a synthetic
/// `~/.gemini/antigravity-cli/` layout under a tempdir. Hermetic: never
/// touches the real install on the test runner.
final class AgyConversationReaderTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let conversationsDir: URL
        let brainDir: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-reader-\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        let brain = root.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, conversationsDir: conversations, brainDir: brain)
    }

    // MARK: - Install detection

    func test_isInstalled_returnsFalse_whenDirectoryMissing() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(AgyConversationReader.isInstalled(rootURL: bogus))
    }

    func test_isInstalled_returnsTrue_whenConversationsDirExists() throws {
        let fixture = try makeFixture()
        XCTAssertTrue(AgyConversationReader.isInstalled(rootURL: fixture.root))
    }

    // MARK: - Read

    func test_read_emptyDirectory_returnsEmptySnapshot() throws {
        let fixture = try makeFixture()
        let snapshot = AgyConversationReader.read(rootURL: fixture.root)
        XCTAssertEqual(snapshot, .empty)
    }

    func test_read_missingDirectory_returnsEmptySnapshot() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(AgyConversationReader.read(rootURL: bogus), .empty)
    }

    func test_read_singlePlaintextConversation_estimatesTokensFromBrainMarkdown() throws {
        let fixture = try makeFixture()
        let uuid = "11111111-1111-4111-8111-111111111111"

        // Plaintext-ish .pb (well under the 0.45 non-printable threshold).
        let payload = String(repeating: "list_dir tool_call_id ", count: 64)
        try payload.write(
            to: fixture.conversationsDir.appendingPathComponent("\(uuid).pb"),
            atomically: true,
            encoding: .utf8
        )

        // Matching brain dir with a markdown artifact for the token estimate.
        let brain = fixture.brainDir.appendingPathComponent(uuid, isDirectory: true)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        let markdown = String(repeating: "x", count: 400) // 400 bytes / 4 = 100 tokens
        try markdown.write(
            to: brain.appendingPathComponent("task.md"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = AgyConversationReader.read(rootURL: fixture.root)
        XCTAssertEqual(snapshot.conversationCount, 1)
        XCTAssertEqual(snapshot.conversations.first?.conversationUUID, uuid)
        XCTAssertEqual(snapshot.conversations.first?.probe.kind, .plaintext)
        XCTAssertEqual(snapshot.totalEstimatedTokens, 100)
        XCTAssertNotNil(snapshot.conversations.first?.brainURL)
        XCTAssertNotNil(snapshot.lastModified)
    }

    func test_read_conversationWithoutBrainDir_returnsZeroTokenEstimate() throws {
        let fixture = try makeFixture()
        let uuid = "22222222-2222-4222-8222-222222222222"

        try "plaintext payload".write(
            to: fixture.conversationsDir.appendingPathComponent("\(uuid).pb"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = AgyConversationReader.read(rootURL: fixture.root)
        XCTAssertEqual(snapshot.conversationCount, 1)
        XCTAssertNil(snapshot.conversations.first?.brainURL)
        XCTAssertEqual(snapshot.totalEstimatedTokens, 0)
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
    }

    func test_read_multipleConversations_sortedByMtimeDescending() throws {
        let fixture = try makeFixture()
        let older = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let newer = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        try "old".write(
            to: fixture.conversationsDir.appendingPathComponent("\(older).pb"),
            atomically: true,
            encoding: .utf8
        )
        // Backdate the older file so the sort order is unambiguous.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: fixture.conversationsDir.appendingPathComponent("\(older).pb").path
        )
        try "new".write(
            to: fixture.conversationsDir.appendingPathComponent("\(newer).pb"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = AgyConversationReader.read(rootURL: fixture.root)
        XCTAssertEqual(snapshot.conversationCount, 2)
        XCTAssertEqual(snapshot.conversations.first?.conversationUUID, newer)
        XCTAssertEqual(snapshot.conversations.last?.conversationUUID, older)
    }

    func test_read_ignoresNonPbFiles() throws {
        let fixture = try makeFixture()
        let uuid = "33333333-3333-4333-8333-333333333333"
        try "real".write(
            to: fixture.conversationsDir.appendingPathComponent("\(uuid).pb"),
            atomically: true,
            encoding: .utf8
        )
        // Sibling junk that the reader must skip.
        try "ignore me".write(
            to: fixture.conversationsDir.appendingPathComponent("\(uuid).db-wal"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: fixture.conversationsDir.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = AgyConversationReader.read(rootURL: fixture.root)
        XCTAssertEqual(snapshot.conversationCount, 1)
        XCTAssertEqual(snapshot.conversations.first?.conversationUUID, uuid)
    }

    // MARK: - Default root resolution

    func test_defaultRoot_pointsAtAntigravityCliDir() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let root = AgyConversationReader.defaultRoot(homeDirectory: home)
        XCTAssertEqual(root.path, "/Users/example/.gemini/antigravity-cli")
    }
}
