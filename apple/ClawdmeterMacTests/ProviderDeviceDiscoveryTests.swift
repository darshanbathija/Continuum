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
            displayName: "OpenRouter",
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
        XCTAssertNil(ProviderDeviceSetupAction.importClaudeFromClaudeCode.shellCommand)
    }

    func test_discover_returnsAllProviders() async {
        let result = await ProviderDeviceDiscovery.discover()
        XCTAssertEqual(result.statuses.count, ProviderEnablement.allProviderIds.count)
        XCTAssertEqual(
            Set(result.statuses.map(\.providerId)),
            Set(ProviderEnablement.allProviderIds)
        )
    }
}
