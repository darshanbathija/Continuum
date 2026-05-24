import XCTest
import WebKit
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class RunProfileManagerTests: XCTestCase {
    func test_detectPreviewURLUsesNewestLocalURL() {
        let messages = [
            message("old server at http://localhost:3000"),
            message("external https://example.com ignored"),
            message("new server at http://127.0.0.1:5173/app"),
        ]

        let url = RunProfileManager.detectPreviewURL(in: messages)

        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:5173/app")
    }

    func test_resolveStoresHealthBackedSnapshot() async {
        let sessionId = UUID()
        let manager = RunProfileManager(
            sessionId: sessionId,
            chatStore: nil,
            healthChecker: StaticHealthChecker(health: .healthy(statusCode: 200))
        )

        await manager.resolveNowForTesting(messages: [message("ready at http://localhost:8080")])

        XCTAssertEqual(manager.snapshot?.sessionId, sessionId)
        XCTAssertEqual(manager.snapshot?.url.absoluteString, "http://localhost:8080")
        XCTAssertEqual(manager.snapshot?.health, .healthy(statusCode: 200))
        XCTAssertNil(manager.lastError)
    }

    func test_browserCommentPromptIncludesDetectedContextAndSanitizesControls() {
        let prompt = InAppBrowser.browserCommentPrompt(
            url: URL(string: "http://localhost:5173/app"),
            selector: "#save\nbutton",
            snippet: "Save\tchanges",
            comment: "button is hidden\non mobile"
        )

        XCTAssertTrue(prompt.contains("[BROWSER CONTEXT]"))
        XCTAssertTrue(prompt.contains("URL: http://localhost:5173/app"))
        XCTAssertTrue(prompt.contains("Selector: #save button"))
        XCTAssertTrue(prompt.contains("Snippet: Save changes"))
        XCTAssertTrue(prompt.contains("button is hidden on mobile"))
        XCTAssertTrue(prompt.hasSuffix("\n"))
    }

    func test_startRunCapturesOutputDetectsURLAndPersistsState() async throws {
        let sessionId = UUID()
        let processManager = FakeRunProcessManager(
            outputs: [.stdout("ready at http://localhost:4321\n")],
            exitCode: 0
        )
        let manager = RunProfileManager(
            sessionId: sessionId,
            chatStore: nil,
            healthChecker: StaticHealthChecker(health: .healthy(statusCode: 204)),
            processManager: processManager
        )

        manager.runCommand = "npm run dev"
        manager.startRun(cwd: "/tmp/clawdmeter")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.status, .exited)
        XCTAssertEqual(manager.stdoutLines, ["ready at http://localhost:4321"])
        XCTAssertEqual(manager.snapshot?.url.absoluteString, "http://localhost:4321")
        XCTAssertEqual(manager.snapshot?.source, "run")
        XCTAssertEqual(manager.snapshot?.health, .healthy(statusCode: 204))
        XCTAssertEqual(manager.lastExitCode, 0)
        XCTAssertEqual(manager.stateSnapshot.sessionId, sessionId)
        XCTAssertEqual(manager.stateSnapshot.cwd, "/tmp/clawdmeter")
        XCTAssertEqual(manager.stateSnapshot.command, "npm run dev")
        XCTAssertEqual(manager.stateSnapshot.detectedURL, "http://localhost:4321")
        XCTAssertEqual(manager.stateSnapshot.status, "exited")
    }

    func test_codeRunProfileServiceCapturesMacHostedRunOutput() async throws {
        let sessionId = UUID()
        let service = CodeRunProfileService(processManager: FakeRunProcessManager(
            outputs: [.stdout("remote ready at http://localhost:4555\n")],
            exitCode: 0
        ))
        let session = agentSession(id: sessionId, cwd: "/tmp/clawdmeter-remote-run")

        let starting = await service.start(
            session: session,
            command: "npm run dev",
            messages: []
        )
        XCTAssertEqual(starting.sessionId, sessionId)
        XCTAssertEqual(starting.cwd, "/tmp/clawdmeter-remote-run")
        XCTAssertEqual(starting.command, "npm run dev")

        try await Task.sleep(nanoseconds: 100_000_000)
        let snapshot = await service.snapshot(session: session, messages: [])

        XCTAssertEqual(snapshot.status, .exited)
        XCTAssertEqual(snapshot.lastExitCode, 0)
        XCTAssertEqual(snapshot.stdoutLines, ["remote ready at http://localhost:4555"])
        XCTAssertEqual(snapshot.detectedURL, "http://localhost:4555")
        XCTAssertEqual(snapshot.source, "run")
    }

    func test_codeRunProfileServiceDetectsTranscriptPreviewURL() async {
        let sessionId = UUID()
        let service = CodeRunProfileService(processManager: FakeRunProcessManager(outputs: [], exitCode: 0))
        let session = agentSession(id: sessionId, cwd: "/tmp/clawdmeter-transcript")

        let snapshot = await service.snapshot(
            session: session,
            messages: [message("preview served at http://127.0.0.1:5173/app")]
        )

        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.cwd, "/tmp/clawdmeter-transcript")
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(snapshot.detectedURL, "http://127.0.0.1:5173/app")
        XCTAssertEqual(snapshot.source, "transcript")
    }

    func test_localRunProcessE2ESmokeDetectsHealthyPreviewAndBuildsBrowserContext() async throws {
        guard ShellRunner.locateBinary("python3") != nil else {
            throw XCTSkip("python3 is required for the run/preview smoke test")
        }

        let sessionId = UUID()
        let manager = RunProfileManager(
            sessionId: sessionId,
            chatStore: nil,
            healthChecker: URLSessionHealthChecker(),
            processManager: LocalRunProcessManager()
        )
        manager.runCommand = """
        python3 -u - <<'PY'
        import http.server
        import socketserver

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(b"<html><body><button id='save'>Save</button></body></html>")

        class Server(socketserver.TCPServer):
            allow_reuse_address = True

        with Server(("127.0.0.1", 0), Handler) as httpd:
            print(f"http://127.0.0.1:{httpd.server_address[1]}", flush=True)
            httpd.serve_forever()
        PY
        """

        manager.startRun(cwd: FileManager.default.temporaryDirectory.path)
        defer { manager.stopRun() }

        let didDetectHealthyURL = await eventually(timeout: 5) {
            guard let snapshot = manager.snapshot else { return false }
            if case .healthy(statusCode: 200) = snapshot.health {
                return snapshot.source == "run"
            }
            return false
        }
        XCTAssertTrue(didDetectHealthyURL)
        XCTAssertEqual(manager.status, .running)
        XCTAssertEqual(manager.snapshot?.sessionId, sessionId)

        let url = try XCTUnwrap(manager.snapshot?.url)
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.contains("id='save'"))

        let prompt = InAppBrowser.browserCommentPrompt(
            url: url,
            selector: "#save",
            snippet: "Save",
            comment: "Button should submit the current draft"
        )
        XCTAssertTrue(prompt.contains("[BROWSER CONTEXT]"))
        XCTAssertTrue(prompt.contains("Selector: #save"))
        XCTAssertTrue(prompt.contains("Button should submit the current draft"))
    }

    func test_wkCommentBridgePostsSelectorAndSnippetFromCommandClick() async throws {
        let userContent = WKUserContentController()
        let bridgeExpectation = expectation(description: "bridge posts selected element")
        let bridge = TestBridgeHandler(expectation: bridgeExpectation)
        userContent.add(bridge, name: "clawdmeterComment")
        userContent.addUserScript(WKUserScript(
            source: InAppBrowser.commentBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        let webView = WKWebView(frame: .zero, configuration: config)
        let loadExpectation = expectation(description: "html loads")
        let navigation = TestNavigationDelegate(expectation: loadExpectation)
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<html><body><button id='save'>Save Draft</button></body></html>",
            baseURL: URL(string: "http://127.0.0.1")
        )

        await fulfillment(of: [loadExpectation], timeout: 3)
        _ = try await webView.evaluateJavaScript("""
        document.getElementById('save').dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true,
          metaKey: true
        }));
        """)
        await fulfillment(of: [bridgeExpectation], timeout: 3)

        let body = try XCTUnwrap(bridge.body as? [String: Any])
        XCTAssertEqual(body["selector"] as? String, "#save")
        XCTAssertEqual(body["snippet"] as? String, "Save Draft")
        userContent.removeScriptMessageHandler(forName: "clawdmeterComment")
        webView.navigationDelegate = nil
    }

    private func message(_ body: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            kind: .assistantText,
            title: "Agent",
            body: body,
            at: Date()
        )
    }

    private func agentSession(id: UUID, cwd: String) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: cwd,
            repoDisplayName: "Test",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .local,
            runtimeCwd: cwd
        )
    }

    private func eventually(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}

private final class TestBridgeHandler: NSObject, WKScriptMessageHandler {
    let expectation: XCTestExpectation
    var body: Any?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        body = message.body
        expectation.fulfill()
    }
}

private final class TestNavigationDelegate: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }
}

private struct StaticHealthChecker: URLHealthChecking {
    let health: RunProfileManager.Health

    func check(_ url: URL) async -> RunProfileManager.Health {
        health
    }
}

private final class FakeRunProcessHandle: RunProcessHandle, @unchecked Sendable {
    private(set) var didTerminate = false

    func terminate() {
        didTerminate = true
    }
}

private struct FakeRunProcessManager: RunProcessManaging {
    let outputs: [RunProcessOutput]
    let exitCode: Int32?

    func start(
        command: String,
        cwd: String,
        environment: [String: String]?,
        onOutput: @escaping @Sendable (RunProcessOutput) -> Void,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> RunProcessHandle {
        let handle = FakeRunProcessHandle()
        Task {
            for output in outputs {
                onOutput(output)
            }
            onExit(exitCode)
        }
        return handle
    }
}
