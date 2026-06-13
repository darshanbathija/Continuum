// Regression coverage for the "Couldn't change permission mode —
// legacy_session_retired" toast a user hit toggling Bypass on a Grok
// (harness) session.
//
// Root cause: SessionsModel.setPermissionMode unconditionally routed every
// provider through SessionConfigChanger.swap, which is a Claude-PTY-only
// kill+respawn helper. Harness providers (Codex/Cursor/Gemini/Grok/OpenCode)
// have no CLI argv, so swap returned .spawnError("legacy_session_retired"),
// which both surfaced the misleading toast AND rolled the optimistic
// AutopilotState write back — so the permission chip snapped to the old mode
// on every pick.
//
// Fix: for non-Claude-PTY sessions the store write IS the whole operation
// (read at the agent's next launch, like the empty-state spawn path and the
// daemon's agent-agnostic handleSetAutopilot). No PTY respawn, no rollback,
// no error.

import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class PermissionModeHarnessTests: XCTestCase {

    private var directory: URL!

    private func makeModel() throws -> (SessionsModel, AgentSessionRegistry) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionModeHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registryURL = directory.appendingPathComponent("sessions.json")
        let registry = AgentSessionRegistry(storeURL: registryURL)
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: WorkspaceStore(
                storeURL: directory.appendingPathComponent("workspaces.json"),
                sessionsURL: registryURL
            )
        )
        return (model, registry)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func makeHarnessSession(_ registry: AgentSessionRegistry, agent: AgentKind) async throws -> AgentSession {
        try await registry.create(
            repoKey: "/repo/clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: agent,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .local,
            effort: nil
        )
    }

    /// Picking Bypass on a harness (Grok) session flips AutopilotState and
    /// leaves it flipped — no "legacy_session_retired" rollback. The chip's
    /// resolved mode reads back as `.bypass`.
    func test_bypassOnHarnessSession_persistsWithoutRollback() async throws {
        let (model, registry) = try makeModel()
        let session = try await makeHarnessSession(registry, agent: .grok)
        XCTAssertFalse(SessionConfigChanger.isClaudePty(session),
                       "precondition: a Grok session must not resolve as a Claude PTY session")
        addTeardownBlock { @MainActor in
            AutopilotState.shared.setEnabled(false, sessionId: session.id)
            PermissionModeStore.shared.setAcceptEdits(false, sessionId: session.id)
        }

        await model.setPermissionMode(sessionId: session.id, to: .bypass)

        XCTAssertTrue(AutopilotState.shared.isEnabled(sessionId: session.id),
                      "Bypass must stay enabled — the swap rollback used to clear it")
        XCTAssertEqual(PermissionModeStore.shared.currentMode(for: session), .bypass,
                       "The permission chip should read back as Bypass, not snap to the prior mode")
    }

    /// Accept-edits persists for a harness (Codex) session too, and a
    /// follow-up flip back to Ask clears it cleanly.
    func test_acceptEditsThenAskOnHarnessSession_persistsEachPick() async throws {
        let (model, registry) = try makeModel()
        let session = try await makeHarnessSession(registry, agent: .codex)
        addTeardownBlock { @MainActor in
            AutopilotState.shared.setEnabled(false, sessionId: session.id)
            PermissionModeStore.shared.setAcceptEdits(false, sessionId: session.id)
        }

        await model.setPermissionMode(sessionId: session.id, to: .acceptEdits)
        XCTAssertTrue(PermissionModeStore.shared.acceptEdits(sessionId: session.id))
        XCTAssertEqual(PermissionModeStore.shared.currentMode(for: session), .acceptEdits)

        await model.setPermissionMode(sessionId: session.id, to: .ask)
        XCTAssertFalse(PermissionModeStore.shared.acceptEdits(sessionId: session.id))
        XCTAssertFalse(AutopilotState.shared.isEnabled(sessionId: session.id))
        XCTAssertEqual(PermissionModeStore.shared.currentMode(for: session), .ask)
    }
}
