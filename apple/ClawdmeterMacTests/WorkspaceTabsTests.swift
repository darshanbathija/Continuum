import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class WorkspaceTabsTests: XCTestCase {

    func test_openDraftWorkspaceTabDoesNotPersistSessionOrChangeWorktree() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTabsTests")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "sonnet",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            planMode: false,
            mode: .worktree
        )
        model.openSession(source)

        model.openDraftWorkspaceTab(
            from: source,
            defaults: ComposerStore.ChipDefaults(
                agent: .claude,
                modelId: "sonnet",
                effort: .max,
                mode: .worktree,
                planMode: false
            )
        )

        XCTAssertNil(model.openSessionId)
        XCTAssertEqual(model.registry.sessions.count, 1)
        XCTAssertEqual(model.draftWorkspaceTab?.workspaceKey, WorkspaceKey.of(source))
        XCTAssertEqual(model.draftWorkspaceTab?.workspaceKey.workspacePath, "/repo/.claude/worktrees/kolkata")
    }

    func test_registryPersistsInheritedContextSources() async throws {
        let (registry, directory) = try Self.makeIsolatedRegistry("WorkspaceTabsRegistry")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let registryURL = directory.appendingPathComponent("sessions.json")
        let sourceId = UUID()
        let session = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            planMode: false,
            mode: .worktree
        )

        try await registry.setInheritedContextSources(sessionId: session.id, sourceIds: [sourceId])

        let reloaded = AgentSessionRegistry(storeURL: registryURL)
        XCTAssertEqual(reloaded.session(id: session.id)?.inheritedContextSourceIds, [sourceId])
    }

    func test_existingWorkspaceRecordPathsPreserveWorktreeCwdForAgentapiProviders() {
        let paths = SessionsModel.existingWorkspaceRecordPaths(
            repoPath: "/repo",
            workspacePath: "/repo/.claude/worktrees/kolkata",
            mode: .worktree
        )

        XCTAssertEqual(paths.cwd, "/repo/.claude/worktrees/kolkata")
        XCTAssertEqual(paths.worktreePath, "/repo/.claude/worktrees/kolkata")
    }

    func test_existingWorkspaceRecordPathsKeepLocalSessionsOnCanonicalCwdWithoutWorktreePath() {
        let paths = SessionsModel.existingWorkspaceRecordPaths(
            repoPath: "/repo",
            workspacePath: "/repo",
            mode: .local
        )

        XCTAssertEqual(paths.cwd, "/repo")
        XCTAssertNil(paths.worktreePath)
    }

    func test_registryRuntimeCwdCanRepresentGeminiAndOpencodeSameWorkspaceSessions() async throws {
        let (registry, directory) = try Self.makeIsolatedRegistry("WorkspaceTabsRuntimeCwd")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let paths = SessionsModel.existingWorkspaceRecordPaths(
            repoPath: "/repo",
            workspacePath: "/repo/.claude/worktrees/kolkata",
            mode: .worktree
        )

        let gemini = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .gemini,
            model: nil,
            goal: nil,
            worktreePath: paths.worktreePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )
        let opencode = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .opencode,
            model: nil,
            goal: nil,
            worktreePath: paths.worktreePath,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree
        )

        XCTAssertEqual(gemini.runtimeCwd, paths.cwd)
        XCTAssertEqual(gemini.worktreePath, paths.worktreePath)
        XCTAssertEqual(gemini.mode, .worktree)
        XCTAssertFalse(gemini.ownsWorktree)
        XCTAssertEqual(opencode.runtimeCwd, paths.cwd)
        XCTAssertEqual(opencode.worktreePath, paths.worktreePath)
        XCTAssertEqual(opencode.mode, .worktree)
        XCTAssertFalse(opencode.ownsWorktree)
    }

    func test_openWorkspaceTerminalTabUsesExistingSessionWithoutCreatingWorktree() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalTabs")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "gpt",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            planMode: false,
            mode: .worktree
        )

        model.openWorkspaceTerminalTab(from: source)

        XCTAssertEqual(model.registry.sessions.count, 1)
        XCTAssertEqual(model.openSessionId, source.id)
        XCTAssertNil(model.draftWorkspaceTab)
        XCTAssertEqual(model.selectedWorkspaceTerminalTab?.sessionId, source.id)
        XCTAssertNil(model.selectedWorkspaceTerminalTab?.paneRefId)
        XCTAssertEqual(model.selectedWorkspaceTerminalTab?.workspaceKey, WorkspaceKey.of(source))
    }

    func test_openWorkspaceTerminalTabRejectsSessionsWithoutTmuxPane() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalNoPane")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .opencode,
            model: "opencode",
            goal: "source",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            planMode: false,
            mode: .worktree,
            ownsWorktree: false
        )

        model.openWorkspaceTerminalTab(from: source)

        XCTAssertFalse(model.canOpenWorkspaceTerminalTab(from: source))
        XCTAssertNil(model.selectedWorkspaceTerminalTab)
        XCTAssertEqual(model.workspaceTerminalTabs(in: WorkspaceKey.of(source)!).count, 0)
    }

    func test_workspaceTerminalTabsAreScopedAndIgnoreMissingPaneRefs() async throws {
        let (model, registry, directory) = try Self.makeIsolatedModel("WorkspaceTerminalScope")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: nil,
            goal: "first",
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            planMode: false,
            mode: .worktree
        )
        let second = try await registry.create(
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: "second",
            worktreePath: "/repo/.claude/worktrees/delhi",
            tmuxWindowId: "@2",
            tmuxPaneId: "%2",
            planMode: false,
            mode: .worktree
        )
        let pane = TerminalPaneRef(paneId: "%3", title: "Logs", isPrimary: false)
        try await registry.addTerminalPane(sessionId: first.id, pane: pane)

        model.openWorkspaceTerminalTab(from: first, paneRefId: pane.id, createdAt: Date(timeIntervalSince1970: 2))
        model.openWorkspaceTerminalTab(from: second, createdAt: Date(timeIntervalSince1970: 1))
        try await registry.removeTerminalPane(sessionId: first.id, paneRefId: pane.id)

        XCTAssertEqual(model.workspaceTerminalTabs(in: WorkspaceKey.of(first)!).count, 0)
        XCTAssertEqual(model.workspaceTerminalTabs(in: WorkspaceKey.of(second)!).map { $0.sessionId }, [second.id])
        XCTAssertEqual(model.selectedWorkspaceTerminalTab?.sessionId, second.id)
    }

    func test_inheritedAttachmentStagerCopiesBytesAndWritesManifest() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InheritedAttachmentStager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let worktree = temp.appendingPathComponent("worktree", isDirectory: true)
        let dest = temp.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let source = AgentSession(
            id: UUID(),
            repoKey: temp.path,
            repoDisplayName: "repo",
            agent: .codex,
            model: nil,
            goal: nil,
            worktreePath: worktree.path,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .worktree,
            runtimeCwd: worktree.path
        )
        let sourceDir = try XCTUnwrap(AttachmentStaging.stagingDir(for: source))
        let original = sourceDir.appendingPathComponent("design.md")
        try "hello".write(to: original, atomically: true, encoding: .utf8)
        try "# old digest".write(
            to: sourceDir.appendingPathComponent("inherited-\(UUID().uuidString).md"),
            atomically: true,
            encoding: .utf8
        )

        let staged = try InheritedAttachmentStager.stage(sourceSessions: [source], into: dest)

        let manifestURL = dest.appendingPathComponent(InheritedAttachmentStager.manifestFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(staged.contains(manifestURL))
        let copiedFiles = staged.filter { $0.lastPathComponent != InheritedAttachmentStager.manifestFilename }
        XCTAssertEqual(copiedFiles.count, 1)
        XCTAssertEqual(try String(contentsOf: copiedFiles[0], encoding: .utf8), "hello")
        let manifest = try JSONDecoder().decode(
            InheritedAttachmentStager.Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.entries.first?.originalName, "design.md")
        XCTAssertNil(manifest.entries.first?.error)
    }

    func test_inheritedAttachmentStagerDoesNotCopySiblingCodexAttachmentsFromSameWorktree() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InheritedAttachmentScope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let worktree = temp.appendingPathComponent("worktree", isDirectory: true)
        let dest = temp.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let selectedSource = makeCodexSession(repo: temp.path, worktree: worktree.path)
        let unselectedSibling = makeCodexSession(repo: temp.path, worktree: worktree.path)
        let selectedDir = try XCTUnwrap(AttachmentStaging.stagingDir(for: selectedSource))
        let siblingDir = try XCTUnwrap(AttachmentStaging.stagingDir(for: unselectedSibling))
        try "selected".write(to: selectedDir.appendingPathComponent("selected.txt"), atomically: true, encoding: .utf8)
        try "sibling".write(to: siblingDir.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)

        let staged = try InheritedAttachmentStager.stage(sourceSessions: [selectedSource], into: dest)

        let copiedPayloads = try staged
            .filter { $0.lastPathComponent != InheritedAttachmentStager.manifestFilename }
            .map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(copiedPayloads, ["selected"])
    }

    private func makeCodexSession(repo: String, worktree: String) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: repo,
            repoDisplayName: "repo",
            agent: .codex,
            model: nil,
            goal: nil,
            worktreePath: worktree,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .worktree,
            runtimeCwd: worktree,
            ownsWorktree: false
        )
    }

    private static func makeIsolatedRegistry(_ name: String) throws -> (AgentSessionRegistry, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registryURL = directory.appendingPathComponent("sessions.json")
        return (AgentSessionRegistry(storeURL: registryURL), directory)
    }

    private static func makeIsolatedModel(_ name: String) throws -> (SessionsModel, AgentSessionRegistry, URL) {
        let (registry, directory) = try makeIsolatedRegistry(name)
        let workspaceStore = WorkspaceStore(
            storeURL: directory.appendingPathComponent("workspaces.json"),
            sessionsURL: directory.appendingPathComponent("sessions.json")
        )
        let supervisor = TmuxSupervisor(
            tmux: TmuxControlClient(configuration: .init(tmuxBinary: "/usr/bin/false")),
            registry: registry
        )
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            supervisor: supervisor,
            workspaceStore: workspaceStore
        )
        return (model, registry, directory)
    }
}
