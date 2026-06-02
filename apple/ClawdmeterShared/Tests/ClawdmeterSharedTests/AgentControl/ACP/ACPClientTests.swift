import XCTest
@testable import ClawdmeterShared

/// Unit + integration tests for the native ACP client (Phase 2). Covers the
/// decode contract (against real captured initialize frames), the NDJSON
/// transport (framing, id correlation, _meta strip), the event mapper, the
/// per-agent support policy, and a full FakeAcpAgent-driven turn incl. the
/// permission round-trip and the two-phase start-failure contract.
final class ACPClientTests: XCTestCase {

    // MARK: decode contract (real captured shapes)

    func testGrokInitializeDecodes() throws {
        let json = """
        {"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false},"_meta":{"x.ai/fs_notify":true}},"authMethods":[{"id":"grok.com","name":"Grok","description":"Sign in with Grok"}],"_meta":{"grokShell":true}}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ACPInitializeResult.self, from: json)
        XCTAssertEqual(r.protocolVersion, 1)
        XCTAssertTrue(r.supportsLoadSession)
        XCTAssertEqual(r.authMethods.map(\.id), ["grok.com"])
    }

    func testCursorInitializeDecodes() throws {
        let json = """
        {"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true},"sessionCapabilities":{"list":{}}},"authMethods":[{"id":"cursor_login","name":"Cursor Login"}]}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ACPInitializeResult.self, from: json)
        XCTAssertEqual(r.protocolVersion, 1)
        XCTAssertTrue(r.supportsLoadSession)
        XCTAssertEqual(r.authMethods.first?.id, "cursor_login")
    }

    // MARK: JSON value + _meta strip

    func testStrippingMetaRecursively() throws {
        let v = ACPJSONValue.object([
            "a": .int(1),
            "_meta": .object(["secret": .string("x")]),
            "nested": .object(["_meta": .string("drop"), "keep": .bool(true)]),
            "arr": .array([.object(["_meta": .int(9), "v": .int(2)])]),
        ])
        let s = v.strippingMeta()
        XCTAssertNil(s["_meta"])
        XCTAssertNil(s["nested"]?["_meta"])
        XCTAssertEqual(s["nested"]?["keep"]?.boolValue, true)
        XCTAssertNil(s["arr"]?.arrayValue?.first?["_meta"])
        XCTAssertEqual(s["arr"]?.arrayValue?.first?["v"]?.intValue, 2)
    }

    // MARK: NDJSON transport

    func testNdjsonRequestResponseCorrelationAndMetaStrip() async throws {
        // An echo writer that immediately feeds back a response with _meta.
        actor EchoWriter: AcpByteWriter {
            var feed: (@Sendable (Data) async -> Void)?
            func setFeed(_ f: @escaping @Sendable (Data) async -> Void) { feed = f }
            func write(_ data: Data) async throws {
                guard let v = try? JSONDecoder().decode(ACPJSONValue.self, from: data),
                      case .object(let o) = v, let id = o["id"] else { return }
                let resp = ACPJSONValue.object([
                    "jsonrpc": .string("2.0"), "id": id,
                    "result": .object(["ok": .bool(true), "_meta": .object(["leak": .string("nope")])]),
                ])
                var d = try! JSONEncoder().encode(resp); d.append(0x0A)
                await feed?(d)
            }
        }
        let writer = EchoWriter()
        let conn = NdjsonRpcConnection(writer: writer)
        await writer.setFeed { await conn.feed($0) }
        let result = try await conn.request("ping", params: .object([:]))
        XCTAssertEqual(result["ok"]?.boolValue, true)
        XCTAssertNil(result["_meta"], "_meta must be stripped from inbound results")
    }

    func testNdjsonPartialAndSplitFrameBuffering() async throws {
        // A no-op writer; we drive `feed` directly with a frame split across
        // chunks, including a split inside a multibyte character (é = C3 A9).
        struct NoopWriter: AcpByteWriter { func write(_ data: Data) async throws {} }
        let conn = NdjsonRpcConnection(writer: NoopWriter())
        let box = NotificationBox()
        await conn.setOnNotification { method, params in await box.record(method, params) }

        let full = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"café"}}}}"# + "\n"
        var bytes = Array(full.utf8)
        // split into 3 arbitrary chunks (mid-token + mid-line)
        let c1 = Data(bytes[0..<10]); let c2 = Data(bytes[10..<40]); let c3 = Data(bytes[40...])
        await conn.feed(c1)
        await conn.feed(c2)
        let countBeforeNewline = await box.count
        XCTAssertEqual(countBeforeNewline, 0, "no complete line yet")
        await conn.feed(c3)
        let recorded = await box.methods
        XCTAssertEqual(recorded, ["session/update"])
    }

    // MARK: event mapper

    func testEventMapperVariants() {
        var titles: [String: String] = [:]
        func map(_ update: ACPJSONValue) -> [HarnessEvent] {
            let note = ACPSessionNotification(sessionId: "s", update: ACPSessionUpdate(
                kind: ACPSessionUpdate.Kind(rawValue: update["sessionUpdate"]?.stringValue ?? "") ?? .unknown,
                rawKind: update["sessionUpdate"]?.stringValue ?? "unknown",
                raw: update))
            return ACPEventMapper.map(note, toolTitles: &titles)
        }
        XCTAssertEqual(map(.object(["sessionUpdate": .string("agent_message_chunk"),
                                    "content": .object(["text": .string("hi")])])),
                       [.agentMessageDelta("hi")])
        let plan = map(.object(["sessionUpdate": .string("plan"),
                                "plan": .object(["entries": .array([.object(["content": .string("a")])])])]))
        XCTAssertEqual(plan, [.plan([ACPPlanEntry(content: "a")])])
        let tool = map(.object(["sessionUpdate": .string("tool_call"),
                                "toolCall": .object(["toolCallId": .string("t"), "title": .string("T"), "status": .string("in_progress")])]))
        XCTAssertEqual(tool, [.toolCall(HarnessToolCall(toolCallId: "t", title: "T", kind: nil, status: .inProgress))])
        // unknown variant degrades, never throws/drops
        XCTAssertEqual(map(.object(["sessionUpdate": .string("brand_new_variant")])),
                       [.unknownUpdate(kind: "brand_new_variant")])
    }

    // MARK: per-agent support policy

    func testGrokSupport() {
        let g = GrokAcpSupport()
        XCTAssertEqual(g.binaryName, "grok")
        XCTAssertEqual(g.spawnArgv(model: "grok-build", effort: "high", alwaysApprove: true),
                       ["agent", "--no-leader", "--always-approve", "-m", "grok-build", "--reasoning-effort", "high", "stdio"])
        XCTAssertEqual(g.spawnArgv(model: nil, effort: nil, alwaysApprove: false),
                       ["agent", "--no-leader", "stdio"])
        XCTAssertEqual(g.resolveAuthMethod(offered: [ACPAuthMethod(id: "grok.com")]), "grok.com")
        XCTAssertFalse(g.supportsInSessionModelChange)
    }

    func testCursorSupport() {
        let c = CursorAcpSupport()
        XCTAssertEqual(c.spawnArgv(model: "auto", effort: nil, alwaysApprove: false), ["acp"])
        XCTAssertEqual(c.resolveAuthMethod(offered: [ACPAuthMethod(id: "cursor_login")]), "cursor_login")
        XCTAssertTrue(c.supportsInSessionModelChange)
    }

    // MARK: full drive (FakeAcpAgent)

    func testFullDriveEmitsPlanToolAndTurnEnded() async throws {
        let (driver, _) = await makeDriver(mode: .normal)
        let events = await drive(driver) { _ in }
        XCTAssertTrue(events.contains(.agentMessageDelta("Hello from fake")))
        XCTAssertTrue(events.contains { if case .plan(let p) = $0 { return p.count == 2 } else { return false } })
        XCTAssertTrue(events.contains { if case .toolCall(let t) = $0 { return t.status == .completed } else { return false } })
        XCTAssertEqual(events.last, .turnEnded(.endTurn))
    }

    func testPermissionRoundTrip() async throws {
        let (driver, _) = await makeDriver(mode: .withPermission)
        var sawPermission = false
        let events = await drive(driver) { e in
            if case .permissionRequest(let req) = e {
                sawPermission = true
                await driver.respondToPermission(requestId: req.requestId, optionId: "allow_once")
            }
        }
        XCTAssertTrue(sawPermission, "agent permission request must surface as a HarnessEvent")
        XCTAssertEqual(events.last, .turnEnded(.endTurn), "turn completes after we answer the permission")
    }

    func testTwoPhaseStartFailsSynchronously() async throws {
        let (driver, _) = await makeDriver(mode: .failInitialize)
        do {
            _ = try await driver.start(model: nil, effort: nil, cwd: "/tmp", alwaysApprove: false)
            XCTFail("start should throw on initialize failure")
        } catch let ACPError.startFailed(msg) {
            XCTAssertTrue(msg.contains("initialize"))
        }
    }

    func testCancelSendsSessionCancel() async throws {
        let (driver, agent) = await makeDriver(mode: .normal)
        _ = try await driver.start(model: nil, effort: nil, cwd: "/tmp", alwaysApprove: false)
        await driver.cancel()
        let cancelled = await agent.sawCancel
        XCTAssertTrue(cancelled)
        await driver.close()
    }

    // MARK: helpers

    private func makeDriver(mode: FakeAcpAgent.Mode, trustGate: RepoTrustGate? = nil) async -> (AcpAgentDriver, FakeAcpAgent) {
        let agent = FakeAcpAgent(mode: mode)
        let conn = NdjsonRpcConnection(writer: agent)
        // wire the fake's outbound delivery into the connection (awaited, no race)
        await agent.setDeliver { await conn.feed($0) }
        let driver = AcpAgentDriver(connection: conn, support: GrokAcpSupport(),
                                    clientInfo: ACPClientInfo(name: "clawdmeter-test", version: "0.0.0"),
                                    trustGate: trustGate)
        return (driver, agent)
    }

    /// Phase 6: with a trust gate, the agent's fs/write is validated through the
    /// gate — an in-root path writes the file (result); an escaping path is
    /// refused (error) and no file is created.
    func testFsWriteGatedByTrustModel() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acpfs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        guard let gate = RepoTrustGate(repoRoot: root.path) else { return XCTFail("gate") }

        let (driver, agent) = await makeDriver(mode: .normal, trustGate: gate)
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = try await driver.start(model: nil, effort: nil, cwd: root.path, alwaysApprove: false)

        // allow — in-root write succeeds and the file lands on disk.
        let okResp = await agent.requestFsWrite(path: "notes.txt", content: "hello")
        XCTAssertNotNil(okResp["result"], "in-root write should return a result")
        XCTAssertNil(okResp["error"])
        XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8), "hello")

        // deny — traversal escape is refused with an error and writes nothing.
        let denyResp = await agent.requestFsWrite(path: "../escape.txt", content: "x")
        XCTAssertNotNil(denyResp["error"], "escaping write must be denied")
        XCTAssertFalse(fm.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.txt").path))

        await driver.close()
    }

    /// Start the driver, send a prompt, collect events until `.turnEnded`
    /// (with a hard timeout). `onEvent` lets a test react mid-stream (e.g.
    /// answer a permission prompt).
    private func drive(_ driver: AcpAgentDriver,
                       onEvent: @escaping @Sendable (HarnessEvent) async -> Void) async -> [HarnessEvent] {
        // ensure deliver is wired before start
        try? await Task.sleep(nanoseconds: 50_000_000)
        let collector = EventCollector()
        let consume = Task {
            for await e in driver.events {
                await onEvent(e)
                let done = await collector.add(e)
                if done { break }
            }
        }
        do {
            _ = try await driver.start(model: nil, effort: nil, cwd: "/tmp", alwaysApprove: false)
            await driver.prompt("do the thing")
        } catch {
            consume.cancel()
            return []
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); consume.cancel() }
        _ = await consume.value
        timeout.cancel()
        let result = await collector.all()
        await driver.close()
        return result
    }
}

/// Thread-safe event sink that signals completion on `.turnEnded`.
actor EventCollector {
    private var events: [HarnessEvent] = []
    func add(_ e: HarnessEvent) -> Bool {
        events.append(e)
        if case .turnEnded = e { return true }
        return false
    }
    func all() -> [HarnessEvent] { events }
}

actor NotificationBox {
    private(set) var methods: [String] = []
    var count: Int { methods.count }
    func record(_ method: String, _ params: ACPJSONValue) { methods.append(method) }
}
