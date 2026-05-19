import XCTest
@testable import ClawdmeterShared

/// E3 #1 / X1 contract test for `UsageEnvelope` dual-shape:
///
///   - Server v6 emits BOTH the legacy `{claude, codex}` top-level fields
///     AND the new `usage: [String: UsageData]` dict.
///   - Client v6 prefers `usage[id]` per provider, falls back to the
///     legacy `<id>` field PER PROVIDER (X1 fix) — not envelope-wide.
///   - Client v5 ignores the unknown `usage` field and reads the legacy
///     fields.
///
/// The "per-provider" part is critical. If the fallback were envelope-
/// wide (use legacy ONLY when the dict is entirely absent), a v7+ server
/// emitting `{usage: {gemini: …}}` without `claude` / `codex` legacy
/// fields would correctly surface Gemini to a v6 client. But a v6 server
/// emitting `{usage: {gemini: …}, claude: ..., codex: ...}` would have
/// the v6 client miss Claude + Codex because the dict-not-empty check
/// short-circuited the legacy path. Per-provider fallback fixes this.
final class WireEnvelopeDualShapeTests: XCTestCase {

    private func usage(sessionPct: Int) -> UsageData {
        UsageData(
            sessionPct: sessionPct,
            sessionResetMins: 60,
            sessionEpoch: 1715000000,
            weeklyPct: 0,
            weeklyResetMins: 0,
            weeklyEpoch: 0,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1715000000),
            organizationID: nil
        )
    }

    /// v6 server emits dual-shape: legacy {claude, codex} + dict {gemini}.
    /// A v6 client must read all three correctly.
    func test_v6Reader_dualShape_picksUpAllThreeProviders() throws {
        let envelope = UsageEnvelope(
            claude: usage(sessionPct: 11),
            codex:  usage(sessionPct: 22),
            usage:  ["gemini": usage(sessionPct: 33)],
            lastChecked: Date(timeIntervalSince1970: 1715000100)
        )
        XCTAssertEqual(envelope.usageData(for: "claude")?.sessionPct, 11, "Claude must come through legacy field")
        XCTAssertEqual(envelope.usageData(for: "codex")?.sessionPct,  22, "Codex must come through legacy field")
        XCTAssertEqual(envelope.usageData(for: "gemini")?.sessionPct, 33, "Gemini must come through new dict")
    }

    /// v7-style server (legacy fields stripped) emits all 3 providers in
    /// the dict. v6 client should still read everything.
    func test_v6Reader_dictOnly_picksUpEverything() throws {
        let envelope = UsageEnvelope(
            claude: nil,
            codex:  nil,
            usage:  [
                "claude": usage(sessionPct: 11),
                "codex":  usage(sessionPct: 22),
                "gemini": usage(sessionPct: 33)
            ],
            lastChecked: Date(timeIntervalSince1970: 1715000100)
        )
        XCTAssertEqual(envelope.usageData(for: "claude")?.sessionPct, 11)
        XCTAssertEqual(envelope.usageData(for: "codex")?.sessionPct,  22)
        XCTAssertEqual(envelope.usageData(for: "gemini")?.sessionPct, 33)
    }

    /// Dict takes priority when both shapes carry the same provider.
    func test_dictOverridesLegacyField_perProvider() throws {
        // Legacy says 10%; dict says 99%. Dict wins.
        let envelope = UsageEnvelope(
            claude: usage(sessionPct: 10),
            codex: nil,
            usage:  ["claude": usage(sessionPct: 99)],
            lastChecked: Date()
        )
        XCTAssertEqual(envelope.usageData(for: "claude")?.sessionPct, 99,
                       "v6 client must prefer the dict value over the legacy field")
    }

    /// Legacy field carries the provider when the dict is missing the key.
    /// Critical X1 case: v6 server emits `{usage: {gemini: …}}` while
    /// Claude/Codex are in legacy. Without per-provider fallback, both
    /// legacy providers would be lost.
    func test_perProviderFallback_dictMissingEntry_usesLegacy() throws {
        let envelope = UsageEnvelope(
            claude: usage(sessionPct: 11),
            codex:  usage(sessionPct: 22),
            usage:  ["gemini": usage(sessionPct: 33)],
            lastChecked: Date()
        )
        XCTAssertNotNil(envelope.usageData(for: "claude"), "Per-provider fallback must surface Claude via legacy field")
        XCTAssertEqual(envelope.usageData(for: "claude")?.sessionPct, 11)
        XCTAssertNotNil(envelope.usageData(for: "codex"))
        XCTAssertEqual(envelope.usageData(for: "codex")?.sessionPct, 22)
    }

    /// Unknown providers (a future v8 server emitting `mistral`) return
    /// nil cleanly. No crash, no fallback to a wrong provider.
    func test_unknownProviderId_returnsNil() throws {
        let envelope = UsageEnvelope(
            claude: usage(sessionPct: 11),
            codex:  usage(sessionPct: 22),
            usage:  nil,
            lastChecked: Date()
        )
        XCTAssertNil(envelope.usageData(for: "mistral"))
        XCTAssertNil(envelope.usageData(for: "gemini"), "Dict absent + no legacy gemini key → nil")
    }

    /// JSON round-trip: a v6 server-emitted envelope decodes both shapes.
    func test_jsonRoundTrip_emitsBothShapes() throws {
        let original = UsageEnvelope(
            claude: usage(sessionPct: 11),
            codex:  usage(sessionPct: 22),
            usage:  ["gemini": usage(sessionPct: 33)],
            lastChecked: Date(timeIntervalSince1970: 1715000100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"claude\""), "Legacy claude field must be present in encoded shape")
        XCTAssertTrue(json.contains("\"codex\""),  "Legacy codex field must be present in encoded shape")
        XCTAssertTrue(json.contains("\"usage\""),  "New usage dict must be present in encoded shape")
        XCTAssertTrue(json.contains("\"gemini\""), "Gemini key must be inside the usage dict")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(UsageEnvelope.self, from: data)
        XCTAssertEqual(round.usageData(for: "claude")?.sessionPct, 11)
        XCTAssertEqual(round.usageData(for: "codex")?.sessionPct,  22)
        XCTAssertEqual(round.usageData(for: "gemini")?.sessionPct, 33)
    }

    /// v5 client compat — v5 decoders pre-dated `usage` dict. The
    /// envelope's decoder accepts unknown fields tolerantly because the
    /// dict path uses `decodeIfPresent`. Round-trip: encode without dict,
    /// decode still works.
    func test_legacyOnlyShape_decodesCleanly() throws {
        let legacy = UsageEnvelope(
            claude: usage(sessionPct: 11),
            codex:  usage(sessionPct: 22),
            usage:  nil,
            lastChecked: Date(timeIntervalSince1970: 1715000100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(UsageEnvelope.self, from: data)
        XCTAssertEqual(round.usageData(for: "claude")?.sessionPct, 11)
        XCTAssertEqual(round.usageData(for: "codex")?.sessionPct,  22)
        XCTAssertNil(round.usageData(for: "gemini"))
    }
}
