import XCTest
@testable import ClawdmeterShared

/// Routing decision for a cross-vendor live model switch (e.g. a Codex session
/// asked to run Opus). Pure + table-driven so the daemon `handleChangeModel`,
/// the Mac `SessionsModel.switchModel`, and `switchAgentInPlace` all agree on
/// which switches respawn a Claude PTY, which respawn a harness bridge, and
/// which are deferred — without spinning up the daemon.
final class CrossVendorSwitchTargetTests: XCTestCase {

    func test_sameVendor_isNotCrossVendor() {
        for agent: AgentKind in [.claude, .codex, .cursor, .grok, .gemini, .opencode] {
            XCTAssertEqual(crossVendorSwitchTarget(from: agent, to: agent), .notCrossVendor,
                           "\(agent.rawValue) → \(agent.rawValue) is a same-vendor swap")
        }
    }

    func test_intoClaude_spawnsClaudePty() {
        for from: AgentKind in [.codex, .cursor, .grok, .gemini] {
            XCTAssertEqual(crossVendorSwitchTarget(from: from, to: .claude), .claudePty,
                           "\(from.rawValue) → Claude must spawn a fresh Claude PTY")
        }
    }

    func test_intoReconfigurableHarness_spawnsHarness() {
        // Claude → any managed harness, and harness → a different managed harness.
        XCTAssertEqual(crossVendorSwitchTarget(from: .claude, to: .codex), .harness)
        XCTAssertEqual(crossVendorSwitchTarget(from: .claude, to: .cursor), .harness)
        XCTAssertEqual(crossVendorSwitchTarget(from: .codex, to: .cursor), .harness)
        XCTAssertEqual(crossVendorSwitchTarget(from: .grok, to: .gemini), .harness)
    }

    func test_opencodeSourceOrTarget_isDeferred() {
        // OpenCode either side has no in-place teardown/respawn analogue yet —
        // must be an honest `.unsupported`, never a silent no-op.
        if case .unsupported = crossVendorSwitchTarget(from: .opencode, to: .claude) {} else {
            XCTFail("opencode → Claude should be unsupported")
        }
        if case .unsupported = crossVendorSwitchTarget(from: .codex, to: .opencode) {} else {
            XCTFail("codex → opencode should be unsupported")
        }
        if case .unsupported = crossVendorSwitchTarget(from: .opencode, to: .codex) {} else {
            XCTFail("opencode → codex should be unsupported")
        }
    }

    func test_unknownTarget_isDeferred() {
        if case .unsupported = crossVendorSwitchTarget(from: .codex, to: .unknown) {} else {
            XCTFail("→ unknown agent should be unsupported")
        }
    }

    func test_unsupportedCarriesUserFacingReason() {
        guard case .unsupported(let reason) = crossVendorSwitchTarget(from: .codex, to: .opencode) else {
            return XCTFail("expected unsupported")
        }
        XCTAssertFalse(reason.isEmpty, "unsupported must carry user-facing copy for the toast")
    }
}
