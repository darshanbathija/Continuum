import XCTest
@testable import ClawdmeterShared

/// Phase 10 wire-shape tests. The APNS payload structs live in the Mac
/// module (need to import nothing from ActivityKit so they can be
/// signed/sent from the daemon), but the underlying
/// `SessionLiveActivityContentState` keys must stay in sync with what
/// the iOS widget extension decodes. These tests pin the JSON shape so
/// future renames flag in CI instead of breaking Lock Screen pills
/// silently.
#if os(iOS)
final class LiveActivityWireTests: XCTestCase {
    func test_content_state_roundtrip() throws {
        let state = SessionLiveActivityContentState(
            activeSessionCount: 3,
            latestCity: "Tokyo",
            latestAgentKind: .claude,
            latestState: "running",
            needsAttention: false
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SessionLiveActivityContentState.self, from: data)
        XCTAssertEqual(decoded.activeSessionCount, 3)
        XCTAssertEqual(decoded.latestCity, "Tokyo")
        XCTAssertEqual(decoded.latestAgentKind, .claude)
        XCTAssertEqual(decoded.latestState, "running")
        XCTAssertFalse(decoded.needsAttention)
    }

    func test_content_state_needs_attention_serializes() throws {
        let state = SessionLiveActivityContentState(
            activeSessionCount: 1,
            latestCity: "Lagos",
            latestAgentKind: .codex,
            latestState: "planning",
            needsAttention: true
        )
        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["activeSessionCount"] as? Int, 1)
        XCTAssertEqual(json["needsAttention"] as? Bool, true)
        XCTAssertEqual(json["latestAgentKind"] as? String, "codex")
    }
}
#endif
