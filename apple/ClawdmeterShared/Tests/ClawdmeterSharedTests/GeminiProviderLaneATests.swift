#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Lane A foundation tests for the 2026-05-19 Gemini provider work.
/// Covers the load-bearing invariants identified by the eng review:
///   - E3 #1 / X1: wire envelope dual-shape + per-provider fallback
///   - E3 #3: ProviderConfig.supportsAutoRevive flag (regression for `id == "claude"` refactor)
///   - E3 #4: UsageHistorySnapshot compat getters return `.empty` for missing keys
///   - X2: TokenTotals back-compat — old JSON without `requestCount` decodes to 0
///   - byProvider Codable round-trip + legacy v8 shape decode (D9)
///   - AgentKind tolerant decoder (D9)
final class GeminiProviderLaneATests: XCTestCase {

    // MARK: - X2: TokenTotals Codable back-compat

    func test_tokenTotals_decodesOldJSONWithoutRequestCount_asZero() throws {
        // Old shape — v8 cache + iCloud snapshots written before the
        // 2026-05-19 Gemini work. No requestCount field. Custom Codable
        // init(from:) supplies a 0 default; without that we'd hard-fail.
        // costUSD encodes as a JSON number (not string) per Decimal's
        // synthesized Codable.
        let json = """
        {
          "inputTokens": 100,
          "outputTokens": 50,
          "cacheCreationTokens": 0,
          "cacheReadTokens": 0,
          "reasoningTokens": 0,
          "costUSD": 1.25
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TokenTotals.self, from: json)
        XCTAssertEqual(decoded.inputTokens, 100)
        XCTAssertEqual(decoded.outputTokens, 50)
        XCTAssertEqual(decoded.requestCount, 0, "Missing requestCount must decode to 0, not throw keyNotFound (X2 fix)")
        XCTAssertEqual(decoded.costUSD, Decimal(1.25))
    }

    func test_tokenTotals_roundTrip_preservesRequestCount() throws {
        let original = TokenTotals(inputTokens: 10, outputTokens: 5, costUSD: 0, requestCount: 42)
        let data = try JSONEncoder().encode(original)
        let roundtripped = try JSONDecoder().decode(TokenTotals.self, from: data)
        XCTAssertEqual(roundtripped, original)
        XCTAssertEqual(roundtripped.requestCount, 42)
    }

    func test_tokenTotals_addition_sumsRequestCount() {
        let a = TokenTotals(inputTokens: 0, requestCount: 3)
        let b = TokenTotals(inputTokens: 0, requestCount: 7)
        XCTAssertEqual((a + b).requestCount, 10)
    }

    // MARK: - byProvider Codable round-trip (D9)

    func test_byProvider_codable_roundTrip() throws {
        let totals = TokenTotals(inputTokens: 100, costUSD: Decimal(1.5))
        let provider = ProviderTotals(
            today: WindowTotals(totals: totals, byRepo: [], restCount: 0),
            past7d: .empty,
            past30d: .empty,
            past90d: .empty,
            allTime: .empty,
            byDay: [:]
        )

        let snapshot = UsageHistorySnapshot(
            byProvider: [.claude: provider, .gemini: .empty],
            computedAt: Date(timeIntervalSince1970: 1_750_000_000),
            sequenceNumber: 42,
            sessionCount: 5,
            unpricedModelTokens: [:]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageHistorySnapshot.self, from: encoded)

        XCTAssertEqual(decoded.byProvider.keys.sorted(by: { $0.rawValue < $1.rawValue }), [.claude, .gemini])
        XCTAssertEqual(decoded.claude.today.totals.inputTokens, 100)
        XCTAssertEqual(decoded.gemini.today.totals.inputTokens, 0)
    }

    func test_byProvider_legacyV8Shape_migratesOnDecode() throws {
        // v8 snapshots written before the refactor have top-level `claude`
        // and `codex` fields, no `byProvider` dict. Decoder must migrate.
        let json = """
        {
          "claude": {
            "today": { "totals": { "inputTokens": 50, "outputTokens": 25, "cacheCreationTokens": 0, "cacheReadTokens": 0, "reasoningTokens": 0, "costUSD": 0.75 }, "byRepoFlat": [], "restCount": 0 },
            "past7d": { "totals": { "inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0, "cacheReadTokens": 0, "reasoningTokens": 0, "costUSD": 0 }, "byRepoFlat": [], "restCount": 0 },
            "past30d": { "totals": { "inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0, "cacheReadTokens": 0, "reasoningTokens": 0, "costUSD": 0 }, "byRepoFlat": [], "restCount": 0 },
            "allTime": { "totals": { "inputTokens": 50, "outputTokens": 25, "cacheCreationTokens": 0, "cacheReadTokens": 0, "reasoningTokens": 0, "costUSD": 0.75 }, "byRepoFlat": [], "restCount": 0 },
            "byDay": []
          },
          "codex": {
            "today": { "totals": { "inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0, "cacheReadTokens": 0, "reasoningTokens": 0, "costUSD": 0 }, "byRepoFlat": [], "restCount": 0 },
            "past7d": { "totals": { "inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0, "cacheReadTokens": 0, "reasoningTokens": 0, "costUSD": 0 }, "byRepoFlat": [], "restCount": 0 },
            "past30d": { "totals": { "inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0, "cacheReadTokens": 0, "reasoningTokens": 0, "costUSD": 0 }, "byRepoFlat": [], "restCount": 0 },
            "allTime": { "totals": { "inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0, "cacheReadTokens": 0, "reasoningTokens": 0, "costUSD": 0 }, "byRepoFlat": [], "restCount": 0 },
            "byDay": []
          },
          "computedAt": 1750000000,
          "sequenceNumber": 1,
          "sessionCount": 1,
          "unpricedModelTokens": {}
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(UsageHistorySnapshot.self, from: json)

        XCTAssertEqual(decoded.byProvider[.claude]?.allTime.totals.inputTokens, 50)
        XCTAssertEqual(decoded.byProvider[.codex]?.allTime.totals.inputTokens, 0)
        XCTAssertNil(decoded.byProvider[.gemini], "Legacy v8 had no Gemini bucket; decoder must not synthesize one")
    }

    // MARK: - E3 #4: compat getters return .empty

    func test_compatGetters_returnEmpty_whenProviderKeyAbsent() {
        // A Gemini-only snapshot (e.g., a future user without Claude/Codex).
        let snapshot = UsageHistorySnapshot(
            byProvider: [.gemini: .empty],
            computedAt: Date(),
            sequenceNumber: 1,
            sessionCount: 0,
            unpricedModelTokens: [:]
        )

        // Compat getters must NOT crash on missing keys — they return .empty.
        XCTAssertEqual(snapshot.claude.allTime.totals.totalTokens, 0)
        XCTAssertEqual(snapshot.codex.allTime.totals.totalTokens, 0)
        XCTAssertEqual(snapshot.gemini.allTime.totals.totalTokens, 0)
    }

    // MARK: - D9: AgentKind tolerant decoder

    func test_agentKind_knownRawsRoundTrip() throws {
        for kind in AgentKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(AgentKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func test_agentKind_unknownRaw_decodesAsUnknown_doesNotThrow() throws {
        // X3 (wire v12, 2026-05-22): older clients reading a future-
        // version payload tagged with an unknown agent kind must not
        // crash the envelope. The lenient decoder folds unknowns to
        // `.unknown` (NOT `.claude` — that was the silent-mislabel bug
        // Codex flagged in the eng-review). Downstream UI renders these
        // as "Other agent" instead of impersonating Claude semantics.
        //
        // Pre-X3 behavior (wire v11 and earlier) folded unknowns to
        // `.claude`; PR #28 (OpenCode adapter) depends on the v12 fix
        // so older v11 iOS clients don't show OpenCode sessions as
        // Claude.
        let json = Data("\"future-runtime\"".utf8)
        let decoded = try JSONDecoder().decode(AgentKind.self, from: json)
        XCTAssertEqual(decoded, .unknown)
    }

    // MARK: - E3 #1 / X1: wire envelope dual-shape + per-provider fallback

    func test_usageEnvelope_v6_perProviderFallback() throws {
        // v6 server emits BOTH legacy + dict. Specifically: dict contains
        // ONLY Gemini, while legacy fields carry Claude + Codex. v6 reader
        // must merge all three (per-provider fallback, not envelope-level).
        let claudeData = UsageData(sessionPct: 47, sessionResetMins: 130, sessionEpoch: 1_750_001_000,
                                   weeklyPct: 12, weeklyResetMins: 4000, weeklyEpoch: 1_750_500_000,
                                   status: .allowed, representativeClaim: .fiveHour, updatedAt: Date())
        let codexData = UsageData(sessionPct: 30, sessionResetMins: 200, sessionEpoch: 1_750_002_000,
                                  weeklyPct: 8, weeklyResetMins: 4500, weeklyEpoch: 1_750_500_000,
                                  status: .allowed, representativeClaim: .fiveHour, updatedAt: Date())
        let geminiData = UsageData(sessionPct: 60, sessionResetMins: 150, sessionEpoch: 1_750_003_000,
                                   weeklyPct: 0, weeklyResetMins: 10_080, weeklyEpoch: 1_750_999_000,
                                   status: .allowed, representativeClaim: .fiveHour, updatedAt: Date())

        let envelope = UsageEnvelope(
            claude: claudeData,
            codex: codexData,
            usage: ["gemini": geminiData],  // Dict has ONLY Gemini
            lastChecked: Date()
        )

        // Per-provider fallback: dict-first for each id, legacy-fallback.
        XCTAssertEqual(envelope.usageData(for: "claude")?.sessionPct, 47,
                       "Claude not in dict — must fall back to legacy field")
        XCTAssertEqual(envelope.usageData(for: "codex")?.sessionPct, 30,
                       "Codex not in dict — must fall back to legacy field")
        XCTAssertEqual(envelope.usageData(for: "gemini")?.sessionPct, 60,
                       "Gemini in dict — must read from dict")
    }

    func test_usageEnvelope_v5_payload_decodes() throws {
        // v5 server: legacy only, no `usage` dict field. v6 client must
        // decode this cleanly (decodeIfPresent path).
        let json = """
        {
          "claude": { "sessionPct": 47, "sessionResetMins": 130, "sessionEpoch": 1750001000, "weeklyPct": 12, "weeklyResetMins": 4000, "weeklyEpoch": 1750500000, "status": "allowed", "representativeClaim": "five_hour", "updatedAt": "2026-05-19T08:00:00Z" },
          "codex": { "sessionPct": 30, "sessionResetMins": 200, "sessionEpoch": 1750002000, "weeklyPct": 8, "weeklyResetMins": 4500, "weeklyEpoch": 1750500000, "status": "allowed", "representativeClaim": "five_hour", "updatedAt": "2026-05-19T08:00:00Z" },
          "lastChecked": "2026-05-19T08:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(UsageEnvelope.self, from: json)
        XCTAssertNil(envelope.usage, "v5 payload has no usage dict")
        XCTAssertNotNil(envelope.claude)
        // Per-provider read still works via legacy fallback.
        XCTAssertEqual(envelope.usageData(for: "claude")?.sessionPct, 47)
        XCTAssertEqual(envelope.usageData(for: "gemini")?.sessionPct, nil, "v5 server: no Gemini available")
    }

    // MARK: - D9: GeminiTokenProvider parses real-shape oauth_creds.json

    func test_geminiTokenProvider_parsesFixtureOAuthBundle() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-oauth_creds.json")
        let pastExpiry = Int64(Date().timeIntervalSince1970 * 1000) - 60_000  // 1 min in the past
        let fixture = """
        {
          "access_token": "ya29.fake-test-token",
          "refresh_token": "1//fake-refresh",
          "scope": "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.profile",
          "token_type": "Bearer",
          "id_token": "fake.id.token",
          "expiry_date": \(pastExpiry)
        }
        """.data(using: .utf8)!
        try fixture.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let provider = GeminiTokenProvider(authPath: temp)
        XCTAssertTrue(provider.hasToken, "Token present in fixture")
        XCTAssertEqual(provider.currentAccessToken, "ya29.fake-test-token")
        XCTAssertTrue(provider.currentScope?.contains("cloud-platform") ?? false)
        XCTAssertTrue(provider.isTokenExpired, "Fixture's expiry_date is in the past — D4 stale-token UX trigger")
    }

    // MARK: - AntigravityUsageParser smoke (v0.6.0 — replaces GeminiUsageParser per D1)

    /// v0.6.0 replaces the Gemini CLI v0.42 `logs.json` path with the
    /// Antigravity 2 `conversations/<uuid>.pb` + brain dir layout. The
    /// new parser is encryption-aware (see Commit 4 — Antigravity 2
    /// encrypts conversation .pb files at rest) and falls back to
    /// metadata-based usage estimates from the brain dir.
    func test_antigravityUsageParser_emitsRecordPerConversation() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-antigravity")
        let brainUUID = "11111111-1111-4111-8111-111111111111"
        let brain = temp.appendingPathComponent("brain/\(brainUUID)", isDirectory: true)
        let conversations = temp.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Two metadata files = 2 turns.
        try "{}".write(to: brain.appendingPathComponent("task.md.metadata.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: brain.appendingPathComponent("implementation_plan.md.metadata.json"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 400).write(to: brain.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)

        // Encrypted-looking conversation file (random bytes).
        var randomBytes = [UInt8](repeating: 0, count: 1024)
        for i in 0..<randomBytes.count { randomBytes[i] = UInt8.random(in: 0...255) }
        let convURL = conversations.appendingPathComponent("\(brainUUID).pb")
        try Data(randomBytes).write(to: convURL)

        // Build a minimal brain index pointing at this brain.
        let index = BrainSummaryIndex(
            byUUID: [brainUUID: BrainSummary(brainUUID: brainUUID, cwd: URL(fileURLWithPath: "/Users/test/Repo"))],
            byCwdPath: ["/users/test/repo": [brainUUID]]
        )

        let records = try AntigravityUsageParser.parse(
            conversationURL: convURL,
            antigravityDataDir: temp,
            brainIndex: index,
            modelName: "gemini-3.5-flash"
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.provider, .gemini)
        XCTAssertEqual(records.first?.tokens.requestCount, 2, "2 metadata.json files = 2 turns")
        XCTAssertEqual(records.first?.model, "gemini-3.5-flash")
        XCTAssertEqual(records.first?.repo, "/Users/test/Repo")
        XCTAssertEqual(records.first?.dedupKey, "antigravity:\(brainUUID)")
    }

    // MARK: - QA ISSUE-001 regression: D7 stale-fallback emission must replace

    /// Regression: ISSUE-001 — Gemini D7 stale badge never fired on Mac
    /// because UsagePoller.shouldReplace dropped the cached-fallback
    /// emission. Root cause: cached fallback set `updatedAt` to the
    /// last-success time, identical to the prev .allowed snapshot, so
    /// `shouldReplace` returned false ("incoming.updatedAt > self.updatedAt"
    /// was false) and the poller re-emitted the .allowed cached state.
    /// Status .unknown never reached the dashboard, badge never rendered.
    ///
    /// Fix: GeminiSource.cachedFallbackOrThrow emits with `updatedAt =
    /// Date()` (now). This test locks the contract at the UsageData
    /// model layer: a cached-fallback emission MUST replace a prior
    /// .allowed snapshot in shouldReplace semantics so .unknown status
    /// propagates to AppModel.usage.
    ///
    /// Found by /qa on main, 2026-05-19.
    /// Report: .gstack/qa-reports/qa-report-clawdmeter-mac-2026-05-19.md
    func test_cachedFallbackEmission_replacesPriorAllowed_soUnknownStatusPropagates() {
        let now = Date()
        let resetEpoch = Int(now.timeIntervalSince1970) + 5 * 3600

        let prev = UsageData(
            sessionPct: 23,
            sessionResetMins: 300,
            sessionEpoch: resetEpoch,
            weeklyPct: 0,
            weeklyResetMins: 0,
            weeklyEpoch: 0,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: now.addingTimeInterval(-3600) // 1h ago
        )

        // GeminiSource.cachedFallbackOrThrow shape: same sessionEpoch,
        // .unknown status, updatedAt = NOW (the fix). The poller must
        // accept this so the dashboard sees status = .unknown.
        let cachedFallback = UsageData(
            sessionPct: 23,
            sessionResetMins: 300,
            sessionEpoch: resetEpoch,
            weeklyPct: 0,
            weeklyResetMins: 0,
            weeklyEpoch: 0,
            status: .unknown,
            representativeClaim: .unknown,
            updatedAt: now
        )

        XCTAssertTrue(
            prev.shouldReplace(with: cachedFallback),
            "Cached-fallback emission with updatedAt = now MUST replace prior .allowed snapshot — otherwise D7 stale badge never fires"
        )
    }

    /// Counterfactual: the BUG path (cached fallback emits with prev's
    /// `updatedAt`) MUST NOT replace. Locks the failure mode so a future
    /// refactor that reverts to `updatedAt: lastUpdatedAt` is caught.
    func test_cachedFallback_withStaleUpdatedAt_correctlyDropped() {
        let now = Date()
        let resetEpoch = Int(now.timeIntervalSince1970) + 5 * 3600

        let prev = UsageData(
            sessionPct: 23, sessionResetMins: 300, sessionEpoch: resetEpoch,
            weeklyPct: 0, weeklyResetMins: 0, weeklyEpoch: 0,
            status: .allowed, representativeClaim: .fiveHour,
            updatedAt: now.addingTimeInterval(-3600)
        )

        // Buggy shape: same updatedAt as prev. shouldReplace returns
        // false → poller drops emission → status stays .allowed →
        // dashboard never shows stale badge. THIS is the regression.
        let buggyFallback = UsageData(
            sessionPct: 23, sessionResetMins: 300, sessionEpoch: resetEpoch,
            weeklyPct: 0, weeklyResetMins: 0, weeklyEpoch: 0,
            status: .unknown, representativeClaim: .unknown,
            updatedAt: now.addingTimeInterval(-3600) // SAME as prev
        )

        XCTAssertFalse(
            prev.shouldReplace(with: buggyFallback),
            "Emission with same updatedAt as prev should NOT replace — locks the bug condition"
        )
    }
}
#endif
