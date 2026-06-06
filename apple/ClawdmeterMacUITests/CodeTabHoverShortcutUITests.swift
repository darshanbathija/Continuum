import XCTest

final class CodeTabHoverShortcutUITests: XCTestCase {
    private struct UITestFixture {
        let appSupportDirectory: URL
        let claudeProjectsRoot: URL
    }

    private var app: XCUIApplication!
    private var testAppSupportDirectory: URL!
    private var testClaudeProjectsRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixture = try Self.seedWorkspaceStore()
        testAppSupportDirectory = fixture.appSupportDirectory
        testClaudeProjectsRoot = fixture.claudeProjectsRoot
        app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launchEnvironment["CLAWDMETER_UI_TESTING"] = "1"
        app.launchEnvironment["CLAWDMETER_TEST_APP_SUPPORT_DIR"] = testAppSupportDirectory.path
        app.launchEnvironment["CLAWDMETER_TEST_CLAUDE_PROJECTS_ROOT"] = testClaudeProjectsRoot.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        if let testAppSupportDirectory {
            try? FileManager.default.removeItem(at: testAppSupportDirectory)
        }
        testAppSupportDirectory = nil
        testClaudeProjectsRoot = nil
    }

    func testCodeTabComposerControlsExposeShortcutTargets() throws {
        openCodeTab()

        XCTAssertTrue(element("code.composer.attach").waitForExistence(timeout: 10), "Composer attachment control should be addressable for Command-U.")
        XCTAssertTrue(element("code.composer.model-effort").waitForExistence(timeout: 10), "Model/effort selector should expose a stable hover/shortcut target.")
        XCTAssertTrue(element("code.composer.permission-mode").waitForExistence(timeout: 10), "Plan/permission selector should expose a stable hover/shortcut target.")
        XCTAssertTrue(element("code.composer.context-usage").waitForExistence(timeout: 10), "Context display should expose a stable hover/shortcut target.")

        app.typeKey("u", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])
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
        XCTAssertTrue(element("code.browser.url").waitForExistence(timeout: 5), "Browser toolbar should expose URL entry.")
        XCTAssertTrue(element("code.browser.runStatus").waitForExistence(timeout: 5), "Browser toolbar should expose run status.")
        XCTAssertTrue(element("code.browser.restart").waitForExistence(timeout: 5), "Browser toolbar should expose restart.")

        element("code.browser.backToChat").click()
        XCTAssertTrue(waitForNonExistence(fullWorkspaceBrowser, timeout: 5), "Back to Chat should close the full-workspace Browser surface.")
    }

    func testTerminalNewTabMenuWhenTerminalSurfaceExists() throws {
        openCodeTab()

        let terminalMenu = element("code.terminal.new-tab")
        guard terminalMenu.waitForExistence(timeout: 3) else {
            throw XCTSkip("No terminal surface is visible in this UI-test environment.")
        }

        terminalMenu.click()
        XCTAssertTrue(app.menuItems["Chat"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Terminal"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testEnvVariablesSettingsExposeRepoSetAndVariableControls() throws {
        openSettingsTab()

        let envSection = element("settings.section.envVariables")
        XCTAssertTrue(envSection.waitForExistence(timeout: 10), "Settings should expose the Env Variables section.")
        envSection.click()

        XCTAssertTrue(element("settings.env.root").waitForExistence(timeout: 10), "Env Variables settings root should render.")

        let addVariable = element("settings.env.add-variable")
        XCTAssertTrue(addVariable.waitForExistence(timeout: 5), "Seeded workspace should expose variable creation controls.")

        XCTAssertTrue(element("settings.env.new-set-name").exists, "Env set name field should be present.")
        XCTAssertTrue(element("settings.env.create-set").exists, "Env set create button should be present.")
        XCTAssertTrue(element("settings.env.scope-tabs").exists, "Env variables should expose Project/Shared scope tabs.")
        XCTAssertTrue(element("settings.env.search").exists, "Env variables should expose search.")
        XCTAssertTrue(element("settings.env.set-filter").exists, "Env variables should expose set filters.")
        XCTAssertTrue(element("settings.env.source-filter").exists, "Env variables should expose source filters.")
        XCTAssertTrue(element("settings.env.type-filter").exists, "Env variables should expose type filters.")
        XCTAssertTrue(element("settings.env.status-filter").exists, "Env variables should expose status filters.")
        XCTAssertTrue(element("settings.env.sort").exists, "Env variables should expose sorting.")
        XCTAssertTrue(element("settings.env.variable-table").exists, "Env variables should render as a table.")
        XCTAssertTrue(element("settings.env.import").exists, "Env variables should expose .env import.")
        XCTAssertTrue(app.staticTexts["TEST_API_KEY"].waitForExistence(timeout: 5), "Saved variables should appear as table rows.")
        XCTAssertTrue(app.staticTexts["Sensitive"].waitForExistence(timeout: 5), "Saved variables should show their type in the table.")
        XCTAssertTrue(app.staticTexts["Active"].waitForExistence(timeout: 5), "Saved variables should show active status in the table.")

        element("settings.env.import").click()
        XCTAssertTrue(element("settings.env.import.contents").waitForExistence(timeout: 5), "Import flow should expose paste/file contents.")
        XCTAssertTrue(element("settings.env.import.preview").exists, "Import flow should expose parsed preview rows.")
        XCTAssertTrue(element("settings.env.import.save").exists, "Import flow should expose explicit import action.")
        app.buttons["Cancel"].click()

        element("settings.env.add-variable").click()
        XCTAssertTrue(element("settings.env.variable.key").waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.env.variable.value").waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.env.variable.sets").waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.env.variable.save").waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
    }

    func testAdvancedProvisioningSettingsExposeDeviceCheckAndEnvImportControls() throws {
        openSettingsTab()

        let advancedSection = element("settings.section.advanced")
        XCTAssertTrue(advancedSection.waitForExistence(timeout: 10), "Settings should expose the Advanced section.")
        advancedSection.click()

        XCTAssertTrue(element("settings.provisioning.root").waitForExistence(timeout: 10), "Provisioning settings root should render.")
        XCTAssertTrue(element("settings.provisioning.check-device").exists, "Provisioning should expose Check Device.")
        XCTAssertTrue(element("settings.provisioning.category-filter").exists, "Provisioning should expose category filters.")
        XCTAssertTrue(element("settings.provisioning.vendor.supabase").waitForExistence(timeout: 5), "Supabase vendor row should render.")

        let importButton = element("settings.provisioning.import.supabase")
        XCTAssertTrue(importButton.waitForExistence(timeout: 5), "Supabase row should expose env import CTA.")
        importButton.click()

        XCTAssertTrue(element("settings.provisioning.env.current-repo").waitForExistence(timeout: 5), "Env import should expose current repo selection.")
        XCTAssertTrue(element("settings.provisioning.env.all-repos").exists, "Env import should expose all-repos targeting.")
        XCTAssertTrue(element("settings.provisioning.env.value.SUPABASE_URL").exists, "Env import should expose vendor env value fields.")
        XCTAssertTrue(element("settings.provisioning.env.preview").exists, "Env import should expose preview.")
        XCTAssertTrue(element("settings.provisioning.env.import").exists, "Env import should expose import.")
        app.buttons["Close"].click()
    }

    private func openCodeTab() {
        app.typeKey("3", modifierFlags: .command)
        let codeTab = element("dash.tab.code")
        if codeTab.waitForExistence(timeout: 10) {
            codeTab.click()
        }
    }

    private func openSettingsTab() {
        app.typeKey("4", modifierFlags: .command)
        let settingsTab = element("dash.tab.settings")
        if settingsTab.waitForExistence(timeout: 10) {
            settingsTab.click()
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
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

    private static func seedWorkspaceStore() throws -> UITestFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClawdmeterMacUITests-\(UUID().uuidString)", isDirectory: true)
        let repoRoot = root.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

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

        let session: [String: Any] = [
            "id": "66666666-6666-4666-8666-666666666666",
            "repoKey": repoRoot.path,
            "repoDisplayName": "UITest Repo",
            "agent": "claude",
            "model": "sonnet",
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
        let sessionsStore: [String: Any] = [
            "schemaVersion": 6,
            "sessions": [session],
        ]
        let sessionsData = try JSONSerialization.data(withJSONObject: sessionsStore, options: [.prettyPrinted, .sortedKeys])
        try sessionsData.write(to: root.appendingPathComponent("sessions.json"), options: [.atomic])

        let claudeProjectsRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        let projectDirectory = claudeProjectsRoot.appendingPathComponent(encodedClaudeProjectPath(repoRoot.path), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcript = """
        {"type":"user","timestamp":"2026-06-06T00:00:00.000Z","message":{"role":"user","content":"Show me the latest branch preview."}}
        {"type":"assistant","timestamp":"2026-06-06T00:00:01.000Z","message":{"role":"assistant","model":"claude-sonnet-4","stop_reason":"end_turn","content":[{"type":"text","text":"Preview is available at http://127.0.0.1:5173."}]}}
        """
        let transcriptData = Data(transcript.appending("\n").utf8)
        try transcriptData.write(to: projectDirectory.appendingPathComponent("preview-e2e.jsonl"), options: [.atomic])

        let envStore: [String: Any] = [
            "schemaVersion": 2,
            "sets": [[
                "id": "33333333-3333-4333-8333-333333333333",
                "workspaceId": "11111111-1111-4111-8111-111111111111",
                "name": "local",
                "slug": "local",
                "isActive": true,
                "sortOrder": 0,
                "createdAt": "2026-05-27T00:00:00Z",
                "updatedAt": "2026-05-27T00:00:00Z",
            ]],
            "variables": [[
                "id": "44444444-4444-4444-8444-444444444444",
                "key": "TEST_API_KEY",
                "scope": "local",
                "kind": "sensitive",
                "isEnabled": true,
                "valueAccount": "repo-env:44444444-4444-4444-8444-444444444444",
                "createdAt": "2026-05-27T00:00:00Z",
                "updatedAt": "2026-05-27T00:00:00Z",
            ]],
            "assignments": [[
                "id": "55555555-5555-4555-8555-555555555555",
                "variableId": "44444444-4444-4444-8444-444444444444",
                "workspaceId": "11111111-1111-4111-8111-111111111111",
                "setId": "33333333-3333-4333-8333-333333333333",
                "isEnabled": true,
                "createdAt": "2026-05-27T00:00:00Z",
                "updatedAt": "2026-05-27T00:00:00Z",
            ]],
            "importBatches": [],
            "auditEvents": [],
        ]
        let envData = try JSONSerialization.data(withJSONObject: envStore, options: [.prettyPrinted, .sortedKeys])
        try envData.write(to: root.appendingPathComponent("repo-env-variables.json"), options: [.atomic])
        return UITestFixture(appSupportDirectory: root, claudeProjectsRoot: claudeProjectsRoot)
    }

    private static func encodedClaudeProjectPath(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
