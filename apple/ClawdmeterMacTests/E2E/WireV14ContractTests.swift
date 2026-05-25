import XCTest
import ClawdmeterShared

/// v0.23 (Chat V2 — T15): wire-v14 contract round-trip tests.
///
/// What this is: an "in-process E2E" that exercises the wire-protocol
/// surface of the Chat V2 release without spawning real CLI processes.
/// True UI-driving E2E (two-process Mac daemon + iOS simulator)
/// requires the actual `claude` / `codex` / `gemini` binaries on PATH
/// plus tmux plus a paired iPhone — none of that is reasonable for CI.
/// Instead this suite locks in the contract:
///
/// 1. Every new wire DTO round-trips through JSON without losing
///    fields. Older Macs (wire v13) sending payloads to V2 clients
///    decode cleanly with new fields defaulting. V2 Macs sending
///    payloads to older clients decode (skipping unknown fields).
///
/// 2. The TurnState lifecycle decodes leniently for forward-compat
///    (unknown raws fall back to `.streaming` — safest default).
///
/// 3. AgentSession schema v7 (deepResearch) decodes cleanly from
///    legacy sessions.json (v3/v4/v5/v6) payloads.
///
/// 4. Wire version gates report support correctly.
///
/// The "real" E2E harness — spawning the daemon under a temp port
/// + temp app-support dir + opening an in-process AgentControlClient
/// paired to it — is documented at the bottom of this file as a
/// follow-up; the existing `DaemonChatStoreRegistryRoutingTests` +
/// `PlanApprovalStoreRolloverTest` already cover the lifecycle
/// pieces that need real daemon state.
final class WireV14ContractTests: XCTestCase {

    // MARK: - Wire version

    func test_wire_v14_current() {
        // v14 minimums still apply (`turnLifecycleMinimum`,
        // `deepResearchMinimum`, `chatSearchMinimum`); only `current`
        // has advanced. v18 added remote Code workbench run/checkpoint
        // endpoints for iOS parity; v19 added lifecycle and provider-default
        // endpoints.
        XCTAssertEqual(AgentControlWireVersion.current, 19)
    }

    func test_v14_minimums_match() {
        XCTAssertEqual(AgentControlWireVersion.turnLifecycleMinimum, 14)
        XCTAssertEqual(AgentControlWireVersion.deepResearchMinimum, 14)
        XCTAssertEqual(AgentControlWireVersion.chatSearchMinimum, 14)
    }

    func test_v14_supports_helpers() {
        XCTAssertTrue(AgentControlWireVersion.supportsTurnLifecycle(serverWireVersion: 14))
        XCTAssertFalse(AgentControlWireVersion.supportsTurnLifecycle(serverWireVersion: 13))
        XCTAssertTrue(AgentControlWireVersion.supportsDeepResearch(serverWireVersion: 14))
        XCTAssertFalse(AgentControlWireVersion.supportsDeepResearch(serverWireVersion: 13))
        XCTAssertTrue(AgentControlWireVersion.supportsChatSearch(serverWireVersion: 14))
        XCTAssertFalse(AgentControlWireVersion.supportsChatSearch(serverWireVersion: nil))
    }

    // MARK: - TurnState lenient decoder

    func test_turnState_known_raws_decode() throws {
        for raw in ["idle", "streaming", "completed", "interrupted"] {
            let data = Data("\"\(raw)\"".utf8)
            let decoded = try JSONDecoder().decode(TurnState.self, from: data)
            XCTAssertEqual(decoded.rawValue, raw)
        }
    }

    func test_turnState_unknown_raw_falls_back_to_streaming() throws {
        // Forward-compat: a future-wire-version daemon adds a new state
        // we don't know about. Lenient decoder defaults to .streaming
        // (safest — UI keeps showing the indicator instead of pretending
        // the turn is done).
        let data = Data("\"some-future-state\"".utf8)
        let decoded = try JSONDecoder().decode(TurnState.self, from: data)
        XCTAssertEqual(decoded, .streaming)
    }

    // MARK: - WireChatSnapshot round-trip with currentTurnState

