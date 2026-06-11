import XCTest
@testable import Clawdmeter
import ClawdmeterShared

final class ProviderDeviceDiscoveryTests: XCTestCase {

    func test_providerDeviceStatus_isReady_claudeRequiresAuthOnly() {
        let ready = ProviderDeviceStatus(
            providerId: "claude",
            displayName: "Claude",
            cliInstalled: false,
            authenticated: true,
            status: .authenticated
        )
        XCTAssertTrue(ready.isReady)

        let notReady = ProviderDeviceStatus(
            providerId: "claude",
            displayName: "Claude",
            cliInstalled: true,
            authenticated: false,
            status: .unauthenticated
        )
        XCTAssertFalse(notReady.isReady)
    }

    func test_providerDeviceStatus_isReady_codexRequiresCLIAndAuth() {
        XCTAssertTrue(ProviderDeviceStatus(
            providerId: "codex",
            displayName: "Codex",
            cliInstalled: true,
            authenticated: true,
            status: .authenticated
        ).isReady)

        XCTAssertFalse(ProviderDeviceStatus(
            providerId: "codex",
            displayName: "Codex",
            cliInstalled: true,
            authenticated: false,
            status: .unauthenticated
        ).isReady)
    }

    func test_providerDeviceStatus_isReady_opencodeRequiresAuthOnly() {
        XCTAssertTrue(ProviderDeviceStatus(
            providerId: "opencode",
            displayName: "OpenCode",
            cliInstalled: false,
            authenticated: true,
            status: .authenticated
        ).isReady)
    }

    func test_providerDiscoveryResult_readyProviderIDs() {
        let statuses = [
            ProviderDeviceStatus(
                providerId: "claude",
                displayName: "Claude",
                cliInstalled: false,
                authenticated: true,
                status: .authenticated
            ),
            ProviderDeviceStatus(
                providerId: "grok",
                displayName: "Grok",
                cliInstalled: false,
                authenticated: false,
                status: .notInstalled
            ),
        ]
        let result = ProviderDiscoveryResult(statuses: statuses)
        XCTAssertEqual(result.readyProviderIDs, ["claude"])
        XCTAssertEqual(result.status(for: "claude")?.displayName, "Claude")
    }

    func test_setupAction_shellCommands() {
        XCTAssertEqual(ProviderDeviceSetupAction.runCodexLogin.shellCommand, "codex login")
        XCTAssertEqual(ProviderDeviceSetupAction.runCursorAgentLogin.shellCommand, "cursor-agent login")
        XCTAssertNotNil(ProviderDeviceSetupAction.installCodexCLI.shellCommand)
        XCTAssertNotNil(ProviderDeviceSetupAction.installCursorCLI.shellCommand)
        XCTAssertNil(ProviderDeviceSetupAction.importClaudeFromClaudeCode.shellCommand)
    }

    func test_providerDeviceStatus_isReady_cursorRequiresCLIAndAuth() {
        XCTAssertTrue(ProviderDeviceStatus(
            providerId: "cursor",
            displayName: "Cursor",
            cliInstalled: true,
            authenticated: true,
            status: .authenticated
        ).isReady)

        XCTAssertFalse(ProviderDeviceStatus(
            providerId: "cursor",
            displayName: "Cursor",
            cliInstalled: true,
            authenticated: false,
            status: .unauthenticated
        ).isReady)
    }

    /// Grok pre-selects off the binary but must not claim authentication it
    /// never probed.
    func test_providerDeviceStatus_isReady_grokKeysOffBinaryOnly() {
        let installed = ProviderDeviceStatus(
            providerId: "grok",
            displayName: "Grok",
            cliInstalled: true,
            authenticated: false,
            status: .installed
        )
        XCTAssertTrue(installed.isReady)

        let missing = ProviderDeviceStatus(
            providerId: "grok",
            displayName: "Grok",
            cliInstalled: false,
            authenticated: false,
            status: .notInstalled
        )
        XCTAssertFalse(missing.isReady)
    }

    func test_setupAction_loginLabels() {
        XCTAssertEqual(ProviderDeviceSetupAction.runCodexLogin.label, "Log In")
        XCTAssertEqual(ProviderDeviceSetupAction.runCursorAgentLogin.label, "Log In")
    }

    func test_discover_returnsAllProviders() async {
        let result = await ProviderDeviceDiscovery.discover()
        XCTAssertEqual(result.statuses.count, ProviderEnablement.allProviderIds.count)
        XCTAssertEqual(
            Set(result.statuses.map(\.providerId)),
            Set(ProviderEnablement.allProviderIds)
        )
    }

    /// Even when the probe deadline expires, discovery must return a full
    /// placeholder set (one row per provider) so onboarding leaves the
    /// scanning spinner instead of stranding — and it must return promptly
    /// at the deadline, not after the slow probe eventually finishes.
    func test_discover_timedOutStillReturnsAllProvidersPromptly() async {
        let started = Date()
        let result = await ProviderDeviceDiscovery.discover(timeout: .milliseconds(1))
        XCTAssertEqual(
            Set(result.statuses.map(\.providerId)),
            Set(ProviderEnablement.allProviderIds)
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0)
    }
}
