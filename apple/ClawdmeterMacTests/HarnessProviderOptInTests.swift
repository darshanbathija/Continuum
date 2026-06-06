import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Locks the harness-is-the-default contract for non-Claude drive paths.
///
/// The `codex app-server` harness is the DEFAULT Codex drive path (Sessions +
/// Chat); the legacy tmux/SDK Codex paths are decode-only compatibility now.
///
/// Gemini no longer has a kill-switch: the retired agentapi/gRPC drives were
/// removed once the headless `agy` CLI was live-verified.
@MainActor
final class HarnessProviderOptInTests: XCTestCase {

    func test_codeSessionTransportPolicy_keepsManagedHarnessesOffArgvPreflight() {
        XCTAssertEqual(
            AgentTransportPolicy.codeSessionTransport(
                for: .codex,
                acpSupported: false
            ),
            .codexAppServer
        )
        XCTAssertEqual(
            AgentTransportPolicy.codeSessionTransport(
                for: .gemini,
                acpSupported: false
            ),
            .transportOwningHarness
        )
        XCTAssertEqual(
            AgentTransportPolicy.codeSessionTransport(
                for: .grok,
                acpSupported: false
            ),
            .transportOwningHarness
        )
        XCTAssertEqual(
            AgentTransportPolicy.codeSessionTransport(
                for: .cursor,
                acpSupported: true
            ),
            .acpHarness
        )
    }

    func test_codeSessionTransportPolicy_keepsClaudeOnArgvPreflight() {
        XCTAssertTrue(
            AgentTransportPolicy.codeSessionTransport(
                for: .claude,
                acpSupported: false
            ).requiresArgvPreflight
        )
    }
}
