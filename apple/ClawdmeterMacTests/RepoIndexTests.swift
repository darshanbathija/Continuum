import XCTest
import ClawdmeterShared
@testable import Clawdmeter

final class RepoIndexTests: XCTestCase {
    func test_refreshUsesWorkspaceSnapshotOnlyAndEmitsNoRecentSessions() async throws {
        let defaults = UserDefaults.standard
        let originalRoots = defaults.stringArray(forKey: RepoIndex.scanRootsKey)
        defaults.set(["/tmp/continuum-external-scan-root"], forKey: RepoIndex.scanRootsKey)
        defer {
            if let originalRoots {
                defaults.set(originalRoots, forKey: RepoIndex.scanRootsKey)
            } else {
                defaults.removeObject(forKey: RepoIndex.scanRootsKey)
            }
        }

        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-owned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let workspace = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: repoRoot.path,
            repoDisplayName: "Continuum Owned",
            runtimeCwd: repoRoot.appendingPathComponent(".claude/worktrees/main").path,
            activeSessionIds: [UUID()]
        )
        let repoIndex = RepoIndex(workspaceSnapshotProvider: { [workspace] })

        let snapshot = await repoIndex.refresh()

        XCTAssertEqual(snapshot.map(\.key), [repoRoot.path])
        XCTAssertEqual(snapshot.first?.displayName, "Continuum Owned")
        XCTAssertEqual(snapshot.first?.recentSessions, [])
        XCTAssertEqual(snapshot.first?.hasActiveSessions, false)
        XCTAssertEqual(snapshot.first?.liveSessionCount, 0)
    }
}
