import XCTest
@testable import ClawdmeterShared

final class ContextDigestTests: XCTestCase {

    func test_rendersWireSnapshotConversationPlanSourcesAndArtifacts() {
        let session = makeSession(planText: "1. Ship tabs")
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let snapshot = WireChatSnapshot(
            sessionId: session.id,
            items: [
                .message(ChatMessage(id: "u1", kind: .userText, title: "You", body: "Build tabs", at: now)),
                .toolRun(id: "tool1", pairs: [
                    ToolPair(
                        id: "tool1",
                        call: ChatMessage(id: "c1", kind: .toolCall, title: "Read", body: "Read file", at: now),
                        result: ChatMessage(id: "r1", kind: .toolResult, title: "Read", body: "File contents", at: now)
                    )
                ])
            ],
            planSteps: [PlanStep(id: "p1", text: "Wire tab strip", isComplete: false)],
            sourceEntries: [SourceEntry(id: "f:a", kind: .file, label: "A.swift", payload: "/repo/A.swift", count: 2)],
            artifactEntries: [ArtifactEntry(path: "/repo/report.md")],
            totalInputTokens: 10,
            totalOutputTokens: 20,
            lastEventAt: now,
            updateCounter: 4
        )

        let digest = ContextDigest.render(snapshot: snapshot, sourceSession: session)

        XCTAssertTrue(digest.contains("# Inherited context - repo"))
        XCTAssertTrue(digest.contains("### You"))
        XCTAssertTrue(digest.contains("Build tabs"))
        XCTAssertTrue(digest.contains("### Tool result: Read"))
        XCTAssertTrue(digest.contains("- [ ] Wire tab strip"))
        XCTAssertTrue(digest.contains("A.swift"))
        XCTAssertTrue(digest.contains("report.md"))
    }

    func test_toolResultsClampIndependently() {
        let session = makeSession()
        let now = Date(timeIntervalSince1970: 1)
        let snapshot = WireChatSnapshot(
            sessionId: session.id,
            items: [
                .message(ChatMessage(
                    id: "r1",
                    kind: .toolResult,
                    title: "Bash",
                    body: String(repeating: "x", count: 100),
                    at: now
                ))
            ],
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 0,
            totalOutputTokens: 0,
            lastEventAt: now,
            updateCounter: 1
        )

        let digest = ContextDigest.render(
            snapshot: snapshot,
            sourceSession: session,
            options: .init(toolResultByteLimit: 12, maxDigestBytes: 10_000)
        )

        XCTAssertTrue(digest.contains("... 88 bytes elided ..."))
    }

    func test_totalDigestCapKeepsOutputUnderLimit() {
        let session = makeSession()
        let now = Date(timeIntervalSince1970: 1)
        let snapshot = WireChatSnapshot(
            sessionId: session.id,
            items: [
                .message(ChatMessage(
                    id: "a1",
                    kind: .assistantText,
                    title: "Claude",
                    body: String(repeating: "abcdef", count: 1_000),
                    at: now
                ))
            ],
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 0,
            totalOutputTokens: 0,
            lastEventAt: now,
            updateCounter: 1
        )

        let digest = ContextDigest.render(
            snapshot: snapshot,
            sourceSession: session,
            options: .init(toolResultByteLimit: 2_048, maxDigestBytes: 1_024)
        )

        XCTAssertLessThanOrEqual(digest.utf8.count, 1_024)
        XCTAssertTrue(digest.contains("earlier inherited context elided"))
    }

    private func makeSession(planText: String? = nil) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: "/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "sonnet",
            goal: nil,
            worktreePath: "/repo/.claude/worktrees/kolkata",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: planText,
            createdAt: Date(timeIntervalSince1970: 1),
            lastEventAt: Date(timeIntervalSince1970: 1),
            lastEventSeq: 1,
            mode: .worktree,
            runtimeCwd: "/repo/.claude/worktrees/kolkata"
        )
    }
}
