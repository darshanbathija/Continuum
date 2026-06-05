import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Drives AcpHarnessBridge with a fake AgentDriver (no real agent process) and
/// asserts the HarnessEvent → SessionChatStore projection + the permission
/// round-trip + teardown. Covers the daemon-side ACP integration that the
/// shared AcpHarnessProjection tests don't (the bridge owns event consumption,
/// the permission-id map, and the store applier).
@MainActor
final class AcpHarnessBridgeTests: XCTestCase {

    /// Minimal AgentDriver double with a controllable event stream + call log.
    actor FakeHarnessDriver: AgentDriver {
        nonisolated let events: AsyncStream<HarnessEvent>
        private nonisolated let cont: AsyncStream<HarnessEvent>.Continuation
        private(set) var prompts: [String] = []
        private(set) var cancelled = false
        private(set) var permissionResponses: [(RpcId, String?)] = []
        private(set) var closed = false

        init() {
            var c: AsyncStream<HarnessEvent>.Continuation!
            events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
        }
        /// Push an event into the stream (nonisolated — the Continuation is Sendable).
        nonisolated func emit(_ e: HarnessEvent) { cont.yield(e) }

        func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String { "fake-ext-1" }
        func prompt(_ text: String) async { prompts.append(text) }
        func cancel() async { cancelled = true }
        func respondToPermission(requestId: RpcId, optionId: String?) async { permissionResponses.append((requestId, optionId)) }
        func close() async { closed = true; cont.finish() }
    }

    /// Stores started by a test; stopped in tearDown so the detached 16ms
    /// commit loop each one spawns doesn't leak across tests.
    private var startedStores: [SessionChatStore] = []

    override func tearDown() async throws {
        for s in startedStores { s.stop() }
        startedStores = []
        try await super.tearDown()
    }

    private func makeBridge(_ driver: FakeHarnessDriver, name: String = "Grok") -> (AcpHarnessBridge, SessionChatStore) {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        // start() launches the commit loop that publishes the snapshot; without
        // it, appendSDKMessages/setCurrentTurnState never surface in `snapshot`.
        store.start()
        startedStores.append(store)
        let bridge = AcpHarnessBridge(
            sessionId: UUID(), store: store, model: "test-model",
            agentDisplayName: name, driver: driver, child: nil, connection: nil
        )
        return (bridge, store)
    }

    /// Poll a predicate until true or timeout (the bridge consumes events on a Task).
    private func waitUntil(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testLedgerDeltaTreatsMonotonicUsageUpdatesAsCumulative() {
        let first = HarnessUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15)
        XCTAssertEqual(AcpHarnessBridge.ledgerDelta(for: first, after: nil), first)

        let second = HarnessUsage(inputTokens: 21, outputTokens: 8, totalTokens: 29)
        let delta = AcpHarnessBridge.ledgerDelta(for: second, after: first)
        XCTAssertEqual(delta?.inputTokens, 11)
        XCTAssertEqual(delta?.outputTokens, 3)
        XCTAssertEqual(delta?.totalTokens, 14)

        XCTAssertNil(
            AcpHarnessBridge.ledgerDelta(for: second, after: second),
            "replayed final usage totals should not create another ledger row"
        )

        let nextTurn = HarnessUsage(inputTokens: 3, outputTokens: 2, totalTokens: 5)
        XCTAssertEqual(
            AcpHarnessBridge.ledgerDelta(for: nextTurn, after: second),
            nextTurn,
            "lower totals are independent usage events, not negative deltas"
        )
    }

    func testAssistantTextBuffersAndFlushesOnceOnTurnEnd() async throws {
        let driver = FakeHarnessDriver()
        let (bridge, store) = makeBridge(driver)
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        driver.emit(.agentMessageDelta("Hello "))
        driver.emit(.agentMessageDelta("world"))
        driver.emit(.turnEnded(.endTurn))

        let flushed = await waitUntil {
            store.messages.contains { $0.kind == .assistantText && $0.body == "Hello world" }
        }
        XCTAssertTrue(flushed, "deltas should buffer + flush as one assistant row on turnEnded")
        let assistantRows = store.messages.filter { $0.kind == .assistantText }
        XCTAssertEqual(assistantRows.count, 1, "exactly one flushed row, not one per delta")
        XCTAssertEqual(assistantRows.first?.title, "Grok")
        let completed = await waitUntil { store.snapshot.currentTurnState == .completed }
        XCTAssertTrue(completed)
        await bridge.teardown()
    }

