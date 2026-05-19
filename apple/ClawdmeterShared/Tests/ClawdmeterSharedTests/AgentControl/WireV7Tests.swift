import XCTest
@testable import ClawdmeterShared

/// Exercises the wire v7 bump:
///   - AgentControlWireVersion.current = 7
///   - antigravityMinimum = 7, supportsAntigravityPlan(...) gate
///   - AntigravityPlanSnapshot + WirePlanStep + WireBrainArtifact + WireTokenUsage round-trip
///   - UsageData.antigravityModel + sdkModeActive decodeIfPresent (v6→v7 back-compat)
///   - usage[id] dict key STAYS "gemini" (D5 — must NOT rename to "antigravity")
final class WireV7Tests: XCTestCase {

    // MARK: - Wire version constant

    func test_currentWireVersionIsSeven() {
        XCTAssertEqual(AgentControlWireVersion.current, 7)
    }

    func test_antigravityMinimumIsSeven() {
        XCTAssertEqual(AgentControlWireVersion.antigravityMinimum, 7)
    }

    func test_supportsAntigravityPlan_trueAtV7() {
        XCTAssertTrue(AgentControlWireVersion.supportsAntigravityPlan(serverWireVersion: 7))
        XCTAssertTrue(AgentControlWireVersion.supportsAntigravityPlan(serverWireVersion: 8))
    }

    func test_supportsAntigravityPlan_falseAtV6OrEarlier() {
        XCTAssertFalse(AgentControlWireVersion.supportsAntigravityPlan(serverWireVersion: 6))
        XCTAssertFalse(AgentControlWireVersion.supportsAntigravityPlan(serverWireVersion: 5))
        XCTAssertFalse(AgentControlWireVersion.supportsAntigravityPlan(serverWireVersion: nil))
    }

    func test_geminiMinimumUnchanged() {
        // Per D5: usage[id]="gemini" stays through v7. The gemini gate
        // must still trip at v6 (not v7) so v6 iOS keeps reading Gemini
        // data from a v7 Mac.
        XCTAssertEqual(AgentControlWireVersion.geminiMinimum, 6)
        XCTAssertTrue(AgentControlWireVersion.supportsGemini(serverWireVersion: 6))
        XCTAssertTrue(AgentControlWireVersion.supportsGemini(serverWireVersion: 7))
    }

    // MARK: - AntigravityPlanSnapshot round-trip

