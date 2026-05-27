import XCTest
@testable import ClawdmeterShared

/// F1e-wire parity tests: prove the `AntigravityAdapter`-routed analytics
/// path produces the same `[UsageRecord]` output as the legacy
/// `AntigravityUsageParser` for every representative Antigravity
/// conversation directory shape.
///
/// **Why this matters.** The F1e-wire PR introduces the
/// `FeatureFlags.useAntigravityAdapter` strangler-fig flag. With the flag
/// OFF, the analytics pipeline calls `AntigravityUsageParser.parse(...)`
/// directly. With the flag ON, it calls
/// `AntigravityAdapterUsageBridge.parse(...)` which routes through
/// `AntigravityAdapter.translate(...)`. Both paths must return the same
/// `[UsageRecord]` value. This suite is the authoritative parity
/// contract — failing it means the wire has silently changed analytics
/// output.
///
/// **Coverage.** Fixtures mirror every shape the legacy parser exercises:
///   - Happy-path conversation with brain dir + metadata.json turns
///     (byte-estimator path — `.pb`).
///   - Brain dir with no metadata.json files (zero turns → empty array).
///   - Brain UUID present in the BrainSummaryIndex (repo from index).
///   - Brain UUID NOT in the index → repo falls back to `antigravity/<prefix>`.
///   - Brain summary with cwd takes precedence over projectTitle.
///   - Brain summary with only projectTitle → repo = projectTitle.
///   - agy dedup prefix → dedupKey reflects the prefix.
///   - `.db` overload: see DB-overload tests under
///     `#if os(macOS) || os(iOS)` — the overload is platform-gated to
///     match the existing PR #154 guard.
///
/// **Plan:** F1e-wire (Phase 1; D23 strangler-fig) — last F1 wire.
final class F1eParityTests: XCTestCase {

    // MARK: - Setup

    override func tearDown() {
        super.tearDown()
        FeatureFlags.useAntigravityAdapterOverride = nil
    }

    /// Helper: build a minimal Antigravity conversation directory with N
    /// metadata.json files in the brain dir and a synthetic .pb file in
    /// conversations/. Returns the data dir + conversation URL.
    private func makeFixture(
        brainUUID: String = "11111111-1111-4111-8111-111111111111",
        metadataFiles: [String] = ["task.md.metadata.json"],
        plaintextSizes: [String: Int] = [:],
        extension ext: String = "pb"
    ) throws -> (dataDir: URL, conversationURL: URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-f1e")
        let brain = temp.appendingPathComponent("brain/\(brainUUID)", isDirectory: true)
        let conversations = temp.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)

        for name in metadataFiles {
            try "{}".write(to: brain.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for (name, size) in plaintextSizes {
            try String(repeating: "x", count: size)
                .write(to: brain.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // Encrypted-looking conversation file (random bytes).
        var randomBytes = [UInt8](repeating: 0, count: 1024)
        for i in 0..<randomBytes.count { randomBytes[i] = UInt8.random(in: 0...255) }
        let convURL = conversations.appendingPathComponent("\(brainUUID).\(ext)")
        try Data(randomBytes).write(to: convURL)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }
        return (temp, convURL)
    }

    /// Helper: build a minimal BrainSummaryIndex from a (uuid, cwd?, title?) tuple.
    private func makeIndex(
        brainUUID: String,
        cwd: URL? = nil,
        title: String? = nil
    ) -> BrainSummaryIndex {
        let summary = BrainSummary(
            brainUUID: brainUUID,
            cwd: cwd,
            projectTitle: title
        )
        var byCwd: [String: [String]] = [:]
        if let cwd { byCwd[cwd.path.lowercased()] = [brainUUID] }
        return BrainSummaryIndex(byUUID: [brainUUID: summary], byCwdPath: byCwd)
    }

    /// Helper: run both paths on the same fixture, assert structural equality.
    private func assertParity(
        conversationURL: URL,
        antigravityDataDir: URL,
        brainIndex: BrainSummaryIndex,
        modelName: String,
        dedupPrefix: String = "antigravity",
        file: StaticString = #file,
        testLine: UInt = #line
    ) throws {
        let legacy = try AntigravityUsageParser.parse(
            conversationURL: conversationURL,
            antigravityDataDir: antigravityDataDir,
            brainIndex: brainIndex,
            modelName: modelName,
            dedupPrefix: dedupPrefix
        )
        let adapted = try AntigravityAdapterUsageBridge.parse(
            conversationURL: conversationURL,
            antigravityDataDir: antigravityDataDir,
            brainIndex: brainIndex,
            modelName: modelName,
            dedupPrefix: dedupPrefix
        )
        XCTAssertEqual(legacy, adapted, """
        Parity violation:
          legacy:  \(legacy)
          adapted: \(adapted)
        """, file: file, line: testLine)
    }

    // MARK: - Happy paths (.pb byte-estimator)

    func test_parity_pbConversation_oneTurn_brainIndexHasCwd() throws {
        let brainUUID = "aaaaaaaa-1111-4111-8111-111111111111"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: ["task.md.metadata.json"],
            plaintextSizes: ["task.md": 400]
        )
        let index = makeIndex(
            brainUUID: brainUUID,
            cwd: URL(fileURLWithPath: "/Users/test/Repo")
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: index,
            modelName: "gemini-3.5-flash"
        )
    }

    func test_parity_pbConversation_multipleTurns() throws {
        let brainUUID = "bbbbbbbb-2222-4222-8222-222222222222"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: [
                "task.md.metadata.json",
                "plan.md.metadata.json",
                "design.md.metadata.json"
            ],
            plaintextSizes: [
                "task.md": 800,
                "plan.md": 1200,
                "design.md": 600
            ]
        )
        let index = makeIndex(
            brainUUID: brainUUID,
            cwd: URL(fileURLWithPath: "/Users/test/MultiTurn")
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: index,
            modelName: "gemini-3.5-flash"
        )
    }

