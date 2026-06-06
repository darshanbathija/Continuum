import XCTest
import ClawdmeterShared
@testable import Clawdmeter

final class RepoIndexTests: XCTestCase {
    func test_refreshUsesWorkspaceSnapshotOnlyAndEmitsNoRecentSessions() async {
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

        let workspace = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: "/Users/dev/continuum-owned",
            repoDisplayName: "Continuum Owned",
            runtimeCwd: "/Users/dev/continuum-owned/.claude/worktrees/main",
            activeSessionIds: [UUID()]
        )
        let repoIndex = RepoIndex(workspaceSnapshotProvider: { [workspace] })

        let snapshot = await repoIndex.refresh()

        XCTAssertEqual(snapshot.map(\.key), ["/Users/dev/continuum-owned"])
        XCTAssertEqual(snapshot.first?.displayName, "Continuum Owned")
        XCTAssertEqual(snapshot.first?.recentSessions, [])
        XCTAssertEqual(snapshot.first?.hasActiveSessions, false)
        XCTAssertEqual(snapshot.first?.liveSessionCount, 0)
    }
}
