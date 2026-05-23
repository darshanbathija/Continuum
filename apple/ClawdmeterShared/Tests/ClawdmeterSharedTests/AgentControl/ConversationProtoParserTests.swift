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

    // MARK: - v0.8.0 step_payload decode (Phase 0.5 fixtures)

    /// Build the synthetic step_payload bytes from the Phase 0.5 hex
    /// dump in docs/agentapi-event-catalog.md. Outer wrapper:
    /// `08 <st> 20 <stat> 2A <len> <inner...>`
    private func encodeStepPayload(
        stepType: UInt8,
        status: UInt8,
        inner: [UInt8]
    ) -> Data {
        var bytes: [UInt8] = [0x08, stepType, 0x20, status, 0x2A]
        bytes += varint(inner.count)
        bytes += inner
        return Data(bytes)
    }

    private func encodeToolCallInner(toolCallId: String, toolName: String) -> [UInt8] {
        // Inner field 4 = toolcall submessage; field 1 = id, field 2 = name.
        let idBytes = [UInt8](toolCallId.utf8)
        let nameBytes = [UInt8](toolName.utf8)
        var toolCall: [UInt8] = []
        toolCall += [0x0A]
        toolCall += varint(idBytes.count)
        toolCall += idBytes
        toolCall += [0x12]
        toolCall += varint(nameBytes.count)
        toolCall += nameBytes

        var inner: [UInt8] = []
        inner += [0x22] // field 4 length-delim
        inner += varint(toolCall.count)
        inner += toolCall
        return inner
    }

    private func varint(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v & 0x7F))
        return out
    }

    func test_decode_returnsStepTypeAndStatusForToolCall() {
        let inner = encodeToolCallInner(toolCallId: "abc123", toolName: "list_dir")
        let payload = encodeStepPayload(stepType: 9, status: 3, inner: inner)
        let decoded = ConversationProtoParser.decode(payload)
        XCTAssertEqual(decoded.stepType, 9)
        XCTAssertEqual(decoded.stepStatus, 3)
        XCTAssertTrue(decoded.parseClean)
    }

    func test_decode_extractsToolNameAndCallIdFromNestedPayload() {
        let inner = encodeToolCallInner(toolCallId: "vdmtno6", toolName: "view_file")
        let payload = encodeStepPayload(stepType: 8, status: 3, inner: inner)
        let decoded = ConversationProtoParser.decode(payload)
        XCTAssertEqual(decoded.toolCallId, "vdmtno6")
        XCTAssertEqual(decoded.toolName, "view_file")
        XCTAssertTrue(decoded.parseClean)
    }

    func test_decode_handlesLongerToolNamesAndUTF8() {
        let inner = encodeToolCallInner(toolCallId: "longer-id-1234", toolName: "apply_patch")
        let payload = encodeStepPayload(stepType: 9, status: 3, inner: inner)
        let decoded = ConversationProtoParser.decode(payload)
        XCTAssertEqual(decoded.toolCallId, "longer-id-1234")
        XCTAssertEqual(decoded.toolName, "apply_patch")
    }

    func test_decode_toleratesUnknownOuterFields() {
        // Insert a field 3 varint between known fields → decoder must
        // skip it without losing the toolcall.
        let inner = encodeToolCallInner(toolCallId: "x", toolName: "list_dir")
        var bytes: [UInt8] = [0x08, 0x09, 0x18, 0x07, 0x20, 0x03, 0x2A]
        bytes += varint(inner.count)
        bytes += inner
        let decoded = ConversationProtoParser.decode(Data(bytes))
        XCTAssertEqual(decoded.stepType, 9)
        XCTAssertEqual(decoded.stepStatus, 3)
        XCTAssertEqual(decoded.toolName, "list_dir")
        XCTAssertTrue(decoded.parseClean)
    }

    func test_decode_emptyDataYieldsAllNils() {
        let decoded = ConversationProtoParser.decode(Data())
        XCTAssertNil(decoded.stepType)
        XCTAssertNil(decoded.stepStatus)
        XCTAssertNil(decoded.toolCallId)
        XCTAssertNil(decoded.toolName)
        XCTAssertTrue(decoded.parseClean) // empty != malformed
    }

    func test_decode_truncatedLengthDelimitedMarksUnclean() {
        // Outer field 5 with length 100 but only 3 bytes follow.
        var bytes: [UInt8] = [0x08, 0x09, 0x20, 0x03, 0x2A, 0x64]
        bytes += [0xAA, 0xBB, 0xCC]
        let decoded = ConversationProtoParser.decode(Data(bytes))
        XCTAssertEqual(decoded.stepType, 9)
        XCTAssertEqual(decoded.stepStatus, 3)
        XCTAssertFalse(decoded.parseClean)
    }

    func test_decode_innerWithoutToolCallSubmessageStillReturnsOuterFields() {
        // Inner with only field 1 (metadata) — no field 4 toolcall.
        // Field 1 length-delim, 4 bytes of garbage.
        let inner: [UInt8] = [0x0A, 0x04, 0xAA, 0xBB, 0xCC, 0xDD]
        let payload = encodeStepPayload(stepType: 13, status: 1, inner: inner)
        let decoded = ConversationProtoParser.decode(payload)
        XCTAssertEqual(decoded.stepType, 13)
        XCTAssertEqual(decoded.stepStatus, 1)
        XCTAssertNil(decoded.toolName)
        XCTAssertNil(decoded.toolCallId)
        XCTAssertTrue(decoded.parseClean)
    }

    func test_decode_realPhase05Hex_listDir() {
        // Phase 0.5 hex from docs/agentapi-event-catalog.md row 3.
        // Trimmed to the relevant outer/inner/toolcall slice. tool_call_id
        // "igigay6r" (8 bytes), tool_name "list_dir" (8 bytes). Note: doc
        // showed "gigay6rl3" as 9 chars but the hex bytes are 8 — the
        // doc has an off-by-one in the prose annotation; the wire bytes
        // are the source of truth.
        let inner = encodeToolCallInner(toolCallId: "igigay6r", toolName: "list_dir")
        let payload = encodeStepPayload(stepType: 9, status: 3, inner: inner)
        let decoded = ConversationProtoParser.decode(payload)
        XCTAssertEqual(decoded.stepType, 9)
        XCTAssertEqual(decoded.stepStatus, 3)
        XCTAssertEqual(decoded.toolName, "list_dir")
        XCTAssertEqual(decoded.toolCallId, "igigay6r")
        XCTAssertTrue(decoded.parseClean)
    }

    // MARK: - [Message] block scrape (2.0.6 chat-reply extraction)

    func test_messageBlock_extractsAgentReplyFromStepType101() {
        // Synthesized payload mimicking the shape Antigravity 2.0.6
        // step_type=101 rows actually carry: arbitrary proto-header bytes,
        // the ASCII `[Message] ` marker, structured fields up to
        // `content=…`, then a protobuf tag/length boundary (low byte) that
        // terminates the string. The scraper should ignore the binary
        // surround and pull out the four structured fields.
        let prefix = Data([0x08, 0x65, 0x20, 0x03, 0x2A, 0x7B])
        let messageText = "[Message] timestamp=2026-05-23T01:00:00Z sender=64d4fe97-f999-4078-8a44-5b776543c90d priority=MESSAGE_PRIORITY_HIGH content=# Summary\nA binary search tree keeps left < node < right at every node."
        let body = Data(messageText.utf8)
        let suffix = Data([0x12, 0x04, 0x68, 0x69])  // proto tag terminating
        let payload = prefix + body + suffix

        let blocks = ConversationProtoParser.scrapeMessageBlocks(payload)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.sender, "64d4fe97-f999-4078-8a44-5b776543c90d")
        XCTAssertEqual(blocks.first?.timestamp, "2026-05-23T01:00:00Z")
        XCTAssertEqual(blocks.first?.priority, "MESSAGE_PRIORITY_HIGH")
        XCTAssertEqual(blocks.first?.content,
                       "# Summary\nA binary search tree keeps left < node < right at every node.")
        if case .agent(let id) = blocks.first?.senderKind {
            XCTAssertEqual(id, "64d4fe97-f999-4078-8a44-5b776543c90d")
        } else {
            XCTFail("bare-UUID sender should classify as .agent")
        }
    }

    func test_messageBlock_classifiesSystemSenderAsUserPromptEcho() {
        let text = "[Message] timestamp=2026-05-23T01:00:00Z sender=system priority=MESSAGE_PRIORITY_HIGH content=Say hi in one short sentence."
        let payload = Data([0x2A, 0x7F]) + Data(text.utf8) + Data([0x12, 0x00])
        let blocks = ConversationProtoParser.scrapeMessageBlocks(payload)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.senderKind, .system)
    }

    func test_messageBlock_classifiesTaskCompletionSender() {
        let text = "[Message] timestamp=2026-05-23T01:00:00Z sender=2a8342b1-af24-4f15-8209-fb65a36c4d93/task-23 priority=MESSAGE_PRIORITY_HIGH content=Task id \"2a8342b1.../task-23\" finished with result: ok"
        let payload = Data([0x2A, 0x80, 0x01]) + Data(text.utf8) + Data([0x12, 0x00])
        let blocks = ConversationProtoParser.scrapeMessageBlocks(payload)
        XCTAssertEqual(blocks.count, 1)
        if case .taskCompletion(let taskId) = blocks.first?.senderKind {
            XCTAssertEqual(taskId, "task-23")
        } else {
            XCTFail("sender with `/task-N` suffix should classify as .taskCompletion")
        }
    }

    func test_messageBlock_extractsMultipleBlocksInSinglePayload() {
        // Larger conversations can pack the user prompt + an agent
        // summary + a task signal into the same step_type=101 row. All
        // three should round-trip out, in document order.
        let m1 = "[Message] timestamp=2026-05-23T01:00:00Z sender=system priority=P1 content=hello"
        let m2 = "[Message] timestamp=2026-05-23T01:00:05Z sender=aaa-bbb-ccc priority=P2 content=hi back"
        let payload =
            Data([0x2A, 0x40]) + Data(m1.utf8) +
            Data([0x12, 0x00, 0x2A, 0x40]) + Data(m2.utf8) +
            Data([0x12, 0x00])
        let blocks = ConversationProtoParser.scrapeMessageBlocks(payload)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].senderKind, .system)
        if case .agent(let id) = blocks[1].senderKind {
            XCTAssertEqual(id, "aaa-bbb-ccc")
        } else {
            XCTFail("second block should be agent")
        }
    }

    func test_messageBlock_rejectsMalformedShape() {
        // A payload containing the `[Message] ` marker but missing one
        // of the required fields (no `priority=`) should be discarded —
        // defends against the marker appearing inside an unrelated
        // tool-arg string.
        let bad = "[Message] timestamp=ts sender=who content=text"
        let payload = Data([0x2A, 0x40]) + Data(bad.utf8) + Data([0x12, 0x00])
        XCTAssertEqual(ConversationProtoParser.scrapeMessageBlocks(payload).count, 0)
    }

    func test_decode_populatesMessagesFromStepPayload() {
        // End-to-end: decode() should expose the scraped messages on
        // the returned DecodedStep so the chat ingestor doesn't have to
        // call the scraper separately.
        let text = "[Message] timestamp=2026-05-23T01:00:00Z sender=zzz-zzz priority=P content=hi"
        let payload = Data([0x08, 0x65, 0x20, 0x03, 0x2A, 0x60]) + Data(text.utf8) + Data([0x12, 0x00])
        let decoded = ConversationProtoParser.decode(payload)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages.first?.content, "hi")
    }
}
