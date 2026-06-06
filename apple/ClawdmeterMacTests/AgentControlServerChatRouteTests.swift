import Foundation
import Combine
import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class AgentControlServerChatRouteTests: XCTestCase {
    private var tempDir: URL!
    private var server: AgentControlServer!
    private var registry: AgentSessionRegistry!

    override func setUp() async throws {
        try await super.setUp()

        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdmeter-chat-route-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sessionsURL = tempDir.appendingPathComponent("sessions.json")
        registry = AgentSessionRegistry(storeURL: sessionsURL)

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
        OpencodeProcessManager.shared.stop()

        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func test_persistedCodexSDKChatSendReturnsRetired410() async throws {
        let session = try await registry.createChat(
            provider: .codex,
            model: "gpt-5.5",
            chatCwd: tempDir.path,
            codexChatBackend: .sdk,
            effort: .high,
            chatVendor: .chatgpt,
            billingProvider: "codex"
        )

        let response = try await postJSON(
            "/sessions/\(session.id.uuidString)/send",
            SendPromptRequest(text: "old sdk path", asFollowUp: false, idempotencyKey: UUID().uuidString)
        )

        XCTAssertEqual(response.status, 410)
        let object = try XCTUnwrap(jsonObject(response.data))
        XCTAssertEqual(object["error"] as? String, "legacy_session_retired")
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

    func test_sendToLegacyPaneBackedSessionReturnsRetired410() async throws {
        let session = try await registry.create(
            repoKey: tempDir.path,
            repoDisplayName: "Legacy",
            agent: .claude,
            model: "sonnet",
            goal: "Legacy pane",
            worktreePath: tempDir.path,
            tmuxWindowId: "@legacy",
            tmuxPaneId: "%legacy",
            planMode: false,
            mode: .worktree
        )

        let response = try await postJSON(
            "/sessions/\(session.id.uuidString)/send",
            SendPromptRequest(text: "should retire", asFollowUp: false, idempotencyKey: UUID().uuidString)
        )

        XCTAssertEqual(response.status, 410)
        let object = try XCTUnwrap(jsonObject(response.data))
        XCTAssertEqual(object["error"] as? String, "legacy_session_retired")
        XCTAssertNil(registry.session(id: session.id)?.customName)
    }

    func test_configAndReviveLegacyPaneBackedSessionsReturnRetired410() async throws {
        let effortSession = try await createLegacyPaneSession(goal: "Legacy effort")
        let effort = try await postJSON(
            "/sessions/\(effortSession.id.uuidString)/effort",
            ChangeEffortRequest(effort: .high, idempotencyKey: UUID().uuidString)
        )
        XCTAssertEqual(effort.status, 410)
        XCTAssertEqual(try XCTUnwrap(jsonObject(effort.data))["error"] as? String, "legacy_session_retired")

        let modeSession = try await createLegacyPaneSession(goal: "Legacy mode")
        let mode = try await postJSON(
            "/sessions/\(modeSession.id.uuidString)/mode",
            ChangeModeRequest(mode: .local, planMode: false, idempotencyKey: UUID().uuidString)
        )
        XCTAssertEqual(mode.status, 410)
        XCTAssertEqual(try XCTUnwrap(jsonObject(mode.data))["error"] as? String, "legacy_session_retired")

        let reviveSession = try await createLegacyPaneSession(goal: "Legacy revive")
        try await registry.updateStatus(id: reviveSession.id, status: .degraded)
        let revive = try await postJSON(
            "/sessions/\(reviveSession.id.uuidString)/revive",
            ReviveRequest(idempotencyKey: UUID().uuidString)
        )
        XCTAssertEqual(revive.status, 410)
        XCTAssertEqual(try XCTUnwrap(jsonObject(revive.data))["error"] as? String, "legacy_session_retired")
    }

    func test_remainingLegacyPaneBackedMutationsReturnRetired410() async throws {
        let modelSession = try await createLegacyPaneSession(goal: "Legacy model")
        let model = try await postJSON(
            "/sessions/\(modelSession.id.uuidString)/model",
            ChangeModelRequest(model: "claude-sonnet-4-6", effort: .medium, idempotencyKey: UUID().uuidString)
        )
        XCTAssertEqual(model.status, 410, bodySnippet(model.data))
        XCTAssertEqual(try XCTUnwrap(jsonObject(model.data))["error"] as? String, "legacy_session_retired")

        let interruptSession = try await createLegacyPaneSession(goal: "Legacy interrupt")
        let interrupt = try await requestRaw(
            path: "/sessions/\(interruptSession.id.uuidString)/interrupt",
            method: "POST"
        )
        XCTAssertEqual(interrupt.status, 410, bodySnippet(interrupt.data))
        XCTAssertEqual(try XCTUnwrap(jsonObject(interrupt.data))["error"] as? String, "legacy_session_retired")

        let approveSession = try await createLegacyPaneSession(goal: "Legacy approve")
        try await registry.updateStatus(id: approveSession.id, status: .planning)
        try await registry.setPlanText(id: approveSession.id, planText: "1. Legacy plan")
        let approve = try await requestRaw(
            path: "/sessions/\(approveSession.id.uuidString)/approve-plan",
            method: "POST"
        )
        XCTAssertEqual(approve.status, 410, bodySnippet(approve.data))
        XCTAssertEqual(try XCTUnwrap(jsonObject(approve.data))["error"] as? String, "legacy_session_retired")

        let terminalSession = try await createLegacyPaneSession(goal: "Legacy add terminal")
        let addTerminal = try await postJSON(
            "/sessions/\(terminalSession.id.uuidString)/terminals",
            ["title": "Ignored"]
        )
        XCTAssertEqual(addTerminal.status, 410, bodySnippet(addTerminal.data))
        XCTAssertEqual(try XCTUnwrap(jsonObject(addTerminal.data))["error"] as? String, "legacy_session_retired")
    }

    func test_terminalListOnLegacyPaneBackedSessionReturnsRetired410() async throws {
        let session = try await createLegacyPaneSession(goal: "Legacy terminal")

        let response = try await requestRaw(path: "/sessions/\(session.id.uuidString)/terminals", method: "GET")

        XCTAssertEqual(response.status, 410)
        XCTAssertEqual(try XCTUnwrap(jsonObject(response.data))["error"] as? String, "legacy_session_retired")
    }

    func test_terminalRenameAndDeleteOnLegacyPaneBackedSessionReturnRetired410() async throws {
        let session = try await createLegacyPaneSession(goal: "Legacy terminal mutation")
        let terminalRefId = UUID().uuidString

        let rename = try await requestRaw(
            path: "/sessions/\(session.id.uuidString)/terminals/\(terminalRefId)",
            method: "PATCH",
            body: try JSONEncoder().encode(["title": "Ignored"])
        )
        XCTAssertEqual(rename.status, 410)
        XCTAssertEqual(try XCTUnwrap(jsonObject(rename.data))["error"] as? String, "legacy_session_retired")

        let delete = try await requestRaw(
            path: "/sessions/\(session.id.uuidString)/terminals/\(terminalRefId)",
            method: "DELETE"
        )
        XCTAssertEqual(delete.status, 410)
        XCTAssertEqual(try XCTUnwrap(jsonObject(delete.data))["error"] as? String, "legacy_session_retired")
    }

    func test_addRenameDeleteDirectTerminalPaneRoutes() async throws {
        let session = try await registry.create(
            repoKey: tempDir.path,
            repoDisplayName: "Terminal",
            agent: .opencode,
            model: "opencode-default",
            goal: "Terminal pane",
            worktreePath: tempDir.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )

        let add = try await postJSON(
            "/sessions/\(session.id.uuidString)/terminals",
            ["title": "Logs"]
        )
        XCTAssertEqual(add.status, 200, bodySnippet(add.data))
        let pane = try decode(TerminalPaneRef.self, from: add.data)
        XCTAssertFalse(pane.isPrimary)

        let rename = try await requestRaw(
            path: "/sessions/\(session.id.uuidString)/terminals/\(pane.id.uuidString)",
            method: "PATCH",
            body: try JSONEncoder().encode(["title": "Build Logs"])
        )
        XCTAssertEqual(rename.status, 200, bodySnippet(rename.data))
        let renamed = try decode(TerminalPaneRef.self, from: rename.data)
        XCTAssertEqual(renamed.title, "Build Logs")

        let list = try await requestRaw(path: "/sessions/\(session.id.uuidString)/terminals", method: "GET")
        XCTAssertEqual(list.status, 200, bodySnippet(list.data))
        let panes = try decode([TerminalPaneRef].self, from: list.data)
        XCTAssertEqual(panes.count, 1)

        let delete = try await requestRaw(
            path: "/sessions/\(session.id.uuidString)/terminals/\(pane.id.uuidString)",
            method: "DELETE"
        )
        XCTAssertEqual(delete.status, 200, bodySnippet(delete.data))
    }

    func test_terminalAddOnHarnessSessionReturnsUnsupported() async throws {
        let session = try await registry.create(
            repoKey: tempDir.path,
            repoDisplayName: "Harness Terminal",
            agent: .cursor,
            model: CursorModelCatalog.autoModelId,
            goal: "Harness terminal",
            worktreePath: tempDir.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        XCTAssertEqual(session.runtimeBinding?.runtimeKind, .acpCursor)
        XCTAssertEqual(session.runtimeBinding?.capabilities.supportsTerminal, false)

        let add = try await postJSON(
            "/sessions/\(session.id.uuidString)/terminals",
            ["title": "Blocked"]
        )

        XCTAssertEqual(add.status, 409, bodySnippet(add.data))
        XCTAssertEqual(try XCTUnwrap(jsonObject(add.data))["error"] as? String, "terminal_not_supported")
    }

    func test_staleHarnessSessionsReturn503ForSendAndInterrupt() async throws {
        let cases: [(AgentKind, String?, SessionRuntimeKind)] = [
            (.cursor, CursorModelCatalog.autoModelId, .acpCursor),
            (.codex, "gpt-5.5", .codexAppServer),
            (.gemini, nil, .agyHeadless),
            (.grok, nil, .acpGrok),
        ]

        for (agent, model, expectedRuntime) in cases {
            let session = try await registry.create(
                repoKey: tempDir.path,
                repoDisplayName: "Stale \(agent.rawValue)",
                agent: agent,
                model: model,
                goal: "Stale harness",
                worktreePath: tempDir.path,
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                planMode: false,
                mode: .worktree
            )
            XCTAssertEqual(session.runtimeBinding?.runtimeKind, expectedRuntime)

            let send = try await postJSON(
                "/sessions/\(session.id.uuidString)/send",
                SendPromptRequest(text: "stale harness prompt", asFollowUp: false, idempotencyKey: UUID().uuidString)
            )
            XCTAssertEqual(send.status, 503, "\(agent.rawValue): \(bodySnippet(send.data))")
            XCTAssertEqual(try XCTUnwrap(jsonObject(send.data))["error"] as? String, "acp_session_not_live")

            let interrupt = try await requestRaw(
                path: "/sessions/\(session.id.uuidString)/interrupt",
                method: "POST"
            )
            XCTAssertEqual(interrupt.status, 503, "\(agent.rawValue): \(bodySnippet(interrupt.data))")
            XCTAssertEqual(try XCTUnwrap(jsonObject(interrupt.data))["error"] as? String, "acp_session_not_live")
        }
    }

    func test_registryReplacingPrimaryTerminalPaneDoesNotDuplicatePrimary() async throws {
        let session = try await registry.create(
            repoKey: tempDir.path,
            repoDisplayName: "Primary",
            agent: .codex,
            model: nil,
            goal: "Primary",
            worktreePath: tempDir.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let firstRefId = UUID()
        try await registry.replacePrimaryTerminalPane(
            sessionId: session.id,
            pane: TerminalPaneRef(id: firstRefId, paneId: "pty-1", title: "Shell", isPrimary: true)
        )
        try await registry.replacePrimaryTerminalPane(
            sessionId: session.id,
            pane: TerminalPaneRef(id: firstRefId, paneId: "pty-2", title: "Shell", isPrimary: true)
        )

        let panes = try XCTUnwrap(registry.session(id: session.id)?.terminalPanes)
        XCTAssertEqual(panes.filter(\.isPrimary).count, 1)
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes.first?.paneId, "pty-2")
    }

    func test_usageRouteIncludesCursorMonthlyQuota() async throws {
        let expected = UsageData(
            sessionPct: 48,
            sessionResetMins: 10_000,
            sessionEpoch: 1_782_259_911,
            weeklyPct: 48,
            weeklyResetMins: 10_000,
            weeklyEpoch: 1_782_259_911,
            status: .allowed,
            representativeClaim: .unknown,
            updatedAt: Date(timeIntervalSince1970: 1_777_777_777),
            organizationID: "Included in Ultra",
            cursorQuota: UsageData.CursorQuota(
                totalPct: 48,
                autoPct: 25,
                apiPct: 95,
                resetMins: 10_000,
                resetEpoch: 1_782_259_911,
                includedUsageLabel: "Included in Ultra",
                extraUsageLabel: "Free extra usage may vary."
            )
        )
        let cursorModel = AppModel(
            config: .cursor,
            source: StaticUsageSource(usage: expected),
            tokenProvider: NoopTokenProvider()
        )
        let published = expectation(description: "Cursor usage published")
        let token = cursorModel.$usage.compactMap { $0 }.sink { value in
            if value.cursorQuota?.totalPct == 48 {
                published.fulfill()
            }
        }
        defer {
            token.cancel()
            cursorModel.stop()
        }

        server.attachUsageSources(claude: nil, codex: nil, cursor: cursorModel, history: nil)
        cursorModel.start()
        await fulfillment(of: [published], timeout: 5)

        let raw = try await requestRaw(path: "/usage", method: "GET")
        XCTAssertEqual(raw.status, 200, bodySnippet(raw.data))
        let envelope = try decode(UsageEnvelope.self, from: raw.data)
        let usage = try XCTUnwrap(envelope.usage)
        let cursor = try XCTUnwrap(usage["cursor"])
        XCTAssertEqual(cursor.sessionPct, 48)
        XCTAssertEqual(cursor.cursorQuota?.totalPct, 48)
        XCTAssertEqual(cursor.cursorQuota?.autoPct, 25)
        XCTAssertEqual(cursor.cursorQuota?.apiPct, 95)
        XCTAssertEqual(cursor.cursorQuota?.extraUsageLabel, "Free extra usage may vary.")
        XCTAssertNil(envelope.claude)
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
                        provider: .unknown,
                        model: "noop",
                        effort: .high
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
        XCTAssertNil(frontier.slots[0].sessionId)
        XCTAssertEqual(frontier.slots[0].reason, "invalid_chat_runtime_metadata: provider \(AgentKind.unknown.rawValue) has no chat vendor mapping")
        XCTAssertNil(frontier.slots[1].sessionId)
        XCTAssertEqual(frontier.slots[1].reason, "openrouter auth missing test")
        XCTAssertEqual(registry.sessions.count, 0)
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
        XCTAssertEqual(session.runtimeBinding?.runtimeKind, .acpCursor)
        XCTAssertEqual(session.runtimeBinding?.metadata["chatVendor"], ChatVendor.cursor.rawValue)
        XCTAssertNil(session.tmuxPaneId)
        XCTAssertNil(session.tmuxWindowId)

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
                XCTAssertEqual(session.provisioning?.filesToCopy.mode, .patterns)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: (worktreePath as NSString).appendingPathComponent(".env.local")),
                    "\(agent.rawValue) did not copy ignored .env.local"
                )
                // Default copy is `.env*` only now — node_modules / cache are
                // gitignored but must NOT be copied. Copying every ignored file
                // tripped the file/byte cap on real repos and failed the spawn.
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: (worktreePath as NSString).appendingPathComponent("node_modules/pkg/index.js")),
                    "\(agent.rawValue) should not copy the ignored dependency directory by default"
                )
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: (worktreePath as NSString).appendingPathComponent("cache/empty")),
                    "\(agent.rawValue) should not copy the ignored empty directory by default"
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

    // MARK: - Frontier broadcast: gemini drives via headless agy (Antigravity 2.0)

    /// End-to-end through the REAL daemon: create a {gemini, grok} broadcast group,
    /// send one prompt, and assert the GEMINI child streams a real assistant reply.
    /// This is the honest proof of the migration — a broadcast gemini child routes
    /// through the harness (`AntigravityHeadlessDriver` / `agy`), NOT the retired
    /// agentapi conversation path. It exercises the full chain: spawn
    /// (isChatHarnessEligible → createHarnessChatSessionCore), per-child send fan-out
    /// (bridge-first), and snapshot streaming.
    ///
    /// Live (burns agy + grok quota); gated by the same live sentinel as the other
    /// provider-route tests. Needs both `agy` (Antigravity 2) and `grok` on PATH —
    /// broadcast requires ≥2 successful children.
    func testFrontierGeminiBroadcastDrivesViaAgy() async throws {
        try await requireLiveProviderRouteTests()
        try XCTSkipUnless(ShellRunner.locateBinary("agy") != nil, "agy (Antigravity 2) not on PATH")
        try XCTSkipUnless(ShellRunner.locateBinary("grok") != nil, "grok not on PATH (need a 2nd broadcast child)")

        // The daemon gates spawns on ProviderEnablement; enable both, restore after.
        let savedGemini = ProviderEnablement.isEnabled(AgentKind.gemini.rawValue)
        let savedGrok = ProviderEnablement.isEnabled(AgentKind.grok.rawValue)
        ProviderEnablement.setEnabled(AgentKind.gemini.rawValue, true)
        ProviderEnablement.setEnabled(AgentKind.grok.rawValue, true)
        defer {
            ProviderEnablement.setEnabled(AgentKind.gemini.rawValue, savedGemini)
            ProviderEnablement.setEnabled(AgentKind.grok.rawValue, savedGrok)
        }

        // 0) Picker gate: the provider probe must report gemini SELECTABLE
        //    headlessly (agy on PATH) even with the Antigravity desktop app closed.
        //    Before the agy migration this required `agentapiLive` (app running).
        await ChatProviderProbe.shared.invalidate()
        let providers = await ChatProviderProbe.shared.currentProviders()
        let geminiRow = try XCTUnwrap(providers.providers.first { $0.provider == .gemini })
        XCTAssertTrue(geminiRow.available && geminiRow.capabilityProbePassed,
                      "gemini must be selectable headlessly via agy: \(geminiRow.reason ?? "no reason")")

        // 1) Create the broadcast group. Slot 0 = gemini (headless agy), 1 = grok.
        let createReq = CreateFrontierRequest(clientRequestId: UUID(), models: [
            FrontierModelSlot(provider: .gemini),
            FrontierModelSlot(provider: .grok),
        ])
        let createResp = try await postJSON("/chat-sessions/frontier", createReq, timeout: 60)
        XCTAssertTrue([200, 201].contains(createResp.status),
                      "frontier create status \(createResp.status): \(bodySnippet(createResp.data))")
        let group = try decode(CreateFrontierResponse.self, from: createResp.data)
        let geminiSlot = try XCTUnwrap(group.slots.first { $0.index == 0 }, "no gemini slot in response")
        let geminiId = try XCTUnwrap(geminiSlot.sessionId,
                                     "gemini child spawn failed: \(geminiSlot.reason ?? "unknown")")
        XCTAssertTrue(group.hasMinimumBroadcast,
                      "need ≥2 live children for a real broadcast; slots: \(group.slots)")

        // 2) Migration invariant: the gemini child is HARNESS-driven (a live
        //    bridge) — the agentapi conversation path is gone entirely.
        XCTAssertTrue(server.isHarnessLive(geminiId),
                      "gemini broadcast child must have a live harness bridge (agy)")
        _ = try XCTUnwrap(registry.session(id: geminiId))

        // 3) Broadcast one prompt; assert the gemini child streams a real reply.
        //    The prompt itself contains "PONG" once (echoed as the user bubble), so
        //    requiring ≥2 occurrences proves the ASSISTANT replied (not just the echo).
        let sendReq = FrontierSendRequest(text: "Reply with the single word PONG and nothing else.")
        let sendResp = try await postJSON(
            "/chat-sessions/frontier/\(group.groupId.uuidString)/send", sendReq, timeout: 30)
        XCTAssertTrue([200, 202].contains(sendResp.status),
                      "frontier send status \(sendResp.status): \(bodySnippet(sendResp.data))")

        // The frontier child does NOT echo the user prompt into its store, so the
        // only "PONG" comes from the assistant. Require an assistantText item AND
        // PONG present — proving the agy-driven child produced a real reply.
        var geminiReplied = false
        var lastSnapshot = "<none>"
        for _ in 0..<150 {  // ~30s; agy --print typically replies in ~8-13s
            let snap = try await requestRaw(
                path: "/sessions/\(geminiId.uuidString)/chat-snapshot", method: "GET")
            if snap.status == 200, let s = String(data: snap.data, encoding: .utf8) {
                lastSnapshot = s
                if s.contains("\"kind\":\"assistantText\"") && s.uppercased().contains("PONG") {
                    geminiReplied = true
                    break
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(geminiReplied,
                      "gemini broadcast child did not stream an assistant reply via headless agy; last snapshot: \(lastSnapshot.prefix(400))")
    }

    // MARK: - OpenRouter model plumbing (opencode message body)

    /// The OpenRouter/OpenCode vendor stores the picked model id on
    /// session.model; opencodeMessageBody must forward it as OpenCode's
    /// {providerID, modelID} object, except for the "opencode-default"
    /// sentinel (and empty/nil), which must keep OpenCode's own default.
    func testOpencodeModelObjectMapsRealSlugAndSkipsDefault() {
        // Real OpenRouter slug → routed via providerID "openrouter".
        let real = AgentControlServer.opencodeModelObject(forModelId: "anthropic/claude-opus-4.7")
        XCTAssertEqual(real?["providerID"], "openrouter")
        XCTAssertEqual(real?["modelID"], "anthropic/claude-opus-4.7")

        // Arbitrary slug from the ~320-model live catalog also passes through.
        let llama = AgentControlServer.opencodeModelObject(forModelId: "meta-llama/llama-3.3-70b-instruct")
        XCTAssertEqual(llama?["modelID"], "meta-llama/llama-3.3-70b-instruct")

        // Sentinel + empty + nil → nil (OpenCode keeps its config default).
        XCTAssertNil(AgentControlServer.opencodeModelObject(forModelId: "opencode-default"))
        XCTAssertNil(AgentControlServer.opencodeModelObject(forModelId: "   "))
        XCTAssertNil(AgentControlServer.opencodeModelObject(forModelId: nil))
    }

    private struct RawResponse {
        let status: Int
        let data: Data
    }

    private final class StaticUsageSource: AISource, @unchecked Sendable {
        let providerID = "cursor"
        let displayName = "Cursor"
        let isAuthenticated = true
        private let usage: UsageData

        init(usage: UsageData) {
            self.usage = usage
        }

        func poll() async throws -> UsageData {
            usage
        }

        func refreshCredentialsIfNeeded() async throws -> Bool {
            true
        }
    }

    private struct NoopTokenProvider: TokenProvider {
        var currentAccessToken: String? { "token" }
        var hasToken: Bool { true }
        func refreshIfNeeded() async throws -> Bool { false }
    }

    private func createLegacyPaneSession(goal: String) async throws -> AgentSession {
        try await registry.create(
            repoKey: tempDir.path,
            repoDisplayName: "Legacy",
            agent: .claude,
            model: "sonnet",
            goal: goal,
            worktreePath: tempDir.path,
            tmuxWindowId: "@legacy-\(UUID().uuidString)",
            tmuxPaneId: "%legacy-\(UUID().uuidString)",
            planMode: false,
            mode: .worktree
        )
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
