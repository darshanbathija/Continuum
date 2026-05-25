#if canImport(SwiftUI)
import XCTest
@testable import ClawdmeterShared

final class TahoeCodeProjectListTests: XCTestCase {
    func test_collapsesDuplicateVisibleRepoNamesAndPreservesRows() {
        let firstSessionId = UUID()
        let secondSessionId = UUID()
        let first = TahoeCodeRepo(
            key: "/Users/dev/Downloads/CC Watch/Clawdmeter",
            name: "Clawdmeter",
            tint: OKLCH(l: 0.72, c: 0.16, h: 120),
            liveSessionCount: 4,
            sessions: [
                TahoeCodeSession(
                    id: firstSessionId,
                    title: "Main checkout",
                    agent: .claude,
                    model: "Claude",
                    status: .running,
                    mode: "local",
                    subtitle: "running"
                )
            ],
            recents: [
                TahoeCodeRecent(id: "jsonl-a", title: "First", provider: .claude, live: true, ago: "now")
            ]
        )
        let duplicate = TahoeCodeRepo(
            key: "/Users/dev/conductor/workspaces/Clawdmeter/memphis",
            name: "clawdmeter",
            tint: OKLCH(l: 0.72, c: 0.16, h: 220),
            liveSessionCount: 3,
            sessions: [
                TahoeCodeSession(
                    id: secondSessionId,
                    title: "Conductor branch",
                    agent: .codex,
                    model: "Codex",
                    status: .planning,
                    mode: "worktree",
                    subtitle: "planning"
                )
            ],
            recents: [
                TahoeCodeRecent(id: "jsonl-a", title: "Duplicate", provider: .claude, live: false, ago: "1m"),
                TahoeCodeRecent(id: "jsonl-b", title: "Second", provider: .codex, live: false, ago: "2m")
            ]
        )

        let collapsed = TahoeCodeProjectList.collapseDuplicateVisibleNames([first, duplicate])

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].key, first.key)
        XCTAssertEqual(collapsed[0].name, first.name)
        XCTAssertEqual(collapsed[0].liveSessionCount, 7)
        XCTAssertEqual(collapsed[0].sessions.map(\.id), [firstSessionId, secondSessionId])
        XCTAssertEqual(collapsed[0].recents.map(\.id), ["jsonl-a", "jsonl-b"])
    }

    func test_preservesDistinctNamesInOriginalOrder() {
        let a = TahoeCodeRepo(key: "/tmp/a", name: "Alpha", tint: OKLCH(l: 0.72, c: 0.16, h: 10))
        let b = TahoeCodeRepo(key: "/tmp/b", name: "Beta", tint: OKLCH(l: 0.72, c: 0.16, h: 20))

        let collapsed = TahoeCodeProjectList.collapseDuplicateVisibleNames([a, b])

        XCTAssertEqual(collapsed.map(\.key), [a.key, b.key])
        XCTAssertEqual(collapsed.map(\.name), [a.name, b.name])
    }
}
#endif
