import XCTest
@testable import ClawdmeterShared

/// D4 (v0.17, wire v12): per-provider auto-revive RPC body. The Mac
/// daemon's `handleSetAutoRevive(providerId:request:connection:)`
/// decodes this; the iOS Live tab's toggle calls
/// `AgentControlClient.setAutoRevive(provider:enabled:)` which posts
/// this body.
final class SetAutoReviveRequestTests: XCTestCase {

    func test_encode_enabled_true() throws {
        let req = SetAutoReviveRequest(enabled: true)
        let data = try JSONEncoder().encode(req)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, #"{"enabled":true}"#)
    }

    func test_encode_enabled_false() throws {
        let req = SetAutoReviveRequest(enabled: false)
        let data = try JSONEncoder().encode(req)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, #"{"enabled":false}"#)
    }

    func test_decode_roundtrip() throws {
        for enabled in [true, false] {
            let req = SetAutoReviveRequest(enabled: enabled)
            let data = try JSONEncoder().encode(req)
            let decoded = try JSONDecoder().decode(SetAutoReviveRequest.self, from: data)
            XCTAssertEqual(decoded.enabled, enabled)
        }
    }

    func test_decode_rejects_missing_field() {
        // Defensive: if the wire payload arrives without `enabled`, the
        // decode must throw (and the server returns 400) rather than
        // silently defaulting to false.
        let data = Data("{}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SetAutoReviveRequest.self, from: data))
    }
}
