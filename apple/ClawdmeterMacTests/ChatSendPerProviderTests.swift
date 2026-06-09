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
///   • Part 3 — the non-harness providers (Claude PTY JSONL and OpenCode
///     serve SSE) project fake stream events into the same chat store and
///     lifecycle state without a real provider binary.
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
        // Persisted SDK-style Codex chats are retired once app-server harness is
        // the only Codex chat runtime.
        XCTAssertEqual(chatRoute(agent: .codex, codexBackend: .sdk), .legacyRetired)
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

    func test_send_claudeChat_routesToPty() {
        XCTAssertEqual(chatRoute(agent: .claude), .claudePty)
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

    private struct HarnessProviderCase {
        let agent: AgentKind
        let displayName: String
        let model: String
        let effort: String?
    }

    private struct DriverStart: Equatable {
        let model: String?
        let effort: String?
        let cwd: String
        let alwaysApprove: Bool
    }

    private let sharedHarnessProviderCases: [HarnessProviderCase] = [
        HarnessProviderCase(agent: .codex, displayName: "Codex", model: "gpt-5.5", effort: "high"),
        HarnessProviderCase(agent: .gemini, displayName: "Gemini", model: "gemini-3.5-flash-thinking", effort: nil),
        HarnessProviderCase(agent: .cursor, displayName: "Cursor", model: "cursor-default", effort: nil),
        HarnessProviderCase(agent: .grok, displayName: "Grok", model: "grok-build", effort: "high")
    ]

    /// Minimal AgentDriver double with a controllable event stream + prompt log.
    private actor SendFakeDriver: AgentDriver {
        nonisolated let events: AsyncStream<HarnessEvent>
        private nonisolated let cont: AsyncStream<HarnessEvent>.Continuation
        private(set) var starts: [DriverStart] = []
        private(set) var prompts: [String] = []
        init() {
            var c: AsyncStream<HarnessEvent>.Continuation!
            events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
        }
        nonisolated func emit(_ e: HarnessEvent) { cont.yield(e) }
        func start(model: String?, effort: String?, cwd: String, alwaysApprove: Bool) async throws -> String {
            starts.append(DriverStart(model: model, effort: effort, cwd: cwd, alwaysApprove: alwaysApprove))
            return "fake"
        }
        func prompt(_ text: String) async { prompts.append(text) }
        func cancel() async {}
        func respondToPermission(requestId: RpcId, optionId: String?) async {}
        func close() async { cont.finish() }
    }

    private var startedStores: [SessionChatStore] = []

    override func tearDown() async throws {
        for s in startedStores { s.stop() }
        startedStores = []
        OpencodeSSEAdapter.shared.chatStoreAccessor = nil
        OpencodeSSEAdapter.shared.stop()
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

    private func makeHarnessBridge(
        displayName: String,
        model: String = "m"
    ) -> (AcpHarnessBridge, SessionChatStore, SendFakeDriver) {
        let id = UUID()
        let store = SessionChatStore(sessionId: id, sdkOnly: true)
        store.start()
        startedStores.append(store)
        let driver = SendFakeDriver()
        let bridge = AcpHarnessBridge(
            sessionId: id, store: store, model: model,
            agentDisplayName: displayName, driver: driver, child: nil, connection: nil
        )
        return (bridge, store, driver)
    }

    private func makeJSONLStore() throws -> (SessionChatStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-provider-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let store = SessionChatStore(sessionId: UUID(), sessionFileURL: url)
        store.start()
        startedStores.append(store)
        return (store, url)
    }

    private func appendJSONLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// The path codex / grok / cursor / gemini chat all share once a bridge is
    /// live: send a message → the driver receives it → the reply streams back.
    func test_harnessChatSend_deliversPromptAndStreamsReply() async throws {
        let (bridge, store, driver) = makeHarnessBridge(displayName: "ChatGPT")
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        await bridge.prompt("hello from the test", origin: .userComposer)
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

    func test_harnessBridgeBlocksLegacyPromptBeforeDriver() async throws {
        let (bridge, store, driver) = makeHarnessBridge(displayName: "ChatGPT")
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        let accepted = await bridge.prompt("background prompt")
        let delivered = await driver.prompts

        XCTAssertFalse(accepted)
        XCTAssertEqual(delivered, [])
        XCTAssertEqual(store.snapshot.currentTurnState, .idle)
        await bridge.teardown()
    }

    /// Grok drives the same bridge path (its streaming-json → HarnessEvent
    /// mapping is unit-tested in GrokHeadlessDriverTests); confirm thought + text
    /// deltas both project into the store under the Grok display name.
    func test_harnessChatSend_grokThoughtAndTextProject() async throws {
        let (bridge, store, driver) = makeHarnessBridge(displayName: "Grok")
        try await bridge.start(binary: nil, arguments: [], cwd: "/tmp", env: [:], effort: nil, alwaysApprove: false)

        await bridge.prompt("fake grok prompt", origin: .userComposer)
        driver.emit(.agentThoughtDelta("considering…"))
        driver.emit(.agentMessageDelta("fake grok reply"))
        driver.emit(.turnEnded(.endTurn))

        let replied = await waitUntil {
            store.messages.contains { $0.kind == .assistantText && $0.body == "fake grok reply" }
        }
        XCTAssertTrue(replied, "grok's text reply projects as an assistant row")
        let row = store.messages.first { $0.kind == .assistantText && $0.body == "fake grok reply" }
        XCTAssertEqual(row?.title, "Grok")
        await bridge.teardown()
    }

    func test_harnessProviderMatrix_deliversPromptStreamsCompletionForEverySharedHarnessProvider() async throws {
        for fixture in sharedHarnessProviderCases {
            let (bridge, store, driver) = makeHarnessBridge(displayName: fixture.displayName, model: fixture.model)
            try await bridge.start(
                binary: nil,
                arguments: [],
                cwd: "/tmp/\(fixture.agent.rawValue)",
                env: [:],
                effort: fixture.effort,
                alwaysApprove: false
            )

            let starts = await driver.starts
            XCTAssertEqual(
                starts,
                [DriverStart(model: fixture.model, effort: fixture.effort, cwd: "/tmp/\(fixture.agent.rawValue)", alwaysApprove: false)],
                "\(fixture.agent.rawValue) must start with the selected model/effort instead of inheriting a stale tab"
            )

            let prompt = "hello \(fixture.agent.rawValue)"
            await bridge.prompt(prompt, origin: .userComposer)
            let delivered = await driver.prompts
            XCTAssertEqual(delivered, [prompt], "\(fixture.agent.rawValue) prompt must reach the live bridge")

            let streaming = await waitUntil { store.snapshot.currentTurnState == .streaming }
            XCTAssertTrue(streaming, "\(fixture.agent.rawValue) send must surface streaming state immediately")

            let body = "\(fixture.displayName) fake reply"
            driver.emit(.agentMessageDelta("\(fixture.displayName) "))
            driver.emit(.agentMessageDelta("fake reply"))
            driver.emit(.turnEnded(.endTurn))

            let replied = await waitUntil {
                store.messages.contains {
                    $0.kind == .assistantText
                        && $0.title == fixture.displayName
                        && $0.body == body
                        && !$0.isError
                }
            }
            XCTAssertTrue(replied, "\(fixture.agent.rawValue) streamed completion must land in the transcript")
            let completed = await waitUntil { store.snapshot.currentTurnState == .completed }
            XCTAssertTrue(completed, "\(fixture.agent.rawValue) completion must clear the active turn")
            await bridge.teardown()
        }
    }

    func test_harnessProviderMatrix_projectsProviderErrorsForEverySharedHarnessProvider() async throws {
        for fixture in sharedHarnessProviderCases {
            let (bridge, store, driver) = makeHarnessBridge(displayName: fixture.displayName, model: fixture.model)
            try await bridge.start(
                binary: nil,
                arguments: [],
                cwd: "/tmp/\(fixture.agent.rawValue)",
                env: [:],
                effort: fixture.effort,
                alwaysApprove: false
            )

            let prompt = "trigger \(fixture.agent.rawValue) error"
            await bridge.prompt(prompt, origin: .userComposer)
            driver.emit(.error(code: fixture.agent.rawValue, message: "\(fixture.displayName) failed"))

            let projected = await waitUntil {
                store.messages.contains {
                    $0.kind == .assistantText
                        && $0.title == fixture.displayName
                        && $0.body == "\(fixture.displayName) failed"
                        && $0.isError
                }
            }
            XCTAssertTrue(projected, "\(fixture.agent.rawValue) provider error must render as an error row")
            let interrupted = await waitUntil { store.snapshot.currentTurnState == .interrupted }
            XCTAssertTrue(interrupted, "\(fixture.agent.rawValue) provider error must leave the turn interruptible/recoverable")
            await bridge.teardown()
        }
    }

    // MARK: - Part 3 — non-harness provider streams

    func test_claudePtyJsonlStream_projectsPromptReplyUsageAndLifecycle() async throws {
        let (store, url) = try makeJSONLStore()

        try appendJSONLine(
            #"{"type":"user","timestamp":"2026-06-09T00:00:00Z","message":{"role":"user","content":"hello claude"}}"#,
            to: url
        )
        let promptProjected = await waitUntil {
            store.snapshot.currentTurnState == .streaming
                && store.messages.contains { $0.kind == .userText && $0.body == "hello claude" }
        }
        XCTAssertTrue(promptProjected, "Claude PTY JSONL user line must project into chat and mark the turn streaming")

        try appendJSONLine(
            #"{"type":"assistant","timestamp":"2026-06-09T00:00:01Z","message":{"id":"claude-reply-1","role":"assistant","model":"claude-sonnet-4-5","stop_reason":"end_turn","content":[{"type":"text","text":"Claude fake reply"}],"usage":{"input_tokens":123,"output_tokens":45,"cache_creation_input_tokens":6,"cache_read_input_tokens":7}}}"#,
            to: url
        )

        let replyProjected = await waitUntil {
            store.snapshot.currentTurnState == .completed
                && store.messages.contains {
                    $0.kind == .assistantText
                        && $0.title == "Claude"
                        && $0.body == "Claude fake reply"
                }
                && store.snapshot.lastInputTokens == 123
                && store.snapshot.lastOutputTokens == 45
                && store.snapshot.lastCacheCreationTokens == 6
                && store.snapshot.lastCacheReadTokens == 7
                && store.snapshot.modelHint == "claude-sonnet-4-5"
        }
        XCTAssertTrue(replyProjected, "Claude PTY JSONL assistant completion must update transcript, usage, model, and turn state")
    }

    func test_opencodeServeSSE_projectsPromptReplyAndLifecycle() async throws {
        let id = UUID()
        let store = SessionChatStore(sessionId: id, sdkOnly: true)
        store.start()
        startedStores.append(store)

        OpencodeSSEAdapter.shared.register(clawdmeterID: id, opencodeID: "opc-stream")
        OpencodeSSEAdapter.shared.chatStoreAccessor = { lookup in
            lookup == id ? store : nil
        }

        OpencodeSSEAdapter.shared.handleEvent(
            type: "message.added",
            properties: [
                "sessionID": "opc-stream",
                "message": [
                    "id": "opc-user-1",
                    "role": "user",
                    "content": "hello opencode"
                ]
            ]
        )
        let promptProjected = await waitUntil {
            store.snapshot.currentTurnState == .streaming
                && store.messages.contains { $0.kind == .userText && $0.body == "hello opencode" }
        }
        XCTAssertTrue(promptProjected, "OpenCode user SSE event must keep the turn streaming")

        OpencodeSSEAdapter.shared.handleEvent(
            type: "message.added",
            properties: [
                "sessionID": "opc-stream",
                "message": [
                    "id": "opc-assistant-1",
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "OpenCode fake reply"]
                    ]
                ]
            ]
        )
        let replyProjected = await waitUntil {
            store.snapshot.currentTurnState == .completed
                && store.messages.contains {
                    $0.kind == .assistantText
                        && $0.title == "Assistant"
                        && $0.body == "OpenCode fake reply"
                        && !$0.isError
                }
        }
        XCTAssertTrue(replyProjected, "OpenCode assistant SSE event must land in chat and complete the active turn")
    }

    func test_opencodeServeSSE_projectsProviderErrorAndInterruptsTurn() async throws {
        let id = UUID()
        let store = SessionChatStore(sessionId: id, sdkOnly: true)
        store.start()
        startedStores.append(store)
        store.setCurrentTurnState(.streaming)

        OpencodeSSEAdapter.shared.register(clawdmeterID: id, opencodeID: "opc-error")
        OpencodeSSEAdapter.shared.chatStoreAccessor = { lookup in
            lookup == id ? store : nil
        }

        OpencodeSSEAdapter.shared.handleEvent(
            type: "session.error",
            properties: [
                "sessionID": "opc-error",
                "error": "OpenCode failed"
            ]
        )

        let errorProjected = await waitUntil {
            store.snapshot.currentTurnState == .interrupted
                && store.messages.contains {
                    $0.kind == .assistantText
                        && $0.title == "OpenCode"
                        && $0.body == "OpenCode failed"
                        && $0.isError
                }
        }
        XCTAssertTrue(errorProjected, "OpenCode session.error must render as provider error and interrupt the turn")
    }
}
