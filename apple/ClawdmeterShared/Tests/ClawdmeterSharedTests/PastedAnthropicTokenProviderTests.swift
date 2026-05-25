#if os(iOS) || os(watchOS) || os(macOS)
import XCTest
@testable import ClawdmeterShared

/// v0.7.4 regression tests for the singleton + cache-clear invariants
/// introduced in P1-Shared-2 and codex-2. The two together fix a real
/// "Sign out" leak: a non-singleton plus a Keychain-error-gated clear
/// meant logging out on the iPhone could leave a stale token serving
/// the daemon until process restart.
final class PastedAnthropicTokenProviderTests: XCTestCase {

    /// P1-Shared-2: `shared()` must return the same instance every call.
    /// Without this, each call site gets its own `cached` field and
    /// invalidations never cross caller boundaries.
    func test_shared_returnsSingleton() {
        let a = PastedAnthropicTokenProvider.shared()
        let b = PastedAnthropicTokenProvider.shared()
        XCTAssertTrue(a === b,
                      "PastedAnthropicTokenProvider.shared() must return the same instance to satisfy the P1-Shared-2 invariant.")
    }

    /// codex-2: setToken("") clears `cached` unconditionally, including
    /// when the Keychain delete fails. This test exercises the happy
    /// path (Keychain entry exists, delete succeeds, cache clears) —
    /// the failure-branch regression would require a Keychain stub which
    /// the current shape doesn't support, but this still guards against
    /// someone removing the `cached = nil` line entirely on the
    /// already-empty / non-existent token path.
    func test_setTokenEmpty_clearsCache() throws {
        // Use a unique service name so the test doesn't collide with the
        // real shared instance's Keychain entry.
        let provider = PastedAnthropicTokenProvider(
            serviceName: "com.clawdmeter.tests.\(UUID().uuidString)",
            accessGroup: nil,
            synchronizable: false
        )

        // Seed a token. setToken returns Bool indicating Keychain write
        // succeeded; some CI environments without a Keychain may fail
        // here, in which case currentAccessToken stays nil and the test
        // below is moot — skip rather than spuriously fail.
        let seeded = provider.setToken("sk-ant-test-fixture")
        guard seeded, provider.currentAccessToken == "sk-ant-test-fixture" else {
            // Keychain unavailable in this environment (CI without
            // unlocked login keychain). Skip.
            throw XCTSkip("Keychain not available in this environment")
        }

        _ = provider.setToken("")
        XCTAssertNil(provider.currentAccessToken,
                     "setToken(\"\") must clear the in-memory cache so callers don't observe the stale token after sign-out.")
    }

    /// Whitespace-only tokens are treated as empty. Regression catch for
    /// someone changing the `trimmingCharacters` guard later.
    func test_setTokenWhitespace_clearsCache() throws {
        let provider = PastedAnthropicTokenProvider(
            serviceName: "com.clawdmeter.tests.\(UUID().uuidString)",
            accessGroup: nil,
            synchronizable: false
        )
        let seeded = provider.setToken("sk-ant-test-fixture")
        guard seeded, provider.currentAccessToken == "sk-ant-test-fixture" else {
            throw XCTSkip("Keychain not available in this environment")
        }
        _ = provider.setToken("   \n  \t ")
        XCTAssertNil(provider.currentAccessToken,
                     "Whitespace-only tokens must be treated as empty.")
    }
}
#endif
