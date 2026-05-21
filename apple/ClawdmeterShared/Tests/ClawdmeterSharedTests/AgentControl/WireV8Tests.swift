import XCTest
@testable import ClawdmeterShared

/// Exercises the wire v8 bump:
///   - AgentControlWireVersion.current = 8
///   - codexSDKMinimum = 8, supportsCodexSDK(...) gate
///   - UsageData.codexSDKModeActive decodeIfPresent (v6/v7 → v8 back-compat)
///   - v8 round-trip preserves all four optional model/SDK fields
final class WireV8Tests: XCTestCase {

    func test_currentWireVersionIsEight() {
        // v0.8.0 agy-migration: bumped to 10 (skips v9 which is chat-tab's).
        // Test name kept for git-blame continuity; assertion tracks current.
        XCTAssertEqual(AgentControlWireVersion.current, 10)
    }

    func test_codexSDKMinimumIsEight() {
        XCTAssertEqual(AgentControlWireVersion.codexSDKMinimum, 8)
    }

    func test_supportsCodexSDK_trueAtV8() {
        XCTAssertTrue(AgentControlWireVersion.supportsCodexSDK(serverWireVersion: 8))
        XCTAssertTrue(AgentControlWireVersion.supportsCodexSDK(serverWireVersion: 9))
    }

    func test_supportsCodexSDK_falseAtV7OrEarlier() {
        XCTAssertFalse(AgentControlWireVersion.supportsCodexSDK(serverWireVersion: 7))
        XCTAssertFalse(AgentControlWireVersion.supportsCodexSDK(serverWireVersion: 6))
        XCTAssertFalse(AgentControlWireVersion.supportsCodexSDK(serverWireVersion: nil))
    }

    func test_otherMinimumsUnchanged() {
        // Sanity: bumping current to 8 didn't drift the earlier gates.
        XCTAssertEqual(AgentControlWireVersion.antigravityMinimum, 7)
        XCTAssertEqual(AgentControlWireVersion.geminiMinimum, 6)
        XCTAssertEqual(AgentControlWireVersion.chatSubscribeMinimum, 5)
        XCTAssertEqual(AgentControlWireVersion.composeDraftMinimum, 4)
    }

    // MARK: - UsageData v6 → v8 decode

    func test_usageData_v6PayloadDecodesIntoV8StructWithNils() throws {
        let v6json = #"""
        {
          "sessionPct": 42, "sessionResetMins": 100, "sessionEpoch": 1779219000,
          "weeklyPct": 17, "weeklyResetMins": 5000, "weeklyEpoch": 1779000000,
          "status": "allowed", "representativeClaim": "five_hour",
          "updatedAt": "2026-05-19T18:30:00Z"
        }
        """#
        let decoded = try JSONDecoder.iso8601.decode(UsageData.self, from: v6json.data(using: .utf8)!)
        XCTAssertEqual(decoded.sessionPct, 42)
        XCTAssertNil(decoded.antigravityModel)
        XCTAssertNil(decoded.sdkModeActive)
        XCTAssertNil(decoded.codexSDKModeActive, "v6 payload has no codexSDKModeActive → nil")
    }

    func test_usageData_v7PayloadDecodesIntoV8StructWithNilCodexFlag() throws {
        let v7json = #"""
        {
          "sessionPct": 42, "sessionResetMins": 100, "sessionEpoch": 1779219000,
          "weeklyPct": 17, "weeklyResetMins": 5000, "weeklyEpoch": 1779000000,
          "status": "allowed", "representativeClaim": "five_hour",
          "updatedAt": "2026-05-19T18:30:00Z",
          "antigravityModel": "gemini-3.5-flash",
          "sdkModeActive": true
        }
        """#
        let decoded = try JSONDecoder.iso8601.decode(UsageData.self, from: v7json.data(using: .utf8)!)
        XCTAssertEqual(decoded.antigravityModel, "gemini-3.5-flash")
        XCTAssertEqual(decoded.sdkModeActive, true)
        XCTAssertNil(decoded.codexSDKModeActive, "v7 payload has no codexSDKModeActive — nil")
    }

    func test_usageData_v8PayloadRoundTrips() throws {
        let original = UsageData(
            sessionPct: 50, sessionResetMins: 60, sessionEpoch: 1779219000,
            weeklyPct: 25, weeklyResetMins: 3600, weeklyEpoch: 1779000000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1779219000),
            antigravityModel: "gemini-3.5-flash",
            sdkModeActive: true,
            codexSDKModeActive: true
        )
        let data = try JSONEncoder.iso8601.encode(original)
        let decoded = try JSONDecoder.iso8601.decode(UsageData.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.codexSDKModeActive, true)
    }

    func test_usageData_v8EncodedOmitsNilCodexFlag() throws {
        // encodeIfPresent — when codexSDKModeActive is nil, the key
        // must NOT appear in the encoded JSON (back-compat with v7).
        let v8withoutCodex = UsageData(
            sessionPct: 50, sessionResetMins: 60, sessionEpoch: 1779219000,
            weeklyPct: 25, weeklyResetMins: 3600, weeklyEpoch: 1779000000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1779219000),
            antigravityModel: "gemini-3.5-flash",
            sdkModeActive: false
        )
        let data = try JSONEncoder.iso8601.encode(v8withoutCodex)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertFalse(jsonString.contains("codexSDKModeActive"))
    }

    func test_usageData_v8EncodedIncludesCodexFlagWhenSet() throws {
        let v8 = UsageData(
            sessionPct: 50, sessionResetMins: 60, sessionEpoch: 1779219000,
            weeklyPct: 25, weeklyResetMins: 3600, weeklyEpoch: 1779000000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1779219000),
            codexSDKModeActive: true
        )
        let data = try JSONEncoder.iso8601.encode(v8)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"codexSDKModeActive\":true"))
    }
}

// MARK: - Test helpers (reused from WireV7Tests)

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
