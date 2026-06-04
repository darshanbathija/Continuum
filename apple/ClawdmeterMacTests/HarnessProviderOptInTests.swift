import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Locks the harness-is-the-default contract for non-Claude drive paths.
///
/// The `codex app-server` harness is the DEFAULT Codex drive path (Sessions +
/// Chat); the legacy tmux/SDK Codex paths are deprecated. `codexAppServerEnabled`
/// survives only as a live-verify kill-switch: default ON, opt OUT by writing the
/// key `false`.
///
/// (Gemini no longer has a kill-switch: the Antigravity agentapi + Cascade gRPC
/// drives were removed once the headless `agy` CLI was live-verified, so `agy` is
/// the sole Gemini drive path.)
@MainActor
final class HarnessProviderOptInTests: XCTestCase {

    private let codexKey = "clawdmeter.codex.appServer.enabled"
    // Save/restore so the suite never clobbers the real user's kill-switch state
    // (the test host shares the `com.clawdmeter.mac` domain).
    private var savedCodex: Any?

    override func setUp() {
        super.setUp()
        savedCodex = UserDefaults.standard.object(forKey: codexKey)
    }

    override func tearDown() {
        restore(codexKey, savedCodex)
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
}
