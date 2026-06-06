import XCTest
@testable import ClawdmeterShared

/// Behavior tests for `SessionCommandRouter`. The router pins the current
/// command transport contract: live ACP bridges win, Claude uses a direct PTY,
/// OpenCode uses `serve`, and old pane/window-backed
/// sessions are retired instead of reconnected.
final class SessionCommandRouterTests: XCTestCase {

    // Convenience builder so each test reads as just the axes that matter.
    private func ctx(
        agent: AgentKind,
        kind: SessionKind = .code,
        codexChatBackend: CodexChatBackend? = nil,
        runtimeIsACPDriven: Bool = false,
        hasLiveBridge: Bool = false
    ) -> SessionCommandRouter.SessionContext {
        SessionCommandRouter.SessionContext(
            agent: agent,
            kind: kind,
            codexChatBackend: codexChatBackend,
            runtimeIsACPDriven: runtimeIsACPDriven,
            hasLiveBridge: hasLiveBridge
        )
    }

    // MARK: one case per backend

    func testClaudeCodeResolvesClaudePty() {
        XCTAssertEqual(SessionCommandRouter.resolve(ctx(agent: .claude)), .claudePty)
    }

    // MARK: Track A — Claude PTY is always on

    private func claudeCtx(kind: SessionKind, ptyEnabled: Bool) -> SessionCommandRouter.SessionContext {
        SessionCommandRouter.SessionContext(agent: .claude, kind: kind, claudePtyEnabled: ptyEnabled)
    }

    func testClaudeFlagIsIgnoredAndAlwaysResolvesClaudePty() {
        XCTAssertEqual(SessionCommandRouter.resolve(claudeCtx(kind: .code, ptyEnabled: false)), .claudePty)
        XCTAssertEqual(SessionCommandRouter.resolve(claudeCtx(kind: .chat, ptyEnabled: false)), .claudePty)
        XCTAssertEqual(SessionCommandRouter.resolve(claudeCtx(kind: .code, ptyEnabled: true)), .claudePty)
        XCTAssertEqual(SessionCommandRouter.resolve(claudeCtx(kind: .chat, ptyEnabled: true)), .claudePty)
    }

    func testFlagDoesNotDivertNonClaude() {
        // The compatibility flag only exists for old callers. It does not
        // route other agents into Claude's PTY path.
        XCTAssertEqual(SessionCommandRouter.resolve(SessionCommandRouter.SessionContext(
            agent: .codex, kind: .chat, codexChatBackend: .cli, claudePtyEnabled: true)), .legacyRetired)
        XCTAssertEqual(SessionCommandRouter.resolve(SessionCommandRouter.SessionContext(
            agent: .codex, kind: .chat, codexChatBackend: .sdk, claudePtyEnabled: true)), .legacyRetired)
        XCTAssertEqual(SessionCommandRouter.resolve(SessionCommandRouter.SessionContext(
            agent: .opencode, kind: .code, claudePtyEnabled: true)), .opencodeServe)
    }

    func testFlagOnButLiveBridgeStillBridge() {
        // A live ACP bridge still wins (precedence above the claudePty branch).
        XCTAssertEqual(SessionCommandRouter.resolve(SessionCommandRouter.SessionContext(
            agent: .claude, kind: .code, hasLiveBridge: true, claudePtyEnabled: true)), .harnessBridge)
    }

    func testClaudePtyIsPaneless() {
        XCTAssertTrue(SessionCommandRoute.claudePty.isPaneless)
    }

    func testFlagOnButHasLegacyPaneRetires() {
        XCTAssertEqual(SessionCommandRouter.resolve(SessionCommandRouter.SessionContext(
            agent: .claude, kind: .code, claudePtyEnabled: true, hasLegacyPaneMetadata: true)), .legacyRetired)
        XCTAssertEqual(SessionCommandRouter.resolve(SessionCommandRouter.SessionContext(
            agent: .claude, kind: .chat, claudePtyEnabled: true, hasLegacyPaneMetadata: true)), .legacyRetired)
    }

    func testFlagOnPanelessClaudeStillResolvesClaudePty() {
        // The default paneless case is a PTY-native session.
        XCTAssertEqual(SessionCommandRouter.resolve(SessionCommandRouter.SessionContext(
            agent: .claude, kind: .chat, claudePtyEnabled: true, hasLegacyPaneMetadata: false)), .claudePty)
    }

    func testCodexCLIChatWithoutBridgeRetires() {
        XCTAssertEqual(
            SessionCommandRouter.resolve(ctx(agent: .codex, kind: .chat, codexChatBackend: .cli)),
            .legacyRetired
        )
    }

    func testCodexSDKChatWithoutHarnessRetires() {
        XCTAssertEqual(
            SessionCommandRouter.resolve(ctx(agent: .codex, kind: .chat, codexChatBackend: .sdk)),
            .legacyRetired
        )
    }

