import XCTest
@testable import ClawdmeterShared

/// Round-trip tests for Sessions v2 wire shape additions. Verifies:
/// - schema v3 fields round-trip through Codable
/// - v2 sessions.json files decode cleanly into v3 (defaults to nil)
/// - ModelCatalog.bundled is self-consistent
/// - Health response carries wireVersion
final class SessionsV2Tests: XCTestCase {

    // MARK: - Reasoning effort

    func testReasoningEffortRoundTrip() throws {
        for effort in ReasoningEffort.allCases {
            let encoded = try JSONEncoder().encode(effort)
            let decoded = try JSONDecoder().decode(ReasoningEffort.self, from: encoded)
            XCTAssertEqual(decoded, effort)
        }
    }

    func testReasoningEffortClaudeFlagValues() {
        // minimal folds into low (claude CLI doesn't expose minimal).
        XCTAssertEqual(ReasoningEffort.minimal.claudeFlagValue, "low")
        XCTAssertEqual(ReasoningEffort.low.claudeFlagValue, "low")
        XCTAssertEqual(ReasoningEffort.medium.claudeFlagValue, "medium")
        XCTAssertEqual(ReasoningEffort.high.claudeFlagValue, "high")
        XCTAssertEqual(ReasoningEffort.xhigh.claudeFlagValue, "xhigh")
        XCTAssertEqual(ReasoningEffort.max.claudeFlagValue, "max")
    }

    func testReasoningEffortCodexConfigValues() {
        // Codex exposes low/medium/high/xhigh but not max — `.max` folds
        // into xhigh on the codex CLI side. All other levels pass through
        // unchanged as their raw value.
        XCTAssertEqual(ReasoningEffort.minimal.codexConfigValue, "minimal")
        XCTAssertEqual(ReasoningEffort.low.codexConfigValue, "low")
        XCTAssertEqual(ReasoningEffort.medium.codexConfigValue, "medium")
        XCTAssertEqual(ReasoningEffort.high.codexConfigValue, "high")
        XCTAssertEqual(ReasoningEffort.xhigh.codexConfigValue, "xhigh")
        XCTAssertEqual(ReasoningEffort.max.codexConfigValue, "xhigh")
    }

    func testReasoningEffortLenientDecode() throws {
        // Older Macs that wrote a `max` value should round-trip into the
        // new case; future unknown values fall back to `xhigh` rather
        // than failing the whole AgentSession Codable round-trip.
        let maxJson = "\"max\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ReasoningEffort.self, from: maxJson), .max)
        let bogusJson = "\"future-effort\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ReasoningEffort.self, from: bogusJson), .xhigh)
    }

    // MARK: - PermissionMode