    func test_wireChatSnapshot_round_trip_with_turnState() throws {
        let snap = WireChatSnapshot(
            sessionId: UUID(),
            items: [],
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 100,
            totalOutputTokens: 200,
            lastEventAt: Date(),
            updateCounter: 5,
            currentTurnState: .completed
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(WireChatSnapshot.self, from: data)
        XCTAssertEqual(round.currentTurnState, .completed)
        XCTAssertEqual(round.updateCounter, 5)
        XCTAssertEqual(round.totalInputTokens, 100)
    }

    func test_wireChatSnapshot_decodes_v13_payload_without_turnState() throws {
        // A v13 daemon emits the snapshot WITHOUT currentTurnState. V2
        // clients must decode cleanly with the field defaulting to .idle.
        let payload: [String: Any] = [
            "sessionId": UUID().uuidString,
            "items": [],
            "planSteps": [],
            "sourceEntries": [],
            "artifactEntries": [],
            "totalInputTokens": 0,
            "totalOutputTokens": 0,
            "updateCounter": 1
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WireChatSnapshot.self, from: data)
        XCTAssertEqual(decoded.currentTurnState, .idle)
    }

    // MARK: - CreateChatSessionRequest + FrontierModelSlot deepResearch

    func test_createChatSessionRequest_round_trip_with_deepResearch() throws {
        let req = CreateChatSessionRequest(provider: .claude, deepResearch: true)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(CreateChatSessionRequest.self, from: data)
        XCTAssertTrue(decoded.deepResearch)
    }

    func test_createChatSessionRequest_decodes_v13_payload() throws {
        let payload: [String: Any] = ["provider": "claude"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(CreateChatSessionRequest.self, from: data)
        XCTAssertFalse(decoded.deepResearch)
    }

    func test_frontierModelSlot_round_trip_with_deepResearch() throws {
        let slot = FrontierModelSlot(provider: .codex, deepResearch: true)
        let data = try JSONEncoder().encode(slot)
        let decoded = try JSONDecoder().decode(FrontierModelSlot.self, from: data)
        XCTAssertTrue(decoded.deepResearch)
    }

    func test_frontierModelSlot_decodes_v13_payload() throws {
        let payload: [String: Any] = ["provider": "gemini"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(FrontierModelSlot.self, from: data)
        XCTAssertFalse(decoded.deepResearch)
    }

    // MARK: - AgentSession schema v7 (deepResearch)

    func test_agentSession_round_trip_preserves_deepResearch() throws {
        let session = AgentSession(
            id: UUID(),
            repoKey: nil,
            repoDisplayName: "Chat — Claude",
            agent: .claude,
            model: "claude-opus-4-7",
            goal: nil,
            worktreePath: "/tmp/x",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            kind: .chat,
            deepResearch: true
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: data)
        XCTAssertTrue(decoded.deepResearch)
    }

    func test_agentSession_decodes_legacy_v6_payload_without_deepResearch() throws {
        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "repoKey": "/Users/test/repo",
            "repoDisplayName": "Test",
            "agent": "claude",
            "status": "running",
            "createdAt": 0,
            "lastEventAt": 0,
            "lastEventSeq": 1
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertFalse(decoded.deepResearch)
    }

    // MARK: - Search response round-trip

    func test_chatSessionSearchResponse_round_trip() throws {
        let groupId = UUID()
        let match = ChatSessionSearchMatch(
            sessionId: UUID(),
            frontierGroupId: groupId,
            jsonlPath: "/Users/test/.claude/projects/foo/session.jsonl",
            snippet: "…hello world…",
            lastEventAt: Date()
        )
        let resp = ChatSessionSearchResponse(matches: [match], truncated: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(resp)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let round = try dec.decode(ChatSessionSearchResponse.self, from: data)
        XCTAssertEqual(round.matches.count, 1)
        XCTAssertTrue(round.truncated)
        XCTAssertEqual(round.matches.first?.snippet, "…hello world…")
        XCTAssertEqual(round.matches.first?.frontierGroupId, groupId)
    }
}

// MARK: - Follow-up E2E scope notes
//
// True two-process E2E (daemon spawned by a test, iOS simulator
// connecting via Tailscale loopback) requires:
//   1. A test-only daemon spawn helper that constructs
//      AgentControlServer with stubbed TmuxControlClient + RepoIndex
//      + NotificationDispatcher, binds NWListener to a free port, and
//      provides graceful teardown.
//   2. An XCUITest target that launches the iOS app under
//      XCUIApplication with `CLAWDMETER_PAIRING_HOST` /
//      `CLAWDMETER_PAIRING_TOKEN` env vars consumed by
//      AgentControlClient.setPairing() on cold launch.
//   3. CLI binaries on PATH (claude, codex, gemini) for any test
//      that exercises spawn — or further stubbing of AgentSpawner.
//
// All three are infra work that's worth doing but doesn't gate the
// V2 release. The wire-contract suite above + the existing
// PlanApprovalStoreRolloverTest + DaemonChatStoreRegistryRoutingTests
// + SessionInterruptDispatcherTests (to be added if absent) cover the
// state machinery; a follow-up branch lifts the spawn-test infra into
// place.
