import XCTest
import CoreGraphics
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class WorkspaceTabsTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 3, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func test_permissionModeShortcutsStayStableWhenProviderHidesPlanMode() {
        XCTAssertEqual(ComposerInputCore.availablePermissionModes(for: .cursor), [.ask, .acceptEdits, .bypass])
        XCTAssertEqual(PermissionModeChip.shortcutDigit(for: .ask), "1")
        XCTAssertEqual(PermissionModeChip.shortcutDigit(for: .acceptEdits), "2")
        XCTAssertEqual(PermissionModeChip.shortcutDigit(for: .plan), "3")
        XCTAssertEqual(PermissionModeChip.shortcutDigit(for: .bypass), "4")

        let cursorModes = ComposerInputCore.availablePermissionModes(for: .cursor)
        XCTAssertNil(
            ComposerInputCore.permissionMode(fromShortcutRaw: PermissionMode.plan.rawValue, availableModes: cursorModes),
            "Cursor must ignore Plan-mode shortcut events because Cursor does not expose plan mode."
        )
        XCTAssertEqual(
            ComposerInputCore.permissionMode(fromShortcutRaw: PermissionMode.bypass.rawValue, availableModes: cursorModes),
            .bypass,
            "Bypass must remain the stable Command-Shift-4 action even when Plan is hidden."
        )
    }

    func test_permissionModeQuickFlipUsesPlanAndAcceptEditsOnlyWhenAvailable() {
        let allModes = ComposerInputCore.availablePermissionModes(for: .claude)
        XCTAssertEqual(PermissionModeChip.quickFlipTarget(current: .ask, availableModes: allModes), .plan)
        XCTAssertEqual(PermissionModeChip.quickFlipTarget(current: .plan, availableModes: allModes), .acceptEdits)
        XCTAssertEqual(PermissionModeChip.quickFlipTarget(current: .acceptEdits, availableModes: allModes), .plan)
        XCTAssertEqual(PermissionModeChip.quickFlipTarget(current: .bypass, availableModes: allModes), .plan)

        let cursorModes = ComposerInputCore.availablePermissionModes(for: .cursor)
        XCTAssertEqual(PermissionModeChip.quickFlipTarget(current: .ask, availableModes: cursorModes), .acceptEdits)
        XCTAssertEqual(PermissionModeChip.quickFlipTarget(current: .acceptEdits, availableModes: cursorModes), .acceptEdits)
        XCTAssertEqual(PermissionModeChip.quickFlipTarget(current: .bypass, availableModes: cursorModes), .acceptEdits)
    }

    func test_rootCommandRoutingRegistersCodeTabShortcutBackedActions() {
        let enabledCommands = Dictionary(uniqueKeysWithValues: MacRootCommandRouting
            .codeTabCommands(canOpenChatTab: true, canOpenTerminalTab: true)
            .map { ($0.id.rawValue, $0) })

        XCTAssertEqual(enabledCommands["code.newChatTab"]?.shortcutID, "code.newChatTab")
        XCTAssertEqual(enabledCommands["code.newChatTab"]?.scope, .code)
        XCTAssertTrue(enabledCommands["code.newChatTab"]?.isEnabled == true)
        XCTAssertEqual(enabledCommands["code.newTerminalTab"]?.shortcutID, "code.newTerminalTab")
        XCTAssertEqual(enabledCommands["code.newTerminalTab"]?.scope, .code)
        XCTAssertTrue(enabledCommands["code.newTerminalTab"]?.isEnabled == true)

        let disabledCommands = Dictionary(uniqueKeysWithValues: MacRootCommandRouting
            .codeTabCommands(canOpenChatTab: false, canOpenTerminalTab: false)
            .map { ($0.id.rawValue, $0) })
        XCTAssertFalse(disabledCommands["code.newChatTab"]?.isEnabled ?? true)
        XCTAssertFalse(disabledCommands["code.newTerminalTab"]?.isEnabled ?? true)

        XCTAssertEqual(MacRootCommandRouting.workspaceNotificationName(for: "code.newChatTab"), .newCodeChatTab)
        XCTAssertEqual(MacRootCommandRouting.workspaceNotificationName(for: "code.newTerminalTab"), .newCodeTerminalTab)
        XCTAssertEqual(MacRootCommandRouting.workspaceNotificationName(for: "session.rename"), .renameOpenSession)
        XCTAssertNil(MacRootCommandRouting.workspaceNotificationName(for: "code.search"))

        let disabledRename = MacRootCommandRouting.sessionRenameCommand(session: nil)
        XCTAssertEqual(disabledRename.shortcutID, "session.rename")
        XCTAssertFalse(disabledRename.isEnabled)
    }

    func test_openDraftWorkspaceTabDoesNotPersistSessionOrChangeWorktree() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTabsTests")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "sonnet",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        model.openSession(source)

        model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(
                agent: .claude,
                modelId: "sonnet",
                effort: .max,
                mode: .worktree,
                planMode: false
            )
        )

        XCTAssertNil(model.openSessionId)
        XCTAssertEqual(model.registry.sessions.count, 1)
        XCTAssertEqual(model.draftWorkspaceTab?.workspaceKey, WorkspaceKey.of(source))
        XCTAssertEqual(model.draftWorkspaceTab?.workspaceKey.workspacePath, "/repo/.claude/worktrees/kolkata")
    }

    func test_openDraftWorkspaceTabAllowsMultipleUntitledTabsPerWorkspace() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceDraftTabsUnbounded")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let key = try XCTUnwrap(WorkspaceKey.of(source))

        let first = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .codex, modelId: "gpt", effort: .max, mode: .worktree, planMode: false)
        ))
        model.openSession(source)
        let second = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .claude, modelId: "sonnet", effort: .max, mode: .worktree, planMode: false)
        ))
        let third = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .codex, modelId: "gpt-5.5", effort: .max, mode: .worktree, planMode: false)
        ))

        XCTAssertEqual(model.workspaceDraftTabs(in: key).map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(model.draftWorkspaceTab?.id, third.id)

        model.selectDraftWorkspaceTab(first)
        model.clearDraftWorkspaceTab(second)

        XCTAssertEqual(model.workspaceDraftTabs(in: key).map(\.id), [first.id, third.id])
        XCTAssertEqual(model.draftWorkspaceTab?.id, first.id)

        model.clearDraftWorkspaceTab(first)

        XCTAssertEqual(model.workspaceDraftTabs(in: key).map(\.id), [third.id])
        XCTAssertEqual(model.draftWorkspaceTab?.id, third.id)
    }

    func test_openDraftWorkspaceTabFromSelectedDraftAppendsUnboundedSiblingDrafts() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceDraftTabsFromDraft")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let key = try XCTUnwrap(WorkspaceKey.of(source))
        let first = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(
                agent: .gemini,
                modelId: "gemini-3.5-flash-thinking",
                effort: nil,
                mode: .worktree,
                planMode: false
            )
        ))

        let second = model.openDraftWorkspaceTab(from: first)
        let third = model.openDraftWorkspaceTab(from: second)
        let fourth = model.openDraftWorkspaceTab(from: third)

        XCTAssertEqual(model.workspaceDraftTabs(in: key).map(\.id), [first.id, second.id, third.id, fourth.id])
        XCTAssertEqual(model.draftWorkspaceTab?.id, fourth.id)
        XCTAssertNil(model.openSessionId)
        XCTAssertEqual(model.registry.sessions.count, 1, "Opening more Code tabs must not persist sessions before first send.")
        XCTAssertEqual(model.draftWorkspaceTab?.agent, .gemini)
        XCTAssertEqual(model.draftWorkspaceTab?.modelId, "gemini-3.5-flash-thinking")
        XCTAssertNil(model.draftWorkspaceTab?.effort)
    }

    func test_newWorkspaceTerminalTabCanUseSiblingSourceWhenDraftIsSelected() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalFromDraft")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let draft = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .codex, modelId: "gpt-5.5", effort: .max, mode: .worktree, planMode: false)
        ))

        XCTAssertNil(model.openSessionId)
        XCTAssertEqual(model.draftWorkspaceTab?.id, draft.id)
        XCTAssertTrue(model.canOpenNewWorkspaceChatDraftTab())
        XCTAssertTrue(model.canOpenNewWorkspaceTerminalTab())
        XCTAssertEqual(model.sourceForNewWorkspaceTerminalTab()?.id, source.id)
    }

    func test_activeWorkspaceKeyTracksOneSelectedWorktreeAcrossTabTypes() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceActiveWorktree")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let alpha = repo.appendingPathComponent("alpha", isDirectory: true)
        let beta = repo.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)

        let first = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "alpha",
            worktreePath: alpha.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let second = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .claude,
            model: "sonnet",
            goal: "beta",
            worktreePath: beta.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let alphaKey = try XCTUnwrap(WorkspaceKey.of(first))
        let betaKey = try XCTUnwrap(WorkspaceKey.of(second))
        let visibleKeys = [alphaKey, betaKey]

        func activeVisibleKeys() -> [WorkspaceKey] {
            guard let active = model.activeWorkspaceKey else { return [] }
            return visibleKeys.filter { $0 == active }
        }

        model.openSession(first)
        XCTAssertEqual(activeVisibleKeys(), [alphaKey])

        let draft = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: first,
            defaults: ComposerStore.ChipDefaults(agent: .codex, modelId: "gpt-5.5", effort: .max, mode: .worktree, planMode: false)
        ))
        XCTAssertEqual(activeVisibleKeys(), [alphaKey], "Draft tabs must keep the owning worktree selected even after openSessionId is cleared.")

        model.openSession(second)
        XCTAssertEqual(activeVisibleKeys(), [betaKey])

        model.selectDraftWorkspaceTab(draft)
        XCTAssertEqual(activeVisibleKeys(), [alphaKey], "Re-selecting a draft must move selection back to only its worktree.")

        model.openWorkspaceTerminalTab(from: second)
        XCTAssertEqual(activeVisibleKeys(), [betaKey])
        XCTAssertNil(model.selectedWorkspaceDraftTabId)
        XCTAssertNil(model.selectedWorkspaceDocumentTabId)

        model.openWorkspaceDocumentTab(from: first, path: "README.md")
        XCTAssertEqual(activeVisibleKeys(), [alphaKey])
        XCTAssertNil(model.selectedWorkspaceDraftTabId)
        XCTAssertNil(model.selectedWorkspaceTerminalTabId)
        XCTAssertEqual(model.selectedWorkspaceDocumentTab?.workspaceKey, alphaKey)
    }

    func test_workspaceDraftComposerStoresStayIsolatedAcrossDraftTabs() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceDraftComposerIsolation")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let key = try XCTUnwrap(WorkspaceKey.of(source))
        let first = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .codex, modelId: "gpt-5.5", effort: .max, mode: .worktree, planMode: false)
        ))
        let second = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .claude, modelId: "claude-sonnet-4-6", effort: .high, mode: .worktree, planMode: false)
        ))

        let firstStore = model.composerStore(for: first)
        firstStore.text = "first draft should stay on Antigravity"
        firstStore.agent = .gemini
        firstStore.modelId = "gemini-3.5-flash-thinking"
        firstStore.effort = nil
        model.updateDraftWorkspaceTabConfiguration(
            id: first.id,
            agent: firstStore.agent,
            modelId: firstStore.modelId,
            effort: firstStore.effort
        )

        let secondStore = model.composerStore(for: second)
        secondStore.text = "second draft should stay on Claude"
        secondStore.agent = .claude
        secondStore.modelId = "claude-sonnet-4-6"
        secondStore.effort = .high
        model.updateDraftWorkspaceTabConfiguration(
            id: second.id,
            agent: secondStore.agent,
            modelId: secondStore.modelId,
            effort: secondStore.effort
        )

        model.selectDraftWorkspaceTab(first)
        let selectedFirst = try XCTUnwrap(model.draftWorkspaceTab)
        XCTAssertEqual(selectedFirst.id, first.id)
        XCTAssertTrue(model.composerStore(for: selectedFirst) === firstStore)
        XCTAssertEqual(firstStore.text, "first draft should stay on Antigravity")
        XCTAssertEqual(selectedFirst.agent, .gemini)
        XCTAssertEqual(selectedFirst.modelId, "gemini-3.5-flash-thinking")
        XCTAssertNil(selectedFirst.effort)

        model.selectDraftWorkspaceTab(second)
        let selectedSecond = try XCTUnwrap(model.draftWorkspaceTab)
        XCTAssertEqual(selectedSecond.id, second.id)
        XCTAssertTrue(model.composerStore(for: selectedSecond) === secondStore)
        XCTAssertEqual(secondStore.text, "second draft should stay on Claude")
        XCTAssertEqual(selectedSecond.agent, .claude)
        XCTAssertEqual(selectedSecond.modelId, "claude-sonnet-4-6")
        XCTAssertEqual(selectedSecond.effort, .high)
        XCTAssertEqual(model.workspaceDraftTabs(in: key).map(\.id), [first.id, second.id])
    }

    func test_workspaceDraftFirstSendPlanUsesSelectedDraftModelAsFirstTurn() {
        let inheritedSourceId = UUID()
        let draft = WorkspaceDraftTab(
            workspaceKey: WorkspaceKey(
                repoKey: "/repo/Defx V3",
                workspacePath: "/repo/Defx V3/.claude/worktrees/charlotte-2"
            ),
            mode: .worktree,
            agent: .claude,
            modelId: "claude-sonnet-4-6",
            effort: .max
        )

        let plan = EmptyStateFirstSendPlan.make(
            repoKey: "/repo/Defx V3",
            workspaceDraft: draft,
            agent: .gemini,
            model: "gemini-3.5-flash-thinking",
            effort: .max,
            storeMode: .worktree,
            permissionMode: .ask,
            modelSupportsEffort: false,
            goal: "hello - tell me about all improvements we could make",
            inheritedContextSourceIds: [inheritedSourceId]
        )

        XCTAssertEqual(plan.repoPath, "/repo/Defx V3")
        XCTAssertEqual(plan.existingWorkspacePath, "/repo/Defx V3/.claude/worktrees/charlotte-2")
        XCTAssertEqual(plan.agent, .gemini)
        XCTAssertEqual(plan.model, "gemini-3.5-flash-thinking")
        XCTAssertNil(plan.effort, "Gemini draft sends must clear stale effort values when the selected model does not support effort.")
        XCTAssertFalse(plan.planMode)
        XCTAssertEqual(plan.mode, .worktree)
        XCTAssertEqual(plan.inheritedContextSourceIds, [inheritedSourceId])
        XCTAssertFalse(plan.sendAsFollowUp, "A draft tab's first send must not be queued as a follow-up.")
        XCTAssertEqual(plan.sendOrigin, .userComposerFirstTurn)
        XCTAssertTrue(
            ProviderPromptGuard.validate(text: "hello - tell me about all improvements we could make", origin: plan.sendOrigin).allowed
        )
    }

    func test_workspaceDraftFirstSendPlanCoversEveryBundledCodeProviderModel() {
        let inheritedSourceId = UUID()
        let draft = WorkspaceDraftTab(
            workspaceKey: WorkspaceKey(
                repoKey: "/repo/Defx V3",
                workspacePath: "/repo/Defx V3/.claude/worktrees/charlotte-2"
            ),
            mode: .worktree,
            agent: .claude,
            modelId: "claude-sonnet-4-6",
            effort: .max
        )
        let cases = AgentKind.allCases.flatMap { provider in
            ModelCatalog.bundled.entries(for: provider).map { entry in
                (provider: provider, entry: entry)
            }
        }
        XCTAssertFalse(cases.isEmpty)

        XCTContext.runActivity(named: "Draft first-send bundled provider/model matrix") { activity in
            activity.add(XCTAttachment(string: cases.map { provider, entry in
                "\(provider.rawValue): \(entry.id)"
            }.joined(separator: "\n")))
        }

        for (provider, entry) in cases {
            let goal = "hello \(provider.rawValue) \(entry.id)"
            let plan = EmptyStateFirstSendPlan.make(
                repoKey: "/repo/Defx V3",
                workspaceDraft: draft,
                agent: provider,
                model: entry.id,
                effort: .max,
                storeMode: .local,
                permissionMode: .ask,
                modelSupportsEffort: entry.supportsEffort,
                goal: goal,
                inheritedContextSourceIds: [inheritedSourceId]
            )

            XCTAssertEqual(plan.repoPath, "/repo/Defx V3", "\(provider.rawValue) \(entry.id)")
            XCTAssertEqual(
                plan.existingWorkspacePath,
                "/repo/Defx V3/.claude/worktrees/charlotte-2",
                "\(provider.rawValue) \(entry.id)"
            )
            XCTAssertEqual(plan.agent, provider, "\(provider.rawValue) \(entry.id)")
            XCTAssertEqual(plan.model, entry.id, "\(provider.rawValue) \(entry.id)")
            XCTAssertEqual(plan.effort, entry.supportsEffort ? .max : nil, "\(provider.rawValue) \(entry.id)")
            XCTAssertEqual(plan.mode, .worktree, "\(provider.rawValue) \(entry.id)")
            XCTAssertFalse(plan.planMode, "\(provider.rawValue) \(entry.id)")
            XCTAssertEqual(plan.inheritedContextSourceIds, [inheritedSourceId], "\(provider.rawValue) \(entry.id)")
            XCTAssertFalse(plan.sendAsFollowUp, "\(provider.rawValue) \(entry.id)")
            XCTAssertEqual(plan.sendOrigin, .userComposerFirstTurn, "\(provider.rawValue) \(entry.id)")
            XCTAssertTrue(
                ProviderPromptGuard.validate(text: goal, origin: plan.sendOrigin).allowed,
                "\(provider.rawValue) \(entry.id)"
            )
        }
    }

    func test_workspaceDraftTabActionsSurfaceVisibleStateWithin100ms() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceDraftTabLatency")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let key = try XCTUnwrap(WorkspaceKey.of(source))
        let defaults = ComposerStore.ChipDefaults(
            agent: .codex,
            modelId: "gpt-5.5",
            effort: .max,
            mode: .worktree,
            planMode: false
        )

        var opened: [WorkspaceDraftTab] = []
        var worstOpen = Duration.zero
        var worstSelect = Duration.zero
        var worstClose = Duration.zero

        for _ in 0..<50 {
            let start = ContinuousClock.now
            let draft = try XCTUnwrap(model.openDraftWorkspaceTab(from: source, defaults: defaults))
            let elapsed = start.duration(to: ContinuousClock.now)
            worstOpen = max(worstOpen, elapsed)
            opened.append(draft)
            XCTAssertEqual(model.draftWorkspaceTab?.id, draft.id)
            XCTAssertEqual(model.openSessionId, nil)
        }
        XCTAssertEqual(model.workspaceDraftTabs(in: key).count, 50)

        for draft in opened {
            let start = ContinuousClock.now
            model.selectDraftWorkspaceTab(draft)
            let elapsed = start.duration(to: ContinuousClock.now)
            worstSelect = max(worstSelect, elapsed)
            XCTAssertEqual(model.draftWorkspaceTab?.id, draft.id)
        }

        for draft in opened.prefix(25) {
            let start = ContinuousClock.now
            model.clearDraftWorkspaceTab(draft)
            let elapsed = start.duration(to: ContinuousClock.now)
            worstClose = max(worstClose, elapsed)
        }
        XCTAssertEqual(model.workspaceDraftTabs(in: key).count, 25)

        XCTContext.runActivity(named: "Code tab draft-tab feedback latency") { activity in
            activity.add(XCTAttachment(string: """
            opens=50
            closes=25
            worstOpen=\(worstOpen)
            worstSelect=\(worstSelect)
            worstClose=\(worstClose)
            budget=100ms per visible tab-state interaction
            """))
        }
        XCTAssertLessThan(worstOpen, .milliseconds(100), "Clicking Code tab + must surface the new draft tab within 100ms.")
        XCTAssertLessThan(worstSelect, .milliseconds(100), "Selecting an existing draft tab must surface the selected state within 100ms.")
        XCTAssertLessThan(worstClose, .milliseconds(100), "Closing a draft tab must remove it from visible tab state within 100ms.")
    }

    /// Perf gate for the worktree-delete guard added to `endSession`. Closing a
    /// SESSION tab now scans siblings (path-canonicalizing each session) + draft
    /// tabs and, when the worktree-owner is closed first, transfers ownership to
    /// a survivor (a registry save). Closing the owner tab in a heavily-populated
    /// workspace must still stay under the 250ms responsiveness bar.
    func test_closingSessionTabInLargeWorkspaceStaysUnderResponsivenessBudget() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("close-session-perf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let worktree = repo.appendingPathComponent(".claude/worktrees/denver", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        // 200 code sessions sharing one worktree — far beyond any real workspace.
        // The first owns the worktree (the heaviest close: owner-closed-first
        // triggers the sibling scan AND the ownership transfer + save).
        var owner: AgentSession!
        for i in 0..<200 {
            let session = try await registry.create(
                repoKey: repo.path,
                repoDisplayName: "repo",
                agent: .claude,
                model: "claude-sonnet-4-6",
                goal: "tab \(i)",
                worktreePath: worktree.path,
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                planMode: false,
                mode: .worktree,
                ownsWorktree: i == 0
            )
            if i == 0 { owner = session }
        }
        XCTAssertEqual(registry.sessions.count, 200)

        let start = ContinuousClock.now
        await model.endSession(id: owner.id)
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTContext.runActivity(named: "Session-tab close worktree-guard latency") { activity in
            activity.add(XCTAttachment(string: """
            sessions=200
            elapsed=\(elapsed)
            budget=250ms responsiveness bar
            """))
        }
        XCTAssertLessThan(
            elapsed,
            .milliseconds(250),
            "Closing the worktree-owner tab in a 200-session workspace (sibling scan + ownership transfer) must stay within the 250ms responsiveness bar."
        )
        // The owner is gone and ownership moved to a survivor, so the worktree
        // wasn't deleted (siblings still live in it) and the last tab will GC it.
        XCTAssertNil(registry.session(id: owner.id))
        XCTAssertEqual(registry.sessions.count, 199)
        XCTAssertTrue(registry.sessions.contains { $0.ownsWorktree },
                      "Closing the owner while siblings remain must hand ownership to a survivor, not orphan the worktree.")
    }

    func test_endSessionKeepsWorktreeWhenDraftTabsRemain() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("end-session-draft-guard")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let worktree = repo.appendingPathComponent(".claude/worktrees/tbilisi", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let source = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "source",
            worktreePath: worktree.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree,
            ownsWorktree: true
        )
        let key = try XCTUnwrap(WorkspaceKey.of(source))
        model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .claude, modelId: "sonnet", effort: .max, mode: .worktree, planMode: false)
        )
        model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .codex, modelId: "gpt-5.5", effort: .max, mode: .worktree, planMode: false)
        )
        XCTAssertEqual(model.workspaceDraftTabs(in: key).count, 2)

        await model.endSession(id: source.id)

        XCTAssertNil(registry.session(id: source.id))
        XCTAssertEqual(model.workspaceDraftTabs(in: key).count, 2)
        XCTAssertTrue(model.workspaceHasOpenTabs(in: key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertTrue(model.openWorkspaceTabKeys(inRepo: repo.path).contains(key))
        XCTAssertNotNil(model.draftWorkspaceTab, "Closing the session tab must promote a surviving draft tab.")
    }

    func test_closingTwoDraftTabsLeavesSessionForegroundAndWorktreeKeys() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("close-drafts-session-survives")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let worktree = repo.appendingPathComponent(".claude/worktrees/tbilisi", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let source = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "source",
            worktreePath: worktree.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree,
            ownsWorktree: true
        )
        let key = try XCTUnwrap(WorkspaceKey.of(source))
        let first = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .claude, modelId: "sonnet", effort: .max, mode: .worktree, planMode: false)
        ))
        let second = try XCTUnwrap(model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(agent: .codex, modelId: "gpt-5.5", effort: .max, mode: .worktree, planMode: false)
        ))

        model.clearDraftWorkspaceTab(first)
        model.clearDraftWorkspaceTab(second)

        XCTAssertEqual(model.workspaceDraftTabs(in: key).count, 0)
        XCTAssertEqual(model.openSessionId, source.id, "Closing the last draft tabs must restore the surviving session tab.")
        XCTAssertTrue(model.workspaceHasOpenTabs(in: key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertFalse(model.openWorkspaceTabKeys(inRepo: repo.path).contains(key))
    }

    func test_workspaceTabStripCompactsBeyondTwoTabsOnMinimumCenterWidth() {
        let minimumCenterWidth: CGFloat = 420
        let fourTabLabelWidth = WorkspaceTabStrip.adaptiveChatTabLabelWidth(
            availableWidth: minimumCenterWidth,
            itemCount: 4
        )

        XCTAssertLessThanOrEqual(
            WorkspaceTabStrip.estimatedChatTabStripWidth(labelWidth: fourTabLabelWidth, itemCount: 4),
            minimumCenterWidth,
            "The rendered Code tab strip must not look capped at two tabs on the minimum center pane; four chat tabs plus + should fit before horizontal scrolling is needed."
        )

        let manyTabLabelWidth = WorkspaceTabStrip.adaptiveChatTabLabelWidth(
            availableWidth: minimumCenterWidth,
            itemCount: 50
        )
        XCTAssertEqual(
            manyTabLabelWidth,
            fourTabLabelWidth,
            "Opening more tabs should keep a stable compact width and rely on scrolling, not shrink to zero or drop tab items."
        )

        let roomyWidth: CGFloat = 900
        let twoTabLabelWidth = WorkspaceTabStrip.adaptiveChatTabLabelWidth(
            availableWidth: roomyWidth,
            itemCount: 2
        )
        let twoTabScrollWidth = WorkspaceTabStrip.scrollableTabContentWidth(
            availableWidth: roomyWidth,
            labelWidth: twoTabLabelWidth,
            itemCount: 2
        )
        XCTAssertLessThan(
            twoTabScrollWidth + 36,
            roomyWidth,
            "When tabs fit, the + button should sit immediately after the tab content instead of being pushed to the far right."
        )

        let manyTabScrollWidth = WorkspaceTabStrip.scrollableTabContentWidth(
            availableWidth: minimumCenterWidth,
            labelWidth: manyTabLabelWidth,
            itemCount: 50
        )
        XCTAssertEqual(
            manyTabScrollWidth,
            minimumCenterWidth - 36,
            "When tabs overflow, the scroll region should reserve width for the visible + button."
        )
    }

    func test_composerTerminalPasteStripsAnsiAndSurfacesTextWithin100ms() {
        let raw = [
            "\u{001B}]0;terminal title\u{0007}\u{001B}[32mPASS\u{001B}[0m",
            "\u{001B}[200~line 1\u{001B}[201~",
            "\u{001B}]8;;https://example.com/log\u{0007}log link\u{001B}]8;;\u{0007}",
            "\u{001B}[2Kdone"
        ].joined(separator: "\n")

        let start = ContinuousClock.now
        let pasted = ComposerInputCore.textAfterPastingTerminalText(
            existing: "Investigate:",
            rawClipboard: raw
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertEqual(
            pasted,
            """
            Investigate:
            PASS
            line 1
            log link
            done
            """
        )
        XCTAssertFalse(pasted.unicodeScalars.contains { $0.value == 0x1B }, "Composer paste cleanup must not leave raw ESC bytes in the prompt.")
        XCTAssertLessThan(elapsed, .milliseconds(100), "Code composer terminal-paste cleanup should visibly mutate the draft text within 100ms.")

        XCTAssertEqual(
            ComposerInputCore.textAfterPastingTerminalText(existing: "   \n", rawClipboard: "\u{001B}[31mclean\u{001B}[0m"),
            "clean",
            "Pasting into an empty-looking composer should replace the draft instead of prepending blank lines."
        )
    }

    func test_promptHistoryPresentationFiltersStableTargetsAndSaveStateWithin100ms() {
        let savedId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let saved = SavedPromptState(
            id: savedId,
            title: "Fix failing tests",
            body: "swift test --filter WorkspaceTabsTests"
        )
        let history = [
            "ship terminal reconnect polish",
            "fix Code tab prompt history"
        ]

        let start = ContinuousClock.now
        let presentation = ComposerInputCore.promptHistoryPresentation(
            history: history,
            savedPrompts: [saved],
            query: "fix"
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertLessThan(elapsed, .milliseconds(100), "Prompt-history search should surface local row feedback within 100ms.")
        XCTAssertEqual(presentation.savedRows.map(\.accessibilityIdentifier), [
            "code.prompt-history.saved.\(savedId.uuidString.lowercased())"
        ])
        XCTAssertEqual(presentation.savedRows.first?.title, "Fix failing tests")
        XCTAssertEqual(presentation.savedRows.first?.body, saved.body)
        XCTAssertEqual(presentation.historyRows.map(\.title), ["fix Code tab prompt history"])
        XCTAssertEqual(
            presentation.historyRows.map(\.accessibilityIdentifier),
            [ComposerInputCore.promptHistoryRowIdentifier(for: "fix Code tab prompt history")]
        )
        XCTAssertFalse(presentation.showsEmptyHistory)

        let empty = ComposerInputCore.promptHistoryPresentation(
            history: history,
            savedPrompts: [saved],
            query: "no matching prompt"
        )
        XCTAssertTrue(empty.savedRows.isEmpty)
        XCTAssertTrue(empty.historyRows.isEmpty)
        XCTAssertTrue(empty.showsEmptyHistory)
        XCTAssertFalse(ComposerInputCore.canSavePromptText(" \n\t "))
        XCTAssertTrue(ComposerInputCore.canSavePromptText("save this prompt"))
    }

    func test_workspaceDraftModelPickerSelectionSurfacesConfigurationWithin100ms() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceDraftModelPickerLatency")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "claude-sonnet-4-6",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let key = try XCTUnwrap(WorkspaceKey.of(source))
        let defaults = ComposerStore.ChipDefaults(
            agent: .claude,
            modelId: "claude-sonnet-4-6",
            effort: .high,
            mode: .worktree,
            planMode: false
        )

        var drafts: [WorkspaceDraftTab] = []
        for _ in 0..<50 {
            drafts.append(try XCTUnwrap(model.openDraftWorkspaceTab(from: source, defaults: defaults)))
        }
        let untouched = try XCTUnwrap(drafts.first)

        var worstSelection = Duration.zero
        for draft in drafts.dropFirst() {
            let start = ContinuousClock.now
            model.selectDraftWorkspaceTab(draft)
            model.updateDraftWorkspaceTabConfiguration(
                id: draft.id,
                agent: .gemini,
                modelId: "gemini-3.5-flash-thinking",
                effort: nil
            )
            let elapsed = start.duration(to: ContinuousClock.now)
            worstSelection = max(worstSelection, elapsed)

            let selected = try XCTUnwrap(model.draftWorkspaceTab)
            XCTAssertEqual(selected.id, draft.id)
            XCTAssertEqual(selected.agent, .gemini)
            XCTAssertEqual(selected.modelId, "gemini-3.5-flash-thinking")
            XCTAssertNil(selected.effort)
        }

        let remaining = model.workspaceDraftTabs(in: key)
        let untouchedAfterPickerSelections = try XCTUnwrap(remaining.first { $0.id == untouched.id })
        XCTAssertEqual(untouchedAfterPickerSelections.agent, .claude)
        XCTAssertEqual(untouchedAfterPickerSelections.modelId, "claude-sonnet-4-6")
        XCTAssertEqual(untouchedAfterPickerSelections.effort, .high)

        XCTContext.runActivity(named: "Code tab draft model-picker feedback latency") { activity in
            activity.add(XCTAttachment(string: """
            draftCount=50
            pickerSelections=49
            selectedModel=gemini-3.5-flash-thinking
            worstSelection=\(worstSelection)
            budget=100ms per rendered picker selection feedback
            """))
        }
        XCTAssertLessThan(
            worstSelection,
            .milliseconds(100),
            "Picking a model on a draft tab must update the selected draft's visible provider/model state within 100ms."
        )
    }

    func test_registryPersistsInheritedContextSources() async throws {
        let (registry, directory) = try Self.makeIsolatedRegistry("WorkspaceTabsRegistry")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let registryURL = directory.appendingPathComponent("sessions.json")
        let sourceId = UUID()
        let session = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )

        try await registry.setInheritedContextSources(sessionId: session.id, sourceIds: [sourceId])

        let reloaded = AgentSessionRegistry(storeURL: registryURL)
        XCTAssertEqual(reloaded.session(id: session.id)?.inheritedContextSourceIds, [sourceId])
    }

    func test_existingWorkspaceRecordPathsPreserveWorktreeCwdForAgentapiProviders() {
        let paths = SessionsModel.existingWorkspaceRecordPaths(
            repoPath: "/repo",
            workspacePath: "/repo/.claude/worktrees/kolkata",
            mode: .worktree
        )

        XCTAssertEqual(paths.cwd, "/repo/.claude/worktrees/kolkata")
        XCTAssertEqual(paths.worktreePath, "/repo/.claude/worktrees/kolkata")
    }

    func test_existingWorkspaceRecordPathsKeepLocalSessionsOnCanonicalCwdWithoutWorktreePath() {
        let paths = SessionsModel.existingWorkspaceRecordPaths(
            repoPath: "/repo",
            workspacePath: "/repo",
            mode: .local
        )

        XCTAssertEqual(paths.cwd, "/repo")
        XCTAssertNil(paths.worktreePath)
    }

    func test_registryRuntimeCwdCanRepresentGeminiAndOpencodeSameWorkspaceSessions() async throws {
        let (registry, directory) = try Self.makeIsolatedRegistry("WorkspaceTabsRuntimeCwd")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = SessionsModel.existingWorkspaceRecordPaths(
            repoPath: "/repo",
            workspacePath: "/repo/.claude/worktrees/kolkata",
            mode: .worktree
        )

        let gemini = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .gemini,
            model: nil,
            goal: nil,
            worktreePath: paths.worktreePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let opencode = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .opencode,
            model: nil,
            goal: nil,
            worktreePath: paths.worktreePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )

        XCTAssertEqual(gemini.runtimeCwd, paths.cwd)
        XCTAssertEqual(gemini.worktreePath, paths.worktreePath)
        XCTAssertEqual(gemini.mode, .worktree)
        XCTAssertFalse(gemini.ownsWorktree)
        XCTAssertEqual(opencode.runtimeCwd, paths.cwd)
        XCTAssertEqual(opencode.worktreePath, paths.worktreePath)
        XCTAssertEqual(opencode.mode, .worktree)
        XCTAssertFalse(opencode.ownsWorktree)
    }

    func test_sameWorkspaceModelSessionTabsAreNotCappedAtTwo() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceSiblingSessionTabsUnbounded")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let worktree = repo.appendingPathComponent(".claude/worktrees/kolkata", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let fixtures: [(AgentKind, String)] = [
            (.claude, "claude-sonnet-4-6"),
            (.codex, "gpt-5.5"),
            (.gemini, "gemini-3.5-flash-thinking"),
            (.cursor, "cursor-default"),
            (.opencode, "opencode-default"),
            (.grok, "grok-build")
        ]
        var sessions: [AgentSession] = []
        for (agent, modelId) in fixtures {
            sessions.append(try await registry.create(
                repoKey: repo.path,
                repoDisplayName: "repo",
                agent: agent,
                model: modelId,
                goal: "\(agent.rawValue) tab",
                worktreePath: worktree.path,
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                planMode: false,
                mode: .worktree
            ))
        }

        let key = try XCTUnwrap(WorkspaceKey.of(sessions[0]))
        let siblingTabs = WorkspaceKey.siblings(of: key, in: model.registry.sessions)
        XCTAssertEqual(siblingTabs.count, fixtures.count, "The Code top-tab source must include every model session in the worktree, not just two.")
        XCTAssertEqual(Set(siblingTabs.map(\.id)), Set(sessions.map(\.id)))

        for session in sessions {
            model.openSession(session)
            XCTAssertEqual(model.activeWorkspaceKey, key)
        }
        XCTAssertEqual(WorkspaceKey.siblings(of: key, in: model.registry.sessions).count, fixtures.count)
    }

    func test_openWorkspaceTerminalTabUsesExistingSessionWithoutCreatingWorktree() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalTabs")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .opencode,
            model: "opencode",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )

        model.openWorkspaceTerminalTab(from: source)

        XCTAssertEqual(model.registry.sessions.count, 1)
        XCTAssertEqual(model.openSessionId, source.id)
        XCTAssertNil(model.draftWorkspaceTab)
        XCTAssertEqual(model.selectedWorkspaceTerminalTab?.sessionId, source.id)
        XCTAssertNil(model.selectedWorkspaceTerminalTab?.paneRefId)
        XCTAssertEqual(model.selectedWorkspaceTerminalTab?.workspaceKey, WorkspaceKey.of(source))
    }

    func test_openOrCreateWorkspaceTerminalTabSurfacesPendingTabWithin100ms() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalResponsiveShell")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let source = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt",
            goal: "source",
            worktreePath: repo.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )

        let start = ContinuousClock.now
        await model.openOrCreateWorkspaceTerminalTab(from: source)
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertLessThan(elapsed, .milliseconds(100))
        let visibleTab = try XCTUnwrap(model.selectedWorkspaceTerminalTab)
        XCTAssertEqual(visibleTab.sessionId, source.id)
        XCTAssertEqual(visibleTab.workspaceKey, WorkspaceKey.of(source))
        XCTAssertTrue(visibleTab.isPendingDirectShell || visibleTab.paneRefId != nil)
        if visibleTab.isPendingDirectShell {
            XCTAssertNil(visibleTab.paneRefId)
            XCTAssertEqual(visibleTab.pendingTitle, "Shell")
        }

        let promoted = await waitUntil {
            model.selectedWorkspaceTerminalTab?.paneRefId != nil
        }
        XCTAssertTrue(promoted)

        if let tab = model.selectedWorkspaceTerminalTab {
            await model.closeWorkspaceTerminalTab(tab)
        }
    }

    func test_openOrCreateWorkspaceTerminalTabAppendsBeyondSevenWithoutPendingReuse() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalTabsUnbounded")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let source = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt",
            goal: "source",
            worktreePath: repo.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let key = try XCTUnwrap(WorkspaceKey.of(source))

        let start = ContinuousClock.now
        for _ in 0..<8 {
            await model.openOrCreateWorkspaceTerminalTab(from: source)
        }
        let elapsed = start.duration(to: ContinuousClock.now)

        let immediateTabs = model.workspaceTerminalTabs(in: key)
        XCTAssertEqual(immediateTabs.count, 8, "Each terminal-tab request should append a visible pending tab; the old path reused the one pending tab.")
        XCTAssertEqual(Set(immediateTabs.map(\.id)).count, 8)
        XCTAssertEqual(model.selectedWorkspaceTerminalTab?.id, immediateTabs.last?.id)
        XCTAssertLessThan(elapsed, .milliseconds(250), "Opening several terminal tabs should only stage visible pending tabs, not wait for shell startup.")

        let promoted = await waitUntil(10) {
            let tabs = model.workspaceTerminalTabs(in: key)
            return tabs.count == 8 && tabs.allSatisfy { !$0.isPendingDirectShell && $0.paneRefId != nil }
        }
        XCTAssertTrue(promoted, "All pending terminal tabs should promote to direct shell panes.")

        for tab in model.workspaceTerminalTabs(in: key) {
            await model.closeWorkspaceTerminalTab(tab)
        }
    }

    func test_openWorkspaceTerminalTabAllowsHarnessSessionDirectWorktreeShell() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalHarnessDirectShell")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let source = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt",
            goal: "source",
            worktreePath: repo.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )

        await model.openOrCreateWorkspaceTerminalTab(from: source)

        XCTAssertEqual(source.runtimeBinding?.capabilities.supportsTerminal, false)
        XCTAssertTrue(model.canOpenWorkspaceTerminalTab(from: source))
        XCTAssertEqual(model.registry.sessions.count, 1)
        XCTAssertEqual(model.openSessionId, source.id)
        XCTAssertEqual(model.selectedWorkspaceTerminalTab?.sessionId, source.id)
        let promoted = await waitUntil {
            model.selectedWorkspaceTerminalTab?.paneRefId != nil
        }
        XCTAssertTrue(promoted)
        let paneRefId = try XCTUnwrap(model.selectedWorkspaceTerminalTab?.paneRefId)
        let pane = try XCTUnwrap(registry.session(id: source.id)?.terminalPanes.first { $0.id == paneRefId })
        XCTAssertEqual(pane.title, "Shell")
        XCTAssertFalse(pane.isPrimary)
        let host = await TerminalPtyRegistry.shared.host(id: pane.paneId)
        XCTAssertNotNil(host)
        XCTAssertEqual(model.workspaceTerminalTabs(in: WorkspaceKey.of(source)!).count, 1)

        if let tab = model.selectedWorkspaceTerminalTab {
            await model.closeWorkspaceTerminalTab(tab)
        }
    }

    func test_openWorkspaceTerminalTabRejectsLegacyPaneBackedSessions() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalLegacyPane")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .opencode,
            model: "opencode",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: "@legacy",
            tmuxPaneId: "%legacy",
            planMode: false,
            mode: .worktree,
            ownsWorktree: false
        )

        model.openWorkspaceTerminalTab(from: source)

        XCTAssertFalse(model.canOpenWorkspaceTerminalTab(from: source))
        XCTAssertNil(model.selectedWorkspaceTerminalTab)
        XCTAssertEqual(model.workspaceTerminalTabs(in: WorkspaceKey.of(source)!).count, 0)
    }

    func test_workspaceDocumentTabsOpenSelectDedupeAndCloseToOriginChat() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceDocumentTabs")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let docs = repo.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let source = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .opencode,
            model: "opencode",
            goal: "source",
            worktreePath: repo.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        model.openWorkspaceTerminalTab(from: source)
        XCTAssertNotNil(model.selectedWorkspaceTerminalTab)

        model.openWorkspaceDocumentTab(
            from: source,
            path: "docs/report.md",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let expectedPath = docs.appendingPathComponent("report.md").standardizedFileURL.path
        let selected = try XCTUnwrap(model.selectedWorkspaceDocumentTab)
        XCTAssertEqual(selected.path, expectedPath)
        XCTAssertEqual(selected.sessionId, source.id)
        XCTAssertEqual(model.openSessionId, source.id)
        XCTAssertNil(model.selectedWorkspaceTerminalTab)

        model.openWorkspaceDocumentTab(
            from: source,
            path: expectedPath,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(model.workspaceDocumentTabs(in: WorkspaceKey.of(source)!).count, 1)
        XCTAssertEqual(model.selectedWorkspaceDocumentTab?.id, selected.id)

        model.closeWorkspaceDocumentTab(selected)

        XCTAssertTrue(model.workspaceDocumentTabs.isEmpty)
        XCTAssertNil(model.selectedWorkspaceDocumentTab)
        XCTAssertEqual(model.openSessionId, source.id)
    }

    func test_prepareNewSessionClearsWorkspaceTabSelections() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceSwitcherClearsTabs")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs", isDirectory: true), withIntermediateDirectories: true)
        let source = try await registry.create(
            repoKey: repo.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt",
            goal: "source",
            worktreePath: repo.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        model.openWorkspaceTerminalTab(from: source)
        model.openWorkspaceDocumentTab(from: source, path: "docs/report.md")
        XCTAssertNotNil(model.selectedWorkspaceDocumentTabId)

        model.prepareNewSession(in: repo.path)

        XCTAssertEqual(model.selectedRepoKey, repo.path)
        XCTAssertTrue(model.showingNewSessionSheet)
        XCTAssertNil(model.openSessionId)
        XCTAssertNil(model.selectedWorkspaceTerminalTabId)
        XCTAssertNil(model.selectedWorkspaceDocumentTabId)
    }

    func test_markdownDocumentPathResolutionAllowsOnlyWorktreeOrGeneratedDocsRoots() {
        let cwd = "/Users/example/project"
        let home = "/Users/example"

        let worktreeDoc = AgentControlServer.standardizedMarkdownDocumentPath("docs/report.md", relativeTo: cwd)
        XCTAssertEqual(worktreeDoc, "/Users/example/project/docs/report.md")
        XCTAssertTrue(AgentControlServer.isMarkdownDocumentPathAllowed(worktreeDoc!, relativeTo: cwd, homeDirectory: home))

        let generatedDoc = AgentControlServer.standardizedMarkdownDocumentPath(
            "/Users/example/.gstack/projects/report.md",
            relativeTo: cwd
        )
        XCTAssertEqual(generatedDoc, "/Users/example/.gstack/projects/report.md")
        XCTAssertTrue(AgentControlServer.isMarkdownDocumentPathAllowed(generatedDoc!, relativeTo: cwd, homeDirectory: home))

        let outsideDoc = AgentControlServer.standardizedMarkdownDocumentPath("/Users/example/secrets/report.md", relativeTo: cwd)
        XCTAssertEqual(outsideDoc, "/Users/example/secrets/report.md")
        XCTAssertFalse(AgentControlServer.isMarkdownDocumentPathAllowed(outsideDoc!, relativeTo: cwd, homeDirectory: home))

        let extensionlessGeneratedDoc = AgentControlServer.standardizedMarkdownDocumentPath(
            "/Users/example/.gstack/projects/secret",
            relativeTo: cwd
        )
        XCTAssertFalse(GeneratedArtifactDetector.isMarkdownPath(extensionlessGeneratedDoc!))

        XCTAssertEqual(
            AgentControlServer.standardizedMarkdownDocumentPath("~/.gstack/projects/report.md", relativeTo: cwd),
            NSString(string: "~/.gstack/projects/report.md").expandingTildeInPath
        )
        XCTAssertNil(AgentControlServer.standardizedMarkdownDocumentPath("../secrets/report.md", relativeTo: cwd))
        XCTAssertNil(AgentControlServer.standardizedMarkdownDocumentPath("docs/report.md\nbad", relativeTo: cwd))
        XCTAssertNil(AgentControlServer.standardizedMarkdownDocumentPath("docs/report.md", relativeTo: ""))
    }

    func test_workspaceTerminalTabsAreScopedAndIgnoreMissingPaneRefs() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalScope")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let first = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: nil,
            goal: "first",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let second = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: "second",
            worktreePath: "/repo/.claude/worktrees/delhi",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let pane = TerminalPaneRef(paneId: UUID().uuidString, title: "Logs", isPrimary: false)
        try await registry.addTerminalPane(sessionId: first.id, pane: pane)

        model.openWorkspaceTerminalTab(from: first, paneRefId: pane.id, createdAt: Date(timeIntervalSince1970: 2))
        model.openWorkspaceTerminalTab(from: second, createdAt: Date(timeIntervalSince1970: 1))
        try await registry.removeTerminalPane(sessionId: first.id, paneRefId: pane.id)

        XCTAssertEqual(model.workspaceTerminalTabs(in: WorkspaceKey.of(first)!).count, 0)
        XCTAssertEqual(model.workspaceTerminalTabs(in: WorkspaceKey.of(second)!).map { $0.sessionId }, [second.id])
        XCTAssertEqual(model.selectedWorkspaceTerminalTab?.sessionId, second.id)
    }

    func test_inheritedAttachmentStagerCopiesBytesAndWritesManifest() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InheritedAttachmentStager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let worktree = temp.appendingPathComponent("worktree", isDirectory: true)
        let dest = temp.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let source = AgentSession(
            id: UUID(),
            repoKey: temp.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: nil,
            goal: nil,
            worktreePath: worktree.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .worktree,
            runtimeCwd: worktree.path
        )
        let sourceDir = try XCTUnwrap(AttachmentStaging.stagingDir(for: source))
        let original = sourceDir.appendingPathComponent("design.md")
        try "hello".write(to: original, atomically: true, encoding: .utf8)
        try "# old digest".write(
            to: sourceDir.appendingPathComponent("inherited-\(UUID().uuidString).md"),
            atomically: true,
            encoding: .utf8
        )

        let staged = try InheritedAttachmentStager.stage(sourceSessions: [source], into: dest)

        let manifestURL = dest.appendingPathComponent(InheritedAttachmentStager.manifestFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(staged.contains(manifestURL))
        let copiedFiles = staged.filter { $0.lastPathComponent != InheritedAttachmentStager.manifestFilename }
        XCTAssertEqual(copiedFiles.count, 1)
        XCTAssertEqual(try String(contentsOf: copiedFiles[0], encoding: .utf8), "hello")
        let manifest = try JSONDecoder().decode(
            InheritedAttachmentStager.Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.entries.first?.originalName, "design.md")
        XCTAssertNil(manifest.entries.first?.error)
    }

    func test_inheritedAttachmentStagerDoesNotCopySiblingCodexAttachmentsFromSameWorktree() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InheritedAttachmentScope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let worktree = temp.appendingPathComponent("worktree", isDirectory: true)
        let dest = temp.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let selectedSource = makeCodexSession(repo: temp.path, worktree: worktree.path)
        let unselectedSibling = makeCodexSession(repo: temp.path, worktree: worktree.path)
        let selectedDir = try XCTUnwrap(AttachmentStaging.stagingDir(for: selectedSource))
        let siblingDir = try XCTUnwrap(AttachmentStaging.stagingDir(for: unselectedSibling))
        try "selected".write(to: selectedDir.appendingPathComponent("selected.txt"), atomically: true, encoding: .utf8)
        try "sibling".write(to: siblingDir.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)

        let staged = try InheritedAttachmentStager.stage(sourceSessions: [selectedSource], into: dest)

        let copiedPayloads = try staged
            .filter { $0.lastPathComponent != InheritedAttachmentStager.manifestFilename }
            .map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(copiedPayloads, ["selected"])
    }

    private func makeCodexSession(repo: String, worktree: String) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: repo,
            repoDisplayName: "repo",
            agent: .codex,
            model: nil,
            goal: nil,
            worktreePath: worktree,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .worktree,
            runtimeCwd: worktree,
            ownsWorktree: false
        )
    }

    // MARK: - #185 follow-up: dual-path tab-spawn API

    /// `spawnSameWorkspaceChatTab(parentId:)` is the #185-named convenience over
    /// `openDraftWorkspaceTab(from:defaults:)`. The two API names must land in
    /// the same on-screen state (same workspace key, same chip defaults,
    /// same cleared selection) so the two posters cannot drift.
    func test_spawnSameWorkspaceChatTabMatchesOpenDraftWorkspaceTab() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("Spawn185Path")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt-5.5",
            goal: "src",
            worktreePath: "/repo/.claude/worktrees/feature",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        model.openSession(source)

        let draftId = model.spawnSameWorkspaceChatTab(parentId: source.id)

        XCTAssertNotNil(draftId, "spawnSameWorkspaceChatTab must return the minted draft id")
        XCTAssertNil(model.openSessionId, "spawn must clear the foreground session selection like openDraftWorkspaceTab")
        XCTAssertEqual(model.draftWorkspaceTab?.workspaceKey, WorkspaceKey.of(source))
        XCTAssertEqual(model.draftWorkspaceTab?.id, draftId)
        XCTAssertEqual(model.draftWorkspaceTab?.agent, source.agent)
        XCTAssertEqual(model.draftWorkspaceTab?.modelId, source.model)
        XCTAssertEqual(model.draftWorkspaceTab?.mode, source.mode)
        XCTAssertEqual(model.registry.sessions.count, 1, "spawn must not persist a new session before first send")
    }

    /// Unknown parent id returns nil + no side effect.
    func test_spawnSameWorkspaceChatTabIsNoOpForUnknownParentId() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("SpawnNoop")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let before = model.draftWorkspaceTab
        let result = model.spawnSameWorkspaceChatTab(parentId: UUID())
        XCTAssertNil(result)
        XCTAssertEqual(model.draftWorkspaceTab?.id, before?.id)
    }

    /// 2026-06-10 regression: picking ANOTHER provider's model on a bound
    /// session used to swap just the model id onto the running runtime
    /// (`claude --model cursor-default`), which never becomes ready and
    /// strands the session on "Connecting to Claude" while the chip and
    /// header show the foreign model. Cross-provider picks must leave the
    /// session untouched and open a sibling draft configured for the picked
    /// provider/model instead — model plurality lives in tabs.
    func test_switchModelAcrossProvidersOpensSiblingDraftInsteadOfMutatingSession() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("CrossProviderSwitch")
        addTeardownBlock {
            await registry.closeEventStoreForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let session = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "claude-opus-4-8",
            goal: "src",
            worktreePath: "/repo/.claude/worktrees/cusco",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        model.openSession(session)
        let cursorEntry = try XCTUnwrap(
            ModelCatalog.bundled.cursor.first,
            "bundled catalog must include a Cursor entry"
        )

        await model.switchModel(sessionId: session.id, to: cursorEntry, effort: .max)

        let stored = try XCTUnwrap(model.registry.session(id: session.id))
        XCTAssertEqual(stored.agent, .claude, "cross-provider pick must not touch the session's provider")
        XCTAssertEqual(stored.model, "claude-opus-4-8", "cross-provider pick must not hand a foreign model id to the runtime")
        let draft = try XCTUnwrap(model.draftWorkspaceTab, "cross-provider pick must open a sibling draft tab")
        XCTAssertEqual(draft.workspaceKey, WorkspaceKey.of(stored))
        XCTAssertEqual(draft.agent, .cursor)
        XCTAssertEqual(draft.modelId, cursorEntry.id)
        XCTAssertNil(model.openSessionId, "the sibling draft tab should take the foreground selection")
        if !cursorEntry.supportsEffort {
            XCTAssertNil(draft.effort, "stale effort must clear when the picked provider's model does not support it")
        }
    }

    func test_mobileCommandOutboxEntryOrReserveSerializesConcurrentSameKeyUntilRelease() async {
        let outbox = MobileCommandOutbox()

        switch await outbox.entryOrReserve(key: "send-key") {
        case .reserved:
            break
        default:
            XCTFail("first request should reserve a fresh key")
        }

        switch await outbox.entryOrReserve(key: "send-key") {
        case .inFlight:
            break
        default:
            XCTFail("second concurrent request must not execute")
        }

        await outbox.releaseInFlight("send-key")
        _ = await outbox.record(
            key: "send-key",
            kind: .send,
            responseBody: Data(#"{"ok":true}"#.utf8),
            payloadHash: "abc"
        )

        switch await outbox.entryOrReserve(key: "send-key") {
        case .cached(let entry):
            XCTAssertEqual(entry.kind, .send)
            XCTAssertEqual(entry.payloadHash, "abc")
        default:
            XCTFail("processed key should replay from cache")
        }
    }

    func test_mobileCommandOutboxEntryOrReserveIgnoresMissingKey() async {
        let outbox = MobileCommandOutbox()

        switch await outbox.entryOrReserve(key: nil) {
        case .noKey:
            break
        default:
            XCTFail("nil key should not reserve")
        }

        switch await outbox.entryOrReserve(key: "") {
        case .noKey:
            break
        default:
            XCTFail("empty key should not reserve")
        }
    }

    private static func makeIsolatedRegistry(_ name: String) throws -> (AgentSessionRegistry, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registryURL = directory.appendingPathComponent("sessions.json")
        return (AgentSessionRegistry(storeURL: registryURL), directory)
    }

    private static func makeIsolatedModel(_ name: String) throws -> (SessionsModel, AgentSessionRegistry, URL) {
        let (registry, directory) = try makeIsolatedRegistry(name)
        let workspaceStore = WorkspaceStore(
            storeURL: directory.appendingPathComponent("workspaces.json"),
            sessionsURL: directory.appendingPathComponent("sessions.json")
        )
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: workspaceStore
        )
        return (model, registry, directory)
    }
}