    func testOpencodeResolvesOpencodeServe() {
        XCTAssertEqual(SessionCommandRouter.resolve(ctx(agent: .opencode)), .opencodeServe)
    }

    func testGeminiWithLiveBridgeResolvesHarnessBridge() {
        // Gemini drives via the headless `agy` harness bridge now — a live
        // bridge resolves to harnessBridge, same as grok/cursor.
        XCTAssertEqual(
            SessionCommandRouter.resolve(ctx(
                agent: .gemini,
                kind: .chat,
                hasLiveBridge: true
            )),
            .harnessBridge
        )
    }

    func testHarnessBridgeResolvesHarnessBridge() {
        // A grok session with a live bridge → harnessBridge.
        XCTAssertEqual(
            SessionCommandRouter.resolve(ctx(
                agent: .grok,
                runtimeIsACPDriven: true,
                hasLiveBridge: true
            )),
            .harnessBridge
        )
    }

    // MARK: precedence (order is load-bearing)

    func testCodexSDKChatNoLongerBeatsRetiredFallback() {
        let route = SessionCommandRouter.resolve(ctx(agent: .codex, kind: .chat, codexChatBackend: .sdk))
        XCTAssertEqual(route, .legacyRetired)
    }

    func testCodexSDKChatWithHarnessRuntimeStillRetiresWithoutAcpStaleFlag() {
        let context = ctx(
            agent: .codex,
            kind: .chat,
            codexChatBackend: .sdk,
            runtimeIsACPDriven: true
        )

        XCTAssertEqual(SessionCommandRouter.resolve(context), .legacyRetired)
        XCTAssertFalse(SessionCommandRouter.acpExpectedButNoBridge(context))
    }

    func testOpenCodeWithLegacyPaneRetiresBeforeServeRoute() {
        let route = SessionCommandRouter.resolve(SessionCommandRouter.SessionContext(
            agent: .opencode,
            kind: .chat,
            hasLegacyPaneMetadata: true
        ))
        XCTAssertEqual(route, .legacyRetired)
    }

    func testLiveBridgeBeatsRetiredFallbackForAcpSession() {
        // A cursor session driven over ACP with a live bridge → harnessBridge,
        // not retired.
        let route = SessionCommandRouter.resolve(ctx(
            agent: .cursor,
            runtimeIsACPDriven: true,
            hasLiveBridge: true
        ))
        XCTAssertEqual(route, .harnessBridge)
    }

    func testOldCursorCLISessionWithoutBridgeRetires() {
        let route = SessionCommandRouter.resolve(ctx(
            agent: .cursor,
            runtimeIsACPDriven: false,   // legacy cursor_cli, not acp_cursor
            hasLiveBridge: false
        ))
        XCTAssertEqual(route, .legacyRetired)
    }

    // MARK: dead-bridge ACP diagnostic (the 503 signal, not a route)

    func testAcpExpectedButDeadBridgeResolvesRetiredAndIsFlagged() {
        // After a daemon restart an ACP-driven session can have NO live bridge.
        // The route is retired, but the daemon intercepts with an explicit 503
        // stale-harness response before returning the generic 410 retired path.
        let c = ctx(agent: .grok, runtimeIsACPDriven: true, hasLiveBridge: false)
        XCTAssertEqual(SessionCommandRouter.resolve(c), .legacyRetired)
        XCTAssertTrue(SessionCommandRouter.acpExpectedButNoBridge(c))
    }

    func testLiveBridgeIsNotFlaggedAsDeadBridge() {
        let c = ctx(agent: .grok, runtimeIsACPDriven: true, hasLiveBridge: true)
        XCTAssertEqual(SessionCommandRouter.resolve(c), .harnessBridge)
        XCTAssertFalse(SessionCommandRouter.acpExpectedButNoBridge(c))
    }

    func testPlainClaudePtySessionIsNotFlaggedAsDeadBridge() {
        let c = ctx(agent: .claude)
        XCTAssertEqual(SessionCommandRouter.resolve(c), .claudePty)
        XCTAssertFalse(SessionCommandRouter.acpExpectedButNoBridge(c))
    }

    // MARK: instance API parity + route metadata

    func testInstanceRouteMatchesStaticResolve() {
        let router = SessionCommandRouter()
        for agent in AgentKind.allCases {
            let c = ctx(agent: agent)
            XCTAssertEqual(router.route(for: c), SessionCommandRouter.resolve(c))
        }
    }

    func testPanelessFlagMatchesDaemonPaneExpectations() {
        XCTAssertTrue(SessionCommandRoute.opencodeServe.isPaneless)
        XCTAssertTrue(SessionCommandRoute.harnessBridge.isPaneless)
        XCTAssertTrue(SessionCommandRoute.claudePty.isPaneless)
        XCTAssertFalse(SessionCommandRoute.legacyRetired.isPaneless)
    }
}
