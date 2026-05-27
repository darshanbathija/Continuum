import XCTest

final class CodeTabHoverShortcutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launchEnvironment["CLAWDMETER_UI_TESTING"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
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

        let row = element("code.session.row")
        guard row.waitForExistence(timeout: 3) else {
            throw XCTSkip("No Code session row exists in this UI-test environment.")
        }

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

    private func openCodeTab() {
        app.typeKey("3", modifierFlags: .command)
        let codeTab = element("dash.tab.code")
        if codeTab.waitForExistence(timeout: 10) {
            codeTab.click()
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
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
}
