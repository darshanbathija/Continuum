import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// v0.23.9 P1 fix coverage: frontier-group helpers used by continue-from-winner.
///
/// These tests use an isolated tempfile registry so they never touch the
/// user's real `~/Library/Application Support/Clawdmeter/sessions.json`.
@MainActor
final class AgentSessionRegistryFrontierTests: XCTestCase {

    private var tempStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-registry-tests-\(UUID().uuidString)")
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

    // MARK: - frontierGroupChildren(includeArchived:)

    /// Default behavior (includeArchived=false) returns only live children.
    /// This is what Frontier send fan-out and snapshot subscribers rely on
    /// so archived losers can never receive new prompts.
    func test_frontierGroupChildren_defaultExcludesArchived() async throws {
        let reg = registry()
        let groupId = UUID()
        let claude = try await reg.createChat(
            provider: .claude, model: "opus", chatCwd: "/tmp",
            frontierGroupId: groupId, frontierChildIndex: 0
        )
        let codex = try await reg.createChat(
            provider: .codex, model: "gpt-5.5", chatCwd: "/tmp",
            frontierGroupId: groupId, frontierChildIndex: 1
        )

        // Archive one child (simulates a pick-winner archiving the loser).
        try await reg.archive(id: codex.id)

        let liveOnly = reg.frontierGroupChildren(groupId: groupId)
        XCTAssertEqual(liveOnly.count, 1, "default must filter archived")
        XCTAssertEqual(liveOnly.first?.id, claude.id)
    }

    /// Callers that need the full set (pick-winner enumerating losers to
    /// archive) pass includeArchived: true.
    func test_frontierGroupChildren_includeArchivedReturnsAll() async throws {
        let reg = registry()
        let groupId = UUID()
        _ = try await reg.createChat(
            provider: .claude, model: "opus", chatCwd: "/tmp",
            frontierGroupId: groupId, frontierChildIndex: 0
        )
        let codex = try await reg.createChat(
            provider: .codex, model: "gpt-5.5", chatCwd: "/tmp",
            frontierGroupId: groupId, frontierChildIndex: 1
        )
        try await reg.archive(id: codex.id)

        let all = reg.frontierGroupChildren(groupId: groupId, includeArchived: true)
        XCTAssertEqual(all.count, 2, "includeArchived must return live + archived")
        XCTAssertEqual(all.map(\.frontierChildIndex), [0, 1], "sort order preserved")
    }

    func test_frontierGroupChildren_emptyWhenGroupUnknown() async {
        let reg = registry()
        let group = reg.frontierGroupChildren(groupId: UUID())
        XCTAssertTrue(group.isEmpty)
    }

    func test_createChat_recordsVisibleVendorAndBillingProviderMetadata() async throws {
        let reg = registry()
        let session = try await reg.createChat(
            provider: .opencode,
            model: "openai/gpt-5.5",
            chatCwd: "/tmp",
            chatVendor: .openrouter,
            billingProvider: "openrouter"
        )

        let binding = reg.session(id: session.id)?.runtimeBinding
        XCTAssertEqual(binding?.runtimeKind, .opencodeServer)
        XCTAssertEqual(binding?.providerModelId, "openai/gpt-5.5")
        XCTAssertEqual(binding?.billingProvider, "openrouter")
        XCTAssertEqual(binding?.metadata["chatVendor"], ChatVendor.openrouter.rawValue)
    }

    func test_createChat_recordsCursorChatVendorMetadata() async throws {
        let reg = registry()
        let session = try await reg.createChat(
            provider: .cursor,
            model: CursorModelCatalog.autoModelId,
            chatCwd: "/tmp",
            chatVendor: .cursor
        )

        let binding = reg.session(id: session.id)?.runtimeBinding
        XCTAssertEqual(binding?.runtimeKind, .cursorCLI)
        XCTAssertEqual(binding?.providerModelId, CursorModelCatalog.autoModelId)
        XCTAssertEqual(binding?.metadata["chatVendor"], ChatVendor.cursor.rawValue)
    }

    func test_updateRuntimeUpdatesEffectiveCwd() async throws {
        let reg = registry()
        let session = try await reg.create(
            repoKey: "/tmp/source-repo",
            repoDisplayName: "source-repo",
            agent: .claude,
            model: "sonnet",
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: "window-old",
            tmuxPaneId: "pane-old",
            planMode: false,
            mode: .local
        )

        try await reg.updateRuntime(
            id: session.id,
            worktreePath: "/tmp/source-repo-worktree",
            runtimeCwd: .some("/tmp/source-repo-worktree"),
            tmuxWindowId: "window-new",
            tmuxPaneId: "pane-new",
            mode: .worktree
        )

        let updated = reg.session(id: session.id)
        XCTAssertEqual(updated?.runtimeCwd, "/tmp/source-repo-worktree")
        XCTAssertEqual(updated?.effectiveCwd, "/tmp/source-repo-worktree")
        XCTAssertEqual(updated?.worktreePath, "/tmp/source-repo-worktree")
    }

    // MARK: - clearFrontierGroupBinding

    /// After continue-from-winner, the winner's frontierGroupId and
    /// frontierChildIndex are cleared so the sidebar / history / Frontier
    /// snapshot all treat it as a regular Solo chat from that moment on.
    func test_clearFrontierGroupBinding_winnerBecomesSolo() async throws {
        let reg = registry()
        let groupId = UUID()
        let winner = try await reg.createChat(
            provider: .claude, model: "opus", chatCwd: "/tmp",
            frontierGroupId: groupId, frontierChildIndex: 0
        )
        XCTAssertEqual(reg.session(id: winner.id)?.frontierGroupId, groupId)
        XCTAssertEqual(reg.session(id: winner.id)?.frontierChildIndex, 0)

        try await reg.clearFrontierGroupBinding(id: winner.id)

        let promoted = reg.session(id: winner.id)
        XCTAssertNotNil(promoted)
        XCTAssertNil(promoted?.frontierGroupId, "frontierGroupId must be cleared")
        XCTAssertNil(promoted?.frontierChildIndex, "frontierChildIndex must be cleared")
    }

    /// After clearing the winner, frontierGroupChildren no longer surfaces
    /// it — so any further Frontier-send fan-out routes to nobody and the
    /// UI's "≥ 2 live children" guard correctly fails.
    func test_clearFrontierGroupBinding_dropsFromGroupChildren() async throws {
        let reg = registry()
        let groupId = UUID()
        let winner = try await reg.createChat(
            provider: .claude, model: "opus", chatCwd: "/tmp",
            frontierGroupId: groupId, frontierChildIndex: 0
        )
        let loser = try await reg.createChat(
            provider: .codex, model: "gpt-5.5", chatCwd: "/tmp",
            frontierGroupId: groupId, frontierChildIndex: 1
        )
        try await reg.archive(id: loser.id)
        try await reg.clearFrontierGroupBinding(id: winner.id)

        let live = reg.frontierGroupChildren(groupId: groupId)
        XCTAssertTrue(live.isEmpty, "after pick-winner the group has no live children")
    }

    /// Idempotent: clearing again is a no-op.
    func test_clearFrontierGroupBinding_idempotent() async throws {
        let reg = registry()
        let groupId = UUID()
        let s = try await reg.createChat(
            provider: .claude, model: "opus", chatCwd: "/tmp",
            frontierGroupId: groupId, frontierChildIndex: 0
        )
        try await reg.clearFrontierGroupBinding(id: s.id)
        try await reg.clearFrontierGroupBinding(id: s.id)
        let promoted = reg.session(id: s.id)
        XCTAssertNil(promoted?.frontierGroupId)
    }
}
