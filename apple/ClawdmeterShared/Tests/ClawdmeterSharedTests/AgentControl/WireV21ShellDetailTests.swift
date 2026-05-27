import XCTest
@testable import ClawdmeterShared

/// A10 (2026-05-27) — wireVersion 21 shell/detail split tests.
///
/// Verifies:
///   - `AgentControlWireVersion.current` is at least 21 (the bump for A10).
///   - `shellDetailMinimum = 21` and `supportsShellDetail` capability gate
///     returns the right answer at v20 / v21 / nil.
///   - Round-trip: a `ChatShellEvent`, a `ChatDetailEvent`, and a
///     `ChatStreamFrame` envelope all encode/decode through Codable
///     preserving every field.
///   - Back-compat: a v20 client that decodes a v21 server's split
///     payload (one shell + one detail wrapped in `ChatStreamFrame`)
///     can still read it via `WireChatSnapshot.combine(...)`. Conversely,
///     a v21 client decoding a legacy v20 raw `WireChatSnapshot` keeps
///     working.
///   - Performance gate: on the A0 baseline messages10k fixture (100
///     messages, realistic text length), the per-event v21 streaming
///     payload (shell only) is ≥80% smaller than the legacy v20
///     `WireChatSnapshot` payload. This is the user-observed payload
///     during a token burst — the activity strip can render off the
///     shell without waiting for the heavy detail.
///
/// Plan reference: A10 in `.claude/plans/study-this-codebase-crystalline-shore.md`.
final class WireV21ShellDetailTests: XCTestCase {

    // MARK: - Wire version + capability gate

    func test_currentWireVersionIsAtLeast21() {
        XCTAssertGreaterThanOrEqual(AgentControlWireVersion.current, 21)
    }

    func test_shellDetailMinimumIs21() {
        XCTAssertEqual(AgentControlWireVersion.shellDetailMinimum, 21)
    }

    func test_supportsShellDetail_falseBelow21() {
        XCTAssertFalse(AgentControlWireVersion.supportsShellDetail(serverWireVersion: 20))
        XCTAssertFalse(AgentControlWireVersion.supportsShellDetail(serverWireVersion: 19))
        XCTAssertFalse(AgentControlWireVersion.supportsShellDetail(serverWireVersion: 5))
        XCTAssertFalse(AgentControlWireVersion.supportsShellDetail(serverWireVersion: nil))
    }

    func test_supportsShellDetail_trueAt21AndAbove() {
        XCTAssertTrue(AgentControlWireVersion.supportsShellDetail(serverWireVersion: 21))
        XCTAssertTrue(AgentControlWireVersion.supportsShellDetail(serverWireVersion: 22))
        XCTAssertTrue(AgentControlWireVersion.supportsShellDetail(serverWireVersion: 100))
    }

    func test_priorMinimumsUnchanged() {
        // v20 floor — every prior gate stays at its documented value so
        // older feature detection still works.
        XCTAssertEqual(AgentControlWireVersion.composeDraftMinimum, 4)
        XCTAssertEqual(AgentControlWireVersion.chatSubscribeMinimum, 5)
        XCTAssertEqual(AgentControlWireVersion.geminiMinimum, 6)
        XCTAssertEqual(AgentControlWireVersion.antigravityMinimum, 7)
        XCTAssertEqual(AgentControlWireVersion.codexSDKMinimum, 8)
        XCTAssertEqual(AgentControlWireVersion.chatMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.frontierMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.codexChatBackendMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.agentapiMinimum, 10)
        XCTAssertEqual(AgentControlWireVersion.antigravityChatMinimum, 11)
        XCTAssertEqual(AgentControlWireVersion.turnLifecycleMinimum, 14)
        XCTAssertEqual(AgentControlWireVersion.deepResearchMinimum, 14)
        XCTAssertEqual(AgentControlWireVersion.chatSearchMinimum, 14)
        XCTAssertEqual(AgentControlWireVersion.codeV2Minimum, 15)
        XCTAssertEqual(AgentControlWireVersion.workspacesMinimum, 16)
        XCTAssertEqual(AgentControlWireVersion.mobileOutboxMinimum, 16)
        XCTAssertEqual(AgentControlWireVersion.cursorMinimum, 17)
        XCTAssertEqual(AgentControlWireVersion.codeWorkbenchRemoteMinimum, 18)
        XCTAssertEqual(AgentControlWireVersion.lifecycleMinimum, 19)
        XCTAssertEqual(AgentControlWireVersion.providerDefaultsMinimum, 19)
        XCTAssertEqual(AgentControlWireVersion.providerInstanceMinimum, 20)
    }

