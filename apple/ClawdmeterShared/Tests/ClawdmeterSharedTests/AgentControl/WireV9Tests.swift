import XCTest
@testable import ClawdmeterShared

/// v0.8 Chat tab wire v9 round-trip tests. Verifies:
/// - wireVersion.current is 9
/// - chatMinimum / frontierMinimum / codexChatBackendMinimum all = 9
/// - prior minimums (composeDraft=4, chatSubscribe=5, gemini=6,
///   antigravity=7, codexSDK=8) unchanged
/// - supportsChat / supportsFrontier / supportsCodexChatBackend
///   return correct values at v8 vs v9
/// - New chat DTOs round-trip cleanly through Codable
final class WireV9Tests: XCTestCase {

    func test_currentWireVersionIsAtLeastNine() {
        // v0.8.0 chat-tab bumped current to 9. v0.8.1 agy-migration
        // bumped to 10. This test tracks the v9 contract floor — assert
        // ≥ 9 so the v9 feature gates (chatMinimum, frontierMinimum,
        // codexChatBackendMinimum) all sit at or below current.
        XCTAssertGreaterThanOrEqual(AgentControlWireVersion.current, 9)
    }

    func test_chatMinimumIsNine() {
        XCTAssertEqual(AgentControlWireVersion.chatMinimum, 9)
    }

    func test_frontierMinimumIsNine() {
        XCTAssertEqual(AgentControlWireVersion.frontierMinimum, 9)
    }

    func test_codexChatBackendMinimumIsNine() {
        XCTAssertEqual(AgentControlWireVersion.codexChatBackendMinimum, 9)
    }

    func test_priorMinimumsUnchanged() {
        XCTAssertEqual(AgentControlWireVersion.composeDraftMinimum, 4)
        XCTAssertEqual(AgentControlWireVersion.chatSubscribeMinimum, 5)
        XCTAssertEqual(AgentControlWireVersion.geminiMinimum, 6)
        XCTAssertEqual(AgentControlWireVersion.antigravityMinimum, 7)
        XCTAssertEqual(AgentControlWireVersion.codexSDKMinimum, 8)
    }

    func test_supportsChat_falseAtV8OrEarlier() {
        XCTAssertFalse(AgentControlWireVersion.supportsChat(serverWireVersion: 8))
        XCTAssertFalse(AgentControlWireVersion.supportsChat(serverWireVersion: 7))
        XCTAssertFalse(AgentControlWireVersion.supportsChat(serverWireVersion: nil))
    }

    func test_supportsChat_trueAtV9() {
        XCTAssertTrue(AgentControlWireVersion.supportsChat(serverWireVersion: 9))
        XCTAssertTrue(AgentControlWireVersion.supportsChat(serverWireVersion: 10))
    }

    func test_supportsFrontier_falseAtV8OrEarlier() {
        XCTAssertFalse(AgentControlWireVersion.supportsFrontier(serverWireVersion: 8))
        XCTAssertFalse(AgentControlWireVersion.supportsFrontier(serverWireVersion: nil))
    }

    func test_supportsFrontier_trueAtV9() {
        XCTAssertTrue(AgentControlWireVersion.supportsFrontier(serverWireVersion: 9))
    }

    func test_supportsCodexChatBackend_falseAtV8() {
        XCTAssertFalse(AgentControlWireVersion.supportsCodexChatBackend(serverWireVersion: 8))
    }

    func test_supportsCodexChatBackend_trueAtV9() {
        XCTAssertTrue(AgentControlWireVersion.supportsCodexChatBackend(serverWireVersion: 9))
    }

    // MARK: - CreateChatSessionRequest

    func test_createChatSessionRequest_roundTrips() throws {
        let req = CreateChatSessionRequest(
            provider: .claude,
            model: "opus",
            effort: .high,
            codexChatBackend: nil
        )
        let encoded = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(CreateChatSessionRequest.self, from: encoded)
        XCTAssertEqual(decoded.provider, .claude)
        XCTAssertEqual(decoded.model, "opus")
        XCTAssertEqual(decoded.effort, .high)
        XCTAssertNil(decoded.codexChatBackend)
    }