    func testPermissionModeRoundTrip() throws {
        for mode in PermissionMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(PermissionMode.self, from: encoded)
            XCTAssertEqual(decoded, mode)
        }
    }

    func testPermissionModeLenientDecode() throws {
        // Future Mac writes `customMode` that this build doesn't know about;
        // we'd rather fall back to `.ask` than fail the whole session
        // Codable round-trip.
        let bogus = "\"customMode\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(PermissionMode.self, from: bogus), .ask)
    }

    func testPermissionModeDisplayLabels() {
        XCTAssertEqual(PermissionMode.ask.displayName, "Ask permissions")
        XCTAssertEqual(PermissionMode.acceptEdits.displayName, "Accept edits")
        XCTAssertEqual(PermissionMode.plan.displayName, "Plan mode")
        XCTAssertEqual(PermissionMode.bypass.displayName, "Bypass permissions")
        // Bypass is the only trust-gated mode.
        XCTAssertTrue(PermissionMode.bypass.requiresTrust)
        XCTAssertFalse(PermissionMode.ask.requiresTrust)
        XCTAssertFalse(PermissionMode.acceptEdits.requiresTrust)
        XCTAssertFalse(PermissionMode.plan.requiresTrust)
    }

    // MARK: - Sidebar grouping / sorting / filter

    func testSessionGroupingCases() {
        let names = SessionGrouping.allCases.map(\.displayName)
        XCTAssertEqual(names, ["Repo", "Date", "Status", "Agent", "None"])
    }

    func testSessionSortingCases() {
        let names = SessionSorting.allCases.map(\.displayName)
        XCTAssertEqual(names, ["Recency", "Created", "Name"])
    }

    func testSessionStatusFilterCases() {
        let names = SessionStatusFilter.allCases.map(\.displayName)
        XCTAssertEqual(names, ["All", "Active", "Done", "Archived"])
    }

    // MARK: - Model catalog

    func testBundledCatalogIsConsistent() {
        let cat = ModelCatalog.bundled
        XCTAssertFalse(cat.claude.isEmpty, "bundled catalog must ship at least one Claude model")
        XCTAssertFalse(cat.codex.isEmpty, "bundled catalog must ship at least one Codex model")
        // ids unique within each provider
        let claudeIds = Set(cat.claude.map(\.id))
        XCTAssertEqual(claudeIds.count, cat.claude.count, "Claude model ids must be unique")
        let codexIds = Set(cat.codex.map(\.id))
        XCTAssertEqual(codexIds.count, cat.codex.count, "Codex model ids must be unique")
        // displayNames non-empty
        for entry in cat.claude + cat.codex {
            XCTAssertFalse(entry.displayName.isEmpty, "Empty displayName for \(entry.id)")
        }
    }

    func testCatalogEntryLookup() {
        let cat = ModelCatalog.bundled
        XCTAssertNotNil(cat.entry(forId: "claude-opus-4-7"))
        XCTAssertNotNil(cat.entry(forId: "gpt-5.5"))
        XCTAssertNil(cat.entry(forId: "nonexistent-model"))
    }

    // MARK: - Schema v3 round-trip

    func testAgentSessionV3RoundTrip() throws {
        let session = AgentSession(
            id: UUID(),
            repoKey: "/Users/me/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "claude-opus-4-7",
            goal: "Fix the redis timeout",
            worktreePath: "/Users/me/repo/.claude/worktrees/fix-1234ab",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            status: .running,
            planText: nil,
            createdAt: Date(timeIntervalSince1970: 1747100000),
            lastEventAt: Date(timeIntervalSince1970: 1747100100),
            lastEventSeq: 42,
            mode: .worktree,
            effort: .high,
            abPairSessionId: UUID(),
            abPairDecidedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let decoded = try decoder.decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.effort, .high)
        XCTAssertEqual(decoded.abPairSessionId, session.abPairSessionId)
        XCTAssertEqual(decoded.mode, .worktree)
    }

    func testV2SessionDecodesAsV3() throws {
        // Simulate a v2 sessions.json entry: no `effort`, no `abPairSessionId`,
        // no `abPairDecidedAt`. The v3 decoder must accept it and default
        // those fields to nil.
        let v2Json = #"""
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "repoKey": "/repo",
            "repoDisplayName": "repo",
            "agent": "claude",
            "status": "running",
            "createdAt": "2026-05-16T13:00:00Z",
            "lastEventAt": "2026-05-16T13:00:00Z",
            "lastEventSeq": 1,
            "mode": "local"
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: Data(v2Json.utf8))
        XCTAssertNil(decoded.effort)
        XCTAssertNil(decoded.abPairSessionId)
        XCTAssertNil(decoded.abPairDecidedAt)
    }

    // MARK: - NewSessionRequest with v3 fields

    func testNewSessionRequestRoundTrip() throws {
        let req = NewSessionRequest(
            repoKey: "/repo",
            agent: .codex,
            model: "gpt-5.5",
            planMode: false,
            goal: "test",
            useWorktree: true,
            baseBranch: "main",
            effort: .high,
            abPair: .claude
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(NewSessionRequest.self, from: data)
        XCTAssertEqual(decoded.effort, .high)
        XCTAssertEqual(decoded.abPair, .claude)
        XCTAssertEqual(decoded.useWorktree, true)
    }

    func testV2NewSessionRequestStillDecodes() throws {
        let v2Json = #"""
        {
            "repoKey": "/repo",
            "agent": "claude",
            "planMode": true,
            "useWorktree": false
        }
        """#
        let decoded = try JSONDecoder().decode(NewSessionRequest.self, from: Data(v2Json.utf8))
        XCTAssertNil(decoded.effort)
        XCTAssertNil(decoded.abPair)
        XCTAssertEqual(decoded.planMode, true)
    }

    // MARK: - Health response

    func testHealthResponseShape() throws {
        let payload = HealthResponse(serverVersion: "2.0.0")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(HealthResponse.self, from: data)
        XCTAssertEqual(decoded.ok, true)
        XCTAssertEqual(decoded.serverVersion, "2.0.0")
        XCTAssertEqual(decoded.wireVersion, AgentControlWireVersion.current)
    }

    func testWireVersionConstant() {
        // Bumped 3 → 4 on 2026-05-18 for the X1 `compose-draft` WS op.
        // Bumped 4 → 5 on 2026-05-19 (Phase 0a): WireChatSnapshot.updateCounter
        // is now populated from the daemon-owned SessionChatStore.updateCounter
        // (transcript counter) instead of session.lastEventSeq, AND the
        // chat-subscribe WS op (Phase 2) gates on chatSubscribeMinimum.
        // Field name unchanged so v4 iOS clients keep working; only the
        // semantics of updateCounter shifted.
        XCTAssertEqual(AgentControlWireVersion.current, 5)
        XCTAssertEqual(AgentControlWireVersion.composeDraftMinimum, 4)
        XCTAssertEqual(AgentControlWireVersion.chatSubscribeMinimum, 5)
    }

    // MARK: - Mid-session change requests

    func testChangeModelRequestRoundTrip() throws {
        let req = ChangeModelRequest(model: "claude-opus-4-7", effort: .xhigh)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(ChangeModelRequest.self, from: data)
        XCTAssertEqual(decoded.model, "claude-opus-4-7")
        XCTAssertEqual(decoded.effort, .xhigh)
    }

    func testChangeModeRequest() throws {
        let req = ChangeModeRequest(mode: .worktree, planMode: false)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(ChangeModeRequest.self, from: data)
        XCTAssertEqual(decoded.mode, .worktree)
        XCTAssertEqual(decoded.planMode, false)
    }

    func testSendPromptRequest() throws {
        let req = SendPromptRequest(text: "test prompt", asFollowUp: true)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(SendPromptRequest.self, from: data)
        XCTAssertEqual(decoded.text, "test prompt")
        XCTAssertEqual(decoded.asFollowUp, true)
    }

    func testAutopilotRequest() throws {
        let req = AutopilotRequest(enabled: true)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(AutopilotRequest.self, from: data)
        XCTAssertTrue(decoded.enabled)
    }

    // MARK: - WireChatSnapshot

    func testWireChatSnapshotEmptyRoundTrip() throws {
        let snap = WireChatSnapshot(
            sessionId: UUID(),
            items: [], planSteps: [], sourceEntries: [], artifactEntries: [],
            totalInputTokens: 0, totalOutputTokens: 0,
            lastEventAt: nil, updateCounter: 0
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WireChatSnapshot.self, from: data)
        XCTAssertEqual(decoded.updateCounter, 0)
        XCTAssertEqual(decoded.items.count, 0)
    }

    // MARK: - PickWinner conflict response

    func testPickWinnerConflictResponse() throws {
        let when = Date(timeIntervalSince1970: 1747100000)
        let payload = PickWinnerConflictResponse(winnerSessionId: UUID(), decidedAt: when)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(PickWinnerConflictResponse.self, from: data)
        XCTAssertEqual(decoded.alreadyDecided, true)
        XCTAssertEqual(decoded.decidedAt.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - CityPool

    func testCityPoolDeterministic() {
        let id = UUID()
        let c1 = CityPool.cityName(for: id)
        let c2 = CityPool.cityName(for: id)
        XCTAssertEqual(c1, c2, "Same UUID must hash to the same city")
    }

    func testCityPoolUniqueWithCollision() {
        var taken: Set<String> = []
        for i in 0..<20 {
            _ = i
            let id = UUID()
            let city = CityPool.uniqueCityName(for: id, taken: taken)
            XCTAssertFalse(taken.contains(city), "Returned city must not already be taken")
            taken.insert(city)
        }
    }

    // MARK: - WatchSessionSummary

    func testWatchSessionSummaryRoundTrip() throws {
        let session = AgentSession(
            id: UUID(),
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "claude-opus-4-7",
            goal: "Fix the bug",
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .local
        )
        let summary = WatchSessionSummary.from(session: session, modelCatalog: .bundled)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(WatchSessionSummary.self, from: data)
        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.modelDisplay, "Opus 4.7")
        XCTAssertEqual(decoded.agent, .claude)
    }
}
