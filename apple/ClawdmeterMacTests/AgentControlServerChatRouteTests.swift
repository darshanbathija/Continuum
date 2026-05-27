import Foundation
import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class AgentControlServerChatRouteTests: XCTestCase {
    private var tempDir: URL!
    private var server: AgentControlServer!
    private var registry: AgentSessionRegistry!
    private var tmux: TmuxControlClient!

    override func setUp() async throws {
        try await super.setUp()

        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdmeter-chat-route-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sessionsURL = tempDir.appendingPathComponent("sessions.json")
        registry = AgentSessionRegistry(storeURL: sessionsURL)
        tmux = TmuxControlClient(configuration: .init(socketName: "clawdmeter-test-\(UUID().uuidString)"))

        let resolver = SessionFileResolver(
            codexSessionsRoot: tempDir.appendingPathComponent("codex-sessions", isDirectory: true),
            geminiTmpRoot: tempDir.appendingPathComponent("gemini-tmp", isDirectory: true),
            resolveClaudeURL: { _ in nil }
        )
        let chatRegistry = DaemonChatStoreRegistry(resolveURL: { _, _ in nil })
        let workspaceStore = WorkspaceStore(
            storeURL: tempDir.appendingPathComponent("workspaces.json"),
            sessionsURL: sessionsURL
        )
        let portBase = UInt16(Int.random(in: 30_000...60_000))

        server = AgentControlServer(
            repoIndex: RepoIndex(),
            registry: registry,
            tmux: tmux,
            notifications: NotificationDispatcher(),
            chatStoreRegistry: chatRegistry,
            chatFileResolver: resolver,
            workspaceStore: workspaceStore,
            mobileCommandOutbox: MobileCommandOutbox(),
            listenPortRange: portBase...(portBase + 20),
            writesServerMetadata: false
        )
        server.start()
        XCTAssertNotNil(server.boundPort, "test AgentControlServer must bind an HTTP port")
    }

    override func tearDown() async throws {
        await ChatProviderProbe.shared.clearAuthOverride(providerKey: "cursor")
        await ChatProviderProbe.shared.clearAuthOverride(providerKey: "opencode")
        await ChatProviderProbe.shared.invalidate()
        await CursorModelProbe.shared.invalidate()
        await OpenRouterModelProbe.shared.invalidate()

        server?.stop()
        await tmux?.stop()
        OpencodeProcessManager.shared.stop()

        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func test_oneVendorPostChatSessions_createsSoloChatSession() async throws {
        let request = CreateChatSessionRequest(
            provider: .codex,
            model: "gpt-5.5",
            effort: .high,
            codexChatBackend: .sdk,
            chatVendor: .chatgpt
        )

        let response = try await postJSON("/chat-sessions", request)

        XCTAssertEqual(response.status, 200)
        let session = try decode(AgentSession.self, from: response.data)
        XCTAssertEqual(session.kind, .chat)
        XCTAssertEqual(session.agent, .codex)
        XCTAssertEqual(session.model, "gpt-5.5")
        XCTAssertEqual(session.effort, .high)
        XCTAssertEqual(session.codexChatBackend, .sdk)
        XCTAssertNil(session.frontierGroupId)
        XCTAssertNil(session.frontierChildIndex)
        XCTAssertEqual(session.runtimeBinding?.metadata["chatVendor"], ChatVendor.chatgpt.rawValue)
        XCTAssertEqual(registry.session(id: session.id)?.id, session.id)

        _ = try? await requestRaw(path: "/sessions/\(session.id.uuidString)", method: "DELETE")
    }

    func test_lifecycleRouteAndClientReturnSnapshot() async throws {
        let session = try await registry.create(
            repoKey: tempDir.path,
            repoDisplayName: "Route Test",
            agent: .claude,
            model: "sonnet",
            goal: "Verify lifecycle route",
            worktreePath: tempDir.path,
            tmuxWindowId: "@test",
            tmuxPaneId: "%test",
            planMode: true,
            mode: .worktree
        )
        try await registry.setPlanText(id: session.id, planText: "1. Verify route")

        let raw = try await requestRaw(path: "/sessions/\(session.id.uuidString)/lifecycle", method: "GET")
        XCTAssertEqual(raw.status, 200)
        let response = try decode(SessionLifecycleSnapshotResponse.self, from: raw.data)
        XCTAssertEqual(response.snapshot.sessionId, session.id)
        XCTAssertEqual(response.snapshot.phase, .awaitingApproval)
        XCTAssertEqual(response.snapshot.nextAction?.kind, .approvePlan)

        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: Int(try XCTUnwrap(server.boundPort)),
            wsPort: Int(server.boundWsPort ?? 0),
            token: server.localLoopbackToken
        )
        let clientSnapshot = await client.fetchLifecycle(sessionId: session.id)
        XCTAssertEqual(clientSnapshot?.sessionId, session.id)
        XCTAssertEqual(clientSnapshot?.phase, .awaitingApproval)
    }

    func test_oneSlotFrontierRequest_isRejectedByActualRoute() async throws {
        let request = CreateFrontierRequest(
            clientRequestId: UUID(),
            models: [
                FrontierModelSlot(
                    provider: .codex,
                    model: "gpt-5.5",
                    effort: .high,
                    codexChatBackend: .sdk,
                    chatVendor: .chatgpt
                )
            ]
        )

        let response = try await postJSON("/chat-sessions/frontier", request)

        XCTAssertEqual(response.status, 400)
        let object = try XCTUnwrap(jsonObject(response.data))
        XCTAssertEqual(object["error"] as? String, "frontier_slot_count")
        XCTAssertTrue(registry.sessions.isEmpty)
    }

    func test_chatRouteRejectsMismatchedVendorMetadata() async throws {
        let response = try await postJSON(
            "/chat-sessions",
            CreateChatSessionRequest(
                provider: .claude,
                model: "claude-sonnet-4-6",
                chatVendor: .openrouter
            )
        )

        XCTAssertEqual(response.status, 400)
        let object = try XCTUnwrap(jsonObject(response.data))
        XCTAssertEqual(object["error"] as? String, "invalid_chat_runtime_metadata")
        XCTAssertEqual(object["reason"] as? String, "chatVendor does not match provider")
        XCTAssertTrue(registry.sessions.isEmpty)
    }

    func test_chatRouteRejectsClientSuppliedWrongBillingProvider() async throws {
        let response = try await postJSON(
            "/chat-sessions",
            CreateChatSessionRequest(
                provider: .opencode,
                model: "openai/gpt-5.5",
                chatVendor: .openrouter,
                billingProvider: "opencode"
            )
        )

        XCTAssertEqual(response.status, 400)
        let object = try XCTUnwrap(jsonObject(response.data))
        XCTAssertEqual(object["error"] as? String, "invalid_chat_runtime_metadata")
        XCTAssertEqual(object["reason"] as? String, "billingProvider must be derived by the server for the selected chatVendor")
        XCTAssertTrue(registry.sessions.isEmpty)
    }

    func test_frontierRouteAppliesOpenRouterAvailabilityGate() async throws {
        await ChatProviderProbe.shared.setAuthOverride(
            providerKey: "opencode",
            authenticated: false,
            reason: "openrouter auth missing test"
        )

        let response = try await postJSON(
            "/chat-sessions/frontier",
            CreateFrontierRequest(
                clientRequestId: UUID(),
                models: [
                    FrontierModelSlot(
                        provider: .codex,
                        model: "gpt-5.5",
                        effort: .high,
                        codexChatBackend: .sdk,
                        chatVendor: .chatgpt
                    ),
                    FrontierModelSlot(
                        provider: .opencode,
                        model: "openai/gpt-5.5",
                        effort: .high,
                        chatVendor: .openrouter,
                        billingProvider: "openrouter"
                    )
                ]
            )
        )

        XCTAssertEqual(response.status, 201)
        let frontier = try decode(CreateFrontierResponse.self, from: response.data)
        XCTAssertEqual(frontier.slots.count, 2)
        XCTAssertNotNil(frontier.slots[0].sessionId)
        XCTAssertNil(frontier.slots[0].reason)
        XCTAssertNil(frontier.slots[1].sessionId)
        XCTAssertEqual(frontier.slots[1].reason, "openrouter auth missing test")
        XCTAssertEqual(registry.sessions.count, 1)
        XCTAssertEqual(registry.sessions.first?.runtimeBinding?.metadata["chatVendor"], ChatVendor.chatgpt.rawValue)
        if let sessionId = frontier.slots[0].sessionId {
            _ = try? await requestRaw(path: "/sessions/\(sessionId.uuidString)", method: "DELETE")
        }
    }

    func test_openRouterModelProbeMapsReasoningSupportFromSupportedParameters() throws {
        let data = Data("""
        {
          "data": [
            {
              "id": "anthropic/claude-sonnet-4.6",
              "name": "Claude Sonnet 4.6",
              "context_length": 200000,
              "supported_parameters": ["temperature", "reasoning", "include_reasoning"]
            },
            {
              "id": "openai/gpt-5.5",
              "name": "GPT-5.5",
              "context_length": 400000,
              "supported_parameters": ["temperature", "top_p"]
            }
          ]
        }
        """.utf8)

        let models = try OpenRouterModelProbe.parseModelsResponse(data)

        XCTAssertEqual(models.first?.id, "openai/gpt-5.5")
        let claude = try XCTUnwrap(models.first(where: { $0.id == "anthropic/claude-sonnet-4.6" }))
        XCTAssertEqual(claude.displayName, "OpenRouter · Claude Sonnet 4.6")
        XCTAssertEqual(claude.contextWindow, 200_000)
        XCTAssertTrue(claude.supportsThinking)
        XCTAssertTrue(claude.supportsEffort)
        let gpt = try XCTUnwrap(models.first(where: { $0.id == "openai/gpt-5.5" }))
        XCTAssertFalse(gpt.supportsThinking)
        XCTAssertFalse(gpt.supportsEffort)
    }

    func test_openRouterModelProbeDoesNotTreatVerbosityAsReasoningEffort() throws {
        let data = Data("""
        {
          "data": [
            {
              "id": "example/verbosity-only",
              "name": "Verbosity Only",
              "supported_parameters": ["temperature", "verbosity"]
            }
          ]
        }
        """.utf8)

        let models = try OpenRouterModelProbe.parseModelsResponse(data)
        let model = try XCTUnwrap(models.first(where: { $0.id == "example/verbosity-only" }))
        XCTAssertFalse(model.supportsThinking)
        XCTAssertFalse(model.supportsEffort)
    }

    func test_cursorRoute_returns503WhenProbeMarksUnavailable() async throws {
        await ChatProviderProbe.shared.setAuthOverride(
            providerKey: "cursor",
            authenticated: false,
            reason: "cursor auth missing test"
        )

        let response = try await postJSON(
            "/chat-sessions",
            CreateChatSessionRequest(
                provider: .cursor,
                model: CursorModelCatalog.autoModelId,
                chatVendor: .cursor
            )
        )

        XCTAssertEqual(response.status, 503)
        let object = try XCTUnwrap(jsonObject(response.data))
        XCTAssertEqual(object["error"] as? String, "chat_provider_unavailable")
        XCTAssertEqual(object["provider"] as? String, AgentKind.cursor.rawValue)
        XCTAssertEqual(object["reason"] as? String, "cursor auth missing test")
        XCTAssertTrue(registry.sessions.isEmpty)
    }

    func test_cursorRoute_createsSessionWhenProbePasses() async throws {
        try await requireLiveProviderRouteTests()
        let cursorRow = try await requireProviderProbe(.cursor)

        XCTAssertTrue(cursorRow.available)
        XCTAssertTrue(cursorRow.authenticated)
        XCTAssertTrue(cursorRow.capabilityProbePassed)

        let response = try await postJSON(
            "/chat-sessions",
            CreateChatSessionRequest(
                provider: .cursor,
                model: CursorModelCatalog.autoModelId,
                chatVendor: .cursor
            ),
            timeout: 20
        )

        XCTAssertEqual(response.status, 200)
        let session = try decode(AgentSession.self, from: response.data)
        XCTAssertEqual(session.kind, .chat)
        XCTAssertEqual(session.agent, .cursor)
        XCTAssertEqual(session.model, CursorModelCatalog.autoModelId)
        XCTAssertEqual(session.runtimeBinding?.runtimeKind, .cursorCLI)
        XCTAssertEqual(session.runtimeBinding?.metadata["chatVendor"], ChatVendor.cursor.rawValue)
        XCTAssertNotNil(session.tmuxPaneId)

        _ = try? await requestRaw(path: "/sessions/\(session.id.uuidString)", method: "DELETE", timeout: 20)
    }

    func test_openRouterRoute_returns503WhenProbeMarksUnavailable() async throws {
        await ChatProviderProbe.shared.setAuthOverride(
            providerKey: "opencode",
            authenticated: false,
            reason: "openrouter auth missing test"
        )

        let response = try await postJSON(
            "/chat-sessions",
            CreateChatSessionRequest(
                provider: .opencode,
                model: "openai/gpt-5.5",
                chatVendor: .openrouter,
                billingProvider: "openrouter"
            )
        )

        XCTAssertEqual(response.status, 503)
        let object = try XCTUnwrap(jsonObject(response.data))
        XCTAssertEqual(object["error"] as? String, "chat_provider_unavailable")
        XCTAssertEqual(object["provider"] as? String, AgentKind.opencode.rawValue)
        XCTAssertEqual(object["reason"] as? String, "openrouter auth missing test")
        XCTAssertTrue(registry.sessions.isEmpty)
    }

    func test_openRouterRoute_createsOpenCodeSessionAndLiveSendWhenAvailable() async throws {
        try await requireLiveProviderRouteTests()
        _ = try await requireProviderProbe(.opencode)

        let create = try await postJSON(
            "/chat-sessions",
            CreateChatSessionRequest(
                provider: .opencode,
                model: "openai/gpt-5.5",
                effort: .high,
                chatVendor: .openrouter,
                billingProvider: "openrouter"
            ),
            timeout: 30
        )

        XCTAssertEqual(create.status, 200)
        let session = try decode(AgentSession.self, from: create.data)
        XCTAssertEqual(session.kind, .chat)
        XCTAssertEqual(session.agent, .opencode)
        XCTAssertEqual(session.model, "openai/gpt-5.5")
        XCTAssertEqual(session.runtimeBinding?.runtimeKind, .opencodeServer)
        XCTAssertEqual(session.runtimeBinding?.providerModelId, "openai/gpt-5.5")
        XCTAssertEqual(session.runtimeBinding?.billingProvider, "openrouter")
        XCTAssertEqual(session.runtimeBinding?.metadata["chatVendor"], ChatVendor.openrouter.rawValue)

        let send = try await postJSON(
            "/sessions/\(session.id.uuidString)/send",
            SendPromptRequest(
                text: "Reply with exactly: ok",
                asFollowUp: false,
                idempotencyKey: "openrouter-live-\(UUID().uuidString)"
            ),
            timeout: 35
        )
        XCTAssertEqual(send.status, 200)
        let object = try XCTUnwrap(jsonObject(send.data))
        XCTAssertEqual(object["ok"] as? Bool, true)

        _ = try? await requestRaw(path: "/sessions/\(session.id.uuidString)", method: "DELETE", timeout: 20)
    }

    func test_liveCodeProviderSmoke_createsOwnedWorktreesWithoutPermissionPrompts() async throws {
        try requireLiveCodeProviderSmoke()

        let repo = try makeHomeSmokeRepo()
        var created: [AgentSession] = []
        var failures: [String] = []
        let workspacePrefix = WorktreeManager.defaultWorkspaceStorageRoot() + "/"

        for agent in [AgentKind.claude, .codex, .cursor, .opencode, .gemini] {
            do {
                let response = try await postJSON(
                    "/sessions",
                    NewSessionRequest(
                        repoKey: repo.path,
                        agent: agent,
                        goal: "Clawdmeter live \(agent.rawValue) smoke \(UUID().uuidString.prefix(8))",
                        useWorktree: true
                    ),
                    timeout: agent == .opencode ? 40 : 30
                )
                guard response.status == 200 else {
                    failures.append("\(agent.rawValue): HTTP \(response.status) \(bodySnippet(response.data))")
                    continue
                }

                let session = try decode(AgentSession.self, from: response.data)
                created.append(session)

                guard let worktreePath = session.worktreePath else {
                    failures.append("\(agent.rawValue): session did not record a worktreePath")
                    continue
                }
                XCTAssertTrue(
                    worktreePath.hasPrefix(workspacePrefix),
                    "\(agent.rawValue) worktree should live under \(workspacePrefix), got \(worktreePath)"
                )
                XCTAssertFalse(worktreePath.contains("/conductor/workspaces/"))
                XCTAssertFalse(worktreePath.contains("/.claude/worktrees/"))
                XCTAssertEqual(session.mode, .worktree)
                XCTAssertEqual(session.provisioning?.storageRoot, WorktreeManager.defaultWorkspaceStorageRoot())
                XCTAssertEqual(session.provisioning?.filesToCopy.mode, .allIgnored)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: (worktreePath as NSString).appendingPathComponent(".env.local")),
                    "\(agent.rawValue) did not copy ignored .env.local"
                )
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: (worktreePath as NSString).appendingPathComponent("node_modules/pkg/index.js")),
                    "\(agent.rawValue) did not copy ignored dependency directory"
                )
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: (worktreePath as NSString).appendingPathComponent("cache/empty")),
                    "\(agent.rawValue) did not copy ignored empty directory"
                )
                XCTAssertGreaterThan(
                    session.provisioning?.filesToCopy.copiedFileCount ?? 0,
                    0,
                    "\(agent.rawValue) did not report copied ignored files"
                )

                if let prompt = try await pendingPermissionPrompt(sessionId: session.id, timeout: 8) {
                    failures.append("\(agent.rawValue): permission prompt appeared: \(prompt.title)")
                }
            } catch {
                failures.append("\(agent.rawValue): \(error.localizedDescription)")
            }
        }

        for session in created.reversed() {
            _ = try? await requestRaw(path: "/sessions/\(session.id.uuidString)", method: "DELETE", timeout: 20)
        }
        try? FileManager.default.removeItem(at: repo)

        if !failures.isEmpty {
            XCTFail(failures.joined(separator: "\n"))
        }
    }

    private struct RawResponse {
        let status: Int
        let data: Data
    }

    private func postJSON<T: Encodable>(
        _ path: String,
        _ body: T,
        timeout: TimeInterval = 8
    ) async throws -> RawResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try await requestRaw(
            path: path,
            method: "POST",
            body: try encoder.encode(body),
            timeout: timeout
        )
    }

    private func requestRaw(
        path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval = 8
    ) async throws -> RawResponse {
        let port = try XCTUnwrap(server.boundPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(server.localLoopbackToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var lastError: Error?
        for attempt in 0..<20 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return RawResponse(status: status, data: data)
            } catch {
                lastError = error
                if attempt < 19 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func requireProviderProbe(_ provider: AgentKind) async throws -> ChatProviderEntry {
        await ChatProviderProbe.shared.clearAuthOverride(providerKey: ChatProviderProbe.providerKey(provider: provider, codexBackend: nil))
        await ChatProviderProbe.shared.invalidate()
        if provider == .cursor {
            await CursorModelProbe.shared.invalidate()
        }
        let response = await ChatProviderProbe.shared.currentProviders()
        let row = try XCTUnwrap(response.providers.first(where: { $0.provider == provider }))
        try XCTSkipUnless(
            row.available && row.authenticated && row.capabilityProbePassed,
            "\(provider.rawValue) provider probe unavailable: \(row.reason ?? "no reason")"
        )
        return row
    }

    private func requireLiveProviderRouteTests() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLAWDMETER_LIVE_PROVIDER_TESTS"] == "1"
                || liveProviderRouteSentinelExists(),
            "Set CLAWDMETER_LIVE_PROVIDER_TESTS=1 or create .context/run-live-provider-route-tests to run live provider route smoke tests"
        )
    }

    private func liveProviderRouteSentinelExists() -> Bool {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = url
                .appendingPathComponent(".context", isDirectory: true)
                .appendingPathComponent("run-live-provider-route-tests")
            if FileManager.default.fileExists(atPath: marker.path) {
                return true
            }
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                break
            }
            url = next
        }
        return false
    }

    private func requireLiveCodeProviderSmoke() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLAWDMETER_LIVE_PROVIDER_SMOKE"] == "1"
                || liveCodeProviderSmokeSentinelExists(),
            "Set CLAWDMETER_LIVE_PROVIDER_SMOKE=1 or create .context/run-live-code-provider-smoke to run live code-session provider smoke tests"
        )
    }

    private func liveCodeProviderSmokeSentinelExists() -> Bool {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = url
                .appendingPathComponent(".context", isDirectory: true)
                .appendingPathComponent("run-live-code-provider-smoke")
            if FileManager.default.fileExists(atPath: marker.path) {
                return true
            }
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                break
            }
            url = next
        }
        return false
    }

    private func makeHomeSmokeRepo() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Clawdmeter/smoke-sources", isDirectory: true)
        let repo = root.appendingPathComponent("live-provider-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init"], cwd: repo)
        try git(["config", "user.email", "tests@example.com"], cwd: repo)
        try git(["config", "user.name", "Clawdmeter Tests"], cwd: repo)
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try write(".env*\nnode_modules/\ncache/\n*.sqlite*\n", to: repo.appendingPathComponent(".gitignore"))
        try git(["add", "tracked.txt", ".gitignore"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)
        try write("SECRET=1\n", to: repo.appendingPathComponent(".env.local"))
        try write("module\n", to: repo.appendingPathComponent("node_modules/pkg/index.js"))
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("cache/empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("sqlite\n", to: repo.appendingPathComponent("dev.sqlite"))
        try write("wal\n", to: repo.appendingPathComponent("dev.sqlite-wal"))
        try write("shm\n", to: repo.appendingPathComponent("dev.sqlite-shm"))
        return repo
    }

    private func pendingPermissionPrompt(
        sessionId: UUID,
        timeout: TimeInterval
    ) async throws -> PendingPermissionPrompt? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await requestRaw(
                path: "/sessions/\(sessionId.uuidString)/chat-snapshot",
                method: "GET",
                timeout: 8
            )
            if response.status == 200 {
                let snapshot = try decode(WireChatSnapshot.self, from: response.data)
                if let prompt = snapshot.pendingPermissionPrompt {
                    return prompt
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func git(_ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = cwd
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "AgentControlServerChatRouteTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(out)\(err)"]
            )
        }
    }

    private func bodySnippet(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
        return String(text.prefix(300))
    }
}