    func test_parity_pbConversation_brainIndexEmpty_fallsBackToUUIDPrefix() throws {
        // Brain UUID not in index → repo = "antigravity/<8-char-prefix>".
        let brainUUID = "deadbeef-3333-4333-8333-333333333333"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: ["task.md.metadata.json"],
            plaintextSizes: ["task.md": 200]
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: .empty,
            modelName: "gemini-3.5-flash"
        )
    }

    func test_parity_pbConversation_brainIndexHasOnlyProjectTitle() throws {
        // No cwd, only projectTitle → repo = projectTitle.
        let brainUUID = "cccccccc-4444-4444-8444-444444444444"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: ["task.md.metadata.json"],
            plaintextSizes: ["task.md": 600]
        )
        let index = makeIndex(
            brainUUID: brainUUID,
            cwd: nil,
            title: "Friendly Project Title"
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: index,
            modelName: "gemini-3.5-flash"
        )
    }

    func test_parity_pbConversation_brainIndexCwdTakesPrecedenceOverTitle() throws {
        // When both are set, repo = cwd path (legacy semantics).
        let brainUUID = "abcdefab-5555-4555-8555-555555555555"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: ["task.md.metadata.json"],
            plaintextSizes: ["task.md": 1000]
        )
        let index = makeIndex(
            brainUUID: brainUUID,
            cwd: URL(fileURLWithPath: "/Users/test/CwdWins"),
            title: "ShouldNotAppear"
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: index,
            modelName: "gemini-3.5-flash"
        )
    }

    // MARK: - Drops (both paths return [])

    func test_parity_emptyBrain_zeroTurns_bothEmpty() throws {
        // Brain dir exists but has no metadata.json files → turnCount = 0 →
        // legacy returns []. Adapter wire must also return [].
        let brainUUID = "0badf00d-6666-4666-8666-666666666666"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: []
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: .empty,
            modelName: "gemini-3.5-flash"
        )
    }

    // MARK: - dedupPrefix variations

    func test_parity_agyDedupPrefix_keyReflectsPrefix() throws {
        // The agy CLI surface passes dedupPrefix: "agy" so its UUIDs
        // don't collide with the desktop Antigravity surface.
        let brainUUID = "aaaaaaaa-7777-4777-8777-777777777777"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: ["task.md.metadata.json"],
            plaintextSizes: ["task.md": 600]
        )
        let index = makeIndex(
            brainUUID: brainUUID,
            cwd: URL(fileURLWithPath: "/Users/test/AgyRepo")
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: index,
            modelName: "gemini-3.5-pro",
            dedupPrefix: "agy"
        )
    }

    // MARK: - Model passthrough

    func test_parity_modelPassedThrough() throws {
        // The model string the loader pulls off antigravity_state.pbtxt
        // gets propagated unchanged through both paths.
        let brainUUID = "abc12345-8888-4888-8888-888888888888"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: ["task.md.metadata.json"],
            plaintextSizes: ["task.md": 400]
        )
        let index = makeIndex(
            brainUUID: brainUUID,
            cwd: URL(fileURLWithPath: "/Users/test/ModelTest")
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: index,
            modelName: "gemini-3.0-experimental"
        )
    }

    // MARK: - .db overload (macOS/iOS only — matches PR #154 guard)

