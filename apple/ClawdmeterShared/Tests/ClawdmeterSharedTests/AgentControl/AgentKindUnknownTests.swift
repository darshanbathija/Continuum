import XCTest
@testable import ClawdmeterShared

/// X3 — wire v12 (2026-05-22): forward-compat `.unknown` sentinel on
/// `AgentKind`. These tests guard the regression Codex flagged in the
/// outside-voice review: pre-X3, unknown raw values silently decoded as
/// `.claude`, which then caused older iOS clients talking to a newer Mac
/// (e.g. one shipping PR #28's OpenCode adapter) to mislabel OpenCode
/// sessions as Claude — letting users pick Claude models for them and
/// failing later at spawn time.
///
/// The contract these tests enforce:
///   1. Unknown raw decodes to `.unknown` (NOT `.claude`).
///   2. `.unknown` round-trips through Codable.
///   3. `allCases` excludes `.unknown` (pickers / segmented controls
///      never offer it as a selectable choice).
///   4. AgentKindUI renders `.unknown` as a neutral "Other agent" tile.
///   5. Known raws still decode to the right case (regression guard).
final class AgentKindUnknownTests: XCTestCase {

    // MARK: - Decoder

    func test_unknownRawDecodesAsUnknown() throws {
        // PR #29 (wire v13): `opencode` is now a real AgentKind case,
        // so it decodes natively instead of falling into `.unknown`.
        // Test the X3 fallback with a raw this binary genuinely doesn't
        // recognize (a hypothetical future agent kind).
        let json = Data("\"future-runtime-v25\"".utf8)
        let decoded = try JSONDecoder().decode(AgentKind.self, from: json)
        XCTAssertEqual(decoded, .unknown,
            "X3: unknown raw must decode as .unknown, not silently as .claude")
    }

    func test_arbitraryFutureRawDecodesAsUnknown() throws {
        let json = Data("\"some-future-runtime-v17\"".utf8)
        let decoded = try JSONDecoder().decode(AgentKind.self, from: json)
        XCTAssertEqual(decoded, .unknown)
    }

    func test_knownRawsStillDecodeCorrectly() throws {
        // Regression: X3's lenient decoder must NOT break the happy
        // path. PR #29 adds `.opencode` as the 4th known raw.
        let cases: [(String, AgentKind)] = [
            ("\"claude\"", .claude),
            ("\"codex\"", .codex),
            ("\"gemini\"", .gemini),
            ("\"opencode\"", .opencode),
        ]
        for (raw, expected) in cases {
            let decoded = try JSONDecoder().decode(AgentKind.self, from: Data(raw.utf8))
            XCTAssertEqual(decoded, expected, "raw \(raw) must decode as \(expected)")
        }
    }

    func test_unknownRoundTripsThroughCodable() throws {
        let original: AgentKind = .unknown
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentKind.self, from: encoded)
        XCTAssertEqual(decoded, .unknown)
    }

    // MARK: - allCases hygiene

    func test_allCasesExcludesUnknown() {
        // X3 contract: pickers + segmented controls never offer .unknown
        // as a selectable choice. AgentKind.allCases overrides the
        // auto-synthesized CaseIterable conformance to strip it.
        // PR #29 (wire v13): OpenCode became selectable. v17 adds
        // Cursor as another selectable runtime; v26 adds Grok (ACP);
        // .unknown stays excluded.
        XCTAssertFalse(AgentKind.allCases.contains(.unknown),
            "X3: AgentKind.allCases must exclude .unknown so pickers stay clean")
        XCTAssertEqual(AgentKind.allCases.count, 6)
        XCTAssertTrue(AgentKind.allCases.contains(.claude))
        XCTAssertTrue(AgentKind.allCases.contains(.codex))
        XCTAssertTrue(AgentKind.allCases.contains(.gemini))
        XCTAssertTrue(AgentKind.allCases.contains(.opencode))
        XCTAssertTrue(AgentKind.allCases.contains(.cursor))
        XCTAssertTrue(AgentKind.allCases.contains(.grok))
    }

    // MARK: - AgentKindUI fallback rendering

    func test_agentKindUI_displayName_unknown() {
        XCTAssertEqual(AgentKindUI.displayName(for: AgentKind.unknown), "Other agent",
            "X3: unknown agent renders as 'Other agent' in displayName")
    }

    func test_agentKindUI_assetName_unknown() {
        // ClaudeLogo is the safe neutral fallback (any logo that exists
        // works; "Other agent" label disambiguates visually).
        XCTAssertEqual(AgentKindUI.assetName(for: AgentKind.unknown), "ClaudeLogo")
    }

    func test_agentKindUI_isTemplate_unknown() {
        // Template-rendered so it picks up the neutral gray accent.
        XCTAssertTrue(AgentKindUI.isTemplate(for: AgentKind.unknown))
    }

    func test_agentKindUI_accentRGB_unknown_isNeutralGray() {
        let rgb = AgentKindUI.accentRGB(for: AgentKind.unknown)
        XCTAssertEqual(rgb.r, 0x88)
        XCTAssertEqual(rgb.g, 0x88)
        XCTAssertEqual(rgb.b, 0x88)
    }

    // MARK: - Cross-version pairing regression

    func test_v12Client_decodingV14FutureKindPayload_landsOnUnknown() throws {
        // The whole motivation for X3: cross-version forward-compat.
        // PR #29 made `.opencode` a real case (v13). This test now
        // covers the same regression with a hypothetical *future*
        // kind that this binary doesn't recognize — proving the X3
        // pattern holds for the next provider added after OpenCode.
        let sessionJSON = """
        {
            "id": "\(UUID().uuidString)",
            "repoKey": "/Users/test/repo",
            "repoDisplayName": "Test",
            "agent": "future-runtime-v14",
            "status": "running",
            "createdAt": 0,
            "lastEventAt": 0,
            "lastEventSeq": 1
        }
        """
        let data = Data(sessionJSON.utf8)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.agent, .unknown,
            "X3 cross-version regression: future raws must NOT mislabel as claude")
        XCTAssertNotEqual(decoded.agent, .claude,
            "X3: future raws must NOT decode as .claude (the bug X3 fixes)")
    }

    func test_v13Client_decodesOpencodePayloadNatively() throws {
        // Regression for PR #29: a current v13 client reads its own
        // wire correctly. opencode → .opencode (not .unknown).
        let sessionJSON = """
        {
            "id": "\(UUID().uuidString)",
            "repoKey": "/Users/test/repo",
            "repoDisplayName": "Test",
            "agent": "opencode",
            "status": "running",
            "createdAt": 0,
            "lastEventAt": 0,
            "lastEventSeq": 1
        }
        """
        let data = Data(sessionJSON.utf8)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.agent, .opencode,
            "PR #29: opencode payload must decode as .opencode on v13 clients")
    }
}
