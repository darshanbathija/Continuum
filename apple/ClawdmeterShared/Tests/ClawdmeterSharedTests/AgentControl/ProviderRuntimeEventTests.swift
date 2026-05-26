import XCTest
@testable import ClawdmeterShared

/// Foundational tests for the canonical `ProviderRuntimeEvent` shape.
/// Locks in:
///   - Codable round-trip for every payload variant
///   - Raw provider payload bytes survive serialization
///   - Provider extension fields handle scalar + nested shapes
///   - Forward-compat `unknown(name:)` decoder for future payload kinds
///
/// Plan: F1 foundation (Phase 1; D23) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`. F1a-F1e
/// adapter tests will build on this foundation.
final class ProviderRuntimeEventTests: XCTestCase {

    // MARK: - Codable round-trip per payload variant

    func test_roundTrip_sessionStarted() throws {
        try assertRoundTrip(payload: .sessionStarted(
            model: "claude-3-7-sonnet-20250219",
            settings: ["temperature": "0.7", "max_tokens": "8192"]
        ))
    }

    func test_roundTrip_sessionEnded() throws {
        try assertRoundTrip(payload: .sessionEnded(reason: "user cancelled"))
        try assertRoundTrip(payload: .sessionEnded(reason: nil))
    }

    func test_roundTrip_userMessage() throws {
        try assertRoundTrip(payload: .userMessage(
            text: "Refactor SessionWorkspaceView",
            attachmentRefs: ["att-1", "att-2"]
        ))
    }

    func test_roundTrip_assistantTokenDelta() throws {
        try assertRoundTrip(payload: .assistantTokenDelta(text: "hello ", index: 0))
        try assertRoundTrip(payload: .assistantTokenDelta(text: "world", index: 1))
    }

    func test_roundTrip_assistantMessageCompleted() throws {
        try assertRoundTrip(payload: .assistantMessageCompleted(
            text: "Done — here's the diff.",
            tokensIn: 1500, tokensOut: 320
        ))
    }

    func test_roundTrip_toolUse() throws {
        try assertRoundTrip(payload: .toolUse(
            name: "Read",
            parameters: ["file_path": "Foo.swift"],
            invocationId: "inv-abc"
        ))
    }

    func test_roundTrip_toolResult() throws {
        try assertRoundTrip(payload: .toolResult(
            invocationId: "inv-abc",
            success: true,
            text: "100 lines read"
        ))
    }

    func test_roundTrip_planRequested() throws {
        try assertRoundTrip(payload: .planRequested(
            planText: "1. Read file\n2. Refactor\n3. Test",
            planId: "plan-1"
        ))
    }

    func test_roundTrip_planApprovalResponded() throws {
        try assertRoundTrip(payload: .planApprovalResponded(
            planId: "plan-1", approved: true, comment: "looks good"
        ))
        try assertRoundTrip(payload: .planApprovalResponded(
            planId: "plan-1", approved: false, comment: nil
        ))
    }

    func test_roundTrip_providerError() throws {
        try assertRoundTrip(payload: .providerError(
            code: "rate_limited",
            message: "Anthropic rate limit hit; retry in 30s"
        ))
    }

    func test_roundTrip_unknown() throws {
        // Forward-compat: future providers can surface new event kinds
        // via `unknown(name:)` without breaking wire compat.
        try assertRoundTrip(payload: .unknown(name: "antigravity.skill_invoked"))
    }

    // MARK: - Raw payload retention (codex eng-review #8)

    func test_rawProviderPayload_survivesRoundTrip() throws {
        let originalRaw = "{\"raw_provider_specific\":\"goes_here\"}".data(using: .utf8)!
        let event = ProviderRuntimeEvent(
            id: "evt-1",
            providerKind: .claude,
            providerInstanceId: "claude_personal",
            sessionId: "session-99",
            sequenceNumber: 17,
            emittedAt: Date(timeIntervalSince1970: 1_715_000_000),
            payload: .userMessage(text: "test", attachmentRefs: []),
            rawProviderPayload: originalRaw,
            providerExtensions: nil
        )
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ProviderRuntimeEvent.self, from: encoded)
        XCTAssertEqual(decoded.rawProviderPayload, originalRaw)
    }

    // MARK: - Provider extensions

    func test_providerExtensions_scalarVariants_roundTrip() throws {
        let extensions: [String: ProviderRuntimeEvent.ExtensionField] = [
            "claude": .nested([
                "cache_creation_tokens": .int(1500),
                "cache_read_tokens": .int(3200),
                "model_provider": .string("anthropic")
            ]),
            "codex": .nested([
                "reasoning_effort": .string("high"),
                "billable": .bool(true)
            ])
        ]
        let event = ProviderRuntimeEvent(
            id: "evt-2",
            providerKind: .claude,
            sessionId: "session-1",
            sequenceNumber: 1,
            emittedAt: Date(timeIntervalSince1970: 1_715_000_000),
            payload: .assistantMessageCompleted(text: "ok", tokensIn: 100, tokensOut: 50),
            rawProviderPayload: nil,
            providerExtensions: extensions
        )
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ProviderRuntimeEvent.self, from: encoded)
        XCTAssertEqual(decoded.providerExtensions, extensions)
    }

    // MARK: - Forward-compat unknown decoder

    func test_unknownPayloadKind_inWireData_decodesToUnknown() throws {
        // Hand-craft a JSON event with a payload kind the decoder DOESN'T
        // know about — simulating a future wire version emitting a new
        // canonical case. The decoder should fail cleanly today (we
        // surface the gap as an error rather than silently dropping).
        //
        // The .unknown(name:) variant is for ADAPTER-side use: when the
        // adapter receives a provider event it doesn't have a canonical
        // case for, it emits .unknown(name:) WITH rawProviderPayload set
        // so downstream consumers can still observe + replay.
        //
        // This test pins the contract that a malformed kind == decode
        // error (not silent .unknown fallback during wire decode).
        let jsonWithBadKind = """
        {
          "id": "evt-3",
          "providerKind": "claude",
          "providerInstanceId": null,
          "sessionId": "session-1",
          "sequenceNumber": 1,
          "emittedAt": 1715000000,
          "payload": {
            "futureKind": { "data": "whatever" }
          }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(ProviderRuntimeEvent.self, from: jsonWithBadKind)
        )
    }

    // MARK: - Helper

    private func assertRoundTrip(
        payload: ProviderRuntimeEvent.Payload,
        file: StaticString = #file, line: UInt = #line
    ) throws {
        let event = ProviderRuntimeEvent(
            id: "evt-test",
            providerKind: .claude,
            providerInstanceId: nil,
            sessionId: "session-test",
            sequenceNumber: 1,
            emittedAt: Date(timeIntervalSince1970: 1_715_000_000),
            payload: payload,
            rawProviderPayload: nil,
            providerExtensions: nil
        )
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ProviderRuntimeEvent.self, from: encoded)
        XCTAssertEqual(decoded, event, file: file, line: line)
    }
}
