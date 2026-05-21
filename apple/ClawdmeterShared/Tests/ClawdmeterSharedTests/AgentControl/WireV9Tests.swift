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

    func test_currentWireVersionIsNine() {
        XCTAssertEqual(AgentControlWireVersion.current, 9)
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
                FrontierModelSlot(provider: .codex, model: "gpt-5.5", codexChatBackend: .sdk)
            ]
        )
        let encoded = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(CreateFrontierRequest.self, from: encoded)
        XCTAssertEqual(decoded.clientRequestId, requestId)
        XCTAssertEqual(decoded.models.count, 2)
        XCTAssertEqual(decoded.models[1].codexChatBackend, .sdk)
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

    // MARK: - FrontierGroupSnapshot

    func test_frontierGroupSnapshot_withFailedChild() throws {
        let groupId = UUID()
        let snapshot = FrontierGroupSnapshot(
            groupId: groupId,
            updateCounter: 5,
            children: [
                FrontierChild(
                    childIndex: 0,
                    sessionId: UUID(),
                    modelSlug: "opus",
                    snapshot: nil,
                    status: .streaming
                ),
                FrontierChild(
                    childIndex: 1,
                    sessionId: UUID(),
                    modelSlug: "gpt-5.5",
                    snapshot: nil,
                    status: .failed
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FrontierGroupSnapshot.self, from: encoder.encode(snapshot))
        XCTAssertEqual(decoded.children.count, 2)
        XCTAssertEqual(decoded.children[1].status, .failed)
    }

    func test_frontierChildStatus_lenientDecode() throws {
        let bogus = "\"future-state\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FrontierChildStatus.self, from: bogus), .pending)
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