    func test_createChatSessionRequest_withCodexBackend() throws {
        let req = CreateChatSessionRequest(
            provider: .codex,
            model: "gpt-5.5",
            codexChatBackend: .sdk
        )
        let encoded = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(CreateChatSessionRequest.self, from: encoded)
        XCTAssertEqual(decoded.provider, .codex)
        XCTAssertEqual(decoded.codexChatBackend, .sdk)
    }

    // MARK: - CreateFrontierRequest / Response

    func test_createFrontierRequest_carriesClientRequestId() throws {
        let requestId = UUID()
        let req = CreateFrontierRequest(
            clientRequestId: requestId,
            models: [
                FrontierModelSlot(provider: .claude, model: "opus"),
                FrontierModelSlot(
                    provider: .codex,
                    model: "gpt-5.5",
                    effort: .high,
                    codexChatBackend: .sdk,
                    deepResearch: true
                )
            ]
        )
        let encoded = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(CreateFrontierRequest.self, from: encoded)
        XCTAssertEqual(decoded.clientRequestId, requestId)
        XCTAssertEqual(decoded.models.count, 2)
        XCTAssertEqual(decoded.models[1].effort, .high)
        XCTAssertEqual(decoded.models[1].codexChatBackend, .sdk)
        XCTAssertTrue(decoded.models[1].deepResearch)
    }

