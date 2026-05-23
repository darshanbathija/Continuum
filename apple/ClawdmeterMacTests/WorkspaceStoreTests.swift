import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Tests cover migration-from-sessions, upsert/replace semantics, and
/// schema-tolerance for the persisted workspace store. The store is
/// @MainActor; tests are wrapped accordingly.
@MainActor
final class WorkspaceStoreTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.tmpDir = base
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    private var workspacesURL: URL { tmpDir.appendingPathComponent("workspaces.json") }
    private var sessionsURL: URL { tmpDir.appendingPathComponent("sessions.json") }

    // MARK: - Round-trip

    func test_roundTrip_codeWorkspaceRecord() throws {
        let now = Date()
        let record = CodeWorkspaceRecord(
            id: UUID(),
            projectId: UUID(),
            repoRoot: "/Users/dev/work/SomeRepo",
            repoDisplayName: "SomeRepo",
            defaultBranch: "main",
            worktreeRoot: "/Users/dev/work/SomeRepo",
            runtimeCwd: "/Users/dev/work/SomeRepo",
            chatCwd: nil,
            providerDefaults: WorkspaceProviderDefaults(
                defaultAgent: .codex,
                defaultModelByProvider: ["codex": "gpt-5-codex"],
                defaultRuntimeByProvider: ["codex": .codexSDK],
                defaultEffort: .high
            ),
            activeSessionIds: [UUID(), UUID()],
            createdAt: now,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CodeWorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.repoRoot, record.repoRoot)
        XCTAssertEqual(decoded.providerDefaults.defaultAgent, .codex)
        XCTAssertEqual(decoded.providerDefaults.defaultModelByProvider["codex"], "gpt-5-codex")
        XCTAssertEqual(decoded.activeSessionIds.count, 2)
    }

    // MARK: - Migration

    func test_migration_synthesizesOneWorkspacePerRepoRoot() throws {
        let repoA = "/Users/dev/repos/alpha"
        let repoB = "/Users/dev/repos/beta"
        let sessionAOlder = makeSession(
            repoKey: repoA,
            agent: .claude,
            model: "claude-sonnet-4-5",
            createdAt: Date(timeIntervalSinceNow: -3600)
        )
        let sessionANewer = makeSession(
            repoKey: repoA,
            agent: .codex,
            model: "gpt-5",
            effort: .medium,
            createdAt: Date()
        )
        let sessionB = makeSession(
            repoKey: repoB,
            agent: .claude,
            model: "claude-sonnet-4-6",
            createdAt: Date(timeIntervalSinceNow: -120)
        )
        try writeSessionsFile([sessionAOlder, sessionANewer, sessionB])

        let store = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)

        XCTAssertEqual(store.all().count, 2)
        let alpha = store.workspace(forRepoRoot: repoA)
        XCTAssertNotNil(alpha)
        // Migration must pick the NEWEST session's defaults for the
        // workspace seed, not the oldest. This is the user-facing
        // contract: "the next agent I spawn in this repo inherits what
        // I was last using here."
        XCTAssertEqual(alpha?.providerDefaults.defaultAgent, .codex)
        XCTAssertEqual(alpha?.providerDefaults.defaultModelByProvider["codex"], "gpt-5")
        XCTAssertEqual(alpha?.providerDefaults.defaultEffort, .medium)

        let beta = store.workspace(forRepoRoot: repoB)
        XCTAssertEqual(beta?.providerDefaults.defaultAgent, .claude)
        XCTAssertEqual(beta?.providerDefaults.defaultModelByProvider["claude"], "claude-sonnet-4-6")
    }

    func test_migration_isIdempotent() throws {
        let repo = "/Users/dev/repos/gamma"
        try writeSessionsFile([
            makeSession(repoKey: repo, agent: .claude, model: "claude-sonnet-4-5", createdAt: Date())
        ])

        let first = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        XCTAssertEqual(first.all().count, 1)
        let firstId = first.workspace(forRepoRoot: repo)?.id

        // Second instance reads the written workspaces.json and skips
        // migration entirely. The deterministic UUID derivation means
        // the id is stable even if migration were to re-run.
        let second = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        XCTAssertEqual(second.all().count, 1)
        XCTAssertEqual(second.workspace(forRepoRoot: repo)?.id, firstId)
    }

    func test_migration_skipsSessionsWithoutRepoKey() throws {
        // Chat sessions (nil repoKey) and unknown-repo sessions don't
        // belong to any workspace — migration must skip them.
        try writeSessionsFile([
            makeSession(repoKey: nil, agent: .claude, model: "claude-sonnet-4-5", createdAt: Date()),
            makeSession(repoKey: "(unknown)", agent: .claude, model: "claude-sonnet-4-5", createdAt: Date())
        ])
        let store = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        XCTAssertEqual(store.all().count, 0)
    }

    // MARK: - upsert + setProviderDefaults

    func test_upsert_replacesByIdAndPreservesCreatedAt() throws {
        let store = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        let id = UUID()
        let originalCreatedAt = Date(timeIntervalSinceNow: -86_400)
        let first = CodeWorkspaceRecord(
            id: id,
            projectId: UUID(),
            repoRoot: "/repos/delta",
            repoDisplayName: "delta",
            runtimeCwd: "/repos/delta",
            providerDefaults: WorkspaceProviderDefaults(defaultAgent: .claude),
            createdAt: originalCreatedAt,
            updatedAt: originalCreatedAt
        )
        store.upsert(first)
        XCTAssertEqual(store.all().count, 1)

        let updated = CodeWorkspaceRecord(
            id: id,
            projectId: first.projectId,
            repoRoot: first.repoRoot,
            repoDisplayName: "delta-renamed",
            runtimeCwd: first.runtimeCwd,
            providerDefaults: WorkspaceProviderDefaults(defaultAgent: .codex)
        )
        let result = store.upsert(updated)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(result.repoDisplayName, "delta-renamed")
        XCTAssertEqual(result.providerDefaults.defaultAgent, .codex)
        // createdAt must be preserved across upserts; updatedAt should
        // bump forward.
        XCTAssertEqual(result.createdAt, originalCreatedAt)
        XCTAssertGreaterThan(result.updatedAt, originalCreatedAt)
    }

    func test_setProviderDefaults_returnsNilForUnknownId() {
        let store = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        let result = store.setProviderDefaults(
            id: UUID(),
            defaults: WorkspaceProviderDefaults(defaultAgent: .claude)
        )
        XCTAssertNil(result)
    }

    func test_setProviderDefaults_updatesAndPersists() throws {
        let store = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        let record = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: "/repos/epsilon",
            repoDisplayName: "epsilon",
            runtimeCwd: "/repos/epsilon"
        )
        store.upsert(record)
        let result = store.setProviderDefaults(
            id: record.id,
            defaults: WorkspaceProviderDefaults(
                defaultAgent: .opencode,
                defaultModelByProvider: ["opencode": "anthropic/claude-sonnet-4-5"],
                defaultEffort: .high
            )
        )
        XCTAssertEqual(result?.providerDefaults.defaultAgent, .opencode)
        // Confirm the on-disk file was rewritten.
        let raw = try Data(contentsOf: workspacesURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct StoreFile: Decodable {
            var schemaVersion: Int
            var workspaces: [CodeWorkspaceRecord]
        }
        let file = try decoder.decode(StoreFile.self, from: raw)
        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.workspaces.first?.providerDefaults.defaultAgent, .opencode)
    }

    // MARK: - syncActiveSessions

    func test_syncActiveSessions_synthesizesMissingWorkspace() {
        let store = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        let sessionId = UUID()
        store.syncActiveSessions(repoRoot: "/repos/zeta", sessionIds: [sessionId])
        let workspace = store.workspace(forRepoRoot: "/repos/zeta")
        XCTAssertNotNil(workspace)
        XCTAssertEqual(workspace?.activeSessionIds, [sessionId])
        XCTAssertEqual(workspace?.repoDisplayName, "zeta")
    }

    func test_syncActiveSessions_skipsEmptyOrUnknownRoot() {
        let store = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        store.syncActiveSessions(repoRoot: "", sessionIds: [UUID()])
        store.syncActiveSessions(repoRoot: "(unknown)", sessionIds: [UUID()])
        XCTAssertEqual(store.all().count, 0)
    }

    // MARK: - Deterministic UUID

    func test_deterministicUUID_isStable() {
        let a = WorkspaceStore.deterministicUUID(for: "workspace:/repos/zeta")
        let b = WorkspaceStore.deterministicUUID(for: "workspace:/repos/zeta")
        XCTAssertEqual(a, b)
        let c = WorkspaceStore.deterministicUUID(for: "workspace:/repos/eta")
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Helpers

    private func makeSession(
        repoKey: String?,
        agent: AgentKind,
        model: String,
        effort: ReasoningEffort? = nil,
        createdAt: Date = Date()
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: repoKey,
            repoDisplayName: repoKey.map { ($0 as NSString).lastPathComponent } ?? "Chat",
            agent: agent,
            model: model,
            goal: nil,
            worktreePath: repoKey,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: createdAt,
            lastEventAt: createdAt,
            lastEventSeq: 1,
            mode: .local,
            effort: effort
        )
    }

    private func writeSessionsFile(_ sessions: [AgentSession]) throws {
        struct StoreFile: Encodable {
            var schemaVersion: Int
            var sessions: [AgentSession]
        }
        let file = StoreFile(schemaVersion: 5, sessions: sessions)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: sessionsURL)
    }
}
