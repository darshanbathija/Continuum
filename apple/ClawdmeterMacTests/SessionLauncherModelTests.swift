import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class SessionLauncherModelTests: XCTestCase {

    func test_selectableAgentsOnlyIncludesReadyDynamicProviders() {
        // Static providers (claude/codex/gemini) are gated by ProviderEnablement,
        // so enable them explicitly — this test is about the DYNAMIC providers
        // (opencode/cursor/grok) being gated by their *ready* flag on top of an enabled
        // static base. A default all-false availability (pre-probe) yields [].
        let base = SessionLauncherAvailability(claudeEnabled: true, codexEnabled: true, geminiEnabled: true)
        XCTAssertEqual(SessionLauncherModel.selectableAgents(for: base), [.claude, .codex, .gemini])
        XCTAssertEqual(
            SessionLauncherModel.selectableAgents(for: SessionLauncherAvailability(
                claudeEnabled: true, codexEnabled: true, geminiEnabled: true, opencodeReady: true)),
            [.claude, .codex, .gemini, .opencode]
        )
        XCTAssertEqual(
            SessionLauncherModel.selectableAgents(for: SessionLauncherAvailability(
                claudeEnabled: true, codexEnabled: true, geminiEnabled: true, cursorReady: true)),
            [.claude, .codex, .gemini, .cursor]
        )
        XCTAssertEqual(
            SessionLauncherModel.selectableAgents(for: SessionLauncherAvailability(
                claudeEnabled: true, codexEnabled: true, geminiEnabled: true, grokReady: true)),
            [.claude, .codex, .gemini, .grok]
        )
        XCTAssertEqual(
            SessionLauncherModel.selectableAgents(for: SessionLauncherAvailability(
                claudeEnabled: true, codexEnabled: true, geminiEnabled: true,
                opencodeReady: true, cursorReady: true, grokReady: true)),
            [.claude, .codex, .gemini, .opencode, .cursor, .grok]
        )
        XCTAssertEqual(SessionLauncherModel.selectableAgents(for: SessionLauncherAvailability()), [])
    }

    func test_codeTabProviderMatrixDefaultsResolveForEverySelectableAgent() {
        let suiteName = "SessionLauncherProviderMatrix.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = ModelCatalog.bundled.filtered(toEnabledProviderIDs: [
            "claude",
            "codex",
            "gemini",
            "openrouter",
            "cursor",
            "grok",
        ])
        let launcher = SessionLauncherModel(
            modelCatalog: catalog,
            availability: SessionLauncherAvailability(
                claudeEnabled: true,
                codexEnabled: true,
                geminiEnabled: true,
                opencodeReady: true,
                cursorReady: true,
                grokReady: true
            ),
            providerDefaults: ProviderDefaultsStore(defaults: defaults)
        )

        XCTAssertEqual(launcher.selectableAgents, [.claude, .codex, .gemini, .opencode, .cursor, .grok])
        for agent in launcher.selectableAgents {
            let models = catalog.entries(for: agent)
            XCTAssertFalse(models.isEmpty, "\(agent.rawValue) should expose Code-tab model choices.")
            XCTAssertEqual(launcher.defaultModelId(for: agent), models.first?.id)

            let chips = launcher.chipDefaults(for: agent)
            XCTAssertEqual(chips.agent, agent)
            XCTAssertEqual(chips.modelId, models.first?.id)
            XCTAssertEqual(chips.effort, models.first?.supportsEffort == true ? .max : nil)
        }
    }

    func test_liveCursorCatalogDrivesDefaultsAndEffort() {
        let liveCursor = ModelCatalogEntry(
            id: "cursor-gpt-5-5",
            provider: .cursor,
            displayName: "Cursor GPT-5.5",
            supportsThinking: true,
            supportsEffort: false,
            contextWindow: 200_000,
            recommendedFor: "Live account",
            badge: "Live"
        )
        let catalog = ModelCatalog.bundled.replacingCursor([liveCursor])
        let launcher = SessionLauncherModel(
            modelCatalog: catalog,
            availability: SessionLauncherAvailability(cursorReady: true)
        )

        XCTAssertEqual(launcher.defaultModelId(for: .cursor), "cursor-gpt-5-5")
        XCTAssertFalse(launcher.supportsEffort(modelId: "cursor-gpt-5-5"))
        XCTAssertEqual(
            launcher.resolvedModelId(for: .cursor, selectedModelId: "missing-cursor-model"),
            "cursor-gpt-5-5"
        )
    }

    func test_providerDefaultsDriveOpenRouterAndCursorNewSessionDefaults() {
        let suiteName = "SessionLauncherProviderDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providerDefaults = ProviderDefaultsStore(defaults: defaults)
        let cursorEntry = ModelCatalogEntry(
            id: "cursor-account-sonnet",
            provider: .cursor,
            displayName: "Cursor Account Sonnet",
            supportsThinking: true,
            supportsEffort: false
        )
        let catalog = ModelCatalog.bundled
            .replacingCursor([CursorModelCatalog.autoEntry, cursorEntry])
            .replacingOpenRouter([
                ModelCatalogEntry(
                    id: "anthropic/claude-sonnet-4.6",
                    provider: .opencode,
                    displayName: "OpenRouter · Claude Sonnet 4.6",
                    supportsThinking: true,
                    supportsEffort: true,
                    contextWindow: 200_000
                )
            ])

        providerDefaults.setDefault(
            for: .openrouter,
            model: "anthropic/claude-sonnet-4.6",
            effort: .high,
            catalog: catalog
        )
        providerDefaults.setDefault(
            for: .cursor,
            model: "cursor-account-sonnet",
            effort: .high,
            catalog: catalog
        )
        let launcher = SessionLauncherModel(
            modelCatalog: catalog,
            availability: SessionLauncherAvailability(opencodeReady: true, cursorReady: true),
            providerDefaults: providerDefaults
        )

        XCTAssertEqual(launcher.defaultModelId(for: .opencode), "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(launcher.resolvedModelId(for: .opencode, selectedModelId: nil), "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(launcher.resolvedModelId(for: .opencode, selectedModelId: "missing-model"), "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(launcher.chipDefaults(for: .opencode).effort, .high)
        XCTAssertEqual(launcher.defaultModelId(for: .cursor), "cursor-account-sonnet")
        XCTAssertEqual(launcher.resolvedModelId(for: .cursor, selectedModelId: nil), "cursor-account-sonnet")
        XCTAssertNil(launcher.chipDefaults(for: .cursor).effort)
    }

    func test_liveCatalogReplacementNormalizesStalePickerModelsAndEffort() {
        let liveOpenRouter = ModelCatalogEntry(
            id: "openrouter/live-kimi",
            provider: .opencode,
            displayName: "OpenRouter · Live Kimi",
            supportsThinking: true,
            supportsEffort: false
        )
        let liveCursor = ModelCatalogEntry(
            id: "cursor-account-default",
            provider: .cursor,
            displayName: "Cursor Account Default",
            supportsThinking: true,
            supportsEffort: false
        )
        let catalog = ModelCatalog.bundled
            .replacingOpenRouter([liveOpenRouter])
            .replacingCursor([liveCursor])
            .filtered(toEnabledProviderIDs: ["openrouter", "cursor"])
        let launcher = SessionLauncherModel(
            modelCatalog: catalog,
            availability: SessionLauncherAvailability(opencodeReady: true, cursorReady: true)
        )

        XCTAssertEqual(catalog.entries(for: .opencode).map(\.id), ["openrouter/live-kimi"])
        XCTAssertEqual(catalog.entries(for: .cursor).map(\.id), ["cursor-account-default"])

        let openRouterStore = ComposerStore(mode: .emptyState(repoKey: "/repo", agent: .opencode))
        openRouterStore.modelId = "openai/gpt-5.5"
        openRouterStore.effort = .max
        launcher.normalize(openRouterStore)

        XCTAssertEqual(openRouterStore.agent, .opencode)
        XCTAssertEqual(openRouterStore.modelId, "openrouter/live-kimi")
        XCTAssertNil(openRouterStore.effort, "Live OpenRouter replacement rows that do not support effort must clear stale fallback effort.")

        let cursorStore = ComposerStore(mode: .emptyState(repoKey: "/repo", agent: .cursor))
        cursorStore.modelId = "cursor-default"
        cursorStore.effort = .high
        launcher.normalize(cursorStore)

        XCTAssertEqual(cursorStore.agent, .cursor)
        XCTAssertEqual(cursorStore.modelId, "cursor-account-default")
        XCTAssertNil(cursorStore.effort, "Live Cursor replacement rows that do not support effort must clear stale fallback effort.")
    }

    func test_composerAgentResetUsesInjectedCatalog() {
        let liveCursor = ModelCatalogEntry(
            id: "cursor-account-default",
            provider: .cursor,
            displayName: "Cursor Account Default",
            supportsThinking: true,
            supportsEffort: false
        )
        let catalog = ModelCatalog.bundled.replacingCursor([liveCursor])
        let store = ComposerStore(mode: .emptyState(repoKey: nil, agent: .claude))

        store.resetChipsForAgent(.cursor, catalog: catalog)

        XCTAssertEqual(store.agent, .cursor)
        XCTAssertEqual(store.modelId, "cursor-account-default")
        XCTAssertNil(store.effort)
    }

    func test_restoreDraftPreservesPromptForRetry() {
        let attachment = ComposerStore.Attachment(
            sourceURL: URL(fileURLWithPath: "/tmp/design.png"),
            displayName: "design.png",
            byteSize: 123,
            isImage: true
        )
        let store = ComposerStore(mode: .bound(sessionId: UUID()))

        store.restoreDraft(
            text: "retry this prompt",
            attachments: [attachment],
            error: .daemonError(message: "Session started, but send failed.")
        )

        XCTAssertEqual(store.text, "retry this prompt")
        XCTAssertEqual(store.attachments, [attachment])
        XCTAssertEqual(store.lastError, .daemonError(message: "Session started, but send failed."))
        XCTAssertFalse(store.isSending)
    }

    func test_emptyStateComposerBeginSendSurfacesFeedbackWithin100ms() {
        let store = ComposerStore(mode: .emptyState(repoKey: "/repo", agent: .gemini))
        store.text = "hello - tell me about all improvements we could make"
        store.modelId = "gemini-3.5-flash-thinking"
        var worst = Duration.zero

        for _ in 0..<100 {
            XCTAssertTrue(store.canSend)
            let start = ContinuousClock.now
            store.beginSend()
            let elapsed = start.duration(to: ContinuousClock.now)
            worst = max(worst, elapsed)

            XCTAssertTrue(store.isSending)
            XCTAssertNil(store.lastError)
            store.endSend(error: .offline)
            store.text = "hello - tell me about all improvements we could make"
        }

        XCTContext.runActivity(named: "Code empty-state first-send feedback latency") { activity in
            activity.add(XCTAttachment(string: """
            sends=100
            worstBeginSend=\(worst)
            budget=100ms per first-send button feedback
            """))
        }
        XCTAssertLessThan(
            worst,
            .milliseconds(100),
            "Clicking first-send must set the composer sending state within 100ms before spawn/provider work starts."
        )
    }

    func test_firstSendRecoveryIsScopedToPromotedSession() {
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelTests-\(UUID().uuidString).json")
        let workspaceStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelTests-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        defer { try? FileManager.default.removeItem(at: workspaceStoreURL) }
        let registry = AgentSessionRegistry(storeURL: registryURL)
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: WorkspaceStore(storeURL: workspaceStoreURL, sessionsURL: registryURL)
        )
        let promotedSessionId = UUID()
        let attachment = ComposerStore.Attachment(
            sourceURL: URL(fileURLWithPath: "/tmp/spec.md"),
            displayName: "spec.md",
            byteSize: 48,
            isImage: false
        )
        let error = ComposerStore.SendError.daemonError(message: "Safety checkpoint failed. Prompt was not sent.")

        model.queueFirstSendRecovery(
            sessionId: promotedSessionId,
            text: "resume and continue",
            attachments: [attachment],
            error: error
        )

        XCTAssertEqual(model.pendingFirstSendRecoveryVersion, 1)
        let recovery = model.takeFirstSendRecovery(sessionId: promotedSessionId)
        XCTAssertEqual(recovery?.text, "resume and continue")
        XCTAssertEqual(recovery?.attachments, [attachment])
        XCTAssertEqual(recovery?.error, error)
        XCTAssertNil(model.takeFirstSendRecovery(sessionId: promotedSessionId))
    }

    func test_autoFirstSendRecoveryFlushesWhenSelectedHarnessBecomesReady() {
        let now = Date()
        let session = Self.codeSession(
            agent: .gemini,
            model: "gemini-3.5-flash-thinking",
            worktreePath: "/repo/Defx V3/.claude/worktrees/charlotte-2"
        )
        let recovery = PendingFirstSendRecovery(
            text: "hello - tell me about all improvements we could make",
            attachments: [],
            browserComments: [],
            error: .offline,
            createdAt: now,
            clientIntentId: "first-send-test",
            autoSendWhenReady: true
        )

        XCTAssertTrue(
            CenterThread.shouldAutoFlushFirstSendRecovery(
                recovery: recovery,
                session: session,
                harnessReady: true,
                selectedSessionId: session.id,
                now: now
            ),
            "A selected optimistic Code session should auto-send its first prompt as soon as the harness is ready, even if setup took longer than a foreground focus tick."
        )
    }

    func test_autoFirstSendRecoveryDoesNotFlushWhenStaleUnselectedOrRuntimeNotReady() {
        let now = Date()
        let session = Self.codeSession(
            agent: .codex,
            model: "gpt-5.5",
            worktreePath: "/repo/Defx V3/.claude/worktrees/charlotte-2"
        )
        let recovery = PendingFirstSendRecovery(
            text: "first prompt",
            attachments: [],
            browserComments: [],
            error: .offline,
            createdAt: now,
            clientIntentId: "first-send-test",
            autoSendWhenReady: true
        )

        XCTAssertFalse(CenterThread.shouldAutoFlushFirstSendRecovery(
            recovery: recovery,
            session: session,
            harnessReady: false,
            selectedSessionId: session.id,
            now: now
        ))
        XCTAssertFalse(CenterThread.shouldAutoFlushFirstSendRecovery(
            recovery: recovery,
            session: session,
            harnessReady: true,
            selectedSessionId: UUID(),
            now: now
        ))

        let stale = PendingFirstSendRecovery(
            text: recovery.text,
            attachments: [],
            browserComments: [],
            error: recovery.error,
            createdAt: now.addingTimeInterval(-91),
            clientIntentId: recovery.clientIntentId,
            autoSendWhenReady: true
        )
        XCTAssertFalse(CenterThread.shouldAutoFlushFirstSendRecovery(
            recovery: stale,
            session: session,
            harnessReady: true,
            selectedSessionId: session.id,
            now: now
        ))
    }

    func test_boundComposerTreatsEmptyTranscriptAsFirstPrompt() {
        XCTAssertFalse(CenterThread.shouldSendPromptAsFollowUp(snapshot: nil))
        XCTAssertFalse(CenterThread.shouldSendPromptAsFollowUp(snapshot: Self.chatSnapshot(messages: [])))
        XCTAssertFalse(CenterThread.shouldSendPromptAsFollowUp(snapshot: Self.chatSnapshot(messages: [
            Self.chatMessage(kind: .meta, title: "meta", body: "session created")
        ])))
    }

    func test_boundComposerTreatsExistingConversationAsFollowUp() {
        XCTAssertTrue(CenterThread.shouldSendPromptAsFollowUp(snapshot: Self.chatSnapshot(messages: [
            Self.chatMessage(kind: .userText, title: "You", body: "first prompt")
        ])))
        XCTAssertTrue(CenterThread.shouldSendPromptAsFollowUp(snapshot: Self.chatSnapshot(messages: [
            Self.chatMessage(kind: .assistantText, title: "Claude", body: "ready")
        ])))
        XCTAssertTrue(CenterThread.shouldSendPromptAsFollowUp(snapshot: Self.chatSnapshot(messages: [
            Self.chatMessage(kind: .toolCall, title: "Bash", body: "ran git status")
        ])))
    }

    func test_boundComposerDoesNotTreatConnectingEmptyTranscriptAsActiveTurn() {
        let connectingEmpty = Self.chatSnapshot(messages: [], currentTurnState: .streaming)
        XCTAssertFalse(
            CenterThread.shouldSendPromptAsFollowUp(snapshot: connectingEmpty),
            "A connecting-but-empty provider session is still waiting for its first user prompt."
        )
        XCTAssertFalse(
            CenterThread.hasActiveProviderTurn(snapshot: connectingEmpty, pendingMessage: nil),
            "Connecting state alone must not turn the first-prompt Send button into Stop/Queue."
        )

        let connectingWithOnlyMeta = Self.chatSnapshot(
            messages: [Self.chatMessage(kind: .meta, title: "meta", body: "Connecting to Codex")],
            currentTurnState: .streaming
        )
        XCTAssertFalse(
            CenterThread.hasActiveProviderTurn(snapshot: connectingWithOnlyMeta, pendingMessage: nil),
            "Provider setup metadata must not make the first prompt look like a follow-up."
        )
    }

    func test_boundComposerTreatsOptimisticFirstPromptPendingAsActiveTurn() {
        let connectingEmpty = Self.chatSnapshot(messages: [], currentTurnState: .streaming)
        XCTAssertTrue(
            CenterThread.hasActiveProviderTurn(
                snapshot: connectingEmpty,
                pendingMessage: OptimisticPendingMessage(body: "first prompt")
            ),
            "After the user clicks Send, the optimistic pending bubble makes the first prompt interruptible."
        )
        XCTAssertFalse(
            CenterThread.hasActiveProviderTurn(
                snapshot: connectingEmpty,
                pendingMessage: OptimisticPendingMessage(body: "first prompt", state: .queuedOffline)
            ),
            "Queued-offline first prompts should keep the composer in retry/send mode, not Stop mode."
        )
    }

    func test_boundComposerTreatsStreamingExistingConversationAsActiveTurn() {
        let streamingConversation = Self.chatSnapshot(
            messages: [Self.chatMessage(kind: .userText, title: "You", body: "first prompt")],
            currentTurnState: .streaming
        )
        XCTAssertTrue(CenterThread.shouldSendPromptAsFollowUp(snapshot: streamingConversation))
        XCTAssertTrue(
            CenterThread.hasActiveProviderTurn(snapshot: streamingConversation, pendingMessage: nil),
            "Once a real transcript turn exists, streaming should keep Stop/Queue visible."
        )
    }

    func test_configureProvisionalLaunchGivesSub100msFeedbackForRapidPickerToggles() async throws {
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelPerfTests-\(UUID().uuidString).json")
        let workspaceStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelPerfTests-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        defer { try? FileManager.default.removeItem(at: workspaceStoreURL) }
        let registry = AgentSessionRegistry(storeURL: registryURL)
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: WorkspaceStore(storeURL: workspaceStoreURL, sessionsURL: registryURL)
        )
        let session = try await registry.create(
            repoKey: "/repo/clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: .codex,
            model: "gpt-5.5",
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        model.provisioningSessionIds.insert(session.id)
        _ = model.composerStore(for: session, catalog: .bundled)

        var worstToggle = Duration.zero
        let start = ContinuousClock.now
        for index in 0..<200 {
            let agent: AgentKind = index.isMultiple(of: 2) ? .codex : .cursor
            let modelId = index.isMultiple(of: 2) ? "gpt-5.5" : "cursor-account-default"
            let effort: ReasoningEffort? = index.isMultiple(of: 2) ? .high : nil
            let toggleStart = ContinuousClock.now
            XCTAssertTrue(model.configureProvisionalLaunch(
                sessionId: session.id,
                agent: agent,
                modelId: modelId,
                effort: effort
            ))
            let toggleElapsed = toggleStart.duration(to: ContinuousClock.now)
            worstToggle = max(worstToggle, toggleElapsed)
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTContext.runActivity(named: "Code tab provider/model toggle latency") { activity in
            activity.add(XCTAttachment(string: """
            toggles=200
            total=\(elapsed)
            worst=\(worstToggle)
            budget=100ms per visible feedback interaction
            """))
        }
        XCTAssertLessThan(
            worstToggle,
            .milliseconds(100),
            "Each Code-tab provider/model toggle must update the optimistic session within the 100ms feedback budget."
        )
    }

    func test_provisionalLaunchFinalRequestCoversEveryBundledCodeModelPath() async throws {
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelFinalRequestTests-\(UUID().uuidString).json")
        let workspaceStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelFinalRequestTests-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        defer { try? FileManager.default.removeItem(at: workspaceStoreURL) }
        let registry = AgentSessionRegistry(storeURL: registryURL)
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: WorkspaceStore(storeURL: workspaceStoreURL, sessionsURL: registryURL)
        )
        let staleSession = try await registry.create(
            repoKey: "/repo/clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: .claude,
            model: "claude-sonnet-4-5",
            goal: "old work",
            worktreePath: "/repo/clawdmeter/.claude/worktrees/old",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let provisional = try await registry.create(
            repoKey: "/repo/clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: .codex,
            model: "gpt-5.5",
            goal: nil,
            worktreePath: "/repo/clawdmeter/.claude/worktrees/charlotte",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: true,
            mode: .worktree,
            effort: .max
        )
        model.openSession(staleSession)
        model.provisioningSessionIds.insert(provisional.id)
        let catalog = ModelCatalog.bundled.filtered(toEnabledProviderIDs: [
            "claude",
            "codex",
            "gemini",
            "openrouter",
            "cursor",
            "grok",
        ])
        _ = model.composerStore(for: provisional, catalog: catalog)

        let providers: [AgentKind] = [.claude, .codex, .gemini, .opencode, .cursor, .grok]
        let entries = providers.flatMap { provider in
            catalog.entries(for: provider).map { entry in
                (provider: provider, entry: entry)
            }
        }
        let coveredModelIds = Set(entries.map(\.entry.id))
        XCTAssertEqual(coveredModelIds.count, entries.count, "Bundled Code model IDs must be unique across providers.")
        for provider in providers {
            XCTAssertFalse(catalog.entries(for: provider).isEmpty, "\(provider.rawValue) should expose Code-tab model choices.")
        }
        XCTContext.runActivity(named: "Bundled Code provider/model launch matrix") { activity in
            activity.add(XCTAttachment(string: providers.map { provider in
                let ids = catalog.entries(for: provider).map(\.id).joined(separator: ", ")
                return "\(provider.rawValue): \(ids)"
            }.joined(separator: "\n")))
        }

        for (provider, entry) in entries {
            let expectedEffort: ReasoningEffort? = entry.supportsEffort ? .high : nil
            XCTAssertTrue(model.configureProvisionalLaunch(
                sessionId: provisional.id,
                agent: provider,
                modelId: entry.id,
                effort: expectedEffort
            ))

            XCTAssertEqual(model.openSessionId, provisional.id)
            XCTAssertNil(model.selectedWorkspaceTerminalTabId)
            XCTAssertNil(model.selectedWorkspaceDocumentTabId)
            XCTAssertNil(model.openOutsideJSONLPath)

            let request = model.makeProvisionedLaunchRequest(
                sessionId: provisional.id,
                repoKey: "/repo/clawdmeter",
                cwd: "/repo/clawdmeter/.claude/worktrees/charlotte",
                fallbackAgent: .codex,
                fallbackModel: "gpt-5.5",
                fallbackEffort: .max
            )

            XCTAssertEqual(request.sessionId, provisional.id)
            XCTAssertEqual(request.existingWorkspacePath, "/repo/clawdmeter/.claude/worktrees/charlotte")
            XCTAssertEqual(request.agent, provider)
            XCTAssertEqual(request.model, entry.id)
            XCTAssertEqual(request.effort, expectedEffort)
            XCTAssertTrue(request.useWorktree)
            XCTAssertFalse(request.planMode)

            let projected = registry.session(id: provisional.id)
            XCTAssertEqual(projected?.agent, provider)
            XCTAssertEqual(projected?.model, entry.id)
            XCTAssertEqual(projected?.effort, expectedEffort)
        }
    }

    func test_quickSpawnProvisionalRowUsesReservedWorktreeAndSingleSelectionWithin100ms() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherQuickSpawnProvisional-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repo = directory.appendingPathComponent("Defx V3", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let registryURL = directory.appendingPathComponent("sessions.json")
        let workspaceStoreURL = directory.appendingPathComponent("workspaces.json")
        let registry = AgentSessionRegistry(storeURL: registryURL)
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: WorkspaceStore(storeURL: workspaceStoreURL, sessionsURL: registryURL)
        )
        model.repos = [
            AgentRepo(
                key: repo.path,
                displayName: "Defx V3",
                hasActiveSessions: true
            )
        ]
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }

        let oldWorktree = repo.appendingPathComponent(".claude/worktrees/old-branch").path
        let stale = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "Defx V3",
            agent: .claude,
            model: "claude-sonnet-4-5",
            goal: "old work",
            worktreePath: oldWorktree,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        model.openSession(stale)
        let staleKey = try XCTUnwrap(WorkspaceKey.of(stale))
        XCTAssertEqual(model.activeWorkspaceKey, staleKey)

        let sessionId = UUID()
        let started = ContinuousClock.now
        let provisional = try await model.createQuickSpawnProvisionalSession(
            repoKey: repo.path,
            agent: .codex,
            modelId: "gpt-5.5",
            effort: .max,
            sessionId: sessionId
        )
        let elapsed = started.duration(to: ContinuousClock.now)
        addTeardownBlock {
            CityNamer.shared.release(sessionId)
        }

        let provisionalKey = try XCTUnwrap(WorkspaceKey.of(provisional.session))
        let expectedWorktree = WorktreeManager.worktreePath(repoRoot: repo.path, slug: provisional.slug)
        XCTAssertEqual(provisional.session.id, sessionId)
        XCTAssertEqual(provisional.worktreePath, expectedWorktree)
        XCTAssertEqual(provisional.session.worktreePath, expectedWorktree)
        XCTAssertNotEqual(provisional.session.worktreePath, oldWorktree)
        XCTAssertTrue(model.provisioningSessionIds.contains(sessionId))
        XCTAssertNotNil(model.provisioningProgress[sessionId])
        XCTAssertEqual(model.selectedRepoKey, repo.path)
        XCTAssertTrue(model.expandedRepoKeys.contains(repo.path))
        XCTAssertEqual(model.openSessionId, sessionId)
        XCTAssertEqual(model.activeWorkspaceKey, provisionalKey)
        XCTAssertNil(model.selectedWorkspaceDraftTabId)
        XCTAssertNil(model.selectedWorkspaceTerminalTabId)
        XCTAssertNil(model.selectedWorkspaceDocumentTabId)
        XCTAssertNil(model.openOutsideJSONLPath)
        XCTAssertEqual(
            [staleKey, provisionalKey].filter { $0 == model.activeWorkspaceKey },
            [provisionalKey],
            "Quick repo + must leave exactly one selected branch/worktree: the newly reserved provisional worktree."
        )
        XCTAssertLessThan(
            elapsed,
            .milliseconds(100),
            "Repo + must surface the reserved provisional row and selection within the 100 ms feedback budget."
        )
    }

    func test_renameSessionPersistsThroughRegistryCustomName() async throws {
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelRenameTests-\(UUID().uuidString).json")
        let workspaceStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelRenameTests-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        defer { try? FileManager.default.removeItem(at: workspaceStoreURL) }
        let registry = AgentSessionRegistry(storeURL: registryURL)
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: WorkspaceStore(storeURL: workspaceStoreURL, sessionsURL: registryURL)
        )
        let session = try await registry.create(
            repoKey: "/repo/clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: .codex,
            model: "gpt-5.5",
            goal: "Fix rename",
            worktreePath: nil,
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            planMode: false,
            mode: .local
        )

        let renameSucceeded = await model.renameSession(id: session.id, name: "  Rename works  ")
        XCTAssertTrue(renameSucceeded)
        let renamed = registry.session(id: session.id)
        XCTAssertEqual(renamed?.customName, "Rename works")
        XCTAssertEqual(renamed?.displayLabel, "Rename works")

        let reloaded = AgentSessionRegistry(storeURL: registryURL)
        XCTAssertEqual(reloaded.session(id: session.id)?.customName, "Rename works")

        let clearSucceeded = await model.renameSession(id: session.id, name: "   \n  ")
        XCTAssertTrue(clearSucceeded)
        XCTAssertNil(registry.session(id: session.id)?.customName)
        let missingSucceeded = await model.renameSession(id: UUID(), name: "Missing")
        XCTAssertFalse(missingSucceeded)
    }

    private static func chatSnapshot(
        messages: [ChatMessage],
        currentTurnState: TurnState = .idle
    ) -> SessionChatStore.ChatSnapshot {
        SessionChatStore.ChatSnapshot(
            items: [],
            messages: messages,
            updateCounter: 1,
            currentTurnState: currentTurnState
        )
    }

    private static func codeSession(
        agent: AgentKind,
        model: String?,
        worktreePath: String
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: "/repo/Defx V3",
            repoDisplayName: "Defx V3",
            agent: agent,
            model: model,
            goal: nil,
            worktreePath: worktreePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .worktree,
            runtimeCwd: worktreePath,
            effort: nil,
            ownsWorktree: false
        )
    }

    private static func chatMessage(
        kind: ChatMessage.Kind,
        title: String,
        body: String
    ) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            kind: kind,
            title: title,
            body: body,
            at: Date(timeIntervalSince1970: 1_777_200_000)
        )
    }
}
