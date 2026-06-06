import XCTest
@testable import ClawdmeterShared

final class ProviderPromptPolicyTests: XCTestCase {
    func test_userComposerMaySendHiAndPing() {
        XCTAssertTrue(ProviderPromptGuard.validate(text: "hi", origin: .userComposer).allowed)
        XCTAssertTrue(ProviderPromptGuard.validate(text: "PING", origin: .userComposer).allowed)
    }

    func test_legacyOriginsAreBlocked() {
        for text in ["hi", "ping", "PONG", "heartbeat", "keepalive", "Reply with the single word PONG and nothing else."] {
            let decision = ProviderPromptGuard.validate(text: text, origin: .legacyClient)
            XCTAssertFalse(decision.allowed, text)
            XCTAssertEqual(decision.reason, "synthetic_prompt_requires_user_origin")
        }
        let normalPrompt = ProviderPromptGuard.validate(text: "please inspect the failing test", origin: .legacyClient)
        XCTAssertFalse(normalPrompt.allowed)
        XCTAssertEqual(normalPrompt.reason, "legacy_prompt_origin_blocked")
    }

    func test_systemAndLiveTestOriginsNeedExplicitPolicy() {
        XCTAssertFalse(ProviderPromptGuard.validate(text: "real prompt", origin: .systemProbe).allowed)
        XCTAssertFalse(ProviderPromptGuard.validate(text: "real prompt", origin: .systemHeartbeat).allowed)
        XCTAssertFalse(ProviderPromptGuard.validate(text: "real prompt", origin: .liveProviderTest).allowed)
        XCTAssertTrue(ProviderPromptGuard.validate(
            text: "neutral live verification prompt",
            origin: .liveProviderTest,
            allowLiveProviderSpend: true
        ).allowed)
        XCTAssertFalse(ProviderPromptGuard.validate(
            text: "Reply with the single word PONG and nothing else.",
            origin: .liveProviderTest,
            allowLiveProviderSpend: true
        ).allowed)
    }

    func test_oldScheduledFollowUpsDecodeAsManualLegacy() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","fireAt":"2026-06-07T00:00:00Z","prompt":"hi"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let followUp = try decoder.decode(ScheduledFollowUp.self, from: data)
        XCTAssertEqual(followUp.origin, .legacyClient)
        XCTAssertEqual(followUp.deliveryPolicy, .requiresConfirmation)
    }
}
