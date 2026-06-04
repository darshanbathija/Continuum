import XCTest
@testable import ClawdmeterShared

/// Behavior-identity tests for `SessionCommandRouter`. The router is a pure
/// extraction of the per-backend precedence that `AgentControlServer`'s
/// handleSendPrompt / handleInterrupt / handlePermissionRespond inline. Each
/// test pins one branch of the daemon's existing `if` ladder, and the
/// precedence tests prove the ORDER is preserved (a Codex SDK chat must not
/// fall into tmux; a live ACP bridge must win over the legacy tmux path; an
/// old cursor_cli session with NO bridge must still reach tmux — back-compat).
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

    func testClaudeCodeResolvesTmux() {
        XCTAssertEqual(SessionCommandRouter.resolve(ctx(agent: .claude)), .tmux)
    }

    func testCodexCLIChatResolvesTmux() {
        // Codex CLI (not SDK) chat has a real tmux pane → tmux, not codexSDK.
        XCTAssertEqual(
            SessionCommandRouter.resolve(ctx(agent: .codex, kind: .chat, codexChatBackend: .cli)),
            .tmux
        )
    }

    func testCodexSDKChatResolvesCodexSDK() {
        XCTAssertEqual(
            SessionCommandRouter.resolve(ctx(agent: .codex, kind: .chat, codexChatBackend: .sdk)),
            .codexSDK
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

    func testCodexSDKChatBeatsTmux() {
        // The SDK-chat branch is BEFORE the tmux paneId guard in the daemon.
        // Even though a Codex chat could in principle have a pane, the SDK
        // backend must short-circuit to the relay first.
        let route = SessionCommandRouter.resolve(ctx(agent: .codex, kind: .chat, codexChatBackend: .sdk))
        XCTAssertEqual(route, .codexSDK)
        XCTAssertNotEqual(route, .tmux)
    }

    func testLiveBridgeBeatsTmuxForAcpSession() {
        // A cursor session driven over ACP with a live bridge → harnessBridge,
        // not tmux.
        let route = SessionCommandRouter.resolve(ctx(
            agent: .cursor,
            runtimeIsACPDriven: true,
            hasLiveBridge: true
        ))
        XCTAssertEqual(route, .harnessBridge)
    }

    func testOldCursorCLISessionWithoutBridgeResolvesTmux_backCompat() {
        // Back-compat: a legacy cursor_cli session created before the harness
        // shipped has no live bridge. It must still reach the tmux path — the
        // daemon's fall-through — not silently break.
        let route = SessionCommandRouter.resolve(ctx(
            agent: .cursor,
            runtimeIsACPDriven: false,   // legacy cursor_cli, not acp_cursor
            hasLiveBridge: false
        ))
        XCTAssertEqual(route, .tmux)
    }

    // MARK: dead-bridge ACP diagnostic (the 503 signal, not a route)

    func testAcpExpectedButDeadBridgeStillResolvesTmux() {
        // After a daemon restart an ACP-driven session can have NO live bridge.
        // The route is tmux (the fall-through), but the daemon intercepts with
        // an explicit 503 instead of pasting into a dead pane. The router
        // resolves tmux AND flags the case so the caller can pick the 503.
        let c = ctx(agent: .grok, runtimeIsACPDriven: true, hasLiveBridge: false)
        XCTAssertEqual(SessionCommandRouter.resolve(c), .tmux)
        XCTAssertTrue(SessionCommandRouter.acpExpectedButNoBridge(c))
    }

    func testLiveBridgeIsNotFlaggedAsDeadBridge() {
        let c = ctx(agent: .grok, runtimeIsACPDriven: true, hasLiveBridge: true)
        XCTAssertEqual(SessionCommandRouter.resolve(c), .harnessBridge)
        XCTAssertFalse(SessionCommandRouter.acpExpectedButNoBridge(c))
    }

    func testPlainTmuxSessionIsNotFlaggedAsDeadBridge() {
        // A normal Claude session is not ACP-expected, so the 503 signal stays
        // false even though it resolves tmux.
        let c = ctx(agent: .claude)
        XCTAssertEqual(SessionCommandRouter.resolve(c), .tmux)
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
        // The short-circuit backends have no tmux pane; only .tmux does.
        XCTAssertTrue(SessionCommandRoute.codexSDK.isPaneless)
        XCTAssertTrue(SessionCommandRoute.opencodeServe.isPaneless)
        XCTAssertTrue(SessionCommandRoute.harnessBridge.isPaneless)
        XCTAssertFalse(SessionCommandRoute.tmux.isPaneless)
    }
}
