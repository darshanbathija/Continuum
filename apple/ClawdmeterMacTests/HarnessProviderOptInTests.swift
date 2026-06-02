import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Locks the harness-is-the-default contract for non-Claude drive paths.
///
/// The `codex app-server` and Antigravity Cascade gRPC harnesses are now the
/// DEFAULT drive paths (Sessions + Chat); the legacy tmux/SDK/agentapi paths are
/// deprecated. `codexAppServerEnabled` / `antigravityGrpcEnabled` survive only as
/// live-verify kill-switches: default ON, opt OUT by writing the key `false`.
@MainActor
final class HarnessProviderOptInTests: XCTestCase {

    private let codexKey = "clawdmeter.codex.appServer.enabled"
    private let geminiKey = "clawdmeter.antigravity.grpc.enabled"
    // Save/restore so the suite never clobbers the real user's kill-switch state
    // (the test host shares the `com.clawdmeter.mac` domain).
    private var savedCodex: Any?
    private var savedGemini: Any?

    override func setUp() {
        super.setUp()
        savedCodex = UserDefaults.standard.object(forKey: codexKey)
        savedGemini = UserDefaults.standard.object(forKey: geminiKey)
    }

    override func tearDown() {
        restore(codexKey, savedCodex)
        restore(geminiKey, savedGemini)
        super.tearDown()
    }

    private func restore(_ key: String, _ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func test_codexAppServer_isDefaultOn_whenUnset() {
        UserDefaults.standard.removeObject(forKey: codexKey)
        XCTAssertTrue(
            AgentControlServer.codexAppServerEnabled,
            "Codex must default to the app-server harness when no kill-switch is set"
        )
    }

    func test_codexAppServer_killSwitch_optsOut() {
        UserDefaults.standard.set(false, forKey: codexKey)
        XCTAssertFalse(
            AgentControlServer.codexAppServerEnabled,
            "Writing the kill-switch false must drop Codex back off the harness for live-verify"
        )
    }

    func test_antigravityGrpc_isDefaultOn_whenUnset() {
        UserDefaults.standard.removeObject(forKey: geminiKey)
        XCTAssertTrue(
            AgentControlServer.antigravityGrpcEnabled,
            "Gemini must default to the Cascade gRPC harness when no kill-switch is set"
        )
    }

    func test_antigravityGrpc_killSwitch_optsOut() {
        UserDefaults.standard.set(false, forKey: geminiKey)
        XCTAssertFalse(
            AgentControlServer.antigravityGrpcEnabled,
            "Writing the kill-switch false must drop Gemini back off the harness for live-verify"
        )
    }
}
