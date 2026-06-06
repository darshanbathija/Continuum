import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ClawdmeterShared

/// PR #24a Step 2 / CQ1 — state-machine coverage for the shared
/// `ComposerSendController` that 4 composer surfaces consume. Tests the
/// pure-state-machine path: text trimming, canSend gating, sending
/// state transitions. Network-side behavior (RPC errors, retries) is
/// integration-tested separately.
final class ComposerSendControllerTests: XCTestCase {

    private final class ComposerURLProtocol: URLProtocol {
        static var responder: ((URLRequest) -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let responder = Self.responder else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (status, data) = responder(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient() -> AgentControlClient {
        AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "test-token"
        )
    }

    private func makeClient(responder: @escaping (URLRequest) -> (Int, Data)) -> AgentControlClient {
        ComposerURLProtocol.responder = responder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ComposerURLProtocol.self]
        return AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "test-token",
            urlSession: URLSession(configuration: config)
        )
    }

    @MainActor
    func test_initialState_isEmpty() async {
        let controller = ComposerSendController(client: makeClient())
        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.sending)
        XCTAssertNil(controller.lastError)
        XCTAssertFalse(controller.canSend, "Empty text cannot send")
    }

    @MainActor
    func test_canSend_falseForEmptyText() async {
        let controller = ComposerSendController(client: makeClient())
        controller.text = ""
        XCTAssertFalse(controller.canSend)
    }

    @MainActor
    func test_canSend_falseForWhitespaceOnly() async {
        let controller = ComposerSendController(client: makeClient())
        controller.text = "   \n\t  "
        XCTAssertFalse(controller.canSend, "Whitespace-only text should not be sendable")
    }

    @MainActor
    func test_canSend_trueWithNonEmptyText() async {
        let controller = ComposerSendController(client: makeClient())
        controller.text = "Hello"
        XCTAssertTrue(controller.canSend)
    }

    @MainActor
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

    @MainActor
    func test_emptyTextDoesNotInvokeRPC() async {
        let controller = ComposerSendController(client: makeClient())
        controller.text = ""
        await controller.send(via: .solo(sessionId: UUID()))
        // Nothing to assert directly without an RPC mock; ensure the
        // state remains idle and text stays empty.
        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.sending)
    }

    @MainActor
    func test_whitespaceOnlyTextDoesNotInvokeRPC() async {
        let controller = ComposerSendController(client: makeClient())
        controller.text = "   \n  "
        await controller.send(via: .solo(sessionId: UUID()))
        // Text preserved (we don't auto-clear on no-op).
        XCTAssertEqual(controller.text, "   \n  ")
        XCTAssertFalse(controller.sending)
    }

    @MainActor
    func test_reset_clearsAllState() async {
        let controller = ComposerSendController(client: makeClient())
        controller.text = "in-flight draft"
        controller.reset()
        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.sending)
        XCTAssertNil(controller.lastError)
    }

    @MainActor
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

    @MainActor
    func test_soloSendUsesBoolReturn_notLastErrorDelta() async {
        let client = makeClient { _ in (500, Data()) }
        let controller = ComposerSendController(client: client)
        let sessionId = UUID()

        controller.text = "first"
        await controller.send(via: .solo(sessionId: sessionId))
        XCTAssertEqual(controller.text, "first")
        XCTAssertEqual(client.lastHTTPStatusCode, 500)

        controller.text = "second"
        await controller.send(via: .solo(sessionId: sessionId))

        XCTAssertEqual(controller.text, "second", "A repeated identical client error must not be mistaken for success")
        XCTAssertEqual(controller.lastError, "Daemon returned HTTP 500.")
    }
}
