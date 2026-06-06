import XCTest
import WebKit
import ClawdmeterShared
import Darwin
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

    func test_browserCommentContextIncludesDetectedContextAndSanitizesControls() {
        let context = BrowserCommentContext(
            urlString: "http://localhost:5173/app",
            selector: "#save\nbutton",
            snippet: "Save\tchanges",
            comment: "button is hidden\non mobile"
        )
        let prompt = ComposerDraftPayload(browserComments: [context]).render()

        XCTAssertTrue(prompt.contains("[BROWSER COMMENT]"))
        XCTAssertTrue(prompt.contains("URL: http://localhost:5173/app"))
        XCTAssertTrue(prompt.contains("Selector: #save button"))
        XCTAssertTrue(prompt.contains("Snippet: Save changes"))
        XCTAssertTrue(prompt.contains("button is hidden\non mobile"))
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

        let context = BrowserCommentContext(
            urlString: url.absoluteString,
            selector: "#save",
            snippet: "Save",
            comment: "Button should submit the current draft"
        )
        let prompt = ComposerDraftPayload(browserComments: [context]).render()
        XCTAssertTrue(prompt.contains("[BROWSER COMMENT]"))
        XCTAssertTrue(prompt.contains("Selector: #save"))
        XCTAssertTrue(prompt.contains("Button should submit the current draft"))
    }

    func test_previewLaunchPolicyResolvesPackageScriptAndPortEnv() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"dev":"vite --host 127.0.0.1"}}"#.write(
            to: dir.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: dir.appendingPathComponent("pnpm-lock.yaml"))
        let sessionId = UUID()
        let session = agentSession(id: sessionId, cwd: dir.path)

        let command = PreviewLaunchPolicy.resolve(
            session: session,
            messages: [],
            persistedCommand: nil
        )

        XCTAssertEqual(command?.command, "pnpm run dev")
        XCTAssertEqual(command?.source, .packageScript)
        XCTAssertEqual(command?.environment["CONDUCTOR_WORKSPACE_PATH"], dir.path)
        XCTAssertEqual(command?.environment["CONDUCTOR_PORT_BASE"], "\(PreviewLaunchPolicy.portBase(for: sessionId))")
        XCTAssertEqual(command?.environment["CONDUCTOR_PORT_END"], "\(PreviewLaunchPolicy.portBase(for: sessionId) + PreviewLaunchPolicy.portRangeSize - 1)")
        XCTAssertEqual(command?.environment["CONDUCTOR_PORT"], "\(PreviewLaunchPolicy.portBase(for: sessionId))")
        XCTAssertEqual(command?.expectedURL?.absoluteString, "http://localhost:\(PreviewLaunchPolicy.portBase(for: sessionId))")
    }

    func test_previewLaunchPolicyFirstAvailablePortSkipsBusyBase() throws {
        let portBase = try firstTwoPortWindow()
        let socket = try XCTUnwrap(BoundTestSocket(port: portBase))
        XCTAssertEqual(PreviewLaunchPolicy.firstAvailablePort(startingAt: portBase), portBase + 1)
        _ = socket
    }

    func test_previewLaunchPolicyPrefersConductorRunAndSetup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-conductor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"setup":"npm install","run":"npm run dev"}}"#.write(
            to: dir.appendingPathComponent("conductor.json"),
            atomically: true,
            encoding: .utf8
        )
        let session = agentSession(id: UUID(), cwd: dir.path)

        let command = PreviewLaunchPolicy.resolve(
            session: session,
            messages: [],
            persistedCommand: "pnpm run dev"
        )

        XCTAssertEqual(command?.command, "npm run dev")
        XCTAssertEqual(command?.setupScript, "npm install")
        XCTAssertEqual(command?.source, .conductor)
        XCTAssertNotNil(command?.setupFingerprint)
    }

    func test_previewLaunchPolicyReuseRequiresAssignedPortRange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"run":"npm run dev"}}"#.write(
            to: dir.appendingPathComponent("conductor.json"),
            atomically: true,
            encoding: .utf8
        )
        let session = agentSession(id: UUID(), cwd: dir.path)
        let launch = try XCTUnwrap(PreviewLaunchPolicy.resolve(
            session: session,
            messages: [],
            persistedCommand: nil
        ))
        let portBase = PreviewLaunchPolicy.portBase(for: session.id)

        XCTAssertTrue(PreviewLaunchPolicy.shouldReuse(
            requested: launch,
            currentCommand: "npm run dev",
            currentCwd: dir.path,
            currentURL: URL(string: "http://localhost:\(portBase + 3)"),
            currentHealth: .healthy(statusCode: 200),
            currentStatus: .running,
            sessionCwd: dir.path
        ))
        XCTAssertFalse(PreviewLaunchPolicy.shouldReuse(
            requested: launch,
            currentCommand: "npm run dev",
            currentCwd: dir.path,
            currentURL: URL(string: "http://localhost:\(portBase + 10)"),
            currentHealth: .healthy(statusCode: 200),
            currentStatus: .running,
            sessionCwd: dir.path
        ))
    }

    func test_launchPreviewDoesNotOpenStaleHealthyURLFromAnotherCwd() async throws {
        let oldDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-old-\(UUID().uuidString)", isDirectory: true)
        let newDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: oldDir)
            try? FileManager.default.removeItem(at: newDir)
        }

        let sessionId = UUID()
        let portBase = PreviewLaunchPolicy.portBase(for: sessionId)
        let staleURL = URL(string: "http://localhost:\(portBase + 3)")!
        try #"{"scripts":{"run":"npm run dev"}}"#.write(
            to: newDir.appendingPathComponent("conductor.json"),
            atomically: true,
            encoding: .utf8
        )

        let processManager = NonExitingRunProcessManager(outputs: [.stdout("ready at \(staleURL.absoluteString)\n")])
        let manager = RunProfileManager(
            sessionId: sessionId,
            chatStore: nil,
            healthChecker: StaticHealthChecker(health: .healthy(statusCode: 200)),
            processManager: processManager
        )
        manager.startRun(command: "npm run old", cwd: oldDir.path)
        let detectedStaleURL = await eventually(timeout: 2) {
            manager.snapshot?.url == staleURL && manager.status == .running
        }
        XCTAssertTrue(detectedStaleURL)

        let previewURL = await manager.launchPreview(session: agentSession(id: sessionId, cwd: newDir.path))

        XCTAssertNotEqual(previewURL, staleURL)
        XCTAssertEqual(previewURL?.absoluteString, "http://localhost:\(portBase)")
        XCTAssertEqual(processManager.starts.map(\.cwd), [oldDir.path, newDir.path])
        XCTAssertEqual(processManager.starts.last?.command, "npm run dev")
    }

    func test_launchPreviewStopsWhenSetupFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-setup-fails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"setup":"echo setup failed >&2; exit 7","run":"echo should-not-start"}}"#.write(
            to: dir.appendingPathComponent("conductor.json"),
            atomically: true,
            encoding: .utf8
        )
        let processManager = RecordingRunProcessManager(outputs: [], exitCode: 0)
        let manager = RunProfileManager(
            sessionId: UUID(),
            chatStore: nil,
            healthChecker: StaticHealthChecker(health: .healthy(statusCode: 200)),
            processManager: processManager
        )

        let url = await manager.launchPreview(session: agentSession(id: UUID(), cwd: dir.path))

        XCTAssertNil(url)
        XCTAssertEqual(manager.previewState, .failed)
        XCTAssertEqual(manager.status, .failed)
        XCTAssertEqual(manager.lastError, "Setup exited with status 7.")
        XCTAssertEqual(manager.stderrLines, ["setup failed"])
        XCTAssertTrue(processManager.starts.isEmpty)
    }

    func test_launchPreviewPortConflictDoesNotOrphanRunningProcessState() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-port-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"run":"npm run dev"}}"#.write(
            to: dir.appendingPathComponent("conductor.json"),
            atomically: true,
            encoding: .utf8
        )
        let sessionId = UUID()
        let session = agentSession(id: sessionId, cwd: dir.path)
        let sockets = PreviewLaunchPolicy.portRange(startingAt: PreviewLaunchPolicy.portBase(for: sessionId))
            .compactMap { BoundTestSocket(port: $0) }
        defer { _ = sockets }
        XCTAssertNil(PreviewLaunchPolicy.firstAvailablePort(startingAt: PreviewLaunchPolicy.portBase(for: sessionId)))

        let processManager = NonExitingRunProcessManager(outputs: [])
        let manager = RunProfileManager(
            sessionId: sessionId,
            chatStore: nil,
            processManager: processManager
        )
        manager.startRun(command: "npm run dev", cwd: dir.path)
        XCTAssertEqual(manager.status, .running)

        let url = await manager.launchPreview(session: session)

        XCTAssertNil(url)
        XCTAssertEqual(manager.previewState, .failed)
        XCTAssertEqual(manager.status, .running)
        XCTAssertEqual(processManager.starts.count, 1)
        manager.stopRun()
        XCTAssertEqual(manager.status, .idle)
    }

    func test_runExitClearsStalePreviewState() async throws {
        let manager = RunProfileManager(
            sessionId: UUID(),
            chatStore: nil,
            processManager: RecordingRunProcessManager(outputs: [], exitCode: 0)
        )

        manager.startRun(command: "echo done", cwd: FileManager.default.temporaryDirectory.path)
        let exited = await eventually(timeout: 2) {
            manager.status == .exited
        }

        XCTAssertTrue(exited)
        XCTAssertEqual(manager.previewState, .idle)
    }

    func test_browserControllerStorePrunesClosedSessionControllers() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-controller-prune-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeSessionsModel(in: dir)
        let workbench = WorkbenchState(store: WorkbenchStateStore(storeURL: dir.appendingPathComponent("workbench.json")))
        let first = agentSession(id: UUID(), cwd: dir.appendingPathComponent("first").path)
        let second = agentSession(id: UUID(), cwd: dir.appendingPathComponent("second").path)
        let store = BrowserWorkspaceControllerStore()

        let firstController = store.controller(for: first, model: model, workbenchState: workbench)
        let secondController = store.controller(for: second, model: model, workbenchState: workbench)
        XCTAssertEqual(store.countForTesting, 2)

        store.prune(keeping: [second])

        XCTAssertEqual(store.countForTesting, 1)
        XCTAssertTrue(firstController.isShutdownForTesting)
        XCTAssertFalse(secondController.isShutdownForTesting)
    }

    func test_browserBridgePayloadIsBoundedBeforeDraftingComment() throws {
        let session = agentSession(id: UUID(), cwd: FileManager.default.temporaryDirectory.path)
        let controller = BrowserWorkspaceController(session: session, chatStore: nil, initialState: nil)
        let hugeStyle = Dictionary(uniqueKeysWithValues: (0..<80).map {
            ("style-key-\($0)", String(repeating: "x", count: 1_000))
        })
        let hugeClasses = (0..<80).map { "class-\($0)-" + String(repeating: "y", count: 200) }

        controller.receiveBridgePayloadForTesting([
            "eventType": String(repeating: "event", count: 40),
            "annotationId": String(repeating: "id", count: 100),
            "selector": String(repeating: "#selector", count: 100),
            "snippet": String(repeating: "snippet", count: 300),
            "nearbyText": String(repeating: "nearby", count: 400),
            "computedStyleSummary": hugeStyle,
            "cssClasses": hugeClasses
        ])

        let draft = try XCTUnwrap(controller.pendingComment)
        XCTAssertEqual(draft.eventType.count, 48)
        XCTAssertLessThanOrEqual(draft.selector.count, 300)
        XCTAssertLessThanOrEqual(draft.snippet.count, 1_000)
        XCTAssertLessThanOrEqual(draft.nearbyText?.count ?? 0, 1_500)
        XCTAssertLessThanOrEqual(draft.computedStyleSummary.count, 16)
        XCTAssertLessThanOrEqual(draft.computedStyleSummary.values.map(\.count).max() ?? 0, 160)
        XCTAssertLessThanOrEqual(draft.cssClasses.count, 12)
        XCTAssertLessThanOrEqual(draft.cssClasses.map(\.count).max() ?? 0, 80)
    }

    func test_codeRunProfileServiceSetupFingerprintIsSessionScoped() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-service-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"setup":"printf x >> setup-count.txt","run":"echo ready"}}"#.write(
            to: dir.appendingPathComponent("conductor.json"),
            atomically: true,
            encoding: .utf8
        )
        let service = CodeRunProfileService(processManager: FakeRunProcessManager(outputs: [], exitCode: 0))

        _ = await service.start(session: agentSession(id: UUID(), cwd: dir.path), command: nil, messages: [])
        _ = await service.start(session: agentSession(id: UUID(), cwd: dir.path), command: nil, messages: [])

        let count = try String(contentsOf: dir.appendingPathComponent("setup-count.txt"), encoding: .utf8)
        XCTAssertEqual(count, "xx")
    }

    func test_previewLaunchControllerRunsSetupOncePerSessionCwdAndFingerprint() async throws {
        let firstDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-controller-a-\(UUID().uuidString)", isDirectory: true)
        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-controller-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }
        for dir in [firstDir, secondDir] {
            try #"{"scripts":{"setup":"npm install","run":"npm run dev"}}"#.write(
                to: dir.appendingPathComponent("conductor.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        let controller = PreviewLaunchController()
        let sessionId = UUID()
        var setupCwds: [String] = []
        var stateChanges: [PreviewLaunchState] = []
        let current = PreviewCurrentRunSnapshot(command: nil, cwd: nil, url: nil, isRunning: false, isHealthy: false)

        _ = await controller.prepare(
            session: agentSession(id: sessionId, cwd: firstDir.path),
            messages: [],
            persistedCommand: nil,
            current: current,
            forceRestart: false,
            runSetup: { _, cwd, _ in
                setupCwds.append(cwd)
                return PreviewSetupResult(succeeded: true, message: nil)
            },
            onStateChange: { stateChanges.append($0) }
        )
        _ = await controller.prepare(
            session: agentSession(id: sessionId, cwd: firstDir.path),
            messages: [],
            persistedCommand: nil,
            current: current,
            forceRestart: false,
            runSetup: { _, cwd, _ in
                setupCwds.append(cwd)
                return PreviewSetupResult(succeeded: true, message: nil)
            },
            onStateChange: { stateChanges.append($0) }
        )
        _ = await controller.prepare(
            session: agentSession(id: sessionId, cwd: secondDir.path),
            messages: [],
            persistedCommand: nil,
            current: current,
            forceRestart: false,
            runSetup: { _, cwd, _ in
                setupCwds.append(cwd)
                return PreviewSetupResult(succeeded: true, message: nil)
            },
            onStateChange: { stateChanges.append($0) }
        )

        XCTAssertEqual(setupCwds, [firstDir.path, secondDir.path])
        XCTAssertEqual(stateChanges, [.settingUp, .settingUp])
    }

    func test_desktopAndCodeRunProfileServiceUseEquivalentLaunchPolicy() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"run":"npm run dev"}}"#.write(
            to: dir.appendingPathComponent("conductor.json"),
            atomically: true,
            encoding: .utf8
        )
        let session = agentSession(id: UUID(), cwd: dir.path)
        let desktopProcess = RecordingRunProcessManager(outputs: [], exitCode: nil)
        let manager = RunProfileManager(
            sessionId: session.id,
            chatStore: nil,
            healthChecker: StaticHealthChecker(health: .unknown),
            processManager: desktopProcess
        )
        let serviceProcess = RecordingRunProcessManager(outputs: [], exitCode: nil)
        let service = CodeRunProfileService(processManager: serviceProcess)

        let desktopURL = await manager.launchPreview(session: session)
        let serviceSnapshot = await service.start(session: session, command: nil, messages: [])

        let desktopStart = try XCTUnwrap(desktopProcess.starts.first)
        let serviceStart = try XCTUnwrap(serviceProcess.starts.first)
        XCTAssertEqual(desktopStart.command, serviceStart.command)
        XCTAssertEqual(desktopStart.cwd, serviceStart.cwd)
        XCTAssertEqual(desktopStart.environment?["CONDUCTOR_WORKSPACE_PATH"], serviceStart.environment?["CONDUCTOR_WORKSPACE_PATH"])
        XCTAssertEqual(desktopStart.environment?["CONDUCTOR_PORT_BASE"], serviceStart.environment?["CONDUCTOR_PORT_BASE"])
        XCTAssertEqual(desktopStart.environment?["CONDUCTOR_PORT_END"], serviceStart.environment?["CONDUCTOR_PORT_END"])
        XCTAssertEqual(desktopURL?.absoluteString, serviceSnapshot.detectedURL)
    }

    func test_wkCommentBridgePostsSelectorAndSnippetFromCommandClick() async throws {
        let (webView, userContent, bridge) = makeBridgeWebView(description: "bridge posts selected element")
        await loadHTML(try browserFixtureHTML(), in: webView)

        _ = try await webView.evaluateJavaScript("""
        document.getElementById('primary-save').dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true,
          metaKey: true
        }));
        """)
        await fulfillment(of: [bridge.expectation], timeout: 3)

        let body = try XCTUnwrap(bridge.body as? [String: Any])
        XCTAssertEqual(body["selector"] as? String, "#primary-save")
        XCTAssertEqual(body["snippet"] as? String, "Save Draft")
        XCTAssertEqual(body["eventType"] as? String, "click")
        XCTAssertEqual(body["accessibilityLabel"] as? String, "Save primary draft")
        XCTAssertEqual(body["sourceHint"] as? String, "src/components/Toolbar.tsx:18")
        XCTAssertNotNil(body["annotationId"] as? String)
        XCTAssertEqual(body["cssClasses"] as? [String], ["primary-action", "hot"])
        let style = try XCTUnwrap(body["computedStyleSummary"] as? [String: Any])
        XCTAssertNotNil(style["display"])
        userContent.removeScriptMessageHandler(forName: "clawdmeterComment")
        webView.navigationDelegate = nil
    }

    func test_wkCommentBridgePostsTextSelectionAndAreaSelection() async throws {
        let (webView, userContent, bridge) = makeBridgeWebView(
            description: "bridge posts text and area selections",
            expectedFulfillmentCount: 2
        )
        await loadHTML(try browserFixtureHTML(), in: webView)

        _ = try await webView.evaluateJavaScript("""
        const copyElement = document.getElementById('selectable-copy');
        const copy = Array.from(copyElement.childNodes).find((node) =>
          node.nodeType === Node.TEXT_NODE && node.textContent.includes('Select this')
        );
        const start = copy.textContent.indexOf('Select this');
        const range = document.createRange();
        range.setStart(copy, start);
        range.setEnd(copy, start + 11);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        copyElement.dispatchEvent(new MouseEvent('mouseup', {
          bubbles: true,
          cancelable: true
        }));
        const rect = document.getElementById('area-primary').getBoundingClientRect();
        document.dispatchEvent(new MouseEvent('mousedown', {
          bubbles: true,
          cancelable: true,
          shiftKey: true,
          button: 0,
          clientX: rect.left - 8,
          clientY: rect.top - 8
        }));
        document.dispatchEvent(new MouseEvent('mouseup', {
          bubbles: true,
          cancelable: true,
          shiftKey: true,
          button: 0,
          clientX: rect.right + 8,
          clientY: rect.bottom + 8
        }));
        """)
        await fulfillment(of: [bridge.expectation], timeout: 3)

        let textBody = try XCTUnwrap(bridge.bodies.first as? [String: Any])
        XCTAssertEqual(textBody["eventType"] as? String, "textSelection")
        XCTAssertEqual(textBody["selectedText"] as? String, "Select this")
        let areaBody = try XCTUnwrap(bridge.bodies.last as? [String: Any])
        XCTAssertEqual(areaBody["eventType"] as? String, "areaSelect")
        XCTAssertTrue((areaBody["areaSelection"] as? String)?.contains("elements") == true)
        XCTAssertTrue((areaBody["selector"] as? String)?.contains("#area-primary") == true)
        userContent.removeScriptMessageHandler(forName: "clawdmeterComment")
        webView.navigationDelegate = nil
    }

    func test_wkCommentBridgePostsMultiSelectAndMarkerEditDelete() async throws {
        let (webView, userContent, bridge) = makeBridgeWebView(
            description: "bridge posts multi-select and marker actions",
            expectedFulfillmentCount: 4
        )
        await loadHTML(try browserFixtureHTML(), in: webView)

        _ = try await webView.evaluateJavaScript("""
        for (const id of ['multi-one', 'multi-two']) {
          document.getElementById(id).dispatchEvent(new MouseEvent('click', {
            bubbles: true,
            cancelable: true,
            metaKey: true,
            shiftKey: true
          }));
        }
        window.__clawdmeterBrowserOverlayTest.forceRender();
        document.querySelector('[data-clawdmeter-action="edit"]').dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true
        }));
        document.querySelector('[data-clawdmeter-action="delete"]').dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true
        }));
        """)
        await fulfillment(of: [bridge.expectation], timeout: 3)

        let second = try XCTUnwrap(bridge.bodies[1] as? [String: Any])
        XCTAssertEqual(second["eventType"] as? String, "multiSelect")
        XCTAssertEqual(second["selector"] as? String, "#multi-one, #multi-two")
        let edit = try XCTUnwrap(bridge.bodies[2] as? [String: Any])
        XCTAssertEqual(edit["eventType"] as? String, "markerEdit")
        XCTAssertEqual(edit["selector"] as? String, "#multi-one")
        XCTAssertEqual(edit["snippet"] as? String, "First row action")
        let editedAnnotationId = try XCTUnwrap(edit["annotationId"] as? String)
        let deleted = try XCTUnwrap(bridge.bodies[3] as? [String: Any])
        XCTAssertEqual(deleted["eventType"] as? String, "markerDeleted")
        XCTAssertEqual(deleted["annotationId"] as? String, editedAnnotationId)
        let markerCount = try await webView.evaluateJavaScript("window.__clawdmeterBrowserOverlayTest.markerCount()") as? Int
        XCTAssertEqual(markerCount, 1)
        userContent.removeScriptMessageHandler(forName: "clawdmeterComment")
        webView.navigationDelegate = nil
    }

    func test_wkMarkersSurviveReloadAndShadowSelectorsResolve() async throws {
        let (webView, userContent, bridge) = makeBridgeWebView(description: "bridge posts initial marker")
        let html = try browserFixtureHTML()
        await loadHTML(html, in: webView)

        _ = try await webView.evaluateJavaScript("""
        document.getElementById('primary-save').dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true,
          metaKey: true
        }));
        """)
        await fulfillment(of: [bridge.expectation], timeout: 3)
        let beforeReloadCount = try await webView.evaluateJavaScript("window.__clawdmeterBrowserOverlayTest.markerCount()") as? Int
        XCTAssertEqual(beforeReloadCount, 1)

        await loadHTML(html, in: webView)
        _ = try await webView.evaluateJavaScript("window.__clawdmeterBrowserOverlayTest.forceRender()")
        let afterReloadCount = try await webView.evaluateJavaScript("window.__clawdmeterBrowserOverlayTest.markerCount()") as? Int
        XCTAssertEqual(afterReloadCount, 1)

        let shadowSelector = try await webView.evaluateJavaScript("""
        const inner = document.getElementById('shadow-host').shadowRoot.getElementById('shadow-save');
        window.__clawdmeterBrowserOverlayTest.selectorFor(inner);
        """) as? String
        XCTAssertEqual(shadowSelector, "#shadow-host >>> #shadow-save")
        let canResolve = try await webView.evaluateJavaScript("""
        window.__clawdmeterBrowserOverlayTest.canResolveSelector('#shadow-host >>> #shadow-save');
        """) as? Bool
        XCTAssertEqual(canResolve, true)
        userContent.removeScriptMessageHandler(forName: "clawdmeterComment")
        webView.navigationDelegate = nil
    }

    func test_browserControllerStagesFixtureElementCommentIntoComposerChip() async throws {
        let session = agentSession(id: UUID(), cwd: FileManager.default.temporaryDirectory.path)
        let controller = BrowserWorkspaceController(session: session, chatStore: nil, initialState: nil)
        defer { controller.shutdown() }
        await loadHTML(try browserFixtureHTML(), in: controller.webView)
        controller.loadedURL = URL(string: "http://127.0.0.1/preview-fixture")

        _ = try await controller.webView.evaluateJavaScript("""
        document.getElementById('primary-save').dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true,
          metaKey: true
        }));
        """)
        let didReceivePendingComment = await eventually(timeout: 3) {
            controller.pendingComment?.selector == "#primary-save"
        }
        XCTAssertTrue(didReceivePendingComment)

        let pending = try XCTUnwrap(controller.pendingComment)
        XCTAssertEqual(pending.eventType, "click")
        XCTAssertEqual(pending.snippet, "Save Draft")
        XCTAssertEqual(pending.accessibilityLabel, "Save primary draft")
        XCTAssertEqual(pending.sourceHint, "src/components/Toolbar.tsx:18")
        XCTAssertEqual(pending.cssClasses, ["primary-action", "hot"])
        XCTAssertGreaterThan(pending.boundingBox?.width ?? 0, 0)

        let store = ComposerStore(mode: .bound(sessionId: session.id))
        controller.commentText = "Clarify save button label"
        controller.stagePendingComment(into: store)

        XCTAssertNil(controller.pendingComment)
        XCTAssertEqual(controller.commentText, "")
        XCTAssertEqual(store.browserComments.count, 1)
        let comment = try XCTUnwrap(store.browserComments.first)
        XCTAssertEqual(comment.chipLabel, "Comment: Clarify save button label")
        XCTAssertEqual(comment.selector, "#primary-save")
        XCTAssertEqual(comment.snippet, "Save Draft")

        let prompt = store.renderPromptBody(attachmentPaths: [])
        XCTAssertTrue(prompt.contains("# Browser context"))
        XCTAssertTrue(prompt.contains("[BROWSER COMMENT]"))
        XCTAssertTrue(prompt.contains("Summary: Clarify save button label"))
        XCTAssertTrue(prompt.contains("URL: http://127.0.0.1/preview-fixture"))
        XCTAssertTrue(prompt.contains("Selector: #primary-save"))
        XCTAssertTrue(prompt.contains("Accessibility: Save primary draft"))
        XCTAssertTrue(prompt.contains("Source hint: src/components/Toolbar.tsx:18"))
        XCTAssertTrue(prompt.contains("Snippet: Save Draft"))
        XCTAssertTrue(prompt.contains("User comment:\nClarify save button label"))

        store.removeBrowserComment(id: comment.id)
        XCTAssertTrue(store.browserComments.isEmpty)
        XCTAssertFalse(store.canSend)
    }

    func test_browserControllerStagesMarkerEditCommentIntoComposerChip() async throws {
        let session = agentSession(id: UUID(), cwd: FileManager.default.temporaryDirectory.path)
        let controller = BrowserWorkspaceController(session: session, chatStore: nil, initialState: nil)
        defer { controller.shutdown() }
        await loadHTML(try browserFixtureHTML(), in: controller.webView)
        controller.loadedURL = URL(string: "http://127.0.0.1/preview-fixture")

        _ = try await controller.webView.evaluateJavaScript("""
        document.getElementById('primary-save').dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true,
          metaKey: true
        }));
        """)
        let didCreateMarker = await eventually(timeout: 3) {
            controller.pendingComment?.eventType == "click"
                && controller.pendingComment?.selector == "#primary-save"
        }
        XCTAssertTrue(didCreateMarker)
        let createdMarker = try XCTUnwrap(controller.pendingComment)
        let annotationId = try XCTUnwrap(createdMarker.annotationId)
        controller.pendingComment = nil

        _ = try await controller.webView.evaluateJavaScript("""
        window.__clawdmeterBrowserOverlayTest.forceRender();
        document.querySelector('[data-clawdmeter-action="edit"]').dispatchEvent(new MouseEvent('click', {
          bubbles: true,
          cancelable: true
        }));
        """)
        let didReceiveEditDraft = await eventually(timeout: 3) {
            controller.pendingComment?.eventType == "markerEdit"
                && controller.pendingComment?.annotationId == annotationId
                && controller.pendingComment?.selector == "#primary-save"
        }
        XCTAssertTrue(didReceiveEditDraft)

        let editDraft = try XCTUnwrap(controller.pendingComment)
        XCTAssertEqual(editDraft.snippet, "Save Draft")
        XCTAssertEqual(editDraft.accessibilityLabel, "Save primary draft")
        XCTAssertEqual(editDraft.sourceHint, "src/components/Toolbar.tsx:18")
        XCTAssertGreaterThan(editDraft.boundingBox?.width ?? 0, 0)

        let store = ComposerStore(mode: .bound(sessionId: session.id))
        controller.commentText = "Tune edit flow label"
        controller.stagePendingComment(into: store)

        XCTAssertNil(controller.pendingComment)
        XCTAssertEqual(store.browserComments.count, 1)
        let comment = try XCTUnwrap(store.browserComments.first)
        XCTAssertEqual(comment.annotationId, annotationId)
        XCTAssertEqual(comment.chipLabel, "Comment: Tune edit flow label")
        XCTAssertEqual(comment.selector, "#primary-save")
        XCTAssertEqual(comment.snippet, "Save Draft")

        let prompt = store.renderPromptBody(attachmentPaths: [])
        XCTAssertTrue(prompt.contains("Summary: Tune edit flow label"))
        XCTAssertTrue(prompt.contains("Selector: #primary-save"))
        XCTAssertTrue(prompt.contains("User comment:\nTune edit flow label"))

        store.removeBrowserComment(id: comment.id)
        XCTAssertFalse(store.canSend)
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

    private func makeSessionsModel(in dir: URL) -> SessionsModel {
        let sessionsURL = dir.appendingPathComponent("sessions.json")
        let registry = AgentSessionRegistry(storeURL: sessionsURL)
        let workspaceStore = WorkspaceStore(
            storeURL: dir.appendingPathComponent("workspaces.json"),
            sessionsURL: sessionsURL
        )
        return SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: workspaceStore
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

    private func firstTwoPortWindow() throws -> Int {
        for port in 24_000..<30_000 {
            if PreviewLaunchPolicy.isPortAvailable(port),
               PreviewLaunchPolicy.isPortAvailable(port + 1) {
                return port
            }
        }
        throw XCTSkip("No two-port preview test window was available")
    }

    private func makeBridgeWebView(
        description: String,
        expectedFulfillmentCount: Int = 1
    ) -> (WKWebView, WKUserContentController, TestBridgeHandler) {
        let userContent = WKUserContentController()
        let bridgeExpectation = expectation(description: description)
        bridgeExpectation.expectedFulfillmentCount = expectedFulfillmentCount
        let bridge = TestBridgeHandler(expectation: bridgeExpectation)
        userContent.add(bridge, name: "clawdmeterComment")
        userContent.addUserScript(WKUserScript(
            source: InAppBrowser.commentBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        return (webView, userContent, bridge)
    }

    private func browserFixtureHTML(_ name: String = "browser-comment-selector-fixture.html") throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let loadExpectation = expectation(description: "html loads")
        let navigation = TestNavigationDelegate(expectation: loadExpectation)
        webView.navigationDelegate = navigation
        webView.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1/preview"))
        await fulfillment(of: [loadExpectation], timeout: 8)
        try? await Task.sleep(nanoseconds: 60_000_000)
    }
}

private final class TestBridgeHandler: NSObject, WKScriptMessageHandler {
    let expectation: XCTestExpectation
    private(set) var bodies: [Any] = []
    var body: Any?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        body = message.body
        bodies.append(message.body)
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

private final class RecordingRunProcessManager: RunProcessManaging, @unchecked Sendable {
    private(set) var starts: [(command: String, cwd: String, environment: [String: String]?)] = []
    let outputs: [RunProcessOutput]
    let exitCode: Int32?

    init(outputs: [RunProcessOutput], exitCode: Int32?) {
        self.outputs = outputs
        self.exitCode = exitCode
    }

    func start(
        command: String,
        cwd: String,
        environment: [String: String]?,
        onOutput: @escaping @Sendable (RunProcessOutput) -> Void,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> RunProcessHandle {
        starts.append((command, cwd, environment))
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

private final class NonExitingRunProcessManager: RunProcessManaging, @unchecked Sendable {
    private(set) var starts: [(command: String, cwd: String, environment: [String: String]?)] = []
    let outputs: [RunProcessOutput]

    init(outputs: [RunProcessOutput]) {
        self.outputs = outputs
    }

    func start(
        command: String,
        cwd: String,
        environment: [String: String]?,
        onOutput: @escaping @Sendable (RunProcessOutput) -> Void,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> RunProcessHandle {
        starts.append((command, cwd, environment))
        let handle = FakeRunProcessHandle()
        Task {
            for output in outputs {
                onOutput(output)
            }
        }
        _ = onExit
        return handle
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

private final class BoundTestSocket {
    private let fd: Int32

    init?(port: Int) {
        let socketFd = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFd >= 0 else { return nil }
        fd = socketFd

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }
    }

    deinit {
        close(fd)
    }
}