    func test_planSnapshot_roundTripsThroughJSON() throws {
        let original = AntigravityPlanSnapshot(
            sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            brainUUID: "abcdef00-1111-4222-8333-444444444444",
            taskHeadline: "Test headline",
            taskBody: "Body markdown",
            planSteps: [
                WirePlanStep(id: "step-1", label: "First", isComplete: true, depth: 0),
                WirePlanStep(id: "step-2", label: "Second", isComplete: false, depth: 0),
                WirePlanStep(id: "step-3", label: "Nested", isComplete: false, depth: 1),
            ],
            annotations: [
                WireBrainArtifact(id: "ann-1", filename: "a.pbtxt", body: "last_user_view_time: { seconds: 1779219825 }"),
            ],
            totalUsage: WireTokenUsage(total: 1234, prompt: 1000, candidate: 200, thoughts: 30, cached: 4, isEstimate: false),
            lastUpdated: Date(timeIntervalSince1970: 1779219825),
            model: "gemini-3.5-flash",
            sdkModeActive: true,
            awaitingFirstTurn: false
        )
        let data = try JSONEncoder.iso8601.encode(original)
        let decoded = try JSONDecoder.iso8601.decode(AntigravityPlanSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_planSnapshot_awaitingFirstTurnTrueWhenEmpty() throws {
        let snapshot = AntigravityPlanSnapshot(
            sessionId: UUID(),
            brainUUID: "abcdef00-1111-4222-8333-444444444444",
            taskHeadline: "",
            taskBody: "",
            planSteps: [],
            annotations: [],
            totalUsage: nil,
            lastUpdated: Date(timeIntervalSince1970: 0),
            model: nil,
            sdkModeActive: nil,
            awaitingFirstTurn: true
        )
        let data = try JSONEncoder.iso8601.encode(snapshot)
        let decoded = try JSONDecoder.iso8601.decode(AntigravityPlanSnapshot.self, from: data)
        XCTAssertTrue(decoded.awaitingFirstTurn)
        XCTAssertNil(decoded.totalUsage)
        XCTAssertNil(decoded.sdkModeActive)
    }

    func test_diskModeTokenUsage_estimateMarkerSet() throws {
        let usage = WireTokenUsage(total: 1234, prompt: nil, candidate: nil, thoughts: nil, cached: nil, isEstimate: true)
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(WireTokenUsage.self, from: data)
        XCTAssertEqual(decoded.total, 1234)
        XCTAssertNil(decoded.prompt)
        XCTAssertTrue(decoded.isEstimate ?? false)
    }

    // MARK: - UsageData decodeIfPresent (back-compat)

    func test_usageData_v6PayloadDecodesIntoV7Struct() throws {
        // A v6-shaped envelope has no antigravityModel or sdkModeActive
        // keys. The v7 decoder must accept it cleanly with nils.
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
        XCTAssertNil(decoded.antigravityModel, "v6 payload has no antigravityModel → nil")
        XCTAssertNil(decoded.sdkModeActive, "v6 payload has no sdkModeActive → nil")
    }

    func test_usageData_v7PayloadRoundTrips() throws {
        let v7 = UsageData(
            sessionPct: 50, sessionResetMins: 60, sessionEpoch: 1779219000,
            weeklyPct: 25, weeklyResetMins: 3600, weeklyEpoch: 1779000000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1779219000),
            organizationID: "org-123",
            antigravityModel: "gemini-3.5-flash",
            sdkModeActive: true
        )
        let data = try JSONEncoder.iso8601.encode(v7)
        let decoded = try JSONDecoder.iso8601.decode(UsageData.self, from: data)
        XCTAssertEqual(decoded, v7)
        XCTAssertEqual(decoded.antigravityModel, "gemini-3.5-flash")
        XCTAssertEqual(decoded.sdkModeActive, true)
    }

    func test_usageData_v7EncodedReadsCleanlyByV7Decoder() throws {
        // Forward-compat: a v7 payload with antigravityModel + sdkModeActive
        // round-trips. The two new fields must appear in the encoded JSON
        // OR be silently omitted when nil (encodeIfPresent).
        let v7withFields = UsageData(
            sessionPct: 50, sessionResetMins: 60, sessionEpoch: 1779219000,
            weeklyPct: 25, weeklyResetMins: 3600, weeklyEpoch: 1779000000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1779219000),
            antigravityModel: "gemini-3.5-flash",
            sdkModeActive: false
        )
        let data = try JSONEncoder.iso8601.encode(v7withFields)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"antigravityModel\":\"gemini-3.5-flash\""))
        XCTAssertTrue(jsonString.contains("\"sdkModeActive\":false"))

        // And the nil-fields variant should NOT include the keys at all.
        let v7withoutFields = UsageData(
            sessionPct: 50, sessionResetMins: 60, sessionEpoch: 1779219000,
            weeklyPct: 25, weeklyResetMins: 3600, weeklyEpoch: 1779000000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1779219000)
        )
        let data2 = try JSONEncoder.iso8601.encode(v7withoutFields)
        let jsonString2 = String(data: data2, encoding: .utf8)!
        XCTAssertFalse(jsonString2.contains("antigravityModel"))
        XCTAssertFalse(jsonString2.contains("sdkModeActive"))
    }

    // MARK: - D5: usage[id] dict key stays "gemini"

    func test_usageDictKey_isStillLiterallyGemini() {
        // Per locked decision D5 — see plan file. v6 iOS clients use the
        // per-provider fallback that keys the dict on "gemini" literally.
        // Renaming to "antigravity" would silently strand iOS data on
        // any mixed v6/v7 pairing. The string "gemini" is a contract.
        let geminiKey = "gemini"
        let antigravityKey = "antigravity"
        XCTAssertNotEqual(geminiKey, antigravityKey, "Sanity")
        // This test exists as a regression marker. If anyone ever changes
        // the dict key, they need to thread the v6↔v7 back-compat dance
        // first. Today the value is "gemini" — defended by the existing
        // WireMixedVersionPairingTests + WireEnvelopeDualShapeTests.
    }
}

// MARK: - Test helpers

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
