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
    private var workspaceStorageRoot: URL { tmpDir.appendingPathComponent("ClawdmeterWorkspaces", isDirectory: true) }

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
            filesToCopy: WorkspaceFilesToCopySettings(
                mode: .patterns,
                patterns: [".env*", "config/local.json"],
                maxFiles: 12,
                maxBytesPerFile: 1024,
                maxTotalBytes: 4096,
                allowDirectories: false
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
        XCTAssertEqual(decoded.filesToCopy.mode, .patterns)
        XCTAssertEqual(decoded.filesToCopy.patterns, [".env*", "config/local.json"])
        XCTAssertEqual(decoded.filesToCopy.maxFiles, 12)
        XCTAssertEqual(decoded.filesToCopy.maxBytesPerFile, 1024)
        XCTAssertEqual(decoded.filesToCopy.maxTotalBytes, 4096)
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

    func test_updateDefaults_mergesProviderAndFilesToCopyIndependently() throws {
        let store = WorkspaceStore(storeURL: workspacesURL, sessionsURL: sessionsURL)
        let record = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: "/repos/partial",
            repoDisplayName: "partial",
            runtimeCwd: "/repos/partial",
            providerDefaults: WorkspaceProviderDefaults(
                defaultAgent: .claude,
                defaultModelByProvider: ["claude": "sonnet"],
                defaultEffort: .medium
            ),
            filesToCopy: WorkspaceFilesToCopySettings(
                mode: .patterns,
                patterns: [".env*"],
                maxFiles: 10,
                allowDirectories: false
            )
        )
        store.upsert(record)

        let fileOnly = store.updateDefaults(
            id: record.id,
            filesToCopy: WorkspaceFilesToCopySettings(
                mode: .patterns,
                patterns: [".env.local"],
                maxFiles: 1,
                maxBytesPerFile: 128,
                maxTotalBytes: 128,
                allowDirectories: false
            )
        )
        XCTAssertEqual(fileOnly?.providerDefaults.defaultAgent, .claude)
        XCTAssertEqual(fileOnly?.providerDefaults.defaultModelByProvider["claude"], "sonnet")
        XCTAssertEqual(fileOnly?.filesToCopy.mode, .patterns)
        XCTAssertEqual(fileOnly?.filesToCopy.patterns, [".env.local"])
        XCTAssertEqual(fileOnly?.filesToCopy.maxFiles, 1)

        let providerOnly = store.updateDefaults(
            id: record.id,
            providerDefaults: WorkspaceProviderDefaults(
                defaultAgent: .codex,
                defaultModelByProvider: ["codex": "gpt-5.5"],
                defaultEffort: .high
            )
        )
        XCTAssertEqual(providerOnly?.providerDefaults.defaultAgent, .codex)
        XCTAssertEqual(providerOnly?.providerDefaults.defaultModelByProvider["codex"], "gpt-5.5")
        XCTAssertEqual(providerOnly?.filesToCopy.patterns, [".env.local"])
        XCTAssertEqual(providerOnly?.filesToCopy.maxFiles, 1)
    }

    func test_worktreeProvisionCopiesAllIgnoredByDefaultAndWritesManifest() async throws {
        let repo = try makeGitRepo(name: "copy-default")
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try write(".env*\nnode_modules/\ncache/\n*.sqlite*\n", to: repo.appendingPathComponent(".gitignore"))
        try git(["add", "tracked.txt", ".gitignore"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)
        try write("SECRET=1\n", to: repo.appendingPathComponent(".env.local"))
        try write("module\n", to: repo.appendingPathComponent("node_modules/pkg/index.js"))
        try write("db\n", to: repo.appendingPathComponent("dev.sqlite"))
        try write("wal\n", to: repo.appendingPathComponent("dev.sqlite-wal"))
        try write("shm\n", to: repo.appendingPathComponent("dev.sqlite-shm"))
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("cache/empty", isDirectory: true),
            withIntermediateDirectories: true
        )

        let manager = WorktreeManager(workspaceStorageRoot: workspaceStorageRoot.path)
        let provisioned = try await manager.provision(
            repoRoot: repo.path,
            slug: "copy-default-worktree",
            branchName: "copy-default-worktree",
            filesToCopy: WorkspaceFilesToCopySettings()
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent("tracked.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent(".env.local")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent("node_modules/pkg/index.js")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent("dev.sqlite")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent("dev.sqlite-wal")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent("dev.sqlite-shm")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent("cache/empty")))
        XCTAssertTrue(provisioned.path.hasPrefix(workspaceStorageRoot.path + "/copy-default/"))
        XCTAssertFalse(provisioned.path.contains("/.claude/worktrees/"))
        XCTAssertFalse(provisioned.path.hasPrefix(NSHomeDirectory() + "/conductor/workspaces/"))
        XCTAssertEqual(provisioned.metadata.filesToCopy.source, .defaultPatterns)
        XCTAssertEqual(provisioned.metadata.filesToCopy.mode, .allIgnored)
        XCTAssertEqual(provisioned.metadata.filesToCopy.patterns, [])
        XCTAssertEqual(provisioned.metadata.filesToCopy.copiedFileCount, 5)
        XCTAssertGreaterThanOrEqual(provisioned.metadata.filesToCopy.copiedDirectoryCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provisioned.metadata.filesToCopy.manifestPath ?? ""))
        _ = try await manager.cleanupProvisionedWorktree(
            repoRoot: repo.path,
            worktreePath: provisioned.path,
            expectedMarkerId: provisioned.metadata.ownershipMarkerId
        )
    }

    func test_worktreeCleanupDoesNotDeleteUserFilesInsideCopiedDirectories() async throws {
        let repo = try makeGitRepo(name: "cleanup-copied-dir")
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try write("cache/\n", to: repo.appendingPathComponent(".gitignore"))
        try git(["add", "tracked.txt", ".gitignore"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)
        try write("owned\n", to: repo.appendingPathComponent("cache/original.txt"))

        let manager = WorktreeManager(workspaceStorageRoot: workspaceStorageRoot.path)
        let provisioned = try await manager.provision(
            repoRoot: repo.path,
            slug: "cleanup-copied-dir-worktree",
            branchName: "cleanup-copied-dir-worktree",
            filesToCopy: WorkspaceFilesToCopySettings()
        )
        let userFile = URL(fileURLWithPath: provisioned.path, isDirectory: true)
            .appendingPathComponent("cache/user-created.txt")
        try write("user data\n", to: userFile)

        let result = try await manager.cleanupProvisionedWorktree(
            repoRoot: repo.path,
            worktreePath: provisioned.path,
            expectedMarkerId: provisioned.metadata.ownershipMarkerId
        )
        switch result {
        case .deleted:
            XCTFail("cleanup must not delete a worktree containing user-created files")
        case .skipped:
            break
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provisioned.path))
    }

    func test_worktreeCleanupDoesNotDeleteModifiedCopiedFiles() async throws {
        let repo = try makeGitRepo(name: "cleanup-modified-file")
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try write(".env*\n", to: repo.appendingPathComponent(".gitignore"))
        try git(["add", "tracked.txt", ".gitignore"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)
        try write("SECRET=1\n", to: repo.appendingPathComponent(".env.local"))

        let manager = WorktreeManager(workspaceStorageRoot: workspaceStorageRoot.path)
        let provisioned = try await manager.provision(
            repoRoot: repo.path,
            slug: "cleanup-modified-file-worktree",
            branchName: "cleanup-modified-file-worktree",
            filesToCopy: WorkspaceFilesToCopySettings()
        )
        let copiedFile = URL(fileURLWithPath: provisioned.path, isDirectory: true)
            .appendingPathComponent(".env.local")
        try write("SECRET=changed-and-longer\n", to: copiedFile)

        let result = try await manager.cleanupProvisionedWorktree(
            repoRoot: repo.path,
            worktreePath: provisioned.path,
            expectedMarkerId: provisioned.metadata.ownershipMarkerId
        )
        switch result {
        case .deleted:
            XCTFail("cleanup must not delete a worktree containing a modified copied file")
        case .skipped:
            break
        }
        XCTAssertEqual(try String(contentsOf: copiedFile, encoding: .utf8), "SECRET=changed-and-longer\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: provisioned.path))
    }

    func test_worktreeProvisionWorktreeincludeOverridesDefaultEnv() async throws {
        let repo = try makeGitRepo(name: "worktreeinclude")
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try write(".env*\n.secret*\n", to: repo.appendingPathComponent(".gitignore"))
        try write(".secret*\n", to: repo.appendingPathComponent(".worktreeinclude"))
        try git(["add", "tracked.txt", ".gitignore", ".worktreeinclude"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)
        try write("ENV=1\n", to: repo.appendingPathComponent(".env.local"))
        try write("SECRET=1\n", to: repo.appendingPathComponent(".secret.local"))

        let manager = WorktreeManager(workspaceStorageRoot: workspaceStorageRoot.path)
        let provisioned = try await manager.provision(
            repoRoot: repo.path,
            slug: "worktreeinclude-worktree",
            branchName: "worktreeinclude-worktree",
            filesToCopy: WorkspaceFilesToCopySettings(mode: .patterns, patterns: [".env*"], allowDirectories: false)
        )

        XCTAssertEqual(provisioned.metadata.filesToCopy.source, .worktreeinclude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent(".env.local")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent(".secret.local")))
        _ = try await manager.cleanupProvisionedWorktree(
            repoRoot: repo.path,
            worktreePath: provisioned.path,
            expectedMarkerId: provisioned.metadata.ownershipMarkerId
        )
    }

    func test_worktreeProvisionUsesGitNegationPatterns() async throws {
        let repo = try makeGitRepo(name: "worktreeinclude-negation")
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try write(".env*\n", to: repo.appendingPathComponent(".gitignore"))
        try write(".env*\n!.env.local\n", to: repo.appendingPathComponent(".worktreeinclude"))
        try git(["add", "tracked.txt", ".gitignore", ".worktreeinclude"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)
        try write("ENV=local\n", to: repo.appendingPathComponent(".env.local"))
        try write("ENV=copy\n", to: repo.appendingPathComponent(".env.copy"))

        let manager = WorktreeManager(workspaceStorageRoot: workspaceStorageRoot.path)
        let provisioned = try await manager.provision(
            repoRoot: repo.path,
            slug: "worktreeinclude-negation-worktree",
            branchName: "worktreeinclude-negation-worktree",
            filesToCopy: WorkspaceFilesToCopySettings(mode: .patterns, patterns: [".secret*"], allowDirectories: false)
        )

        XCTAssertEqual(provisioned.metadata.filesToCopy.source, .worktreeinclude)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent(".env.copy")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (provisioned.path as NSString).appendingPathComponent(".env.local")))
        XCTAssertEqual(provisioned.metadata.filesToCopy.copiedFileCount, 1)
        _ = try await manager.cleanupProvisionedWorktree(
            repoRoot: repo.path,
            worktreePath: provisioned.path,
            expectedMarkerId: provisioned.metadata.ownershipMarkerId
        )
    }

    func test_worktreeProvisionFailsClosedAndCleansUpOnCopyCap() async throws {
        let repo = try makeGitRepo(name: "cap-fail")
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try write(".env*\n", to: repo.appendingPathComponent(".gitignore"))
        try git(["add", "tracked.txt", ".gitignore"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)
        try write("TOO_BIG=123\n", to: repo.appendingPathComponent(".env.local"))

        let manager = WorktreeManager(workspaceStorageRoot: workspaceStorageRoot.path)
        do {
            _ = try await manager.provision(
                repoRoot: repo.path,
                slug: "cap-fail-worktree",
                branchName: "cap-fail-worktree",
                filesToCopy: WorkspaceFilesToCopySettings(maxBytesPerFile: 1, maxTotalBytes: 1)
            )
            XCTFail("Expected oversized ignored file to fail closed")
        } catch {
            let path = WorktreeManager.worktreePath(
                repoRoot: repo.path,
                slug: "cap-fail-worktree",
                storageRoot: workspaceStorageRoot.path
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func test_worktreeProvisionUsesGitCommonDirProjectForConductorHostedRepo() async throws {
        let repo = try makeGitRepo(name: "Clawdmeter")
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try write(".env*\n", to: repo.appendingPathComponent(".gitignore"))
        try git(["add", "tracked.txt", ".gitignore"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)

        let conductorWorktree = tmpDir
            .appendingPathComponent("conductor/workspaces/Clawdmeter/tacoma", isDirectory: true)
        try FileManager.default.createDirectory(
            at: conductorWorktree.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try git(["worktree", "add", "-b", "source-branch", conductorWorktree.path], cwd: repo)

        let manager = WorktreeManager(workspaceStorageRoot: workspaceStorageRoot.path)
        let provisioned = try await manager.provision(
            repoRoot: conductorWorktree.path,
            slug: "riyadh",
            branchName: "riyadh",
            filesToCopy: WorkspaceFilesToCopySettings(enabled: false)
        )

        XCTAssertEqual(provisioned.metadata.projectSlug, "Clawdmeter")
        XCTAssertEqual(provisioned.metadata.workspaceSlug, "riyadh")
        XCTAssertTrue(provisioned.path.hasPrefix(workspaceStorageRoot.appendingPathComponent("Clawdmeter").path + "/"))
        XCTAssertFalse(provisioned.path.hasPrefix(NSHomeDirectory() + "/conductor/workspaces/"))
        _ = try await manager.cleanupProvisionedWorktree(
            repoRoot: conductorWorktree.path,
            worktreePath: provisioned.path,
            expectedMarkerId: provisioned.metadata.ownershipMarkerId
        )
    }

    func test_worktreeProvisionCreatesBranchAliasWhenBranchDiffersFromCity() async throws {
        let repo = try makeGitRepo(name: "alias-repo")
        try write("tracked\n", to: repo.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"], cwd: repo)
        try git(["commit", "-m", "initial"], cwd: repo)

        let manager = WorktreeManager(workspaceStorageRoot: workspaceStorageRoot.path)
        let provisioned = try await manager.provision(
            repoRoot: repo.path,
            slug: "oslo",
            branchName: "feature/test",
            filesToCopy: WorkspaceFilesToCopySettings(enabled: false)
        )

        let aliasPath = try XCTUnwrap(provisioned.metadata.branchAliasPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aliasPath))
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: aliasPath)
        XCTAssertEqual(target, provisioned.path)
        XCTAssertTrue(aliasPath.hasSuffix("/feature-test"))
        _ = try await manager.cleanupProvisionedWorktree(
            repoRoot: repo.path,
            worktreePath: provisioned.path,
            expectedMarkerId: provisioned.metadata.ownershipMarkerId
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasPath))
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

    private func makeGitRepo(name: String) throws -> URL {
        let repo = tmpDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init"], cwd: repo)
        try git(["config", "user.email", "tests@example.com"], cwd: repo)
        try git(["config", "user.name", "Clawdmeter Tests"], cwd: repo)
        return repo
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func git(_ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = cwd
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "WorkspaceStoreTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(out)\(err)"]
            )
        }
    }
}