    func test_createFrontierResponse_perSlotResults() throws {
        let groupId = UUID()
        let s0 = FrontierSlotResult(index: 0, sessionId: UUID())
        let s1 = FrontierSlotResult(index: 1, sessionId: UUID())
        let s2 = FrontierSlotResult(index: 2, reason: "codex CLI not on PATH")
        let resp = CreateFrontierResponse(groupId: groupId, slots: [s0, s1, s2])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CreateFrontierResponse.self, from: encoder.encode(resp))
        XCTAssertEqual(decoded.groupId, groupId)
        XCTAssertTrue(decoded.slots[0].isOK)
        XCTAssertTrue(decoded.slots[1].isOK)
        XCTAssertFalse(decoded.slots[2].isOK)
        XCTAssertEqual(decoded.slots[2].reason, "codex CLI not on PATH")
    }

    /// v0.23.9 P1 fix: a two-of-three success counts as a real broadcast;
    /// the UI proceeds with two live children and surfaces the third
    /// child's failure reason.
    func test_createFrontierResponse_hasMinimumBroadcastWithTwoSuccesses() {
        let resp = CreateFrontierResponse(
            groupId: UUID(),
            slots: [
                FrontierSlotResult(index: 0, sessionId: UUID()),
                FrontierSlotResult(index: 1, sessionId: UUID()),
                FrontierSlotResult(index: 2, reason: "codex CLI not on PATH")
            ]
        )
        XCTAssertEqual(resp.successfulSlots.count, 2)
        XCTAssertEqual(resp.failedSlots.count, 1)
        XCTAssertEqual(resp.failedSlots.first?.reason, "codex CLI not on PATH")
        XCTAssertTrue(resp.hasMinimumBroadcast)
    }

    /// v0.23.9 P1 fix: a one-of-three success is NOT a broadcast — UI
    /// must refuse to open the broadcast surface and instead show why
    /// the other two slots failed.
    func test_createFrontierResponse_hasMinimumBroadcastFailsWithOneSuccess() {
        let resp = CreateFrontierResponse(
            groupId: UUID(),
            slots: [
                FrontierSlotResult(index: 0, sessionId: UUID()),
                FrontierSlotResult(index: 1, reason: "antigravity not running"),
                FrontierSlotResult(index: 2, reason: "codex auth missing")
            ]
        )
        XCTAssertEqual(resp.successfulSlots.count, 1)
        XCTAssertEqual(resp.failedSlots.count, 2)
        XCTAssertFalse(resp.hasMinimumBroadcast)
    }

    /// v0.23.9 P2 fix: per-child text overrides survive Codable round-trip
    /// so the Frontier send fan-out can route a child-specific prompt
    /// (with that child's attachment path) to each session.
    func test_frontierSendRequest_perChildTextRoundTrips() throws {
        let claudeId = UUID()
        let codexId = UUID()
        let geminiId = UUID()
        let req = FrontierSendRequest(
            text: "what is in this image?",
            asFollowUp: false,
            perChildText: [
                claudeId: "@/path/to/claude/staging/img.png what is in this image?",
                codexId: "@/path/to/codex/staging/img.png what is in this image?",
                geminiId: "@/path/to/gemini/staging/img.png what is in this image?"
            ]
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(FrontierSendRequest.self, from: data)
        XCTAssertEqual(decoded.text, "what is in this image?")
        XCTAssertEqual(decoded.text(forChild: claudeId), "@/path/to/claude/staging/img.png what is in this image?")
        XCTAssertEqual(decoded.text(forChild: codexId), "@/path/to/codex/staging/img.png what is in this image?")
        XCTAssertEqual(decoded.text(forChild: geminiId), "@/path/to/gemini/staging/img.png what is in this image?")
    }

    /// v0.23.9 P2 fix: when no override is registered for a child id,
    /// `text(forChild:)` falls back to the shared `text` so unscoped
    /// callers (no attachments) keep working.
    func test_frontierSendRequest_perChildTextFallsBackToShared() {
        let req = FrontierSendRequest(text: "shared prompt", perChildText: nil)
        let unknownChild = UUID()
        XCTAssertEqual(req.text(forChild: unknownChild), "shared prompt")
    }

    // MARK: - FrontierGroupSnapshot

    func test_frontierGroupSnapshot_withFailedChildAndWinnerMetadata() throws {
        let groupId = UUID()
        let winner = FrontierTurnWinner(groupId: groupId, turnId: "turn-1", childIndex: 0)
        let snapshot = FrontierGroupSnapshot(
            groupId: groupId,
            updateCounter: 5,
            children: [
                FrontierChild(
                    childIndex: 0,
                    sessionId: UUID(),
                    provider: .claude,
                    modelSlug: "opus",
                    snapshot: nil,
                    status: .streaming,
                    currentTurnState: .streaming
                ),
                FrontierChild(
                    childIndex: 1,
                    sessionId: UUID(),
                    provider: .codex,
                    modelSlug: "gpt-5.5",
                    snapshot: nil,
                    status: .failed,
                    currentTurnState: .interrupted
                )
            ],
            turnWinners: [winner]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FrontierGroupSnapshot.self, from: encoder.encode(snapshot))
        XCTAssertEqual(decoded.children.count, 2)
        XCTAssertEqual(decoded.children[0].provider, .claude)
        XCTAssertEqual(decoded.children[0].currentTurnState, .streaming)
        XCTAssertEqual(decoded.children[1].status, .failed)
        XCTAssertEqual(decoded.children[1].provider, .codex)
        XCTAssertEqual(decoded.children[1].currentTurnState, .interrupted)
        XCTAssertEqual(decoded.turnWinners.map(\.turnId), ["turn-1"])
        XCTAssertEqual(decoded.turnWinners.first?.childIndex, 0)
    }

    func test_frontierGroupSnapshot_decodes_legacyPayloadWithoutProviderTurnStateOrWinners() throws {
        let groupId = UUID()
        let sessionId = UUID()
        let payload: [String: Any] = [
            "groupId": groupId.uuidString,
            "updateCounter": 1,
            "children": [[
                "childIndex": 0,
                "sessionId": sessionId.uuidString,
                "modelSlug": "opus",
                "status": "streaming"
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(FrontierGroupSnapshot.self, from: data)
        XCTAssertEqual(decoded.groupId, groupId)
        XCTAssertTrue(decoded.turnWinners.isEmpty)
        XCTAssertEqual(decoded.children.first?.provider, .unknown)
        XCTAssertEqual(decoded.children.first?.currentTurnState, .idle)
    }

    func test_frontierChildStatus_lenientDecode() throws {
        let bogus = "\"future-state\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FrontierChildStatus.self, from: bogus), .pending)
    }

    func test_frontierSendResponse_roundTripsPerChildFailures() throws {
        let groupId = UUID()
        let okSession = UUID()
        let failedSession = UUID()
        let response = FrontierSendResponse(
            groupId: groupId,
            childCount: 2,
            results: [
                FrontierChildSendResult(childIndex: 0, sessionId: okSession, ok: true),
                FrontierChildSendResult(childIndex: 1, sessionId: failedSession, ok: false, reason: "missing_pane_id")
            ]
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(FrontierSendResponse.self, from: data)

        XCTAssertEqual(decoded.groupId, groupId)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.results[0].sessionId, okSession)
        XCTAssertEqual(decoded.results[1].reason, "missing_pane_id")
    }

    func test_frontierTurnWinner_roundTrips() throws {
        let groupId = UUID()
        let winner = FrontierTurnWinner(
            groupId: groupId,
            turnId: "turn-2",
            childIndex: 2,
            decidedAt: Date(timeIntervalSince1970: 1_779_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(FrontierTurnWinner.self, from: encoder.encode(winner))

        XCTAssertEqual(decoded.groupId, groupId)
        XCTAssertEqual(decoded.turnId, "turn-2")
        XCTAssertEqual(decoded.childIndex, 2)
        XCTAssertEqual(decoded.id, "\(groupId.uuidString):turn-2")
    }

    func test_frontierTurnIdentifier_usesGroupUserTurnCount() throws {
        let now = Date(timeIntervalSince1970: 1_779_000_000)
        let childAItems: [ChatItem] = [
            .message(ChatMessage(id: "claude-user-a", kind: .userText, title: "You", body: "one", at: now)),
            .message(ChatMessage(id: "claude-assistant-a", kind: .assistantText, title: "Claude", body: "answer", at: now)),
            .message(ChatMessage(id: "claude-user-b", kind: .userText, title: "You", body: "two", at: now))
        ]
        let childBItems: [ChatItem] = [
            .message(ChatMessage(id: "codex-user-x", kind: .userText, title: "You", body: "one", at: now)),
            .message(ChatMessage(id: "codex-user-y", kind: .userText, title: "You", body: "two", at: now))
        ]
        let childA = WireChatSnapshot(
            sessionId: UUID(),
            items: childAItems,
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 0,
            totalOutputTokens: 0,
            lastEventAt: now,
            updateCounter: 1
        )
        let childB = WireChatSnapshot(
            sessionId: UUID(),
            items: childBItems,
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 0,
            totalOutputTokens: 0,
            lastEventAt: now,
            updateCounter: 1
        )

        let group = FrontierGroupSnapshot(
            groupId: UUID(),
            updateCounter: 1,
            children: [
                FrontierChild(childIndex: 0, sessionId: childA.sessionId, modelSlug: "opus", snapshot: childA, status: .complete),
                FrontierChild(childIndex: 1, sessionId: childB.sessionId, modelSlug: "gpt-5.5", snapshot: childB, status: .complete)
            ]
        )

        XCTAssertEqual(FrontierTurnIdentifier.latest(in: childAItems), "turn-2")
        XCTAssertEqual(FrontierTurnIdentifier.latest(in: childBItems), "turn-2")
        XCTAssertEqual(group.latestTurnId, "turn-2")
    }

    // MARK: - ChatProvidersResponse

    func test_chatProvidersResponse_withCodexSubRows() throws {
        let now = Date()
        let resp = ChatProvidersResponse(providers: [
            ChatProviderEntry(
                provider: .claude,
                available: true, authenticated: true, capabilityProbePassed: true,
                lastProbedAt: now
            ),
            ChatProviderEntry(
                provider: .codex, codexBackend: .sdk,
                available: true, authenticated: true, capabilityProbePassed: true,
                lastProbedAt: now
            ),
            ChatProviderEntry(
                provider: .codex, codexBackend: .cli,
                available: true, authenticated: true, capabilityProbePassed: true,
                lastProbedAt: now
            ),
            ChatProviderEntry(
                provider: .gemini,
                available: false, authenticated: false, capabilityProbePassed: false,
                reason: "v0.9"
            ),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatProvidersResponse.self, from: encoder.encode(resp))
        XCTAssertEqual(decoded.providers.count, 4)
        XCTAssertEqual(decoded.providers[3].provider, .gemini)
        XCTAssertEqual(decoded.providers[3].reason, "v0.9")
    }
}