#if os(macOS) || os(iOS)
    /// `.db` files where the UsageMetadata extractor finds zero matches
    /// fall through to the byte estimator. Both paths must take that
    /// fallback. Synthetic random-bytes `.db` files reliably miss the
    /// signature, so this is a clean fallback exercise.
    func test_parity_dbConversation_noUsageMetadata_fallsBackToByteEstimator() throws {
        let brainUUID = "dbf41010-9999-4999-8999-999999999999"
        let fx = try makeFixture(
            brainUUID: brainUUID,
            metadataFiles: ["task.md.metadata.json"],
            plaintextSizes: ["task.md": 500],
            extension: "db" // random bytes won't be a real SQLite file
        )
        let index = makeIndex(
            brainUUID: brainUUID,
            cwd: URL(fileURLWithPath: "/Users/test/DBFallback")
        )
        try assertParity(
            conversationURL: fx.conversationURL,
            antigravityDataDir: fx.dataDir,
            brainIndex: index,
            modelName: "gemini-3.5-flash"
        )
    }

    /// `.db` overload direct unit test: feed the adapter a known
    /// `AntigravityDBUsage` and confirm the canonical event carries the
    /// same field values back. Lower-level than the full parser
    /// integration but locks the adapter contract in case
    /// AntigravityDBUsageParser's mapping ever shifts.
    func test_dbOverload_translateProducesMatchingEvent() {
        let dbUsage = AntigravityDBUsage(
            inputTokens: 19585,
            outputTokens: 194,
            cachedTokens: 16294,
            reasoningTokens: 139,
            toolUseTokens: 55,
            recordCount: 22
        )
        let events = AntigravityAdapter.translate(
            dbUsage: dbUsage,
            conversationUUID: "test-uuid",
            timestamp: Date(timeIntervalSince1970: 1716662400),
            modelName: "gemini-3.5-flash",
            cwd: "/Users/test/Repo",
            sessionId: "",
            sequenceNumber: 0
        )
        XCTAssertEqual(events.count, 1, "non-empty rollup → one canonical event")
        guard let event = events.first,
              case let .assistantMessageCompleted(_, tIn, tOut) = event.payload else {
            return XCTFail("Expected one assistantMessageCompleted event")
        }
        XCTAssertEqual(tIn, 19585)
        XCTAssertEqual(tOut, 194)

        // Extension envelope carries the full breakdown.
        guard case let .nested(ext) = event.providerExtensions?["antigravity"] else {
            return XCTFail("Expected antigravity extension envelope")
        }
        if case let .string(src) = ext["source"] { XCTAssertEqual(src, "db") } else { XCTFail("source missing") }
        if case let .int(c) = ext["cached_tokens"] { XCTAssertEqual(c, 16294) } else { XCTFail("cached missing") }
        if case let .int(r) = ext["reasoning_tokens"] { XCTAssertEqual(r, 139) } else { XCTFail("reasoning missing") }
        if case let .int(t) = ext["tool_use_tokens"] { XCTAssertEqual(t, 55) } else { XCTFail("toolUse missing") }
        if case let .int(m) = ext["match_count"] { XCTAssertEqual(m, 22) } else { XCTFail("match_count missing") }
    }

    /// `.db` empty-rollup contract: recordCount == 0 → adapter returns
    /// `[]`, matching the legacy parser's "no matches → fall back to byte
    /// estimator" branch (the bridge handles the fallback, not the
    /// adapter).
    func test_dbOverload_emptyRollupReturnsEmpty() {
        let events = AntigravityAdapter.translate(
            dbUsage: .empty,
            conversationUUID: "empty-uuid",
            timestamp: Date(),
            modelName: "gemini-3.5-flash",
            cwd: nil,
            sessionId: "",
            sequenceNumber: 0
        )
        XCTAssertTrue(events.isEmpty)
    }
