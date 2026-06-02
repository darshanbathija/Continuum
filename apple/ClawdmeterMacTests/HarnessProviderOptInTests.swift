import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Locks the "the Settings → Providers toggle IS the harness opt-in" wiring.
///
/// The chain under test:
///   Settings toggle  →  ProviderEnablement.setEnabled(vendor.backingProvider.rawValue)
///                    →  writes `clawdmeter.provider.<id>.enabled`
///   spawn gate       →  AgentControlServer.codexAppServerEnabled / antigravityGrpcEnabled
///                    →  reads the SAME key via ProviderEnablement.isEnabled(.codex/.gemini)
///
/// If a future rename of `ChatVendor.backingProvider` or the gate desyncs the
/// write-key from the read-key, flipping the toggle would silently stop routing
/// to the harness driver. These tests fail loudly instead.
@MainActor
final class HarnessProviderOptInTests: XCTestCase {

    private let codexKey = ProviderEnablement.key(for: "codex")
    private let geminiKey = ProviderEnablement.key(for: "gemini")
    // Save/restore so the suite never clobbers the real user's provider
    // enablement (the test host shares the `com.clawdmeter.mac` domain).
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

    func test_chatgptToggle_optsCodexIntoAppServerHarness() {
        UserDefaults.standard.set(true, forKey: codexKey)
        XCTAssertTrue(
            AgentControlServer.codexAppServerEnabled,
            "Enabling the ChatGPT (Codex) provider must route new Codex sessions through the app-server harness"
        )
        UserDefaults.standard.set(false, forKey: codexKey)
        XCTAssertFalse(
            AgentControlServer.codexAppServerEnabled,
            "Disabling the Codex provider must fall back off the app-server harness"
        )
    }

    func test_antigravityToggle_optsGeminiIntoGrpcHarness() {
        UserDefaults.standard.set(true, forKey: geminiKey)
        XCTAssertTrue(
            AgentControlServer.antigravityGrpcEnabled,
            "Enabling the Antigravity (Gemini) provider must route new sessions through the Cascade gRPC harness"
        )
        UserDefaults.standard.set(false, forKey: geminiKey)
        XCTAssertFalse(
            AgentControlServer.antigravityGrpcEnabled,
            "Disabling the Antigravity provider must fall back off the gRPC harness"
        )
    }

    /// The toggle writes `provider.<backingProvider>.enabled`; the gate reads the
    /// same. Pin both the vendor→agent mapping and the resulting key string so a
    /// rename on either side breaks this test rather than the feature.
    func test_settingsToggleWriteKey_matchesGateReadKey() {
        XCTAssertEqual(ChatVendor.chatgpt.backingProvider, .codex)
        XCTAssertEqual(ChatVendor.antigravity.backingProvider, .gemini)
        XCTAssertEqual(
            ProviderEnablement.key(for: ChatVendor.chatgpt.backingProvider.rawValue),
            "clawdmeter.provider.codex.enabled"
        )
        XCTAssertEqual(
            ProviderEnablement.key(for: ChatVendor.antigravity.backingProvider.rawValue),
            "clawdmeter.provider.gemini.enabled"
        )
    }
}