    // MARK: - Round-trip Codable

    func test_chatShellEvent_roundTrip_preservesEveryField() throws {
        let sessionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let emittedAt = Date(timeIntervalSince1970: 1_716_768_000)
        let shell = ChatShellEvent(
            sessionId: sessionId,
            sequenceNumber: 42,
            kind: .assistant,
            emittedAt: emittedAt,
            tokensIn: 1_234,
            tokensOut: 5_678,
            turnState: .streaming
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(shell)
        let decoded = try decoder.decode(ChatShellEvent.self, from: data)

        XCTAssertEqual(decoded.sessionId, shell.sessionId)
        XCTAssertEqual(decoded.sequenceNumber, shell.sequenceNumber)
        XCTAssertEqual(decoded.kind, shell.kind)
        XCTAssertEqual(decoded.emittedAt, shell.emittedAt)
        XCTAssertEqual(decoded.tokensIn, shell.tokensIn)
        XCTAssertEqual(decoded.tokensOut, shell.tokensOut)
        XCTAssertEqual(decoded.turnState, shell.turnState)
        XCTAssertEqual(decoded, shell)
    }

    func test_chatShellEvent_decoder_lenientOnUnknownKind() throws {
        // A future wireVersion adds a new Kind raw — older clients
        // must NOT crash; they fold the unknown raw into `.system`.
        let json = """
        {
          "sessionId": "00000000-0000-0000-0000-0000000000A1",
          "sequenceNumber": 1,
          "kind": "futurePerception",
          "emittedAt": "2026-05-27T00:00:00Z",
          "turnState": "streaming"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatShellEvent.self, from: json)
        XCTAssertEqual(decoded.kind, .system, "Unknown raw must fold to .system")
    }

    func test_chatDetailEvent_roundTrip_preservesEveryField() throws {
        let sessionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        let items: [ChatItem] = [
            .message(ChatMessage(
                id: "msg-1",
                kind: .userText,
                title: "You",
                body: "Run the tests",
                at: Date(timeIntervalSince1970: 1_716_768_000)
            )),
            .message(ChatMessage(
                id: "msg-2",
                kind: .assistantText,
                title: "Claude",
                body: "Sure — running them now.",
                at: Date(timeIntervalSince1970: 1_716_768_010)
            ))
        ]
        let planSteps = [
            PlanStep(id: "ps-1", text: "Read the source", isComplete: true),
            PlanStep(id: "ps-2", text: "Run the tests", isComplete: false),
        ]
        let prompt = PendingPermissionPrompt(
            id: "p-1",
            title: "Trust this directory?",
            detail: "/Users/x/repo",
            header: "Codex trust",
            options: [
                PermissionOption(id: "yes", label: "Trust"),
                PermissionOption(id: "no",  label: "Don't trust", isDestructive: true),
            ],
            surfacedAt: Date(timeIntervalSince1970: 1_716_768_500)
        )
        let detail = ChatDetailEvent(
            sessionId: sessionId,
            sequenceNumber: 100,
            items: items,
            planSteps: planSteps,
            sourceEntries: [],
            artifactEntries: [],
            codexTodos: [],
            pendingPermissionPrompt: prompt,
            totalInputTokens: 2_000,
            totalOutputTokens: 8_000,
            cacheReadTokens: 0,
            cacheCreationTokens: 0
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(detail)
        let decoded = try decoder.decode(ChatDetailEvent.self, from: data)

        XCTAssertEqual(decoded.sessionId, detail.sessionId)
        XCTAssertEqual(decoded.sequenceNumber, detail.sequenceNumber)
        XCTAssertEqual(decoded.items.count, 2)
        XCTAssertEqual(decoded.planSteps.count, 2)
        XCTAssertEqual(decoded.pendingPermissionPrompt?.id, "p-1")
        XCTAssertEqual(decoded.totalInputTokens, 2_000)
        XCTAssertEqual(decoded.totalOutputTokens, 8_000)
        XCTAssertEqual(decoded, detail)
    }

    func test_chatStreamFrame_roundTrip_acrossEveryCase() throws {
        let sessionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
        let snapshot = makeSnapshot(sessionId: sessionId, messageCount: 4, sequenceNumber: 5)
        let shellFrame = ChatStreamFrame.shell(snapshot.shellEvent())
        let detailFrame = ChatStreamFrame.detail(snapshot.detailEvent())
        let snapshotFrame = ChatStreamFrame.snapshot(snapshot)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for frame in [shellFrame, detailFrame, snapshotFrame] {
            let data = try encoder.encode(frame)
            let decoded = try decoder.decode(ChatStreamFrame.self, from: data)
            // Verify the kind discriminator survives.
            XCTAssertEqual(decoded.typeTag, frame.typeTag)
            // And the inner payload's identifying fields stay consistent.
            switch (frame, decoded) {
            case (.shell(let a), .shell(let b)):
                XCTAssertEqual(a, b)
            case (.detail(let a), .detail(let b)):
                XCTAssertEqual(a, b)
            case (.snapshot(let a), .snapshot(let b)):
                XCTAssertEqual(a.sessionId, b.sessionId)
                XCTAssertEqual(a.updateCounter, b.updateCounter)
                XCTAssertEqual(a.items.count, b.items.count)
            default:
                XCTFail("Frame type mismatch after round-trip")
            }
        }
    }

    func test_chatStreamFrame_decoder_rejectsUnknownType() throws {
        let json = """
        { "type": "nonsense", "shell": {} }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ChatStreamFrame.self, from: json))
    }

    // MARK: - Shell/detail combine

    func test_snapshot_combine_reconstructsOriginalSnapshot() {
        let sessionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
        let snapshot = makeSnapshot(sessionId: sessionId, messageCount: 6, sequenceNumber: 99)
        let combined = WireChatSnapshot.combine(
            shell: snapshot.shellEvent(),
            detail: snapshot.detailEvent()
        )
        XCTAssertEqual(combined.sessionId, snapshot.sessionId)
        XCTAssertEqual(combined.items.count, snapshot.items.count)
        XCTAssertEqual(combined.planSteps, snapshot.planSteps)
        XCTAssertEqual(combined.sourceEntries, snapshot.sourceEntries)
        XCTAssertEqual(combined.artifactEntries, snapshot.artifactEntries)
        XCTAssertEqual(combined.updateCounter, snapshot.updateCounter)
        XCTAssertEqual(combined.currentTurnState, snapshot.currentTurnState)
        XCTAssertEqual(combined.totalInputTokens, snapshot.totalInputTokens)
        XCTAssertEqual(combined.totalOutputTokens, snapshot.totalOutputTokens)
    }

    func test_shellEvent_kindDerivation_isStable() {
        let user = ChatMessage(
            id: "u", kind: .userText, title: "You", body: "hi",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let assistant = ChatMessage(
            id: "a", kind: .assistantText, title: "Claude", body: "hi back",
            at: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let toolCall = ChatMessage(
            id: "t", kind: .toolCall, title: "Bash", body: "ls",
            at: Date(timeIntervalSince1970: 1_700_000_020)
        )
        let meta = ChatMessage(
            id: "m", kind: .meta, title: "system", body: "summary",
            at: Date(timeIntervalSince1970: 1_700_000_030)
        )

        XCTAssertEqual(ChatShellEvent.kind(from: []), .empty)
        XCTAssertEqual(ChatShellEvent.kind(from: [.message(user)]), .user)
        XCTAssertEqual(ChatShellEvent.kind(from: [.message(assistant)]), .assistant)
        XCTAssertEqual(ChatShellEvent.kind(from: [.message(toolCall)]), .tool)
        XCTAssertEqual(ChatShellEvent.kind(from: [.message(meta)]), .system)
        // toolRun group → .tool
        XCTAssertEqual(ChatShellEvent.kind(from: [
            .toolRun(id: "r1", pairs: [])
        ]), .tool)
        // Last item determines kind.
        XCTAssertEqual(
            ChatShellEvent.kind(from: [.message(user), .message(assistant)]),
            .assistant
        )
    }

    // MARK: - Back-compat

    func test_v21ServerPayload_legacyClientCanIgnoreEnvelope() throws {
        // A v20 client that hasn't been updated still reads the legacy
        // raw `WireChatSnapshot` shape (no envelope). The v21 server's
        // dispatch branch sends the legacy shape to v20 clients — proven
        // by `supportsShellDetail(serverWireVersion: 20) == false`. This
        // test asserts a v20 client decoder REFUSES the v21 envelope (it
        // doesn't accidentally accept a shell envelope as a snapshot —
        // which would crash on missing required fields).
        let sessionId = UUID()
        let snapshot = makeSnapshot(sessionId: sessionId, messageCount: 3, sequenceNumber: 7)
        let envelope = ChatStreamFrame.shell(snapshot.shellEvent())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let envelopeData = try encoder.encode(envelope)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A v20 client tries to decode the envelope as a raw
        // WireChatSnapshot — it MUST fail (missing items, planSteps,
        // sourceEntries, etc.). The server is responsible for never
        // sending this shape to a v20 client; the test is defense in
        // depth against a misconfigured server.
        XCTAssertThrowsError(try decoder.decode(WireChatSnapshot.self, from: envelopeData))
    }

    func test_v20ServerPayload_v21ClientFallsBackToLegacyDecode() throws {
        // The flipside: a v21 client receiving a legacy v20 frame must
        // still decode it via the bare `WireChatSnapshot` shape (no
        // envelope). The iOS store's `applyIncomingFrame` tries the
        // envelope first; this asserts the fallback works.
        let sessionId = UUID()
        let snapshot = makeSnapshot(sessionId: sessionId, messageCount: 3, sequenceNumber: 11)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bareData = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // First attempt — envelope decode fails (raw snapshot has no
        // `type` field).
        XCTAssertThrowsError(try decoder.decode(ChatStreamFrame.self, from: bareData))
        // Fallback — bare snapshot decode succeeds.
        let decodedSnapshot = try decoder.decode(WireChatSnapshot.self, from: bareData)
        XCTAssertEqual(decodedSnapshot.sessionId, sessionId)
        XCTAssertEqual(decodedSnapshot.updateCounter, 11)
        XCTAssertEqual(decodedSnapshot.items.count, 3)
    }

    // MARK: - Performance gate — ≥80% payload reduction

    /// Acceptance criterion #5 of A10: on a realistic streaming-burst
    /// fixture, the per-event v21 payload (shell only) must be at least
    /// 80% smaller than the legacy v20 payload (full WireChatSnapshot).
    ///
    /// This measures the per-EVENT wire size, which is what the user
    /// observes during a token burst — the activity strip / sidebar
    /// paints from the shell on each commit while the heavy detail is
    /// still in flight. The detail is sent too (so the total bytes for
    /// a full sync are roughly equal), but the *visible* lag is bounded
    /// by the shell's size.
    func test_streamingBurst_shellPayloadIs80PercentSmallerThanLegacy() throws {
        let sessionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000F0")!
        // 100 messages mirroring the A0 baseline fixture pattern — a
        // realistic agent burst (mix of user / assistant prose / tool
        // calls). The plan calls for "100 messages with realistic text
        // length"; we use the deterministic PerfFixtures generator's
        // own shape so the fixture is reproducible across CI runs.
        let snapshot = makeBurstSnapshot(
            sessionId: sessionId,
            messageCount: 100,
            sequenceNumber: 100
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let legacyBytes = try encoder.encode(snapshot).count
        let shellBytes = try encoder.encode(ChatStreamFrame.shell(snapshot.shellEvent())).count
        let detailBytes = try encoder.encode(ChatStreamFrame.detail(snapshot.detailEvent())).count

        // The acceptance criterion measures per-EVENT payload size.
        // The shell is what the activity-strip render reads off the
        // wire before the detail lands — that's the user-observed
        // payload during a token burst.
        let reductionPct = 1.0 - (Double(shellBytes) / Double(legacyBytes))
        XCTAssertGreaterThanOrEqual(
            reductionPct, 0.80,
            "Shell payload must be ≥80% smaller than legacy snapshot. " +
            "Got shell=\(shellBytes) bytes vs legacy=\(legacyBytes) bytes " +
            "(reduction=\(Int(reductionPct * 100))%). Detail=\(detailBytes) bytes."
        )
        // Sanity: a shell event is bounded by a small constant (header
        // + counters), so its absolute size should fit in a few hundred
        // bytes even on a long session.
        XCTAssertLessThan(shellBytes, 400, "Shell event should be under ~400 bytes; got \(shellBytes)")
    }

    /// Companion measurement test that prints the per-frame sizes so
    /// the PR description can cite them. Doesn't assert — just logs.
    func test_streamingBurst_payloadSizes_loggedForPR() throws {
        let sessionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
        let snapshot = makeBurstSnapshot(
            sessionId: sessionId,
            messageCount: 100,
            sequenceNumber: 100
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let legacyBytes = try encoder.encode(snapshot).count
        let shellBytes = try encoder.encode(ChatStreamFrame.shell(snapshot.shellEvent())).count
        let detailBytes = try encoder.encode(ChatStreamFrame.detail(snapshot.detailEvent())).count
        let v21TotalBytes = shellBytes + detailBytes
        let shellReductionPct = Int((1.0 - Double(shellBytes) / Double(legacyBytes)) * 100)
        let totalReductionPct = Int((1.0 - Double(v21TotalBytes) / Double(legacyBytes)) * 100)

        print(
            "A10 payload sizes (100-message burst): " +
            "legacy=\(legacyBytes)B, shell=\(shellBytes)B, detail=\(detailBytes)B, " +
            "v21 total=\(v21TotalBytes)B. " +
            "Shell-only reduction=\(shellReductionPct)%, total reduction=\(totalReductionPct)%."
        )
    }

    // MARK: - Fixture helpers

    private func makeSnapshot(
        sessionId: UUID,
        messageCount: Int,
        sequenceNumber: UInt64
    ) -> WireChatSnapshot {
        var items: [ChatItem] = []
        items.reserveCapacity(messageCount)
        let baseTime = Date(timeIntervalSince1970: 1_716_768_000)
        for i in 0..<messageCount {
            let kind: ChatMessage.Kind = (i % 2 == 0) ? .userText : .assistantText
            items.append(.message(ChatMessage(
                id: "msg-\(i)",
                kind: kind,
                title: kind == .userText ? "You" : "Claude",
                body: "Message \(i) body text — keep this realistic length.",
                at: baseTime.addingTimeInterval(Double(i) * 2)
            )))
        }
        return WireChatSnapshot(
            sessionId: sessionId,
            items: items,
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 1_000,
            totalOutputTokens: 2_000,
            lastEventAt: baseTime.addingTimeInterval(Double(messageCount) * 2),
            updateCounter: sequenceNumber,
            currentTurnState: .streaming
        )
    }

    /// Build a realistic 100-message burst snapshot. Mirrors the
    /// distribution in `PerfFixtures.messages10k` — 30% user, 50%
    /// assistant, 15% tool calls, 4% tool results, 1% errors — with
    /// per-message body length 50–2000 chars (realistic).
    private func makeBurstSnapshot(
        sessionId: UUID,
        messageCount: Int,
        sequenceNumber: UInt64
    ) -> WireChatSnapshot {
        // Deterministic — use the seeded PRNG already in PerfTesting so
        // CI runs are bit-stable.
        var prng = SeededPRNG(seed: 0xA1_0_5E55_4043)
        var items: [ChatItem] = []
        items.reserveCapacity(messageCount)
        let baseTime = Date(timeIntervalSince1970: 1_716_768_000)
        let userSnippets = [
            "Can you also add a test for the empty case?",
            "What happens if the input is nil here?",
            "Refactor this to use the existing utility.",
            "Open a PR with these changes.",
            "Run the linter and fix anything it flags.",
            "Why does this fail on cold start?",
        ]
        let assistantSnippets = [
            "I'll start by reading the relevant files to understand the structure.",
            "Here's the diff for the change you requested.",
            "Running the test suite to confirm nothing regressed.",
            "Found three places where this pattern repeats — proposing one shared helper.",
            "Need to double-check the auth boundary before I touch this.",
            "Committing the WIP and re-running the build.",
        ]
        for i in 0..<messageCount {
            let r = prng.nextDouble()
            let kind: ChatMessage.Kind
            let snippet: String
            switch r {
            case 0..<0.30:
                kind = .userText
                snippet = prng.pick(userSnippets) ?? "Question?"
            case 0.30..<0.80:
                kind = .assistantText
                snippet = prng.pick(assistantSnippets) ?? "Working on it."
            case 0.80..<0.95:
                kind = .toolCall
                snippet = "tool_use: Read(file: \"apple/ClawdmeterMac/source-\(prng.nextInt(upperBound: 200)).swift\")"
            case 0.95..<0.99:
                kind = .toolResult
                snippet = "tool_result: ok (\(prng.nextInt(upperBound: 4000)) lines read)"
            default:
                kind = .meta
                snippet = "error: rate_limited — retrying in \(prng.nextInt(upperBound: 30))s"
            }
            // Add padding to vary message length 50–2000 chars per the
            // A0 baseline distribution.
            let padLen = 50 + prng.nextInt(upperBound: 1_950)
            let pad = String(repeating: " padded", count: padLen / 8 + 1).prefix(padLen)
            let body = "\(snippet)\(pad)"
            let title: String
            switch kind {
            case .userText: title = "You"
            case .assistantText: title = "Claude"
            case .toolCall: title = "Tool"
            case .toolResult: title = "Tool result"
            case .meta: title = "System"
            }
            items.append(.message(ChatMessage(
                id: "msg-\(i)",
                kind: kind,
                title: title,
                body: body,
                at: baseTime.addingTimeInterval(Double(i) * 2)
            )))
        }
        return WireChatSnapshot(
            sessionId: sessionId,
            items: items,
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 25_000,
            totalOutputTokens: 60_000,
            cacheReadTokens: 5_000,
            cacheCreationTokens: 1_200,
            lastEventAt: baseTime.addingTimeInterval(Double(messageCount) * 2),
            updateCounter: sequenceNumber,
            currentTurnState: .streaming
        )
    }
}
