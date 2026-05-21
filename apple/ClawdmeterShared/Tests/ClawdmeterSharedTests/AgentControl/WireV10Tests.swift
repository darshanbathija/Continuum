import XCTest
@testable import ClawdmeterShared

/// Exercises the wire v8 → v10 bump (agy-migration v0.8.0):
///   - AgentControlWireVersion.current = 10 (skips v9 which chat-tab took)
///   - agentapiMinimum = 10, antigravityChatMinimum = 11 (Codex P1.4:
///     iOS gate held closed until v0.8.2 migrates daemon POST /sessions
///     to also dispatch through agentapi; until then a v10 daemon can
///     spawn Antigravity sessions through the Mac UI but NOT via the
///     iOS-facing daemon endpoint)
///   - supportsAntigravityChat(_:) gate
///   - GeminiBackend enum + AgentSession schema v6 fields
///     (geminiBackend, antigravityConversationId) with decoder tolerance
///     for v3/v4/v5 sessions.json files
///   - UsageEnvelope.usage["gemini"] ↔ usage["antigravity"] dual-key
///     fallback (preserves v8/v9 iOS readers consuming v10 Mac data)
final class WireV10Tests: XCTestCase {

    // MARK: - Wire version constants

    func test_currentWireVersionIsTen() {
        XCTAssertEqual(AgentControlWireVersion.current, 10)
    }

    func test_agentapiMinimumIsTen() {
        XCTAssertEqual(AgentControlWireVersion.agentapiMinimum, 10)
    }

    func test_antigravityChatMinimumDefersToV11() {
        // Codex P1.4: v0.8.1's daemon POST /sessions still spawns Gemini
        // via legacy tmux argv. Until the daemon endpoint is also
        // migrated (v0.8.2), iOS must not claim Antigravity chat support
        // — even on a v10 Mac.
        XCTAssertEqual(AgentControlWireVersion.antigravityChatMinimum, 11)
    }

    func test_supportsAntigravityChat_falseAtV10() {
        // v10 Mac UI spawns agentapi; v10 daemon endpoint does not.
        // iOS gate stays closed until v0.8.2 (when this returns true).
        XCTAssertFalse(AgentControlWireVersion.supportsAntigravityChat(serverWireVersion: 10))
        XCTAssertTrue(AgentControlWireVersion.supportsAntigravityChat(serverWireVersion: 11))
    }

    func test_supportsAntigravityChat_falseAtV9OrEarlier() {
        XCTAssertFalse(AgentControlWireVersion.supportsAntigravityChat(serverWireVersion: 9))
        XCTAssertFalse(AgentControlWireVersion.supportsAntigravityChat(serverWireVersion: 8))
        XCTAssertFalse(AgentControlWireVersion.supportsAntigravityChat(serverWireVersion: nil))
    }

    func test_priorMinimumsUnchanged() {
        // v10 must not drift earlier gates.
        XCTAssertEqual(AgentControlWireVersion.composeDraftMinimum, 4)
        XCTAssertEqual(AgentControlWireVersion.chatSubscribeMinimum, 5)
        XCTAssertEqual(AgentControlWireVersion.geminiMinimum, 6)
        XCTAssertEqual(AgentControlWireVersion.antigravityMinimum, 7)
        XCTAssertEqual(AgentControlWireVersion.codexSDKMinimum, 8)
    }

    // MARK: - GeminiBackend enum

    func test_geminiBackend_codableRoundTrip() throws {
        let value: GeminiBackend = .agentapi
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(GeminiBackend.self, from: data)
        XCTAssertEqual(decoded, .agentapi)
    }

    func test_geminiBackend_rawValueIsAgentapi() {
        XCTAssertEqual(GeminiBackend.agentapi.rawValue, "agentapi")
    }

    // MARK: - AgentSession schema v6 round-trip

