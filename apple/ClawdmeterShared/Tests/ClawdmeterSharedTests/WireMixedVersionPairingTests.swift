import XCTest
@testable import ClawdmeterShared

/// X3-A regression test (Codex outside-voice). Pre-X3-A, iOS used strict
/// equality (`serverWireVersion != AgentControlWireVersion.current`) for
/// `hasWireVersionMismatch`, which surfaced a "version mismatch" banner
/// any time the Mac was on a different wire version than the iPhone —
/// even when the wire shapes were forward-compatible. After X3-A,
/// `hasMismatch(...)` only fires when the server is below the minimum
/// feature floor (`composeDraftMinimum`).
///
/// This suite locks the contract for both directions of pair-version
/// drift:
///   - v5 Mac + v6 iPhone → no mismatch banner (Mac still serves
///     Claude + Codex correctly via legacy fields); Gemini UI is hidden
///     via `supportsGemini = false`.
///   - v6 Mac + v5 iPhone → v5 iPhone has no knowledge of the wire v6
///     concept; mismatch is irrelevant since v5 readers ignore unknown
///     fields tolerantly.
///   - v6 ↔ v6 → mismatch=false, all 3 providers visible.
///   - v7 Mac + v6 iPhone → mismatch=false (forward-compat preserved);
///     Gemini visible. Future v8-only features would gate themselves.
final class WireMixedVersionPairingTests: XCTestCase {

    func test_v5Server_v6Client_noMismatch_geminiHidden() {
        let serverWire = 5
        XCTAssertFalse(AgentControlWireVersion.hasMismatch(serverWireVersion: serverWire),
                       "v5 server is at composeDraftMinimum (4) so should NOT trigger the mismatch banner")
        XCTAssertFalse(AgentControlWireVersion.supportsGemini(serverWireVersion: serverWire),
                       "v5 server cannot serve Gemini (< geminiMinimum)")
        XCTAssertTrue(AgentControlWireVersion.supportsChatSubscribe(serverWireVersion: serverWire))
        XCTAssertTrue(AgentControlWireVersion.supportsComposeDraft(serverWireVersion: serverWire))
    }

    func test_v6Server_v6Client_noMismatch_allFeatures() {
        let serverWire = 6
        XCTAssertFalse(AgentControlWireVersion.hasMismatch(serverWireVersion: serverWire))
        XCTAssertTrue(AgentControlWireVersion.supportsGemini(serverWireVersion: serverWire))
        XCTAssertTrue(AgentControlWireVersion.supportsChatSubscribe(serverWireVersion: serverWire))
        XCTAssertTrue(AgentControlWireVersion.supportsComposeDraft(serverWireVersion: serverWire))
    }

    /// Hypothetical future v7 server — current client must NOT flag
    /// mismatch and must continue rendering everything it knows about.
    /// Forward-compat is the whole point of the X3-A refactor.
    func test_v7Server_v6Client_noMismatch_keepsRendering() {
        let serverWire = 7
        XCTAssertFalse(AgentControlWireVersion.hasMismatch(serverWireVersion: serverWire),
                       "v7+ servers are forward-compatible with v6 clients")
        XCTAssertTrue(AgentControlWireVersion.supportsGemini(serverWireVersion: serverWire))
    }

    /// Genuine "too old" case: a v3 server pre-dates composeDraftMinimum.
    /// Mismatch SHOULD fire here — iOS can't run its baseline feature set
    /// against a server that old.
    func test_v3Server_v6Client_mismatchFires() {
        XCTAssertTrue(AgentControlWireVersion.hasMismatch(serverWireVersion: 3),
                      "v3 server is below composeDraftMinimum (4) — banner SHOULD fire")
    }

    func test_unpaired_serverWireNil_noMismatch() {
        // No paired Mac means no banner. The banner only makes sense when
        // we've heard from the Mac at least once.
        XCTAssertFalse(AgentControlWireVersion.hasMismatch(serverWireVersion: nil))
        XCTAssertFalse(AgentControlWireVersion.supportsGemini(serverWireVersion: nil))
    }

    /// Sanity: minimums haven't drifted from the documented contract.
    /// Bumping them is intentional (and re-runs this test); flipping
    /// them by accident would silently invalidate the audit.
    func test_minimumsMatchContract() {
        XCTAssertEqual(AgentControlWireVersion.current, 6)
        XCTAssertEqual(AgentControlWireVersion.composeDraftMinimum, 4)
        XCTAssertEqual(AgentControlWireVersion.chatSubscribeMinimum, 5)
        XCTAssertEqual(AgentControlWireVersion.geminiMinimum, 6)
    }
}
