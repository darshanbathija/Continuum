import XCTest
import CoreGraphics

final class CodeTabHoverShortcutUITests: XCTestCase {
    private static let seedSessionId = "66666666-6666-4666-8666-666666666666"
    private static let seededSavedPromptId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let seededSavedPromptTitle = "Seeded Saved Prompt"
    private static let seededSavedPromptBody = "Summarize the rendered Code tab prompt history flow."
    private static let seededHistoryPrompt = "Review regression checklist for rendered composer prompt history."
    private static let sameWorktreeSessionFixtures: [(id: String, agent: String, model: String, title: String, provider: String)] = [
        ("66666666-6666-4666-8666-666666666666", "claude", "claude-sonnet-4-6", "Claude Same Worktree", "Claude"),
        ("77777777-7777-4777-8777-777777777777", "codex", "gpt-5-codex", "Codex Same Worktree", "Codex"),
        ("88888888-8888-4888-8888-888888888888", "gemini", "gemini-3.5-flash-thinking", "Antigravity Same Worktree", "Antigravity"),
        ("99999999-9999-4999-8999-999999999999", "opencode", "anthropic/claude-sonnet-4.6", "OpenCode Same Worktree", "OpenCode"),
        ("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "cursor", "cursor-account-default", "Cursor Same Worktree", "Cursor"),
        ("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "grok", "grok-composer-2.5-fast", "Grok Same Worktree", "Grok"),
    ]

    private struct UITestFixture {
        let appSupportDirectory: URL
        let claudeProjectsRoot: URL
        let repoRoot: URL
        let fakeClaudeBinary: URL
    }

    private var app: XCUIApplication!
    private var testAppSupportDirectory: URL!
    private var testClaudeProjectsRoot: URL!
    private var testRepoRootDirectory: URL!
    private var fakeClaudeBinaryURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let usesPlanApprovalFixture = name.contains("testPlanPaneApproveButtonApprovesRenderedPendingPlanAndCreatesCheckpoint")
        let usesMultiSessionTabsFixture = name.contains("testWorkspaceSessionTabsRenderEverySameWorktreeModelSessionAndSwitchHeader")
        let fixture = try Self.seedWorkspaceStore(
            pendingPlan: usesPlanApprovalFixture,
            multiSessionTabs: usesMultiSessionTabsFixture
        )
        testAppSupportDirectory = fixture.appSupportDirectory
        testClaudeProjectsRoot = fixture.claudeProjectsRoot
        testRepoRootDirectory = fixture.repoRoot
        fakeClaudeBinaryURL = fixture.fakeClaudeBinary
        app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing",
            "-clawdmeter.sidebar.status", "all",
            "-clawdmeter.sidebar.grouping", "status",
            "-clawdmeter.sidebar.sorting", "recency",
            "-clawdmeter.sidebar.historyExpanded", "NO",
            // Composer drafts persist in UserDefaults.standard keyed by
            // session id; the fixed seed UUID otherwise leaks one run's
            // typed text into the next (NSArgumentDomain overrides the
            // persisted value for reads, so restoreDraftIfNeeded sees an
            // empty draft every launch).
            "-clawdmeter.composer.draft.\(Self.seedSessionId)", "",
            "-clawdmeter.composer.draft.empty", "",
        ]
        // Terminal tabs now launch `claude --dangerously-skip-permissions`
        // (TerminalPtyRegistry.spawnShell) instead of a bare shell. Inject the
        // fake-claude binary for the terminal tests too so they stay
        // deterministic — the fixture script emits output once then stays
        // alive, which is exactly the "connected + survives reconnect" behavior
        // these tests assert — instead of spawning the host's real claude.
        let usesFakeClaudeBinary = usesPlanApprovalFixture
            || name.localizedCaseInsensitiveContains("terminal")
        if usesFakeClaudeBinary {
            app.launchArguments += [
                "-clawdmeter.binaries.claude", fixture.fakeClaudeBinary.path,
            ]
        }
        app.launchEnvironment["CLAWDMETER_UI_TESTING"] = "1"
        app.launchEnvironment["CLAWDMETER_TEST_APP_SUPPORT_DIR"] = testAppSupportDirectory.path
        app.launchEnvironment["CLAWDMETER_TEST_CLAUDE_PROJECTS_ROOT"] = testClaudeProjectsRoot.path
        app.launchEnvironment["CLAWDMETER_PROVIDER_CLAUDE_ENABLED"] = "1"
        app.launchEnvironment["CLAWDMETER_PROVIDER_GEMINI_ENABLED"] = "1"
        if usesMultiSessionTabsFixture {
            app.launchEnvironment["CLAWDMETER_PROVIDER_CODEX_ENABLED"] = "1"
            app.launchEnvironment["CLAWDMETER_PROVIDER_OPENCODE_ENABLED"] = "1"
            app.launchEnvironment["CLAWDMETER_PROVIDER_CURSOR_ENABLED"] = "1"
            app.launchEnvironment["CLAWDMETER_PROVIDER_GROK_ENABLED"] = "1"
        }
        app.launchEnvironment["CLAWDMETER_DISABLE_PROVIDER_POLLERS"] = "1"
        app.launchEnvironment["CLAWDMETER_TEST_CODE_PR_SESSION_ID"] = Self.seedSessionId
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        if let testAppSupportDirectory {
            try? FileManager.default.removeItem(at: testAppSupportDirectory)
        }
        testAppSupportDirectory = nil
        testClaudeProjectsRoot = nil
        testRepoRootDirectory = nil
        fakeClaudeBinaryURL = nil
    }

    func testCodeTabComposerControlsExposeShortcutTargets() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        if row.waitForExistence(timeout: 10) {
            row.click()
        }

        XCTAssertTrue(element("code.composer.model").waitForExistence(timeout: 10), "Model selector should expose a stable hover/shortcut target.")
        XCTAssertTrue(element("code.composer.permission-mode").waitForExistence(timeout: 10), "Plan/permission selector should expose a stable hover/shortcut target.")
        XCTAssertTrue(element("code.composer.context-usage").waitForExistence(timeout: 10), "Context display should expose a stable hover/shortcut target.")
        XCTAssertTrue(element("code.composer.dictation").waitForExistence(timeout: 10), "Dictation should expose a stable Code composer target.")
        XCTAssertTrue(element("code.composer.send").waitForExistence(timeout: 10), "Send should be an icon-only bottom-right action with a stable target.")
        XCTAssertTrue(element("code.workspace.new-tab").waitForExistence(timeout: 10), "Workspace tab strip should expose the new-tab menu.")

        // attach / history / saved-prompts / paste-ansi / expand now live behind
        // the composer "+" tools menu (Claude-Desktop style). Open it and assert
        // each row is still addressable by its stable identifier.
        openComposerToolsMenu()
        for (id, title) in [
            ("code.composer.attach", "Attach File…"),
            ("code.composer.history", "Prompt History"),
            ("code.composer.saved-prompts", "Saved Prompts"),
            ("code.composer.paste-ansi", "Paste Without ANSI Codes"),
            ("code.composer.expand", "Expand Editor"),
        ] {
            // Hedge identifier + title — SwiftUI Menu-item identifier exposure
            // in XCUITest is timing/version-sensitive (file convention).
            XCTAssertTrue(
                waitForAny([element(id), app.menuItems[title]], timeout: 5),
                "Composer tools menu should expose \(id)."
            )
        }
        app.typeKey(.escape, modifierFlags: [])

        // ⌘U attach still works — it's driven by the menu command notification,
        // not the (now-relocated) attach button.
        app.typeKey("u", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testContextUsageChipOpensRenderedPopoverRowsFromCodeComposer() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let chip = element("code.composer.context-usage")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "Context usage chip should render in the Code composer.")
        XCTAssertTrue(
            accessibilityValue(of: chip).contains("0%"),
            "The fixture has no transcript token usage, so the context ring should be context-only at 0%."
        )
        chip.click()

