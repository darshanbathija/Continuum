import XCTest
@testable import ClawdmeterShared

/// Verifies the encryption detection heuristic + metadata-based usage
/// estimators in `ConversationProtoParser`. We exercise both the
/// `.encrypted` and `.plaintext` branches with synthetic byte fixtures
/// — the heuristic is empirically derived from a 36-file live corpus
/// (every file ~58% non-printable), so the threshold check needs
/// explicit cases on both sides.
final class ConversationProtoParserTests: XCTestCase {

    private func tempBrain(file: StaticString = #file, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - File kind detection

    func test_probe_missingFileProducesMissingKind() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).pb")
        let probe = ConversationProtoParser.probe(conversationURL: url)
        XCTAssertEqual(probe.kind, .missing)
        XCTAssertEqual(probe.fileSize, 0)
        XCTAssertFalse(probe.hasReadableContent)
    }

    func test_probe_emptyFileProducesEmptyKind() throws {
        let dir = try tempBrain()
        let url = dir.appendingPathComponent("conv.pb")
        try Data().write(to: url)
        let probe = ConversationProtoParser.probe(conversationURL: url)
        XCTAssertEqual(probe.kind, .empty)
    }

    func test_probe_encryptedFileProducesEncryptedKind() throws {
        // Generate 1024 bytes of uniformly-random data (simulates the
        // ciphertext byte distribution we observe on real Antigravity
        // conversation files).
        var randomBytes = [UInt8](repeating: 0, count: 1024)
        for i in 0..<randomBytes.count { randomBytes[i] = UInt8.random(in: 0...255) }
        let dir = try tempBrain()
        let url = dir.appendingPathComponent("conv.pb")
        try Data(randomBytes).write(to: url)

        let probe = ConversationProtoParser.probe(conversationURL: url)
        XCTAssertEqual(probe.kind, .encrypted, "Uniform-random bytes should be detected as encrypted")
        XCTAssertFalse(probe.hasReadableContent)
    }

    func test_probe_plaintextFileProducesPlaintextKind() throws {
        // A plaintext protobuf is mostly readable bytes — strings are
        // ASCII, varint integers cluster in the 0-127 single-byte range.
        let plaintext = String(repeating: "hello world this is a plaintext message\n", count: 100)
        let dir = try tempBrain()
        let url = dir.appendingPathComponent("conv.pb")
        try plaintext.data(using: .utf8)!.write(to: url)

        let probe = ConversationProtoParser.probe(conversationURL: url)
        XCTAssertEqual(probe.kind, .plaintext)
        XCTAssertTrue(probe.hasReadableContent)
    }

    // MARK: - Threshold edge cases

    func test_thresholdSeparatesPlaintextFromEncrypted() {
        // 100% printable: 0% non-printable → plaintext.
        let plaintext = Data([UInt8]("abcdefghij".utf8))
        XCTAssertEqual(ConversationProtoParser.countNonPrintable(in: plaintext), 0)

        // 100% non-printable: 100% non-printable → encrypted.
        let encrypted = Data([UInt8](repeating: 0x00, count: 10))
        XCTAssertEqual(ConversationProtoParser.countNonPrintable(in: encrypted), 10)

        // Threshold should be in between; 45% is well-separated from real
        // plaintext (~15%) and real encrypted (~58%).
        XCTAssertEqual(ConversationProtoParser.encryptionThreshold, 0.45, accuracy: 0.01)
    }

    func test_countNonPrintable_excludesAsciiControlCharsWeAccept() {
        // tab, newline, CR all count as printable for our purposes.
        let data = Data([0x09, 0x0a, 0x0d, 0x20, 0x7e])
        XCTAssertEqual(ConversationProtoParser.countNonPrintable(in: data), 0)
    }

    func test_countNonPrintable_countsLowAndHighBytes() {
        // 0x00, 0x01, 0xff all non-printable.
        let data = Data([0x00, 0x01, 0x1f, 0x7f, 0x80, 0xff])
        XCTAssertEqual(ConversationProtoParser.countNonPrintable(in: data), 6)
    }

    // MARK: - Turn count

    func test_countTurns_zeroForEmptyBrain() throws {
        let brain = try tempBrain()
        XCTAssertEqual(ConversationProtoParser.countTurns(brainURL: brain, fileManager: .default), 0)
    }

    func test_countTurns_oneMetadataJsonPerArtifact() throws {
        let brain = try tempBrain()
        try "{}".write(to: brain.appendingPathComponent("task.md.metadata.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: brain.appendingPathComponent("implementation_plan.md.metadata.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: brain.appendingPathComponent("walkthrough.md.metadata.json"), atomically: true, encoding: .utf8)

        let count = ConversationProtoParser.countTurns(brainURL: brain, fileManager: .default)
        XCTAssertEqual(count, 3)
    }

    func test_countTurns_excludesNonMetadataFiles() throws {
        let brain = try tempBrain()
        try "{}".write(to: brain.appendingPathComponent("task.md.metadata.json"), atomically: true, encoding: .utf8)
        try "task".write(to: brain.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: brain.appendingPathComponent("not-metadata.json"), atomically: true, encoding: .utf8)

        let count = ConversationProtoParser.countTurns(brainURL: brain, fileManager: .default)
        XCTAssertEqual(count, 1, "Only `.metadata.json`-suffixed files count")
    }

    // MARK: - Token estimate

    func test_estimateTokens_sumsMarkdownArtifactByteSizesAndDividesByFour() throws {
        let brain = try tempBrain()
        // Write a 400-byte task.md → 100 estimated tokens.
        let payload = String(repeating: "x", count: 400)
        try payload.write(to: brain.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)

        let tokens = ConversationProtoParser.estimatePlaintextTokens(brainURL: brain, fileManager: .default)
        XCTAssertEqual(tokens, 100, "400 bytes ÷ 4 = 100 tokens")
    }

    func test_estimateTokens_sumsAcrossMultipleMarkdownArtifacts() throws {
        let brain = try tempBrain()
        try String(repeating: "x", count: 400).write(to: brain.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 800).write(to: brain.appendingPathComponent("implementation_plan.md"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 200).write(to: brain.appendingPathComponent("walkthrough.md"), atomically: true, encoding: .utf8)

        let tokens = ConversationProtoParser.estimatePlaintextTokens(brainURL: brain, fileManager: .default)
        XCTAssertEqual(tokens, 350, "(400 + 800 + 200) ÷ 4 = 350 tokens")
    }

    func test_estimateTokens_zeroWhenNoMarkdown() throws {
        let brain = try tempBrain()
        try "{}".write(to: brain.appendingPathComponent("task.metadata.json"), atomically: true, encoding: .utf8)
        let tokens = ConversationProtoParser.estimatePlaintextTokens(brainURL: brain, fileManager: .default)
        XCTAssertEqual(tokens, 0)
    }

    // MARK: - Full probe with brain context

    func test_probe_attachesTurnCountAndEstimateWhenBrainProvided() throws {
        let brain = try tempBrain()
        try "{}".write(to: brain.appendingPathComponent("task.md.metadata.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: brain.appendingPathComponent("implementation_plan.md.metadata.json"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 400).write(to: brain.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)

        let convURL = brain.appendingPathComponent("conv.pb")
        // Encrypted-looking content.
        var randomBytes = [UInt8](repeating: 0, count: 1024)
        for i in 0..<randomBytes.count { randomBytes[i] = UInt8.random(in: 0...255) }
        try Data(randomBytes).write(to: convURL)

        let probe = ConversationProtoParser.probe(conversationURL: convURL, brainURL: brain)
        XCTAssertEqual(probe.kind, .encrypted)
        XCTAssertEqual(probe.turnCount, 2)
        XCTAssertEqual(probe.estimatedTokens, 100)
        XCTAssertGreaterThan(probe.fileSize, 0)
    }

    func test_probe_skipsBrainQueriesWhenBrainNil() throws {
        let brain = try tempBrain()
        let convURL = brain.appendingPathComponent("conv.pb")
        try Data(repeating: 0xff, count: 1024).write(to: convURL)

        let probe = ConversationProtoParser.probe(conversationURL: convURL, brainURL: nil)
        XCTAssertEqual(probe.turnCount, 0)
        XCTAssertEqual(probe.estimatedTokens, 0)
    }
}
