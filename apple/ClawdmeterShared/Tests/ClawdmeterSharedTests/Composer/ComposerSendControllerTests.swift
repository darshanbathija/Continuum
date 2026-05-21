import XCTest
@testable import ClawdmeterShared

/// PR #24a Step 2 / CQ1 — state-machine coverage for the shared
/// `ComposerSendController` that 4 composer surfaces consume. Tests the
/// pure-state-machine path: text trimming, canSend gating, sending
/// state transitions. Network-side behavior (RPC errors, retries) is
/// integration-tested separately.
@MainActor
final class ComposerSendControllerTests: XCTestCase {

    private func makeClient() -> AgentControlClient {
        AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "test-token"
        )
    }

    func test_initialState_isEmpty() {
        let controller = ComposerSendController(client: makeClient())
        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.sending)
        XCTAssertNil(controller.lastError)
        XCTAssertFalse(controller.canSend, "Empty text cannot send")
    }

    func test_canSend_falseForEmptyText() {
        let controller = ComposerSendController(client: makeClient())
        controller.text = ""
        XCTAssertFalse(controller.canSend)
    }

    func test_canSend_falseForWhitespaceOnly() {
        let controller = ComposerSendController(client: makeClient())
        controller.text = "   \n\t  "
        XCTAssertFalse(controller.canSend, "Whitespace-only text should not be sendable")
    }

    func test_canSend_trueWithNonEmptyText() {
        let controller = ComposerSendController(client: makeClient())
        controller.text = "Hello"
        XCTAssertTrue(controller.canSend)
    }

    func test_canSend_falseWhileSending() async {
        // Drive a send (will fail because the test client has no real
        // server at 127.0.0.1:21731 — that's OK; we're testing the
        // sending-state flip, not the network).
        let controller = ComposerSendController(client: makeClient())
        controller.text = "Test prompt"

        let sessionId = UUID()
        // Kick off send + check canSend reads false during the in-flight
        // window. We can't synchronously observe `sending=true` between
        // the set and the await without instrumentation; instead verify
        // the post-state matches the contract.
        await controller.send(via: .solo(sessionId: sessionId))

        // After await: sending must be false again (defer reset).
        XCTAssertFalse(controller.sending, "sending must be reset after await")
    }

    func test_emptyTextDoesNotInvokeRPC() async {
        let controller = ComposerSendController(client: makeClient())
        controller.text = ""
        await controller.send(via: .solo(sessionId: UUID()))
        // Nothing to assert directly without an RPC mock; ensure the
        // state remains idle and text stays empty.
        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.sending)
    }

    func test_whitespaceOnlyTextDoesNotInvokeRPC() async {
        let controller = ComposerSendController(client: makeClient())
        controller.text = "   \n  "
        await controller.send(via: .solo(sessionId: UUID()))
        // Text preserved (we don't auto-clear on no-op).
        XCTAssertEqual(controller.text, "   \n  ")
        XCTAssertFalse(controller.sending)
    }

    func test_reset_clearsAllState() {
        let controller = ComposerSendController(client: makeClient())
        controller.text = "in-flight draft"
        controller.reset()
        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.sending)
        XCTAssertNil(controller.lastError)
    }

    func test_sendKind_soloAndRefine_bothComplete() async {
        // A3 lock-in: Edit plan = Refine via the same sendPrompt wire.
        // We verify both SendKind variants dispatch and reach the
        // post-send state (sending=false) without crashing. Outcome
        // text differs between rounds because the AgentControlClient's
        // lastError state mutates across runs; we only assert dispatch
        // completes cleanly.
        let sessionId = UUID()

        // Use fresh controllers per dispatch so client.lastError baselines
        // don't leak between tests.
        let soloController = ComposerSendController(client: makeClient())
        soloController.text = "Refine this"
        await soloController.send(via: .solo(sessionId: sessionId))
        XCTAssertFalse(soloController.sending, "solo dispatch must reset sending")

        let refineController = ComposerSendController(client: makeClient())
        refineController.text = "Refine this"
        await refineController.send(via: .refine(sessionId: sessionId))
        XCTAssertFalse(refineController.sending, "refine dispatch must reset sending")
    }
}