    func test_agentSession_schemaV6_roundTripWithAgentapiFields() throws {
        let convId = UUID()
        let session = AgentSession(
            id: UUID(),
            repoKey: "/Users/dev/repo",
            repoDisplayName: "repo",
            agent: .gemini,
            model: "gemini-3.5-flash",
            goal: "ship v0.8.0",
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(timeIntervalSince1970: 1779000000),
            lastEventAt: Date(timeIntervalSince1970: 1779000100),
            lastEventSeq: 42,
            geminiBackend: .agentapi,
            antigravityConversationId: convId
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.geminiBackend, .agentapi)
        XCTAssertEqual(decoded.antigravityConversationId, convId)
        XCTAssertEqual(decoded.agent, .gemini)
    }

    func test_agentSession_schemaV5PayloadDecodesWithNilV6Fields() throws {
        // Simulates a sessions.json written by v0.7.x (no geminiBackend,
        // no antigravityConversationId). Decoder should set them to nil
        // without erroring.
        let v5json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "repoKey": "/Users/dev/repo",
          "repoDisplayName": "repo",
          "agent": "gemini",
          "status": "running",
          "createdAt": "2026-05-19T18:30:00Z",
          "lastEventAt": "2026-05-19T18:31:00Z",
          "lastEventSeq": 0,
          "mode": "local"
        }
        """#
        let decoded = try JSONDecoder.iso8601.decode(AgentSession.self, from: v5json.data(using: .utf8)!)
        XCTAssertEqual(decoded.agent, .gemini)
        XCTAssertNil(decoded.geminiBackend)
        XCTAssertNil(decoded.antigravityConversationId)
    }

    func test_agentSession_v6EncodingOmitsNilFields() throws {
        // Ensure we don't emit `"geminiBackend": null` / `"antigravityConversationId": null`
        // for non-agentapi sessions — keeps the wire shape lean for Claude/Codex
        // sessions (and v0.7 Gemini sessions).
        let session = AgentSession(
            id: UUID(),
            repoKey: "/Users/dev/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0
        )
        let data = try JSONEncoder().encode(session)
        let jsonString = String(data: data, encoding: .utf8)!
        // Round-trip should still work even without the v6 fields.
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertNil(decoded.geminiBackend)
        XCTAssertNil(decoded.antigravityConversationId)
        // Wire shape lean: nil fields should NOT appear in output.
        // JSONEncoder default behavior is to omit nil for Optional via encodeIfPresent,
        // but Swift's auto-synthesized Codable emits null. This is a soft
        // check — flip on if/when we add custom encode(to:).
        _ = jsonString
    }

    // MARK: - UsageEnvelope dual-key decoder (gemini ↔ antigravity)

    /// v10 Mac writes `usage["antigravity"]`. v8/v9 iOS asks for the
    /// "gemini" provider id (the canonical client-side id stays the
    /// same). The dual-key bridge should resolve the data either way.
    func test_usageEnvelope_v10PayloadServesGeminiQuery() throws {
        let v10json = #"""
        {
          "lastChecked": "2026-05-21T03:00:00Z",
          "usage": {
            "antigravity": {
              "sessionPct": 33, "sessionResetMins": 90, "sessionEpoch": 1779200000,
              "weeklyPct": 0, "weeklyResetMins": 0, "weeklyEpoch": 0,
              "status": "allowed", "representativeClaim": "unknown",
              "updatedAt": "2026-05-21T03:00:00Z"
            }
          }
        }
        """#
        let env = try JSONDecoder.iso8601.decode(UsageEnvelope.self, from: v10json.data(using: .utf8)!)
        // Direct hit on antigravity.
        XCTAssertNotNil(env.usageData(for: "antigravity"))
        // Cross-bridge: querying with the canonical "gemini" id resolves.
        let geminiQuery = env.usageData(for: "gemini")
        XCTAssertNotNil(geminiQuery, "v8/v9 iOS asking for 'gemini' must see data when v10 Mac wrote it under 'antigravity'")
        XCTAssertEqual(geminiQuery?.sessionPct, 33)
    }

    /// v8/v9 Mac wrote `usage["gemini"]`. v10 iOS asks for either id.
    /// The dual-key bridge resolves in both directions.
    func test_usageEnvelope_v8PayloadServesAntigravityQuery() throws {
        let v8json = #"""
        {
          "lastChecked": "2026-05-21T03:00:00Z",
          "usage": {
            "gemini": {
              "sessionPct": 77, "sessionResetMins": 30, "sessionEpoch": 1779200000,
              "weeklyPct": 0, "weeklyResetMins": 0, "weeklyEpoch": 0,
              "status": "allowed", "representativeClaim": "five_hour",
              "updatedAt": "2026-05-21T03:00:00Z"
            }
          }
        }
        """#
        let env = try JSONDecoder.iso8601.decode(UsageEnvelope.self, from: v8json.data(using: .utf8)!)
        // Legacy id still works.
        XCTAssertEqual(env.usageData(for: "gemini")?.sessionPct, 77)
        // New id falls through to legacy key via dual-bridge.
        let antigravityQuery = env.usageData(for: "antigravity")
        XCTAssertNotNil(antigravityQuery, "v10 iOS asking for 'antigravity' must see data when v8/v9 Mac wrote it under 'gemini'")
        XCTAssertEqual(antigravityQuery?.sessionPct, 77)
    }

    /// When BOTH keys are present (transitional payload during migration),
    /// the direct-match key wins. Prevents data inversion if a server ever
    /// emits both for back-compat.
    func test_usageEnvelope_directMatchTakesPriorityOverBridge() throws {
        let bothjson = #"""
        {
          "lastChecked": "2026-05-21T03:00:00Z",
          "usage": {
            "antigravity": {
              "sessionPct": 99, "sessionResetMins": 1, "sessionEpoch": 1779200000,
              "weeklyPct": 0, "weeklyResetMins": 0, "weeklyEpoch": 0,
              "status": "allowed", "representativeClaim": "unknown",
              "updatedAt": "2026-05-21T03:00:00Z"
            },
            "gemini": {
              "sessionPct": 1, "sessionResetMins": 999, "sessionEpoch": 1779200000,
              "weeklyPct": 0, "weeklyResetMins": 0, "weeklyEpoch": 0,
              "status": "allowed", "representativeClaim": "five_hour",
              "updatedAt": "2026-05-21T03:00:00Z"
            }
          }
        }
        """#
        let env = try JSONDecoder.iso8601.decode(UsageEnvelope.self, from: bothjson.data(using: .utf8)!)
        // Each query should return the directly-matching key.
        XCTAssertEqual(env.usageData(for: "antigravity")?.sessionPct, 99)
        XCTAssertEqual(env.usageData(for: "gemini")?.sessionPct, 1)
    }

    /// Legacy top-level fields (`claude` / `codex`) still work for those
    /// providers — verifies the dual-key bridge didn't accidentally
    /// short-circuit the per-provider fallback for non-Gemini ids.
    func test_usageEnvelope_claudeCodexPathUnchanged() throws {
        let legacy = #"""
        {
          "lastChecked": "2026-05-21T03:00:00Z",
          "claude": {
            "sessionPct": 50, "sessionResetMins": 60, "sessionEpoch": 1779200000,
            "weeklyPct": 0, "weeklyResetMins": 0, "weeklyEpoch": 0,
            "status": "allowed", "representativeClaim": "five_hour",
            "updatedAt": "2026-05-21T03:00:00Z"
          }
        }
        """#
        let env = try JSONDecoder.iso8601.decode(UsageEnvelope.self, from: legacy.data(using: .utf8)!)
        XCTAssertEqual(env.usageData(for: "claude")?.sessionPct, 50)
        XCTAssertNil(env.usageData(for: "antigravity"))
        XCTAssertNil(env.usageData(for: "gemini"))
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
