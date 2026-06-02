import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class SessionLauncherModelTests: XCTestCase {

    func test_selectableAgentsOnlyIncludesReadyDynamicProviders() {
        // Static providers (claude/codex/gemini) are gated by ProviderEnablement,
        // so enable them explicitly — this test is about the DYNAMIC providers
        // (opencode/cursor) being gated by their *ready* flag on top of an enabled
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
                claudeEnabled: true, codexEnabled: true, geminiEnabled: true,
                opencodeReady: true, cursorReady: true)),
            [.claude, .codex, .gemini, .opencode, .cursor]
        )
        XCTAssertEqual(SessionLauncherModel.selectableAgents(for: SessionLauncherAvailability()), [])
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

    func test_firstSendRecoveryIsScopedToPromotedSession() {
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelTests-\(UUID().uuidString).json")
        let workspaceStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelTests-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        defer { try? FileManager.default.removeItem(at: workspaceStoreURL) }
        let registry = AgentSessionRegistry(storeURL: registryURL)
        let tmux = TmuxControlClient(configuration: .init(tmuxBinary: "/usr/bin/false"))
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            supervisor: TmuxSupervisor(tmux: tmux, registry: registry),
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

    func test_renameSessionPersistsThroughRegistryCustomName() async throws {
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelRenameTests-\(UUID().uuidString).json")
        let workspaceStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLauncherModelRenameTests-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        defer { try? FileManager.default.removeItem(at: workspaceStoreURL) }
        let registry = AgentSessionRegistry(storeURL: registryURL)
        let tmux = TmuxControlClient(configuration: .init(tmuxBinary: "/usr/bin/false"))
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            supervisor: TmuxSupervisor(tmux: tmux, registry: registry),
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
}
