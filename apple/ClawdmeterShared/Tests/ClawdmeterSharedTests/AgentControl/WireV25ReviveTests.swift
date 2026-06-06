import XCTest
@testable import ClawdmeterShared

/// Wire v25: `POST /sessions/:id/revive` respawns a degraded session's dead
/// runtime.
///   - `AgentControlWireVersion.current >= 25` and `reviveMinimum = 25`.
///   - `supportsRevive` gates the iOS button so older Macs degrade gracefully.
///   - `ReviveRequest` round-trips; `MobileCommandKind.revive` decodes.
final class WireV25ReviveTests: XCTestCase {

    func test_currentWireVersionIsAtLeast25() {
        XCTAssertGreaterThanOrEqual(AgentControlWireVersion.current, 25)
        XCTAssertEqual(AgentControlWireVersion.reviveMinimum, 25)
    }

    func test_supportsRevive_gatesOnReviveMinimum() {
        XCTAssertFalse(AgentControlWireVersion.supportsRevive(serverWireVersion: nil))
        XCTAssertFalse(AgentControlWireVersion.supportsRevive(serverWireVersion: 24))
        XCTAssertTrue(AgentControlWireVersion.supportsRevive(serverWireVersion: 25))
        XCTAssertTrue(AgentControlWireVersion.supportsRevive(serverWireVersion: AgentControlWireVersion.current))
    }

    func test_reviveRequest_roundTrips() throws {
        let key = UUID().uuidString
        let data = try JSONEncoder().encode(ReviveRequest(idempotencyKey: key))
        let decoded = try JSONDecoder().decode(ReviveRequest.self, from: data)
        XCTAssertEqual(decoded.idempotencyKey, key)
    }

    func test_reviveRequest_emptyBodyDecodesNilKey() throws {
        let decoded = try JSONDecoder().decode(ReviveRequest.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.idempotencyKey)
    }

    func test_mobileCommandKind_reviveDecodes() throws {
        let decoded = try JSONDecoder().decode(MobileCommandKind.self, from: Data("\"revive\"".utf8))
        XCTAssertEqual(decoded, .revive)
    }

    func test_mobileCommandKind_unknownStillFallsBackToSend() throws {
        // Forward-compat: an older client decoding a future kind degrades to .send.
        let decoded = try JSONDecoder().decode(MobileCommandKind.self, from: Data("\"future_unknown\"".utf8))
        XCTAssertEqual(decoded, .send)
    }
}