    func testToolCallRendersRow() async throws {
        let driver = FakeHarnessDriver()
        let (bridge, store) = makeBridge(driver)
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        driver.emit(.toolCall(HarnessToolCall(toolCallId: "t1", title: "run tests", kind: "execute", status: .inProgress)))
        let rendered = await waitUntil {
            store.messages.contains { $0.kind == .toolCall && $0.title == "run tests" }
        }
        XCTAssertTrue(rendered)
        await bridge.teardown()
    }

    func testCancelledTurnSetsInterrupted() async throws {
        let driver = FakeHarnessDriver()
        let (bridge, store) = makeBridge(driver)
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        driver.emit(.agentMessageDelta("partial"))
        driver.emit(.turnEnded(.cancelled))
        let interrupted = await waitUntil { store.snapshot.currentTurnState == .interrupted }
        XCTAssertTrue(interrupted)
        await bridge.teardown()
    }

    func testPromptForwardsToDriverAndSetsStreaming() async throws {
        let driver = FakeHarnessDriver()
        let (bridge, store) = makeBridge(driver)
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        await bridge.prompt("do the thing")
        let streaming = await waitUntil { store.snapshot.currentTurnState == .streaming }
        XCTAssertTrue(streaming, "prompt flips turn state to streaming")
        let prompts = await driver.prompts
        XCTAssertEqual(prompts, ["do the thing"])
        await bridge.cancel()
        let cancelled = await driver.cancelled
        XCTAssertTrue(cancelled)
        await bridge.teardown()
    }

    func testPermissionRoundTrip() async throws {
        let driver = FakeHarnessDriver()
        let (bridge, store) = makeBridge(driver)
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        let req = HarnessPermissionRequest(
            requestId: .number(7), sessionId: "s", title: "Write foo.txt?",
            options: [
                ACPPermissionOption(optionId: "allow_once", name: "Allow", kind: "allow_once"),
                ACPPermissionOption(optionId: "reject_once", name: "Reject", kind: "reject_once"),
            ])
        driver.emit(.permissionRequest(req))

        let surfaced = await waitUntil { store.pendingPermissionPrompt?.id == "acp-perm-n7" }
        XCTAssertTrue(surfaced)

        // a stale promptId does not match
        let stale = await bridge.respondToPermission(promptId: "acp-perm-n999", optionId: "allow_once")
        XCTAssertFalse(stale)

        // the live promptId maps back to the driver's RpcId + clears the prompt
        let matched = await bridge.respondToPermission(promptId: "acp-perm-n7", optionId: "allow_once")
        XCTAssertTrue(matched)
        let resp = await driver.permissionResponses
        XCTAssertEqual(resp.count, 1)
        XCTAssertEqual(resp.first?.0, .number(7))
        XCTAssertEqual(resp.first?.1, "allow_once")
        XCTAssertNil(store.pendingPermissionPrompt, "answering clears the pending prompt")
        await bridge.teardown()
    }

    func testTeardownDrainsUnflushedTextAndClosesDriver() async throws {
        let driver = FakeHarnessDriver()
        let (bridge, store) = makeBridge(driver)
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        driver.emit(.agentMessageDelta("unflushed text"))
        // give the consume task a moment to buffer the delta
        let streaming = await waitUntil { store.snapshot.currentTurnState == .streaming }
        XCTAssertTrue(streaming)

        await bridge.teardown()
        let drained = await waitUntil {
            store.messages.contains { $0.kind == .assistantText && $0.body == "unflushed text" }
        }
        XCTAssertTrue(drained, "teardown flushes any buffered assistant text")
        let closed = await driver.closed
        XCTAssertTrue(closed, "teardown closes the driver")
    }

    func testHarnessSessionRegistry() async throws {
        let registry = HarnessSessionRegistry()
        let driver = FakeHarnessDriver()
        let id = UUID()
        let store = SessionChatStore(sessionId: id, sdkOnly: true)
        let bridge = AcpHarnessBridge(sessionId: id, store: store, model: nil,
                                      agentDisplayName: "Grok", driver: driver, child: nil, connection: nil)
        XCTAssertFalse(registry.contains(id))
        registry.register(bridge, for: id)
        XCTAssertTrue(registry.contains(id))
        XCTAssertNotNil(registry.bridge(for: id))
        await registry.remove(id)
        XCTAssertFalse(registry.contains(id))
        let closed = await driver.closed
        XCTAssertTrue(closed, "remove tears the bridge (+ driver) down")
    }
}
