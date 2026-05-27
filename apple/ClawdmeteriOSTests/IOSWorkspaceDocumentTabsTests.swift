import XCTest
import ClawdmeterShared
@testable import Clawdmeter

final class IOSWorkspaceDocumentTabsTests: XCTestCase {
    func test_openSelectDedupeAndCloseMarkdownDocumentTab() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-ios-doc-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let session = makeSession(repoKey: root.path, runtimeCwd: worktree.path)

        var tabs: [IOSWorkspaceDocumentTab] = []
        var selectedId: UUID?

        let opened = try XCTUnwrap(IOSWorkspaceDocumentTabs.open(
            tabs: &tabs,
            selectedId: &selectedId,
            session: session,
            path: "docs/report.md",
            createdAt: Date(timeIntervalSince1970: 10)
        ))

        XCTAssertEqual(tabs, [opened])
        XCTAssertEqual(selectedId, opened.id)
        XCTAssertEqual(opened.path, worktree.appendingPathComponent("docs/report.md").path)
        XCTAssertEqual(
            IOSWorkspaceDocumentTabs.standardizedPath("~/.gstack/projects/report.md", relativeTo: worktree.path),
            "~/.gstack/projects/report.md"
        )

        let duplicate = try XCTUnwrap(IOSWorkspaceDocumentTabs.open(
            tabs: &tabs,
            selectedId: &selectedId,
            session: session,
            path: opened.path,
            createdAt: Date(timeIntervalSince1970: 20)
        ))

        XCTAssertEqual(duplicate.id, opened.id)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(IOSWorkspaceDocumentTabs.tabs(in: try XCTUnwrap(WorkspaceKey.of(session)), all: tabs), [opened])

        IOSWorkspaceDocumentTabs.close(tabs: &tabs, selectedId: &selectedId, tab: opened)
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertNil(selectedId)
    }

    func test_markdownLoaderPrepareParsesDownloadedTextAndRejectsBinary() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-ios-md-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markdown = root.appendingPathComponent("report.md")
        try Data("# Report\n\n- Shipped\n".utf8).write(to: markdown)
        let prepared = try IOSMarkdownDocumentLoader.prepare(localURL: markdown, remotePath: "/repo/report.md")

        XCTAssertEqual(prepared.result.document.blocks.first, .heading(level: 1, text: "Report"))
        XCTAssertEqual(prepared.key.remotePath, "/repo/report.md")

        let binary = root.appendingPathComponent("binary.md")
        try Data([0, 1, 2, 3]).write(to: binary)
        XCTAssertThrowsError(try IOSMarkdownDocumentLoader.prepare(localURL: binary, remotePath: "/repo/binary.md")) { error in
            XCTAssertEqual(error as? IOSMarkdownDocumentLoadError, .binary)
        }
    }

    private func makeSession(repoKey: String, runtimeCwd: String) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: repoKey,
            repoDisplayName: "Repo",
            agent: .codex,
            model: nil,
            goal: "Write docs",
            worktreePath: runtimeCwd,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            lastEventAt: Date(timeIntervalSince1970: 2),
            lastEventSeq: 1,
            mode: .worktree,
            runtimeCwd: runtimeCwd
        )
    }
}
