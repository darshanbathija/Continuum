import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Confirms chat-send works for EVERY provider, to the extent testable without a
/// live agent CLI:
///   • Part 1 — each provider's chat turn ROUTES to the correct backend
///     (SessionCommandRouter is the single source of truth the send handler
///     uses), covering all six providers + the legacy/kill-switch variants.
///   • Part 2 — the HARNESS send path (shared by codex / grok / cursor / gemini
///     chat) actually delivers the prompt to the driver AND streams the reply
///     into the chat store, via a fake driver (no binary).
///
/// True end-to-end with real agents is the live-verify gate, confirmed manually
/// 2026-06-03: `codex app-server` ✓, `cursor-agent acp` ✓, grok headless ✓;
/// Antigravity/Gemini needs the Antigravity 2 app running.
@MainActor
final class ChatSendPerProviderTests: XCTestCase {

    // MARK: - Part 1 — per-provider send routing

    private func chatRoute(
        agent: AgentKind,
        codexBackend: CodexChatBackend? = nil,
        hasLiveBridge: Bool = false
    ) -> SessionCommandRoute {
        SessionCommandRouter.resolve(.init(
            agent: agent, kind: .chat,
            codexChatBackend: codexBackend,
            runtimeIsACPDriven: hasLiveBridge,
            hasLiveBridge: hasLiveBridge
        ))
    }

    func test_send_codexChat_routesToHarnessByDefault() {
        // Harness default: codexChatBackend nil + a live bridge → app-server harness.
        XCTAssertEqual(chatRoute(agent: .codex, hasLiveBridge: true), .harnessBridge)
        // Kill-switch legacy: codexChatBackend .sdk (no bridge) → SDK relay.
        XCTAssertEqual(chatRoute(agent: .codex, codexBackend: .sdk), .codexSDK)
    }

    func test_send_geminiChat_routesToHarnessByDefault() {
        // Gemini drives via the headless agy harness bridge.
        XCTAssertEqual(chatRoute(agent: .gemini, hasLiveBridge: true), .harnessBridge)
    }

    func test_send_grokChat_routesToHarness() {
        XCTAssertEqual(chatRoute(agent: .grok, hasLiveBridge: true), .harnessBridge)
    }

    func test_send_cursorChat_routesToHarness() {
        XCTAssertEqual(chatRoute(agent: .cursor, hasLiveBridge: true), .harnessBridge)
    }

    func test_send_claudeChat_routesToTmux() {
        XCTAssertEqual(chatRoute(agent: .claude), .tmux)
    }

    func test_send_opencodeChat_routesToServe() {
        XCTAssertEqual(chatRoute(agent: .opencode), .opencodeServe)
    }

    func test_send_everyHarnessProvider_resolvesToBridgeWhenLive() {
        for agent in [AgentKind.codex, .gemini, .grok, .cursor] {
            XCTAssertEqual(chatRoute(agent: agent, hasLiveBridge: true), .harnessBridge,
                           "\(agent.rawValue) chat send must route to the harness bridge when live")
        }
    }

    // MARK: - Part 2 — harness send delivery (fake driver, no binary)

    /// Minimal AgentDriver double with a controllable event stream + prompt log.
    private actor SendFakeDriver: AgentDriver {
        nonisolated let events: AsyncStream<HarnessEvent>
        private nonisolated let cont: AsyncStream<HarnessEvent>.Continuation
        private(set) var prompts: [String] = []
        init() {
            var c: AsyncStream<HarnessEvent>.Continuation!
            events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
        }
        nonisolated func emit(_ e: HarnessEvent) { cont.yield(e) }
        func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String { "fake" }
        func prompt(_ text: String) async { prompts.append(text) }
        func cancel() async {}
        func respondToPermission(requestId: RpcId, optionId: String?) async {}
        func close() async { cont.finish() }
    }

    private var startedStores: [SessionChatStore] = []

    override func tearDown() async throws {
        for s in startedStores { s.stop() }
        startedStores = []
        try await super.tearDown()
    }

    private func waitUntil(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func makeHarnessBridge(displayName: String) -> (AcpHarnessBridge, SessionChatStore, SendFakeDriver) {
        let id = UUID()
        let store = SessionChatStore(sessionId: id, sdkOnly: true)
        store.start()
        startedStores.append(store)
        let driver = SendFakeDriver()
        let bridge = AcpHarnessBridge(
            sessionId: id, store: store, model: "m",
            agentDisplayName: displayName, driver: driver, child: nil, connection: nil
        )
        return (bridge, store, driver)
    }

    /// The path codex / grok / cursor / gemini chat all share once a bridge is
    /// live: send a message → the driver receives it → the reply streams back.
    func test_harnessChatSend_deliversPromptAndStreamsReply() async throws {
        let (bridge, store, driver) = makeHarnessBridge(displayName: "ChatGPT")
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        await bridge.prompt("hello from the test")
        let delivered = await driver.prompts
        XCTAssertEqual(delivered, ["hello from the test"], "the chat prompt reaches the driver")
        let streaming = await waitUntil { store.snapshot.currentTurnState == .streaming }
        XCTAssertTrue(streaming, "sending flips the turn state to streaming")

        driver.emit(.agentMessageDelta("hi "))
        driver.emit(.agentMessageDelta("there"))
        driver.emit(.turnEnded(.endTurn))
        let replied = await waitUntil {
            store.messages.contains { $0.kind == .assistantText && $0.body == "hi there" }
        }
        XCTAssertTrue(replied, "the streamed reply lands as one assistant row")
        let completed = await waitUntil { store.snapshot.currentTurnState == .completed }
        XCTAssertTrue(completed)
        await bridge.teardown()
    }

    /// Grok drives the same bridge path (its streaming-json → HarnessEvent
    /// mapping is unit-tested in GrokHeadlessDriverTests); confirm thought + text
    /// deltas both project into the store under the Grok display name.
    func test_harnessChatSend_grokThoughtAndTextProject() async throws {
        let (bridge, store, driver) = makeHarnessBridge(displayName: "Grok")
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        await bridge.prompt("ping")
        driver.emit(.agentThoughtDelta("considering…"))
        driver.emit(.agentMessageDelta("pong"))
        driver.emit(.turnEnded(.endTurn))

        let replied = await waitUntil {
            store.messages.contains { $0.kind == .assistantText && $0.body == "pong" }
        }
        XCTAssertTrue(replied, "grok's text reply projects as an assistant row")
        let row = store.messages.first { $0.kind == .assistantText && $0.body == "pong" }
        XCTAssertEqual(row?.title, "Grok")
        await bridge.teardown()
    }
}
