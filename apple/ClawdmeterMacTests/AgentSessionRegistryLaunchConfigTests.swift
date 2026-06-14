import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Registry-level guarantees that make a cross-vendor live switch safe:
///
/// - `setLaunchConfiguration` repoints agent+model+effort+customProvider in one
///   write and rebuilds `runtimeBinding` so the billing stack flips to the new
///   vendor.
/// - `setClaudeSessionId(nil)` + `clearCodexChatThreadId` drop the OLD vendor's
///   resume ids, so the fresh spawn doesn't try `--resume <foreign id>` (the
///   "stale resume" regression `switchAgentInPlace` defends against).
@MainActor
final class AgentSessionRegistryLaunchConfigTests: XCTestCase {

    private var tempStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-launchcfg-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempStoreURL = dir.appendingPathComponent("sessions.json")
    }

    override func tearDown() async throws {
        if let dir = tempStoreURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func registry() -> AgentSessionRegistry {
        AgentSessionRegistry(storeURL: tempStoreURL)
    }

    private func makeCodeSession(in reg: AgentSessionRegistry, agent: AgentKind, model: String?) async throws -> AgentSession {
        let session = try await reg.create(
            repoKey: "/tmp/test-repo",
            repoDisplayName: "test-repo",
            agent: agent,
            model: model,
            goal: nil,
            worktreePath: "/tmp/test-repo",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        return try XCTUnwrap(reg.session(id: session.id))
    }

    func test_setLaunchConfiguration_flipsAgentModelAndBilling() async throws {
        let reg = registry()
        let session = try await makeCodeSession(in: reg, agent: .codex, model: "gpt-5.4")

        try await reg.setLaunchConfiguration(
            id: session.id, agent: .claude, model: "opus", effort: .high, customProviderId: nil)

        let updated = try XCTUnwrap(reg.session(id: session.id))
        XCTAssertEqual(updated.agent, .claude)
        XCTAssertEqual(updated.model, "opus")
        XCTAssertEqual(updated.effort, .high)
        XCTAssertEqual(updated.runtimeBinding?.billingProvider, "claude",
                       "runtimeBinding must flip so billing follows the new vendor")
        XCTAssertEqual(updated.runtimeBinding?.providerModelId, "opus")
    }

    func test_setLaunchConfiguration_clearsCustomProviderWithExplicitNil() async throws {
        let reg = registry()
        // Seed a session pinned to a custom provider, then switch off it.
        let session = try await makeCodeSession(in: reg, agent: .codex, model: "gpt-5.4")
        try await reg.setLaunchConfiguration(
            id: session.id, agent: .codex, model: "gpt-5.4", effort: nil, customProviderId: .some("acme"))
        XCTAssertEqual(reg.session(id: session.id)?.customProviderId, "acme")

        try await reg.setLaunchConfiguration(
            id: session.id, agent: .claude, model: "opus", effort: nil, customProviderId: .some(nil))
        XCTAssertNil(reg.session(id: session.id)?.customProviderId,
                     "explicit .some(nil) must clear the custom provider on a cross-vendor switch")
    }

    func test_clearsStaleResumeIds_acrossCrossVendorSwitch() async throws {
        let reg = registry()
        // A Claude session that has captured its CLI resume id.
        let session = try await makeCodeSession(in: reg, agent: .claude, model: "opus")
        try await reg.setClaudeSessionId(id: session.id, value: "claude-resume-abc")
        XCTAssertEqual(reg.session(id: session.id)?.claudeSessionId, "claude-resume-abc")

        // Switch to Codex (the new vendor) — then drop the stale resume ids, the
        // exact sequence switchAgentInPlace performs.
        try await reg.setLaunchConfiguration(
            id: session.id, agent: .codex, model: "gpt-5.4", effort: nil, customProviderId: nil)
        try await reg.setClaudeSessionId(id: session.id, value: nil)
        try await reg.clearCodexChatThreadId(id: session.id)

        let updated = try XCTUnwrap(reg.session(id: session.id))
        XCTAssertEqual(updated.agent, .codex)
        XCTAssertNil(updated.claudeSessionId,
                     "a fresh Codex spawn must not inherit the old Claude --resume id")
        XCTAssertNil(updated.codexChatThreadId)
    }

    func test_clearCodexChatThreadId_clearsThreadAndBinding() async throws {
        let reg = registry()
        let session = try await makeCodeSession(in: reg, agent: .codex, model: "gpt-5.4")
        try await reg.setCodexChatThreadId(id: session.id, threadId: "thread-xyz")
        XCTAssertEqual(reg.session(id: session.id)?.codexChatThreadId, "thread-xyz")
        XCTAssertEqual(reg.session(id: session.id)?.runtimeBinding?.externalThreadId, "thread-xyz")

        try await reg.clearCodexChatThreadId(id: session.id)
        XCTAssertNil(reg.session(id: session.id)?.codexChatThreadId)
        XCTAssertNil(reg.session(id: session.id)?.runtimeBinding?.externalThreadId)
    }
}