#endif

    // MARK: - .pb overload — legacy record round-trip

    /// `.pb` overload direct unit test: feed the adapter a legacy
    /// `UsageRecord` and confirm the canonical event round-trips the
    /// tokens cleanly.
    func test_pbOverload_translateRoundTripsTokens() {
        let legacy = UsageRecord(
            provider: .gemini,
            timestamp: Date(timeIntervalSince1970: 1716662400),
            model: "gemini-3.5-flash",
            tokens: TokenTotals(
                inputTokens: 4200,
                outputTokens: 1800,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0,
                costUSD: 0,
                requestCount: 5
            ),
            repo: "/Users/test/Repo",
            dedupKey: "antigravity:test-uuid"
        )
        let events = AntigravityAdapter.translate(
            legacyRecord: legacy,
            conversationUUID: "test-uuid",
            sessionId: "",
            sequenceNumber: 0,
            isEstimated: true
        )
        XCTAssertEqual(events.count, 1)
        guard let event = events.first,
              case let .assistantMessageCompleted(_, tIn, tOut) = event.payload else {
            return XCTFail("Expected one assistantMessageCompleted event")
        }
        XCTAssertEqual(tIn, 4200)
        XCTAssertEqual(tOut, 1800)

        guard case let .nested(ext) = event.providerExtensions?["antigravity"] else {
            return XCTFail("Expected antigravity extension envelope")
        }
        if case let .string(src) = ext["source"] { XCTAssertEqual(src, "pb") } else { XCTFail("source missing") }
        if case let .bool(est) = ext["is_estimated"] { XCTAssertTrue(est) } else { XCTFail("is_estimated missing") }
    }

    // MARK: - Flag-off vs flag-on at the loader boundary

    /// End-to-end check: drive a conversation directory through the loader
    /// twice (once with the flag off, once with it on). The aggregate
    /// `UsageHistorySnapshot.byProvider[.gemini]` totals MUST match
    /// exactly. Catches regressions where the bridge silently drops or
    /// duplicates records at the loader-actor boundary.
    func test_parity_endToEnd_loaderSnapshotMatchesAcrossFlag() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("f1e-parity-loader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Antigravity 2 layout: dataDir/conversations/<uuid>.pb +
        // dataDir/brain/<uuid>/metadata.json files.
        let dataDir = tmp.appendingPathComponent("antigravity", isDirectory: true)
        let conversations = dataDir.appendingPathComponent("conversations", isDirectory: true)
        let brain1 = dataDir.appendingPathComponent("brain/uuid-1", isDirectory: true)
        let brain2 = dataDir.appendingPathComponent("brain/uuid-2", isDirectory: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brain1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brain2, withIntermediateDirectories: true)

        // brain/uuid-1: 2 turns, ~400 bytes content
        try "{}".write(to: brain1.appendingPathComponent("a.md.metadata.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: brain1.appendingPathComponent("b.md.metadata.json"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 400).write(to: brain1.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        // brain/uuid-2: 1 turn, ~800 bytes content
        try "{}".write(to: brain2.appendingPathComponent("a.md.metadata.json"), atomically: true, encoding: .utf8)
        try String(repeating: "y", count: 800).write(to: brain2.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        // .pb conversations (encrypted-looking random bytes).
        var randomBytes = [UInt8](repeating: 0, count: 1024)
        for i in 0..<randomBytes.count { randomBytes[i] = UInt8.random(in: 0...255) }
        try Data(randomBytes).write(to: conversations.appendingPathComponent("uuid-1.pb"))
        try Data(randomBytes).write(to: conversations.appendingPathComponent("uuid-2.pb"))

        // Empty Claude / Codex dirs so the loader doesn't pick stray data
        // off the host filesystem.
        let projectsDir = tmp.appendingPathComponent("projects", isDirectory: true)
        let codexDir = tmp.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        // Flag off
        FeatureFlags.useAntigravityAdapterOverride = false
        defer { FeatureFlags.useAntigravityAdapterOverride = nil }
        let loaderOff = UsageHistoryLoader(
            claudeDir: projectsDir,
            codexDir: codexDir,
            geminiDir: conversations,
            cacheURL: tmp.appendingPathComponent("cache-off.json")
        )
        let snapshotOff = await loaderOff.loadAll()

        // Flag on
        FeatureFlags.useAntigravityAdapterOverride = true
        let loaderOn = UsageHistoryLoader(
            claudeDir: projectsDir,
            codexDir: codexDir,
            geminiDir: conversations,
            cacheURL: tmp.appendingPathComponent("cache-on.json")
        )
        let snapshotOn = await loaderOn.loadAll()

        // Gemini provider totals must be identical across the flag.
        let off = snapshotOff.byProvider[.gemini]
        let on = snapshotOn.byProvider[.gemini]
        XCTAssertEqual(
            off?.allTime.totals.inputTokens,
            on?.allTime.totals.inputTokens,
            "Total input tokens must match across the flag"
        )
        XCTAssertEqual(
            off?.allTime.totals.outputTokens,
            on?.allTime.totals.outputTokens,
            "Total output tokens must match across the flag"
        )
        XCTAssertEqual(
            off?.allTime.totals.cacheCreationTokens,
            on?.allTime.totals.cacheCreationTokens,
            "Cache creation tokens must match across the flag"
        )
        XCTAssertEqual(
            off?.allTime.totals.cacheReadTokens,
            on?.allTime.totals.cacheReadTokens,
            "Cache read tokens must match across the flag"
        )
        XCTAssertEqual(
            off?.allTime.totals.requestCount,
            on?.allTime.totals.requestCount,
            "Request count must match across the flag"
        )
    }
}