        XCTAssertTrue(element("code.context-usage.popover").waitForExistence(timeout: 5), "Clicking the chip should open the context usage popover.")
        XCTAssertTrue(element("code.context-usage.section.context").waitForExistence(timeout: 5), "Popover should render the context breakdown header.")
        XCTAssertTrue(element("code.context-usage.row.messages").waitForExistence(timeout: 5), "Popover should render context breakdown category rows.")
    }

    func testPromptHistoryRenderedSheetSearchUseCopyAndDeleteRows() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        openComposerToolsMenu()
        element("code.composer.history").click()
        XCTAssertTrue(element("code.prompt-history.sheet").waitForExistence(timeout: 5), "Prompt history should open a rendered sheet.")

        let search = element("code.prompt-history.search")
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Prompt history should expose a rendered search field.")
        search.click()
        app.typeText("regression")

        let historyRow = app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@",
            Self.seededHistoryPrompt
        )).firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5), "Filtering should keep the matching history row visible.")
        historyRow.click()

        XCTAssertTrue(waitForComposerInput(containing: Self.seededHistoryPrompt, timeout: 5), "Clicking a history row should insert it into the Code composer.")

        openComposerToolsMenu()
        element("code.composer.history").click()
        let savedRow = element("code.prompt-history.saved.\(Self.seededSavedPromptId)")
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5), "Prompt history should render seeded saved-prompt rows with stable IDs.")
        savedRow.rightClick()
        clickMenuItem(identifier: "unused.copy.prompt", title: "Copy Prompt")
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            Self.seededSavedPromptBody,
            "Copy Prompt should write the saved prompt body to the pasteboard."
        )

        savedRow.rightClick()
        clickMenuItem(identifier: "unused.delete.saved.prompt", title: "Delete Saved Prompt")
        XCTAssertTrue(waitForNonExistence(savedRow, timeout: 5), "Deleting a saved prompt from the rendered history sheet should remove that row.")
        XCTAssertFalse(
            sessionPresentationJSON().contains(Self.seededSavedPromptId),
            "Deleting a saved prompt from the rendered sheet should persist to session-presentation.json."
        )

        element("code.prompt-history.done").click()
    }

    func testExpandedComposerEditorSavesPromptAndSavedPromptMenuReusesIt() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let input = element("code.composer.input")
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Code composer input should render before opening the expanded editor.")
        input.click()
        app.typeText("Draft body from expanded editor")

        openComposerToolsMenu()
        element("code.composer.expand").click()
        XCTAssertTrue(element("code.composer.expanded-editor").waitForExistence(timeout: 5), "Expanded editor should open as a rendered sheet.")

        let expandedInput = element("code.composer.expanded.input")
        XCTAssertTrue(expandedInput.waitForExistence(timeout: 5), "Expanded editor should expose the editable prompt body.")
        expandedInput.click()
        app.typeText(" with saved prompt details")

        let title = element("code.composer.expanded.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Expanded editor should expose the saved-prompt title field.")
        title.click()
        app.typeText("Saved UI Prompt")

        let save = element("code.composer.expanded.save-prompt")
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Expanded editor should expose Save Prompt.")
        XCTAssertTrue(save.isEnabled, "Save Prompt should enable for non-empty editor text.")
        save.click()
        let persisted = waitUntil(timeout: 5) {
            let json = self.sessionPresentationJSON()
            return json.contains("Saved UI Prompt")
                && json.contains("Draft body from expanded editor with saved prompt details")
        }
        if !persisted {
            // Failure diagnostics: capture what actually persisted and what
            // the rendered editor held, so a red run is debuggable from the
            // result bundle without rerunning locally.
            let json = sessionPresentationJSON()
            let attachment = XCTAttachment(string: """
            session-presentation.json:
            \(json.isEmpty ? "<missing/empty>" : json)

            expanded input value: \(accessibilityValue(of: element("code.composer.expanded.input")))
            expanded title value: \(accessibilityValue(of: element("code.composer.expanded.title")))
            """)
            attachment.name = "save-prompt-persistence-diagnostics"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(persisted, "Save Prompt from the rendered expanded editor should persist the prompt.")

        element("code.composer.expanded.done").click()
        XCTAssertTrue(waitForNonExistence(element("code.composer.expanded-editor"), timeout: 5), "Done should close the expanded editor sheet.")

        input.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Temporary overwritten text")
        XCTAssertTrue(waitForComposerInput(containing: "Temporary overwritten text", timeout: 5), "The composer should accept replacement text before menu reuse.")

        openComposerToolsMenu()
        element("code.composer.saved-prompts").click()   // opens the Saved Prompts submenu
        XCTAssertTrue(app.menuItems["Saved UI Prompt"].waitForExistence(timeout: 5),
                      "Saved Prompts submenu should open and expose the saved row.")
        clickMenuItem(identifier: "unused.saved.ui.prompt", title: "Saved UI Prompt")
        XCTAssertTrue(
            waitForComposerInput(containing: "Draft body from expanded editor with saved prompt details", timeout: 5),
            "Selecting the saved prompt from the rendered menu should restore the saved body into the composer."
        )
    }

    func testWorkspaceTerminalShortcutOpensDirectShellTabFromCodeTab() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        app.typeKey("t", modifierFlags: [.command, .shift])

        XCTAssertTrue(element("code.workspace.tab.terminal").waitForExistence(timeout: 10), "Command-Shift-T should create a Code workspace terminal tab.")
        XCTAssertTrue(element("code.workspace.terminal.surface").waitForExistence(timeout: 10), "The Code terminal tab should render the in-app direct shell surface.")
        XCTAssertTrue(app.staticTexts["Terminal connected"].waitForExistence(timeout: 15), "The terminal surface should connect to a live direct shell, not remain stuck in the starting state.")
    }

    func testWorkspaceTerminalReconnectsAfterSocketDrop() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        app.typeKey("t", modifierFlags: [.command, .shift])

        XCTAssertTrue(element("code.workspace.terminal.surface").waitForExistence(timeout: 10), "The Code terminal tab should render the in-app direct shell surface.")
        XCTAssertTrue(
            waitForTerminalStatus(
                identifier: "code.workspace.terminal.status.state",
                text: "Terminal connected",
                timeout: 15,
                stableFor: 0.2
            ),
            "The terminal surface should connect before the socket-drop regression runs."
        )

        DistributedNotificationCenter.default().post(
            name: Notification.Name("ai.continuum.mac.uiTesting.dropTerminalWebSockets"),
            object: nil
        )

        XCTAssertTrue(
            waitForTerminalStatus(
                identifier: "code.workspace.terminal.status.state",
                text: "Terminal reconnecting",
                timeout: 8
            ),
            "Dropping the terminal WebSocket should surface reconnecting state instead of freezing."
        )
        XCTAssertTrue(
            waitForTerminalStatus(
                identifier: "code.workspace.terminal.status.state",
                text: "Terminal connected",
                timeout: 20
            ),
            "The terminal should reconnect to the same direct shell after a dropped WebSocket."
        )
    }

    func testCodeTabSidebarPrimaryControlsExposeTargets() throws {
        openCodeTab()

        XCTAssertTrue(element("code.sidebar.search").waitForExistence(timeout: 10), "Code sidebar search should be a real focused field.")
        XCTAssertTrue(element("code.sidebar.filter").waitForExistence(timeout: 10), "Code sidebar filter menu should be addressable.")
        XCTAssertTrue(element("code.sidebar.add-project").waitForExistence(timeout: 10), "Code Add project menu should be addressable.")
        XCTAssertTrue(element("code.repo.toggle").waitForExistence(timeout: 10), "Repo disclosure should be addressable.")
        XCTAssertTrue(element("code.repo.settings").waitForExistence(timeout: 10), "Repo settings gear should be addressable.")
        XCTAssertTrue(element("code.repo.new-session").waitForExistence(timeout: 10), "Repo quick new-session button should be addressable.")
        XCTAssertTrue(workspaceLeafRowElement().waitForExistence(timeout: 10), "Seeded worktree row should be addressable.")

        element("code.sidebar.search").click()
        app.typeText("Preview")
        XCTAssertTrue(element("code.sidebar.search.clear").waitForExistence(timeout: 5), "Typing in search should reveal clear control.")
        element("code.sidebar.search.clear").click()
    }

    func testRepoSettingsMenuExposesRowsAndNewSessionAction() throws {
        openCodeTab()

        let repoSettings = firstElement("code.repo.settings")
        XCTAssertTrue(repoSettings.waitForExistence(timeout: 10), "Repo settings gear should be addressable.")
        repoSettings.click()

        for menuRow in [
            ("code.repo.settings.new-session", "New session here"),
            ("code.repo.settings.archive-all", "Archive all sessions"),
            ("code.repo.settings.archive-repo", "Archive entire repo"),
            ("code.repo.settings.open-settings", "Settings & Env Variables…"),
            ("code.repo.settings.remove", "Remove from list"),
        ] {
            XCTAssertTrue(
                element(menuRow.0).waitForExistence(timeout: 5),
                "Repo settings menu should expose \(menuRow.1)."
            )
        }

        clickMenuItem(identifier: "code.repo.settings.new-session", title: "New session here")
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5), "New session here should open the Code launcher for the repo.")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testRepoSettingsOpenSettingsShowsRepoSettingsSheet() throws {
        openCodeTab()

        openRepoSettingsMenu()
        clickMenuItem(identifier: "code.repo.settings.open-settings", title: "Settings & Env Variables")

        XCTAssertTrue(
            element("code.repo.settings.sheet").waitForExistence(timeout: 5),
            "Settings & Env Variables should open the repo settings sheet."
        )
        XCTAssertTrue(
            element("settings.env.root").waitForExistence(timeout: 5),
            "Repo settings sheet should include the env variables manager."
        )

        element("code.repo.settings.done").click()
        XCTAssertTrue(
            waitForNonExistence(element("code.repo.settings.sheet"), timeout: 5),
            "Done should dismiss the repo settings sheet."
        )
    }

    func testRepoSettingsArchiveAllArchivesSessionsWithoutRemovingWorkspace() throws {
        openCodeTab()

        openRepoSettingsMenu()
        clickMenuItem(identifier: "code.repo.settings.archive-all", title: "Archive all sessions")

        XCTAssertTrue(waitForSeedSessionArchived(timeout: 5), "Archive all should persist archivedAt for the seeded session.")
        XCTAssertTrue(seedWorkspaceExists(), "Archive all should not remove the managed workspace record.")
        XCTAssertTrue(waitForNonExistence(element("code.worktree.row"), timeout: 5), "Archive all should hide the archived worktree from the default sidebar.")

        selectArchivedFilter()
        XCTAssertTrue(workspaceLeafRowElement().waitForExistence(timeout: 5), "Archived filter should show sessions archived through repo settings.")
    }

    func testRepoSettingsArchiveEntireRepoArchivesSessionsAndRemovesWorkspace() throws {
        openCodeTab()

        openRepoSettingsMenu()
        clickMenuItem(identifier: "code.repo.settings.archive-repo", title: "Archive entire repo")

        XCTAssertTrue(waitForSeedSessionArchived(timeout: 5), "Archive entire repo should archive every session in the repo.")
        XCTAssertTrue(waitForSeedWorkspaceRemoved(timeout: 5), "Archive entire repo should remove the managed workspace record.")

        selectArchivedFilter()
        XCTAssertTrue(workspaceLeafRowElement().waitForExistence(timeout: 5), "Archived filter should still show the archived session after the workspace record is removed.")
    }

    func testRepoSettingsRemoveDropsWorkspaceRecordWithoutArchivingSession() throws {
        openCodeTab()

        XCTAssertTrue(seedWorkspaceExists(), "Fixture should start with a managed workspace record.")
        XCTAssertFalse(seedSessionArchived(), "Fixture session should start unarchived.")

        openRepoSettingsMenu()
        clickMenuItem(identifier: "code.repo.settings.remove", title: "Remove from list")

        XCTAssertTrue(waitForSeedWorkspaceRemoved(timeout: 5), "Remove from list should delete only the managed workspace record.")
        XCTAssertFalse(seedSessionArchived(), "Remove from list must not archive or delete existing session history.")
        XCTAssertTrue(workspaceLeafRowElement().waitForExistence(timeout: 5), "Removing the workspace record should leave the existing session visible/recoverable.")
    }

    func testWorktreeHoverArchiveRevealsActionAndMovesRowToArchivedFilter() throws {
        openCodeTab()

        let row = element("code.worktree.row")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded worktree row should render before archiving.")
        movePointer(to: row.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)))

        let archive = element("code.session.action.archive")
        if !archive.waitForExistence(timeout: 3) {
            row.click()
        }
        XCTAssertTrue(archive.waitForExistence(timeout: 5), "Hovering or selecting the worktree row should reveal one archive action.")
        archive.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(waitForSeedSessionArchived(timeout: 5), "Clicking the archive action should persist archivedAt for the seeded session.")
        XCTAssertTrue(waitForNonExistence(row, timeout: 5), "Archived worktree row should disappear from the default sidebar.")

        selectArchivedFilter()
        XCTAssertTrue(workspaceLeafRowElement().waitForExistence(timeout: 5), "Archived filter should show the archived worktree row.")
    }

    func testCodeTabTitlebarFilterAndCommandKFocusSidebarSearch() throws {
        openCodeTab()

        let titlebarFilter = element("code.titlebar.focus-filters")
        XCTAssertTrue(titlebarFilter.waitForExistence(timeout: 10), "Code titlebar should expose a filter-focus control.")
        titlebarFilter.click()
        app.typeText("Preview")
        XCTAssertTrue(element("code.sidebar.search.clear").waitForExistence(timeout: 5), "Clicking the titlebar filter control should focus sidebar search.")
        element("code.sidebar.search.clear").click()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        app.typeKey("k", modifierFlags: .command)
        app.typeText("Repo")
        XCTAssertTrue(element("code.sidebar.search.clear").waitForExistence(timeout: 5), "Command-K should switch focus back to Code sidebar search.")
        element("code.sidebar.search.clear").click()
    }

    func testTitlebarRightPaneMenuSelectsEveryPaneAndCollapse() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let menu = element("code.titlebar.right-pane")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Code titlebar should expose the right-pane menu.")

        for target in [
            ("plan", "Plan"),
            ("diff", "Diff"),
            ("terminal", "Terminal"),
            ("sources", "Sources"),
            ("artifacts", "Artifacts"),
            ("pr", "PR"),
            ("browser", "Browser"),
        ] {
            menu.click()
            clickMenuItem(identifier: "code.titlebar.right-pane.\(target.0)", title: target.1)

            let pane = element("code.review.pane")
            XCTAssertTrue(pane.waitForExistence(timeout: 5), "Selecting \(target.1) from the titlebar menu should reveal the review pane.")
            XCTAssertTrue(
                element("code.review.selected.\(target.0)").waitForExistence(timeout: 5),
                "Selecting \(target.1) should update the review pane selection."
            )
        }

        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        clickMenuItem(identifier: "code.titlebar.right-pane.collapse", title: "Collapse pane")
        XCTAssertTrue(waitForNonExistence(element("code.review.pane"), timeout: 5), "Collapse pane should hide the review pane.")

        menu.click()
        clickMenuItem(identifier: "code.titlebar.right-pane.expand", title: "Expand pane")
        XCTAssertTrue(element("code.review.pane").waitForExistence(timeout: 5), "Expand pane should reveal the review pane again.")
    }

    func testCenterHeaderDensityMenuUpdatesTranscriptDensity() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let density = element("code.header.density")
        XCTAssertTrue(density.waitForExistence(timeout: 10), "Center header should expose transcript density.")
        XCTAssertTrue(element("code.header.density.selected.balanced").waitForExistence(timeout: 5), "Seeded workspace should start with balanced density.")

        density.click()
        clickMenuItem(identifier: "code.header.density.detailed", title: "Detailed")
        XCTAssertTrue(element("code.header.density.selected.detailed").waitForExistence(timeout: 5), "Selecting Detailed should update the density state.")

        density.click()
        clickMenuItem(identifier: "code.header.density.compact", title: "Compact")
        XCTAssertTrue(element("code.header.density.selected.compact").waitForExistence(timeout: 5), "Selecting Compact should update the density state.")
    }

    func testWorkspaceNewTabButtonCreatesUnboundedChatDraftTabsFromCodeTab() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let newTab = element("code.workspace.new-tab")
        XCTAssertTrue(newTab.waitForExistence(timeout: 10), "Workspace tab strip should expose the new-tab menu.")
        let tabStrip = element("code.workspace.tab-strip")
        XCTAssertTrue(tabStrip.waitForExistence(timeout: 10), "Workspace tab strip should expose a rendered tab count.")

        for draftCount in 1...5 {
            element("code.workspace.new-tab").click()
            XCTAssertTrue(element("code.workspace.tab.draft").waitForExistence(timeout: 5), "Clicking + should open a draft workspace tab.")
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    self.renderedWorkspaceDraftTabCount() == draftCount
                },
                "Clicking + repeatedly should append draft tabs beyond two; expected \(draftCount) rendered draft tabs."
            )
        }

        let draftTabs = app.descendants(matching: .any).matching(identifier: "code.workspace.tab.draft")
        XCTAssertEqual(draftTabs.count, 5, "The workspace strip should expose every draft tab, not cap rendering at two.")
        let fifthDraft = draftTabs.element(boundBy: 4)
        XCTAssertTrue(fifthDraft.waitForExistence(timeout: 5), "The fifth draft tab should exist in the rendered tab strip.")
        XCTAssertTrue(fifthDraft.isHittable, "The tab strip should auto-scroll the newly selected fifth draft into view.")
        XCTAssertTrue(
            accessibilityValue(of: fifthDraft).contains("selected"),
            "The newly-created fifth draft should remain the selected workspace tab."
        )
        XCTAssertTrue(
            newTab.isHittable,
            "The + button must stay outside the scrollable tab items so tab creation never becomes visually capped."
        )
        newTab.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.renderedWorkspaceDraftTabCount() == 6
            },
            "The overflow-safe + button should keep appending draft tabs after the strip overflows."
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "code.workspace.tab.draft").count,
            6,
            "The workspace strip should keep exposing draft tabs beyond the previous visible cap."
        )
    }

    func testWorkspaceSessionTabsRenderEverySameWorktreeModelSessionAndSwitchHeader() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code worktree should render in the sidebar.")
        row.click()

        XCTAssertTrue(
            waitUntil(timeout: 10) {
                self.renderedWorkspaceSessionTabCount() == Self.sameWorktreeSessionFixtures.count
            },
            "The workspace tab strip should render every same-worktree provider/model session, not cap at two."
        )

        for session in Self.sameWorktreeSessionFixtures {
            let tab = sessionTabElement(id: session.id)
            XCTAssertTrue(
                tab.waitForExistence(timeout: 5),
                "Session tab for \(session.provider) should be exposed with its stable session id."
            )
            let value = accessibilityValue(of: tab)
            XCTAssertTrue(value.contains(session.agent), "Session tab value should include provider id \(session.agent).")
            XCTAssertTrue(value.contains(session.model), "Session tab value should include model id \(session.model).")
        }

        for session in [Self.sameWorktreeSessionFixtures[4], Self.sameWorktreeSessionFixtures[5]] {
            let tab = sessionTabElement(id: session.id)
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Session tab for \(session.provider) should exist before switching.")
            XCTAssertTrue(tab.isHittable, "\(session.provider) session tab should be visible/hittable in the crowded strip.")
            tab.click()

            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    let state = self.accessibilityValue(of: self.centerHeaderStateElement(id: session.id))
                    return state.localizedCaseInsensitiveContains(session.id)
                        && state.localizedCaseInsensitiveContains(session.title)
                        && state.localizedCaseInsensitiveContains(session.agent)
                        && state.localizedCaseInsensitiveContains(session.model)
                },
                "Switching to \(session.provider) should update the center header session, provider, and model. Actual header state: \(currentCenterHeaderState())"
            )
            XCTAssertTrue(
                accessibilityValue(of: tab).contains("selected"),
                "\(session.provider) session tab should expose selected state after switching."
            )
        }
    }

    func testWorkspaceNewTabShortcutCreatesUnboundedChatDraftTabsFromDraftSelection() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let tabStrip = element("code.workspace.tab-strip")
        XCTAssertTrue(tabStrip.waitForExistence(timeout: 10), "Workspace tab strip should expose a rendered tab count.")

        for draftCount in 1...4 {
            app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(element("code.workspace.tab.draft").waitForExistence(timeout: 5), "Command-T should open a draft workspace tab.")
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    self.renderedWorkspaceDraftTabCount() == draftCount
                },
                "Command-T should keep appending draft tabs while a draft is selected; expected \(draftCount) rendered draft tabs."
            )
        }
    }

    func testWorkspaceNewTabContextMenuTerminalOpensDirectShellTab() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let newTab = element("code.workspace.new-tab")
        XCTAssertTrue(newTab.waitForExistence(timeout: 10), "Workspace tab strip should expose the new-tab secondary menu.")
        newTab.rightClick()

        XCTAssertTrue(
            waitForAny([element("code.workspace.new-tab.chat"), app.menuItems["Chat"]], timeout: 5),
            "New-tab context menu should expose Chat."
        )
        clickMenuItem(identifier: "code.workspace.new-tab.terminal", title: "Terminal")

        XCTAssertTrue(element("code.workspace.tab.terminal").waitForExistence(timeout: 10), "New-tab secondary Terminal action should create a workspace terminal tab.")
        XCTAssertTrue(element("code.workspace.terminal.surface").waitForExistence(timeout: 10), "New-tab secondary Terminal action should render the in-app direct shell surface.")
        XCTAssertTrue(app.staticTexts["Terminal connected"].waitForExistence(timeout: 15), "The terminal tab opened from the new-tab context menu should connect to a live direct shell.")
    }

    func testDraftModelPickerSwitchesDraftToAntigravityWithoutOpeningOldSession() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let newTab = element("code.workspace.new-tab")
        XCTAssertTrue(newTab.waitForExistence(timeout: 10), "Workspace tab strip should expose the new-tab menu.")
        newTab.click()
        XCTAssertTrue(element("code.workspace.tab.draft").waitForExistence(timeout: 5), "Clicking + should open a draft workspace tab.")

        let modelChip = element("code.composer.model")
        XCTAssertTrue(modelChip.waitForExistence(timeout: 10), "Draft composer should expose the model picker chip.")
        modelChip.click()

        XCTAssertTrue(element("code.composer.model-picker.search").waitForExistence(timeout: 5), "Clicking the chip should open the rich model picker.")
        let antigravityRail = element("code.composer.model-picker.rail.antigravity")
        let pickerDebug = debugHierarchyLines(containing: ["model-picker", "Antigravity", "Gemini", "Claude"])
        XCTAssertTrue(
            antigravityRail.waitForExistence(timeout: 5),
            "Provider-enabled picker should expose the Antigravity rail.\n\(pickerDebug)"
        )
        antigravityRail.click()

        let thinkingRow = element("code.composer.model-picker.row.antigravity.gemini-3-5-flash-thinking")
        if !thinkingRow.waitForExistence(timeout: 1) {
            if !element("code.composer.model-picker.search").exists {
                modelChip.click()
                XCTAssertTrue(element("code.composer.model-picker.search").waitForExistence(timeout: 5), "Model picker should reopen after an interrupted provider click.")
            }
            let retryRail = element("code.composer.model-picker.rail.antigravity")
            XCTAssertTrue(retryRail.waitForExistence(timeout: 5), "Antigravity rail should still be available after reopening the picker.")
            retryRail.click()
        }
        XCTAssertTrue(thinkingRow.waitForExistence(timeout: 5), "Antigravity rail should list Gemini 3.5 Flash Thinking.")
        thinkingRow.click()

        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: modelChip).contains("Gemini 3.5 Flash")
            },
            "Selecting Gemini 3.5 Flash Thinking should update the draft chip instead of returning to a stale session."
        )
        let draftTab = element("code.workspace.tab.draft")
        XCTAssertTrue(draftTab.exists, "Model switching should keep the active workspace tab on the draft.")
        XCTAssertTrue(
            accessibilityValue(of: draftTab).localizedCaseInsensitiveContains("gemini"),
            "Draft tab subtitle should reflect the Antigravity provider selection. Actual: \(accessibilityValue(of: draftTab))"
        )
        let headerConfig = element("code.center.header.configuration")
        XCTAssertTrue(headerConfig.waitForExistence(timeout: 5), "Draft workspace should expose the center header configuration row.")
        XCTAssertTrue(
            headerConfig.label.localizedCaseInsensitiveContains("Antigravity")
                || headerConfig.label.localizedCaseInsensitiveContains("Gemini 3.5 Flash"),
            "Header configuration should mirror the draft model picker. Actual: \(headerConfig.label)"
        )
        let headerState = firstElement("code.center.header.state")
        XCTAssertTrue(
            headerState.label.localizedCaseInsensitiveContains("gemini")
                && headerState.label.localizedCaseInsensitiveContains("gemini-3-5-flash-thinking"),
            "Header state marker should include the selected draft provider and model. Actual: \(headerState.label)"
        )
    }

    func testDraftModelPickerSearchFavoriteShortcutAndUnsupportedEffortPaths() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let newTab = element("code.workspace.new-tab")
        XCTAssertTrue(newTab.waitForExistence(timeout: 10), "Workspace tab strip should expose the new-tab menu.")
        newTab.click()
        XCTAssertTrue(element("code.workspace.tab.draft").waitForExistence(timeout: 5), "Clicking + should open a draft workspace tab.")

        let modelChip = element("code.composer.model")
        let effortChip = element("code.composer.effort")
        XCTAssertTrue(modelChip.waitForExistence(timeout: 10), "Draft composer should expose the model picker chip.")
        XCTAssertTrue(effortChip.waitForExistence(timeout: 10), "Draft composer should expose the effort chip.")
        modelChip.click()
        XCTAssertTrue(element("code.composer.model-picker.search").waitForExistence(timeout: 5), "Clicking the chip should open the rich model picker.")

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: modelChip).contains("Opus 4.8")
            },
            "Command-1 in the picker should select the first visible model row and update the draft chip."
        )

        effortChip.click()
        XCTAssertTrue(app.menuItems["Minimal"].waitForExistence(timeout: 5), "Effort menu should expose Minimal.")
        app.menuItems["Minimal"].click()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: effortChip).contains("Minimal")
            },
            "Selecting Minimal from the effort chip menu should update the draft effort chip."
        )
        app.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: effortChip).contains("Low")
            },
            "Command-Option-E should cycle effort up and update the draft effort chip without leaving Code."
        )
        app.typeKey("e", modifierFlags: [.command, .option, .shift])
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: effortChip).contains("Minimal")
            },
            "Command-Option-Shift-E should cycle effort down and update the draft effort chip without leaving Code."
        )

        let search = element("code.composer.model-picker.search")
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Picker search should remain addressable after changing effort.")
        search.click()
        app.typeText("Haiku")

        let haikuRow = element("code.composer.model-picker.row.claude.claude-haiku-4-5-20251001")
        XCTAssertTrue(haikuRow.waitForExistence(timeout: 5), "Searching Haiku should reveal the unsupported-effort Claude Haiku row.")
        let haikuFavorite = element("code.composer.model-picker.favorite.claude.claude-haiku-4-5-20251001")
        XCTAssertTrue(haikuFavorite.waitForExistence(timeout: 5), "Each model row should expose an addressable favorite control.")
        haikuFavorite.click()

        let clearSearch = element("code.composer.model-picker.search.clear")
        XCTAssertTrue(clearSearch.waitForExistence(timeout: 5), "Typing a search should reveal an addressable clear control.")
        clearSearch.click()
        element("code.composer.model-picker.rail.favorites").click()
        XCTAssertTrue(
            haikuRow.waitForExistence(timeout: 5),
            "Starring Haiku should make it appear under the Favorites rail after clearing search."
        )
        haikuRow.click()

        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: modelChip).contains("Haiku 4.5")
            },
            "Selecting an unsupported-effort model should update the draft model chip."
        )
        XCTAssertFalse(
            effortChip.waitForExistence(timeout: 1),
            "Unsupported-effort models should hide the effort chip."
        )
        XCTAssertTrue(element("code.workspace.tab.draft").exists, "Picker search/favorite/effort actions should keep the active workspace tab on the draft.")
    }

    func testPermissionModeChipOpensMenuAndShortcutsUpdateDraftComposer() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let newTab = element("code.workspace.new-tab")
        XCTAssertTrue(newTab.waitForExistence(timeout: 10), "Workspace tab strip should expose the new-tab menu.")
        newTab.click()
        XCTAssertTrue(element("code.workspace.tab.draft").waitForExistence(timeout: 5), "Clicking + should open a draft workspace tab.")

        let permissionChip = element("code.composer.permission-mode")
        XCTAssertTrue(permissionChip.waitForExistence(timeout: 10), "Draft composer should expose the permission-mode chip.")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip).contains("Ask permissions")
            },
            "New draft composers should start in Ask permissions mode."
        )

        // The entire pill is the hit target now: clicking the chip BODY (not
        // just the chevron) opens the mode menu. Quick-flip-on-click was
        // removed — selecting from the menu is the only click path.
        permissionChip.click()
        clickMenuItem(identifier: "code.composer.permission-mode.plan", title: "Plan mode")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip).contains("Plan mode")
            },
            "Clicking anywhere on the permission pill should open the menu; selecting Plan mode switches the draft into Plan mode."
        )

        app.typeKey("1", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip).contains("Ask permissions")
            },
            "Command-Shift-1 should switch the draft composer back to Ask permissions."
        )

        app.typeKey("2", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip).contains("Accept edits")
            },
            "Command-Shift-2 should switch the draft composer to Accept edits without opening another session."
        )
        XCTAssertTrue(element("code.workspace.tab.draft").exists, "Permission-mode shortcuts should keep the active workspace on the draft.")
    }

    func testPermissionModeMenuRowsAndBypassTrustSheetGate() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        let sessionRow = element("code.session.row")
        if sessionRow.waitForExistence(timeout: 1) {
            sessionRow.click()
        } else {
            row.click()
        }
        XCTAssertTrue(element("code.center.header").waitForExistence(timeout: 10), "Bypass trust coverage must start from a bound session, not the empty/draft composer.")

        let permissionChip = element("code.composer.permission-mode")
        XCTAssertTrue(permissionChip.waitForExistence(timeout: 10), "Seeded session should expose the permission-mode chip.")
        let menu = element("code.composer.permission-mode.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Permission-mode chip should expose a separate full menu target.")
        let priorSessionMode = accessibilityValue(of: permissionChip)

        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        clickMenuItem(identifier: "code.composer.permission-mode.bypass", title: "Bypass permissions")
        XCTAssertTrue(
            waitForAny([
                element("code.permission.bypass-sheet"),
                element("code.permission.bypass.title"),
                app.staticTexts["Trust this repo for bypass mode?"],
                app.staticTexts["Enable bypass mode?"],
            ], timeout: 5),
            "Selecting Bypass on a bound session should open the trust/confirm sheet before changing mode."
        )
        let bypassWarning = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox")
        ).firstMatch
        XCTAssertTrue(
            waitForAny([element("code.permission.bypass.body"), bypassWarning], timeout: 5),
            "Bypass sheet should expose the dangerous-flags warning body."
        )
        XCTAssertTrue(
            waitForAny([
                element("code.permission.bypass.confirm"),
                app.buttons["Trust repo + enable bypass"],
                app.buttons["Enable + respawn"],
            ], timeout: 5),
            "Bypass sheet should expose an explicit confirm action."
        )
        let cancelChoices = [element("code.permission.bypass.cancel"), app.buttons["Cancel"]]
        XCTAssertTrue(waitForAny(cancelChoices, timeout: 5), "Bypass sheet should expose an explicit cancel action.")
        let cancel = firstExisting(cancelChoices)
        cancel.click()
        XCTAssertTrue(waitForNonExistence(cancel, timeout: 5), "Cancelling the bypass sheet should dismiss it.")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip) == priorSessionMode
            },
            "Cancelling the bypass sheet should leave the bound session permission mode unchanged."
        )

        let newTab = element("code.workspace.new-tab")
        XCTAssertTrue(newTab.waitForExistence(timeout: 10), "Workspace tab strip should expose the new-tab menu.")
        newTab.click()
        XCTAssertTrue(element("code.workspace.tab.draft").waitForExistence(timeout: 5), "Clicking + should open a draft workspace tab.")

        XCTAssertTrue(permissionChip.waitForExistence(timeout: 10), "Draft composer should expose the permission-mode chip.")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Draft permission-mode chip should expose a separate full menu target.")

        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        for row in [
            ("code.composer.permission-mode.ask", "Ask permissions"),
            ("code.composer.permission-mode.acceptEdits", "Accept edits"),
            ("code.composer.permission-mode.plan", "Plan mode"),
            ("code.composer.permission-mode.bypass", "Bypass permissions"),
        ] {
            XCTAssertTrue(
                waitForAny([element(row.0), app.menuItems[row.1]], timeout: 5),
                "Permission-mode menu should expose \(row.1)."
            )
        }
        clickMenuItem(identifier: "code.composer.permission-mode.plan", title: "Plan mode")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip).contains("Plan mode")
            },
            "Selecting Plan mode from the menu should update the draft chip to Plan mode."
        )

        menu.click()
        clickMenuItem(identifier: "code.composer.permission-mode.acceptEdits", title: "Accept edits")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip).contains("Accept edits")
            },
            "Selecting Accept edits from the menu should update the draft chip."
        )

        menu.click()
        clickMenuItem(identifier: "code.composer.permission-mode.bypass", title: "Bypass permissions")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip).contains("Bypass permissions")
            },
            "Selecting Bypass permissions from the draft menu should visibly switch the draft to Bypass permissions."
        )

        menu.click()
        clickMenuItem(identifier: "code.composer.permission-mode.ask", title: "Ask permissions")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: permissionChip).contains("Ask permissions")
            },
            "Selecting Ask permissions from the menu should restore the draft chip to Ask permissions."
        )
    }

    func testDraftFirstPromptComposerDoesNotExposeQueuedFollowUpsBeforeSend() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let newTab = element("code.workspace.new-tab")
        XCTAssertTrue(newTab.waitForExistence(timeout: 10), "Workspace tab strip should expose the new-tab menu.")
        newTab.click()
        XCTAssertTrue(element("code.workspace.tab.draft").waitForExistence(timeout: 5), "Clicking + should open a draft workspace tab.")

        let input = element("code.composer.input")
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Draft composer should expose a typed first-prompt input.")
        input.click()
        app.typeText("hello - this is the first prompt")

        let send = element("code.composer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Typed first prompt should keep the icon-only send target visible.")
        XCTAssertTrue(send.isEnabled, "Typed first prompt should enable Send instead of staging a queued follow-up.")
        XCTAssertFalse(element("code.queue.panel").exists, "A draft tab's first prompt must not appear in the queued follow-ups panel before it is sent.")
        XCTAssertFalse(element("code.queue.prompt").exists, "A draft tab's first prompt must stay in the composer, not in a queued prompt row.")
    }

    func testNewWorkspaceShortcutOpensLauncherFromCodeTab() throws {
        openCodeTab()

        app.typeKey("n", modifierFlags: .command)

        let startButton = app.buttons["Start"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5), "Command-N should open the new workspace/session launcher.")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSessionRenameShortcutWhenSessionExists() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")

        row.click()
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForAny([
                app.dialogs["Rename session"],
                app.staticTexts["Rename session"],
                app.textFields["Name"],
            ], timeout: 5),
            "Command-Shift-R should use the shared rename dialog."
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    func testPreviewChipOpensFullWorkspaceBrowserFromCompletedAssistantTurn() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let fullWorkspaceBrowser = element("code.browser.fullWorkspace")
        if fullWorkspaceBrowser.waitForExistence(timeout: 2) {
            XCTAssertTrue(element("code.browser.backToChat").waitForExistence(timeout: 5), "Restored Browser should expose Back to Chat.")
            element("code.browser.backToChat").click()
            XCTAssertTrue(waitForNonExistence(fullWorkspaceBrowser, timeout: 5), "Back to Chat should return to the transcript before exercising Preview.")
        }

        let preview = element("code.turn.preview")
        if preview.waitForExistence(timeout: 20) {
            preview.click()
        } else if !fullWorkspaceBrowser.waitForExistence(timeout: 2) {
            XCTFail("Completed assistant turn should expose a Preview chip or open the full-workspace Browser surface.")
        }
        XCTAssertTrue(fullWorkspaceBrowser.waitForExistence(timeout: 10), "Preview should open the full-workspace Browser surface.")
        XCTAssertTrue(workspaceLeafRowElement().exists, "Full-workspace Browser should keep the repo/worktree sidebar visible.")
        XCTAssertTrue(element("code.browser.backToChat").waitForExistence(timeout: 5), "Browser toolbar should expose Back to Chat.")
        XCTAssertTrue(element("code.browser.back").waitForExistence(timeout: 5), "Browser toolbar should expose Back navigation.")
        XCTAssertTrue(element("code.browser.forward").waitForExistence(timeout: 5), "Browser toolbar should expose Forward navigation.")
        XCTAssertTrue(waitForAny([element("code.browser.reload"), element("code.browser.stop-loading")], timeout: 5), "Browser toolbar should expose reload/stop loading.")
        XCTAssertTrue(element("code.browser.url").waitForExistence(timeout: 5), "Browser toolbar should expose URL entry.")
        XCTAssertTrue(element("code.browser.load-url").waitForExistence(timeout: 5), "Browser toolbar should expose URL load action.")
        XCTAssertTrue(element("code.browser.run-command").waitForExistence(timeout: 5), "Browser run bar should expose command input.")
        XCTAssertTrue(element("code.browser.run-start").waitForExistence(timeout: 5), "Browser run bar should expose start action.")
        XCTAssertTrue(element("code.browser.run-stop").waitForExistence(timeout: 5), "Browser run bar should expose stop action.")
        XCTAssertTrue(element("code.browser.run-output-toggle").waitForExistence(timeout: 5), "Browser run bar should expose output toggle.")
        XCTAssertTrue(element("code.browser.runStatus").waitForExistence(timeout: 5), "Browser toolbar should expose run status.")
        XCTAssertTrue(element("code.browser.restart").waitForExistence(timeout: 5), "Browser toolbar should expose restart.")

        element("code.browser.backToChat").click()
        XCTAssertTrue(waitForNonExistence(fullWorkspaceBrowser, timeout: 5), "Back to Chat should close the full-workspace Browser surface.")
    }

    func testCodeTabReviewPaneControlsExposeTargets() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        let gutterIds = [
            "code.review.gutter.plan",
            "code.review.gutter.diff",
            "code.review.gutter.sources",
            "code.review.gutter.artifacts",
            "code.review.gutter.browser",
            "code.review.gutter.pr",
            "code.review.gutter.terminal",
        ]

        if element(gutterIds[0]).waitForExistence(timeout: 3) {
            for id in gutterIds {
                XCTAssertTrue(element(id).waitForExistence(timeout: 5), "\(id) should be addressable in compact Code-tab layouts.")
            }
            element("code.review.gutter.terminal").click()
        } else {
            let rightPaneMenu = element("code.titlebar.right-pane")
            XCTAssertTrue(rightPaneMenu.waitForExistence(timeout: 5), "Code titlebar should expose the right-pane menu.")
            rightPaneMenu.click()
            for title in ["Plan", "Diff", "Terminal", "Sources", "Artifacts", "Browser", "PR"] {
                XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 5), "Right-pane menu should list \(title).")
            }
            app.menuItems["Terminal"].click()
        }

        XCTAssertTrue(element("code.review.pane").waitForExistence(timeout: 5), "Opening a review target should reveal the review pane.")
        let paneTabs = [
            "code.review.tab.plan",
            "code.review.tab.diff",
            "code.review.tab.sources",
            "code.review.tab.browser",
            "code.review.tab.pr",
            "code.review.tab.terminal",
        ]
        XCTAssertTrue(waitForAny(paneTabs.map(element), timeout: 3), "Expanded review pane should expose tab chips.")
        for id in paneTabs {
            XCTAssertTrue(element(id).waitForExistence(timeout: 5), "\(id) should be addressable.")
            element(id).click()
        }
        assertTerminalReviewTargetVisible()
    }

    func testPlanPaneApproveButtonApprovesRenderedPendingPlanAndCreatesCheckpoint() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded pending-plan Code session should render in the sidebar.")
        row.click()

        openReviewPaneTab(key: "plan", title: "Plan")
        XCTAssertTrue(element("code.plan-pane").waitForExistence(timeout: 10), "Plan pane should render for the pending-plan fixture.")
        let state = element("code.plan-pane.state")
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                self.accessibilityValue(of: state).localizedCaseInsensitiveContains("Pending approval")
            },
            "Plan pane should show the seeded pending approval state before clicking Approve; hierarchy:\n\(debugHierarchyLines(containing: ["code.plan-pane", "Pending approval", "Approve"]))"
        )
        XCTAssertTrue(element("code.plan-pane.steps").waitForExistence(timeout: 5), "The seeded pending plan should render parsed steps.")

        let priorCheckpointCount = checkpointRefCount()
        let approve = element("code.plan-pane.approve")
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "Pending Plan pane should expose the rendered Approve action.")
        approve.click()

        XCTAssertTrue(
            waitUntil(timeout: 15) {
                self.accessibilityValue(of: state).localizedCaseInsensitiveContains("Approved")
            },
            "Clicking the rendered Plan pane Approve button should call the approval route and flip the pane to approved state; hierarchy:\n\(debugHierarchyLines(containing: ["code.plan-pane", "Approved", "Pending approval", "Approve"]))"
        )
        XCTAssertTrue(waitForNonExistence(approve, timeout: 5), "Approved plan state should remove the pending Approve button.")
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                self.checkpointRefCount() >= priorCheckpointCount + 1
            },
            "Approving from the right Plan pane should create a lifecycle checkpoint before the route runs."
        )
    }

    func testSourcesAndArtifactsReviewPanesRenderSeededTranscriptContentAndClicks() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        openReviewPaneTab(key: "sources", title: "Sources")
        XCTAssertTrue(element("code.sources.pane").waitForExistence(timeout: 10), "Sources pane should render with stable target.")
        let sourceRows = app.descendants(matching: .any).matching(identifier: "code.sources.row")
        let notesSource = sourceRows.matching(NSPredicate(format: "label CONTAINS[c] %@", "notes.md")).firstMatch
        XCTAssertTrue(
            notesSource.waitForExistence(timeout: 10),
            "Sources pane should render the seeded Read tool row; hierarchy:\n\(debugHierarchyLines(containing: ["code.sources", "notes.md", "continuum-docs"]))"
        )
        XCTAssertTrue(
            sourceRows.matching(NSPredicate(format: "label CONTAINS[c] %@", "https://example.com/continuum-docs")).firstMatch.waitForExistence(timeout: 5),
            "Sources pane should render the seeded WebFetch URL row."
        )
        notesSource.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: self.element("code.sources.pane")).contains("file: notes.md")
            },
            "Clicking a source row should reach the open handler without launching external apps under UI tests."
        )

        openReviewPaneTab(key: "artifacts", title: "Artifacts")
        XCTAssertTrue(element("code.artifacts.pane").waitForExistence(timeout: 10), "Artifacts pane should render with stable target.")
        let artifactCard = app.descendants(matching: .any)
            .matching(identifier: "code.artifacts.card")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "report.md"))
            .firstMatch
        XCTAssertTrue(
            artifactCard.waitForExistence(timeout: 10),
            "Artifacts pane should render the seeded Write artifact; hierarchy:\n\(debugHierarchyLines(containing: ["code.artifacts", "report.md", "No artifacts"]))"
        )
        artifactCard.click()
        let artifactsPane = firstElement("code.artifacts.pane")
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                self.accessibilityValue(of: artifactsPane).contains("preview:report.md")
            },
            "Clicking an artifact should open the in-app preview state."
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                !self.accessibilityValue(of: artifactsPane).contains("preview:report.md")
            },
            "Escape should close the artifact preview state."
        )
    }

    func testDiffReviewPaneRenderedControlsClickThroughSeededGitDiff() throws {
        let diffNonce = UUID().uuidString
        try writeSeedRepoFile("initial checkpoint state\nlocal diff for rendered review controls \(diffNonce)\n")
        XCTAssertTrue(
            seedRepoStatusLines().contains { $0.contains("notes.md") },
            "The fixture repo should contain a tracked notes.md edit before opening the rendered Diff pane."
        )
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        openReviewPaneTab(key: "diff", title: "Diff")
        XCTAssertTrue(element("code.diff.toolbar").waitForExistence(timeout: 10), "Diff pane should render its toolbar for a dirty git worktree.")
        XCTAssertTrue(element("code.diff.files-count").waitForExistence(timeout: 5), "Diff toolbar should expose file count.")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: self.element("code.diff.unviewed-count")).contains("1 unviewed")
            },
            "Seeded tracked edit should start as one unviewed diff file."
        )

        let layout = element("code.diff.layout")
        XCTAssertTrue(layout.waitForExistence(timeout: 5), "Diff layout segmented control should be addressable.")
        layout.click()

        let next = element("code.diff.next-unviewed")
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Diff pane should expose Next unviewed.")
        XCTAssertTrue(next.isEnabled, "Next unviewed should be enabled before viewing the changed file.")
        next.click()

        XCTAssertTrue(element("code.diff.file.row").waitForExistence(timeout: 5), "Diff pane should render a changed-file row.")
        let reviewed = element("code.diff.file.mark-reviewed")
        XCTAssertTrue(reviewed.waitForExistence(timeout: 5), "Changed-file row should expose Mark reviewed.")
        XCTAssertTrue(reviewed.isEnabled, "Mark reviewed should be enabled for the changed file.")

        let flagChanges = element("code.diff.file.flag-changes")
        XCTAssertTrue(flagChanges.waitForExistence(timeout: 5), "Changed-file row should expose Flag changes.")
        XCTAssertTrue(flagChanges.isEnabled, "Flag changes should be enabled for the changed file.")

        let markAll = element("code.diff.mark-all-viewed")
        XCTAssertTrue(markAll.waitForExistence(timeout: 5), "Diff toolbar should expose Mark all viewed.")
        XCTAssertTrue(markAll.isEnabled, "Mark all viewed should be enabled while a diff exists.")
        markAll.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: self.element("code.diff.unviewed-count")).contains("0 unviewed")
            },
            "Mark all viewed should update the toolbar count in the rendered pane."
        )

        let markViewed = element("code.diff.file.mark-viewed")
        XCTAssertTrue(markViewed.waitForExistence(timeout: 5), "Changed-file row should keep the viewed-state action addressable.")
        XCTAssertFalse(markViewed.isEnabled, "The viewed action should be disabled once the file is already viewed.")

        let hunkToggle = element("code.diff.hunk.toggle-collapse")
        XCTAssertTrue(hunkToggle.waitForExistence(timeout: 5), "Diff hunk row should expose collapse/expand.")
        hunkToggle.click()
        hunkToggle.click()

        let explain = element("code.diff.hunk.explain")
        XCTAssertTrue(explain.waitForExistence(timeout: 5), "Diff hunk row should expose Explain.")
        explain.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: self.element("code.composer.input")).contains("Explain this diff hunk")
            },
            "Explain should insert a follow-up prompt into the Code composer."
        )
    }

    func testGitDiffPaneRenderedStageUnstageButtonsMutateSeededRepo() throws {
        let nonce = UUID().uuidString
        try writeSeedRepoFile("initial checkpoint state\nstaged git diff action \(nonce)\n")
        try Self.runGit(["add", "notes.md"], cwd: testRepoRootDirectory)
        try writeSeedRepoFile("initial checkpoint state\nstaged git diff action \(nonce)\nunstaged git diff action \(nonce)\n")
        XCTAssertTrue(
            seedRepoStatusLines().contains("MM notes.md"),
            "Fixture should start with both staged and unstaged changes before testing rendered Git diff buttons; got \(seedRepoStatusLines())."
        )

        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        openReviewPaneTab(key: "diff", title: "Diff")
        let gitModeCandidates = [
            element("code.diff.mode.git"),
            element("code.diff.mode.git.label"),
            app.buttons["Git"],
        ]
        XCTAssertTrue(
            waitForAny(gitModeCandidates, timeout: 10),
            "Diff pane should expose the Git action mode. Matching hierarchy:\n\(debugHierarchyLines(containing: ["code.diff", "Git", "Review"]))"
        )
        let gitMode = gitModeCandidates.first { $0.exists } ?? gitModeCandidates[0]
        gitMode.click()

        let gitPane = element("code.diff.git.pane")
        XCTAssertTrue(gitPane.waitForExistence(timeout: 10), "Git action pane should render inside the Code Diff tab.")
        let gitState = element("code.diff.git.state")
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                self.accessibilityValue(of: gitState).contains("unstaged:1")
            },
            "Git action pane should load the seeded unstaged diff before exposing actions; state=\(accessibilityValue(of: gitState)) hierarchy:\n\(debugHierarchyLines(containing: ["code.diff.git", "Working tree", "git not found", "notes.md", "Stage", "Unstage"]))"
        )
        let stage = element("code.diff.git.file.stage")
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "Unstaged file row should expose a rendered Stage button; state=\(accessibilityValue(of: gitState)) hierarchy:\n\(debugHierarchyLines(containing: ["code.diff.git", "notes.md", "Stage", "Unstage"]))")
        XCTAssertTrue(element("code.diff.git.file.unstage").waitForExistence(timeout: 10), "Staged file row should expose a rendered Unstage button; state=\(accessibilityValue(of: gitState)) hierarchy:\n\(debugHierarchyLines(containing: ["code.diff.git", "notes.md", "Stage", "Unstage"]))")

        stage.click()
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                self.seedRepoStatusLines().contains("M  notes.md")
            },
            "Clicking the rendered Stage button should move the worktree diff into the index; got \(seedRepoStatusLines())."
        )

        let unstage = element("code.diff.git.file.unstage")
        XCTAssertTrue(unstage.waitForExistence(timeout: 10), "Staged file row should keep Unstage available after staging all changes.")
        unstage.click()
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                self.seedRepoStatusLines().contains(" M notes.md")
            },
            "Clicking the rendered Unstage button should move staged changes back to the worktree; got \(seedRepoStatusLines())."
        )
        XCTAssertTrue(element("code.diff.git.file.stage").waitForExistence(timeout: 10), "Unstaged file row should expose Stage again after unstage.")
    }

    func testPRReviewPaneLoadedFixtureSafeActionsClickThrough() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        openReviewPaneTab(key: "pr", title: "PR")
        XCTAssertTrue(element("code.pr.title").waitForExistence(timeout: 10), "Loaded PR fixture should render a PR title.")
        XCTAssertTrue(element("code.pr.subtitle").waitForExistence(timeout: 5), "Loaded PR fixture should render PR metadata.")
        for id in [
            "code.pr.status.review",
            "code.pr.status.ci",
            "code.pr.status.changes",
            "code.pr.status.todos",
            "code.pr.check.row",
            "code.pr.review-actions",
            "code.pr.approve",
            "code.pr.request-changes",
            "code.pr.merge",
        ] {
            XCTAssertTrue(element(id).waitForExistence(timeout: 5), "\(id) should render for the loaded PR fixture.")
        }

        let requestChanges = element("code.pr.request-changes")
        XCTAssertTrue(requestChanges.isEnabled, "Request changes should be clickable for an open PR fixture.")
        requestChanges.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: self.element("code.composer.input")).contains("Review PR #184")
            },
            "Request changes should insert a review-request prompt into the Code composer."
        )

        let actions = element("code.pr.actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 5), "Loaded PR fixture should expose the PR Actions menu.")
        actions.click()
        clickMenuItem(identifier: "code.pr.copy-url", title: "Copy URL")

        actions.click()
        clickMenuItem(identifier: "code.pr.copy-number", title: "Copy Number")

        actions.click()
        clickMenuItem(identifier: "code.pr.ask-agent-fix-checks", title: "Ask agent to fix checks")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.accessibilityValue(of: self.element("code.composer.input")).contains("Inspect PR #184")
            },
            "Ask agent to fix checks should append its prompt into the Code composer."
        )
    }

    func testCodeTabTerminalReviewShortcutOpensTerminalTarget() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        app.typeKey("`", modifierFlags: .control)

        XCTAssertTrue(element("code.review.pane").waitForExistence(timeout: 5), "Control-backtick should reveal the review pane.")
        XCTAssertTrue(element("code.review.tab.terminal").waitForExistence(timeout: 5), "Control-backtick should focus the Terminal review tab.")
        assertTerminalReviewTargetConnected()
    }

    func testCodeTabTerminalReviewPaneReconnectsAfterSocketDrop() throws {
        openCodeTab()

        let row = workspaceLeafRowElement()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Seeded Code session should render in the sidebar.")
        row.click()

        app.typeKey("`", modifierFlags: .control)

        XCTAssertTrue(element("code.review.pane").waitForExistence(timeout: 5), "Control-backtick should reveal the review pane.")
        XCTAssertTrue(element("code.review.tab.terminal").waitForExistence(timeout: 5), "Control-backtick should focus the Terminal review tab.")
        assertTerminalReviewTargetConnected()

        DistributedNotificationCenter.default().post(
            name: Notification.Name("ai.continuum.mac.uiTesting.dropTerminalWebSockets"),
            object: nil
        )

        XCTAssertTrue(
            waitForTerminalStatus(
                identifier: "code.terminal.status.state",
                text: "Terminal reconnecting",
                timeout: 8
            ),
            "Dropping the right-pane terminal WebSocket should surface reconnecting state."
        )
        XCTAssertTrue(
            waitForTerminalStatus(
                identifier: "code.terminal.status.state",
                text: "Terminal connected",
                timeout: 20
            ),
            "The right-pane terminal should reconnect after a dropped WebSocket."
        )
    }

    private func openCodeTab() {
        app.activate()
        if waitForCodeSurface(timeout: 1) {
            return
        }

        for _ in 0..<2 {
            app.typeKey("3", modifierFlags: .command)
            if waitForCodeSurface(timeout: 5) {
                return
            }

            let codeTab = element("dash.tab.code")
            if codeTab.waitForExistence(timeout: 20) {
                codeTab.click()
                if waitForCodeSurface(timeout: 10) {
                    return
                }
            }

            let labeledCodeTab = app.buttons["Code"]
            if labeledCodeTab.waitForExistence(timeout: 3) {
                labeledCodeTab.click()
                if waitForCodeSurface(timeout: 10) {
                    return
                }
            }
        }

        let viewMenu = app.menuBars.menuBarItems["View"]
        if viewMenu.waitForExistence(timeout: 3) {
            viewMenu.click()
            let menuCode = app.menuItems["Code"]
            if menuCode.waitForExistence(timeout: 3) {
                menuCode.click()
                if waitForCodeSurface(timeout: 10) {
                    return
                }
            }
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    private func waitForCodeSurface(timeout: TimeInterval) -> Bool {
        waitForAny([
            element("code.sidebar.search"),
            element("code.workspace.tab-strip"),
            element("code.worktree.row"),
            element("code.session.row"),
        ], timeout: timeout)
    }

    private func openRepoSettingsMenu(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let repoSettings = firstElement("code.repo.settings")
        XCTAssertTrue(repoSettings.waitForExistence(timeout: 10), "Repo settings gear should be addressable.", file: file, line: line)
        repoSettings.click()
    }

    /// Status filtering lives in the sidebar funnel menu (the always-visible
    /// bucket strip was removed). Open it and pick Archived so archived
    /// sessions become visible.
    private func selectArchivedFilter(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let filter = element("code.sidebar.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "Code sidebar filter menu should be addressable.", file: file, line: line)
        filter.click()
        clickMenuItem(identifier: "code.sidebar.filter.status.archived", title: "Archived", file: file, line: line)
    }

    /// Open the composer "+" tools menu (attach / history / saved-prompts /
    /// paste-ansi / expand now live behind it, Claude-Desktop style).
    private func openComposerToolsMenu(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let menu = element("code.composer.tools-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Composer should expose the + tools menu.", file: file, line: line)
        menu.click()
    }

    private func openReviewPaneTab(
        key: String,
        title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selected = element("code.review.selected.\(key)")
        if selected.waitForExistence(timeout: 1) {
            return
        }

        let gutter = element("code.review.gutter.\(key)")
        if gutter.waitForExistence(timeout: 1) {
            gutter.click()
        } else {
            let rightPaneMenu = element("code.titlebar.right-pane")
            XCTAssertTrue(rightPaneMenu.waitForExistence(timeout: 5), "Code titlebar should expose the right-pane menu.", file: file, line: line)
            rightPaneMenu.click()
            clickMenuItem(identifier: "code.titlebar.right-pane.\(key)", title: title, file: file, line: line)
        }

        XCTAssertTrue(element("code.review.pane").waitForExistence(timeout: 5), "Opening \(title) should reveal the review pane.", file: file, line: line)
        let tab = element("code.review.tab.\(key)")
        if tab.waitForExistence(timeout: 2) {
            tab.click()
        }
        XCTAssertTrue(element("code.review.selected.\(key)").waitForExistence(timeout: 5), "\(title) should become the selected review pane.", file: file, line: line)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func firstElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func firstExisting(_ elements: [XCUIElement]) -> XCUIElement {
        elements.first(where: { $0.exists }) ?? elements[0]
    }

    private func clickMenuItem(
        identifier: String,
        title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identified = element(identifier)
        if identified.waitForExistence(timeout: 2) {
            identified.click()
            return
        }

        let titled = app.menuItems[title]
        XCTAssertTrue(titled.waitForExistence(timeout: 5), "Menu item \(title) should be visible.", file: file, line: line)
        titled.click()
    }

    private func assertTerminalReviewTargetVisible(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitForAny([
                element("code.terminal.surface"),
                app.staticTexts["Terminal unavailable for this session."],
                app.staticTexts["Daemon offline — restart Clawdmeter."],
            ], timeout: 5),
            "Terminal review target should render a live terminal surface or an explicit unavailable/offline state.",
            file: file,
            line: line
        )
    }

    private func assertTerminalReviewTargetConnected(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element("code.terminal.surface").waitForExistence(timeout: 5),
            "Terminal review target should render the live terminal surface for this local worktree session.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitForTerminalStatus(
                identifier: "code.terminal.status.state",
                text: "Terminal connected",
                timeout: 15,
                stableFor: 0.2
            ),
            "Terminal review target should connect to a live terminal, not remain stuck in the starting state.",
            file: file,
            line: line
        )
    }

    private func workspaceLeafRowElement() -> XCUIElement {
        let identified = element("code.worktree.row")
        if identified.exists {
            return identified
        }
        let sessionRow = element("code.session.row")
        if sessionRow.exists {
            return sessionRow
        }
        return app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "Repo", "Claude")).firstMatch
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if elements.contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return elements.contains(where: { $0.exists })
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return !element.exists
    }

    private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return predicate()
    }

    private func waitForComposerInput(containing text: String, timeout: TimeInterval) -> Bool {
        return waitUntil(timeout: timeout) {
            let input = self.firstElement("code.composer.input")
            return input.exists && self.accessibilityValue(of: input).contains(text)
        }
    }

    private func renderedWorkspaceDraftTabCount() -> Int {
        app.descendants(matching: .any)
            .matching(identifier: "code.workspace.tab.draft")
            .count
    }

    private func renderedWorkspaceSessionTabCount() -> Int {
        app.descendants(matching: .any)
            .matching(identifier: "code.workspace.tab.session")
            .count
    }

    private func sessionTabElement(id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ AND value CONTAINS[c] %@",
                "code.workspace.tab.session",
                id
            ))
            .firstMatch
    }

    private func centerHeaderStateElement(id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ AND (value CONTAINS[c] %@ OR label CONTAINS[c] %@)",
                "code.center.header.state",
                id,
                id
            ))
            .firstMatch
    }

    private func currentCenterHeaderState() -> String {
        accessibilityValue(of: firstElement("code.center.header.state"))
    }

    private func sessionPresentationJSON() -> String {
        let url = testAppSupportDirectory.appendingPathComponent("session-presentation.json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func accessibilityValue(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    private func waitForTerminalStatus(
        identifier: String,
        text: String,
        timeout: TimeInterval,
        stableFor: TimeInterval = 0
    ) -> Bool {
        let status = element(identifier)
        let deadline = Date().addingTimeInterval(timeout)
        var firstMatchedAt: Date?
        repeat {
            if status.exists {
                let label = accessibilityValue(of: status)
                if label.localizedCaseInsensitiveContains(text) {
                    if stableFor <= 0 {
                        return true
                    }
                    if firstMatchedAt == nil {
                        firstMatchedAt = Date()
                    }
                    if let firstMatchedAt,
                       Date().timeIntervalSince(firstMatchedAt) >= stableFor {
                        return true
                    }
                } else {
                    firstMatchedAt = nil
                }
            } else {
                firstMatchedAt = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        if status.exists {
            return accessibilityValue(of: status).localizedCaseInsensitiveContains(text)
        }
        return false
    }

    private func debugHierarchyLines(containing needles: [String]) -> String {
        app.debugDescription
            .split(separator: "\n")
            .filter { line in
                needles.contains { line.localizedCaseInsensitiveContains($0) }
            }
            .prefix(80)
            .joined(separator: "\n")
    }

    private func waitForSeedSessionArchived(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if seedSessionArchived() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return seedSessionArchived()
    }

    private func waitForSeedSessionDeleted(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if seedSessionDeleted() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return seedSessionDeleted()
    }

    private func waitForSeedWorkspaceRemoved(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !seedWorkspaceExists() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return !seedWorkspaceExists()
    }

    private func waitForCheckpointRefCount(atLeast expectedCount: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if checkpointRefCount() >= expectedCount {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return checkpointRefCount() >= expectedCount
    }

    private func seedSessionArchived() -> Bool {
        let url = testAppSupportDirectory.appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]],
                  let seeded = sessions.first(where: { $0["id"] as? String == Self.seedSessionId })
        else { return false }
        return seeded["archivedAt"] != nil
    }

    private func seedSessionDeleted() -> Bool {
        let url = testAppSupportDirectory.appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]]
        else { return false }
        return !sessions.contains { $0["id"] as? String == Self.seedSessionId }
    }

    private func seedWorkspaceExists() -> Bool {
        let url = testAppSupportDirectory.appendingPathComponent("workspaces.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]]
        else { return false }
        return workspaces.contains { $0["id"] as? String == "11111111-1111-4111-8111-111111111111" }
    }

    private func checkpointRefCount() -> Int {
        checkpointRefs().count
    }

    private func checkpointRefs() -> [String] {
        guard let output = try? Self.runGit(
            ["for-each-ref", "--format=%(refname)", "refs/clawdmeter/checkpoints/\(Self.seedSessionId)"],
            cwd: testRepoRootDirectory
        ) else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.isEmpty }
            .map(String.init)
    }

    private func latestCheckpointTreePaths() -> Set<String> {
        guard let ref = checkpointRefs().filter({ !$0.contains("/safety-") }).sorted().last,
              let output = try? Self.runGit(["ls-tree", "-r", "--name-only", ref], cwd: testRepoRootDirectory)
        else { return [] }
        return Set(output.split(whereSeparator: \.isNewline).map(String.init))
    }

    private func seedRepoFileContents() throws -> String {
        try repoFileContents("notes.md")
    }

    private func writeSeedRepoFile(_ contents: String) throws {
        try writeRepoFile("notes.md", contents: contents)
    }

    private func repoFileContents(_ relativePath: String) throws -> String {
        try String(
            contentsOf: testRepoRootDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func writeRepoFile(_ relativePath: String, contents: String) throws {
        let url = testRepoRootDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func seedRepoStatusLines() -> [String] {
        guard let output = try? Self.runGit(["status", "--porcelain"], cwd: testRepoRootDirectory) else {
            return []
        }
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func commitSeedRepoFile(_ contents: String, message: String) throws {
        try commitRepoFile("notes.md", contents: contents, message: message)
    }

    private func commitRepoFile(_ relativePath: String, contents: String, message: String) throws {
        try writeRepoFile(relativePath, contents: contents)
        try Self.runGit(["add", relativePath], cwd: testRepoRootDirectory)
        try Self.runGit(["commit", "-m", message], cwd: testRepoRootDirectory)
    }

    private func removeRepoFileAndCommit(_ relativePath: String, message: String) throws {
        try Self.runGit(["rm", relativePath], cwd: testRepoRootDirectory)
        try Self.runGit(["commit", "-m", message], cwd: testRepoRootDirectory)
    }

    private func movePointer(to coordinate: XCUICoordinate) {
        coordinate.hover()
        let point = coordinate.screenPoint
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private static func seedWorkspaceStore(
        pendingPlan: Bool = false,
        multiSessionTabs: Bool = false
    ) throws -> UITestFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClawdmeterMacUITests-\(UUID().uuidString)", isDirectory: true)
        let repoRoot = root.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try "initial checkpoint state\n".write(
            to: repoRoot.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Seeded Report\n\nFixture artifact for the Code tab Artifacts pane.\n".write(
            to: repoRoot.appendingPathComponent("report.md"),
            atomically: true,
            encoding: .utf8
        )
        try Self.runGit(["init"], cwd: repoRoot)
        try Self.runGit(["config", "user.name", "Clawdmeter UI Test"], cwd: repoRoot)
        try Self.runGit(["config", "user.email", "ui-test@example.invalid"], cwd: repoRoot)
        try Self.runGit(["add", "notes.md", "report.md"], cwd: repoRoot)
        try Self.runGit(["commit", "-m", "Initial checkpoint fixture"], cwd: repoRoot)

        let fakeBinRoot = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinRoot, withIntermediateDirectories: true)
        let fakeClaudeBinary = fakeBinRoot.appendingPathComponent("claude")
        let fakeClaudeScript = """
        #!/bin/sh
        echo "UI test Claude approved run active"
        while true; do sleep 1; done
        """
        try fakeClaudeScript.write(to: fakeClaudeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaudeBinary.path)

        let workspace: [String: Any] = [
            "id": "11111111-1111-4111-8111-111111111111",
            "projectId": "22222222-2222-4222-8222-222222222222",
            "repoRoot": repoRoot.path,
            "repoDisplayName": "UITest Repo",
            "runtimeCwd": repoRoot.path,
            "createdAt": "2026-05-27T00:00:00Z",
            "updatedAt": "2026-05-27T00:00:00Z",
        ]
        let store: [String: Any] = [
            "schemaVersion": 1,
            "workspaces": [workspace],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("workspaces.json"), options: [.atomic])

        var session: [String: Any] = [
            "id": Self.seedSessionId,
            "repoKey": repoRoot.path,
            "repoDisplayName": "UITest Repo",
            "agent": "claude",
            "model": "claude-sonnet-4-6",
            "goal": "Exercise browser preview",
            "status": "done",
            "createdAt": "2026-06-06T00:00:00Z",
            "lastEventAt": "2026-06-06T00:00:02Z",
            "lastEventSeq": 2,
            "mode": "local",
            "workspaceId": "11111111-1111-4111-8111-111111111111",
            "runtimeCwd": repoRoot.path,
            "kind": "code",
            "ownsWorktree": false,
            "customName": "Preview E2E",
        ]
        if pendingPlan {
            session["goal"] = "Approve the pending Code-tab plan"
            session["status"] = "planning"
            session["planText"] = """
            1. Review the rendered Plan pane approval button
            2. Create a checkpoint before approval
            3. Restart Claude Code in run mode
            """
        }
        let sessions: [[String: Any]]
        if multiSessionTabs {
            sessions = Self.sameWorktreeSessionFixtures.enumerated().map { index, fixture in
                var seeded = session
                seeded["id"] = fixture.id
                seeded["agent"] = fixture.agent
                seeded["model"] = fixture.model
                seeded["goal"] = "Exercise \(fixture.provider) crowded session tabs"
                seeded["customName"] = fixture.title
                seeded["createdAt"] = "2026-06-06T00:00:0\(index)Z"
                seeded["lastEventAt"] = "2026-06-06T00:00:0\(index + 1)Z"
                seeded["lastEventSeq"] = index + 2
                return seeded
            }
        } else {
            sessions = [session]
        }
        let sessionsStore: [String: Any] = [
            "schemaVersion": 6,
            "sessions": sessions,
        ]
        let sessionsData = try JSONSerialization.data(withJSONObject: sessionsStore, options: [.prettyPrinted, .sortedKeys])
        try sessionsData.write(to: root.appendingPathComponent("sessions.json"), options: [.atomic])

        let presentationStore: [String: Any] = [
            "promptHistory": [
                Self.seededHistoryPrompt,
                "Inspect slow model toggle feedback before provider work starts.",
            ],
            "savedPrompts": [[
                "id": Self.seededSavedPromptId,
                "title": Self.seededSavedPromptTitle,
                "body": Self.seededSavedPromptBody,
                "updatedAt": 0,
            ]],
            "updatedAt": 0,
        ]
        let presentationData = try JSONSerialization.data(withJSONObject: presentationStore, options: [.prettyPrinted, .sortedKeys])
        try presentationData.write(to: root.appendingPathComponent("session-presentation.json"), options: [.atomic])

        let claudeProjectsRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        let projectDirectory = claudeProjectsRoot.appendingPathComponent(encodedClaudeProjectPath(repoRoot.path), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcript = """
        {"type":"user","timestamp":"2026-06-06T00:00:00.000Z","message":{"role":"user","content":"Show me the latest branch preview."}}
        {"type":"assistant","timestamp":"2026-06-06T00:00:01.000Z","message":{"role":"assistant","model":"claude-sonnet-4-6","stop_reason":"end_turn","content":[{"type":"text","text":"Preview is available at http://127.0.0.1:5173."}]}}
        {"type":"assistant","timestamp":"2026-06-06T00:00:02.000Z","message":{"role":"assistant","model":"claude-sonnet-4-6","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_read_notes","name":"Read","input":{"file_path":"notes.md"}},{"type":"tool_use","id":"toolu_fetch_docs","name":"WebFetch","input":{"url":"https://example.com/continuum-docs","prompt":"Find Continuum docs."}},{"type":"tool_use","id":"toolu_write_report","name":"Write","input":{"file_path":"report.md","content":"# Seeded Report\\n\\nFixture artifact for the Code tab Artifacts pane."}}]}}
        """
        let transcriptData = Data(transcript.appending("\n").utf8)
        try transcriptData.write(to: projectDirectory.appendingPathComponent("preview-e2e.jsonl"), options: [.atomic])

        return UITestFixture(
            appSupportDirectory: root,
            claudeProjectsRoot: claudeProjectsRoot,
            repoRoot: repoRoot,
            fakeClaudeBinary: fakeClaudeBinary
        )
    }

    @discardableResult
    private static func runGit(_ arguments: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try gitExecutablePath())
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "Clawdmeter UI Test",
            "GIT_AUTHOR_EMAIL": "ui-test@example.invalid",
            "GIT_COMMITTER_NAME": "Clawdmeter UI Test",
            "GIT_COMMITTER_EMAIL": "ui-test@example.invalid",
        ]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "CodeTabHoverShortcutUITests.git",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(stderrText)\(stdoutText)",
                ]
            )
        }
        return stdoutText
    }

    private static func gitExecutablePath() throws -> String {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw NSError(
            domain: "CodeTabHoverShortcutUITests.git",
            code: 127,
            userInfo: [NSLocalizedDescriptionKey: "No executable git binary found for checkpoint UI fixture."]
        )
    }

    private static func encodedClaudeProjectPath(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
