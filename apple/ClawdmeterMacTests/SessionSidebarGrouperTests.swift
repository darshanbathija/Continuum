import XCTest
import ClawdmeterShared
@testable import Clawdmeter

final class SessionSidebarGrouperTests: XCTestCase {
    func test_statusGroupingUsesConductorFourBucketModel() {
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        let prReview = UUID()
        let sessions = [
            session(status: .running, lastEventAt: now.addingTimeInterval(-5), goal: "running"),
            session(status: .paused, lastEventAt: now.addingTimeInterval(-10), goal: "recent"),
            session(status: .planning, lastEventAt: now.addingTimeInterval(-300), goal: "plan", planText: "Ship this"),
            session(id: prReview, status: .done, lastEventAt: now.addingTimeInterval(-500), goal: "pr"),
            session(status: .done, lastEventAt: now.addingTimeInterval(-900), goal: "done"),
            session(status: .done, lastEventAt: now.addingTimeInterval(-1200), goal: "archived", archivedAt: now),
        ]

        let groups = SessionSidebarGrouper.group(
            sessions: sessions,
            repos: [],
            grouping: .status,
            sorting: .recency,
            statusFilter: .all,
            reviewSessionIds: [prReview],
            now: now
        )

        XCTAssertEqual(groups.map(\.title), ["Active", "In Review", "Done", "Archived"])
        XCTAssertEqual(groups.map { $0.sessions.count }, [2, 2, 1, 1])
        XCTAssertEqual(groups[1].sessions.map(\.goal), ["plan", "pr"])
    }

    func test_statusFilterNarrowsWithinFourBucketView() {
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        let review = session(status: .planning, lastEventAt: now.addingTimeInterval(-60), planText: "Review")
        let done = session(status: .done, lastEventAt: now.addingTimeInterval(-90))

        let groups = SessionSidebarGrouper.group(
            sessions: [review, done],
            repos: [],
            grouping: .status,
            sorting: .recency,
            statusFilter: .inReview,
            now: now
        )

        XCTAssertEqual(groups.map(\.title), ["Active", "In Review", "Done", "Archived"])
        XCTAssertEqual(groups.map { $0.sessions.count }, [0, 1, 0, 0])
        XCTAssertEqual(groups[1].sessions.first?.id, review.id)
    }

    func test_jsonlTailFromEndIgnoresExistingRows() async throws {
        let url = try makeTempJSONL(lines: [
            Self.jsonLine(index: 0),
            Self.jsonLine(index: 1),
        ])
        let stream = AsyncStream<String> { continuation in
            let tail = JSONLTail(fileURL: url, initialReadMode: .fromEnd) { json in
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    continuation.yield(content)
                }
            }
            tail.start()
            continuation.onTermination = { _ in tail.stop() }
        }
        var iterator = stream.makeAsyncIterator()
        try await Task.sleep(nanoseconds: 50_000_000)
        try appendLine(Self.jsonLine(index: 2), to: url)
        let emitted = await iterator.next()
        XCTAssertEqual(emitted, "message 2")
        _ = stream
    }

    @MainActor
    func test_sessionChatStoreStartsWithRecentTailAndCapsMessages() async throws {
        let lines = (0..<250).map(Self.jsonLine(index:))
        let url = try makeTempJSONL(lines: lines)
        let store = SessionChatStore(sessionId: UUID(), sessionFileURL: url)
        store.start()
        defer { store.stop() }

        for _ in 0..<80 where store.snapshot.messages.count < 200 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(store.snapshot.messages.count, 200)
        XCTAssertEqual(store.snapshot.messages.first?.body, "message 50")
        XCTAssertEqual(store.snapshot.messages.last?.body, "message 249")
        XCTAssertTrue(store.hasOlderHistory)

        try appendLine(Self.jsonLine(index: 250), to: url)
        for _ in 0..<80 where store.snapshot.messages.last?.body != "message 250" {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(store.snapshot.messages.count, 200)
        XCTAssertEqual(store.snapshot.messages.first?.body, "message 51")
        XCTAssertEqual(store.snapshot.messages.last?.body, "message 250")
        XCTAssertTrue(store.hasOlderHistory)

        await store.loadOlderHistory()
        for _ in 0..<80 where store.snapshot.messages.count < 251 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(store.snapshot.messages.count, 251)
        XCTAssertEqual(store.snapshot.messages.first?.body, "message 0")
        XCTAssertEqual(store.snapshot.messages.last?.body, "message 250")
        XCTAssertFalse(store.hasOlderHistory)
    }

    func test_transcriptLoaderExplicitPaginationSearchesPastRecentFiveThousandMessages() throws {
        let lines = (0..<5_600).map(Self.jsonLine(index:))
        let url = try makeTempJSONL(lines: lines)

        let page = TranscriptLoader.loadWindowBefore(
            from: url,
            beforeId: "line-605:user-text",
            limit: 3
        )

        XCTAssertTrue(page.cursorFound)
        XCTAssertEqual(page.messages.map(\.body), ["message 602", "message 603", "message 604"])
        XCTAssertTrue(page.truncated)

        let olderThanFiveThousand = TranscriptLoader.loadWindowBefore(
            from: url,
            beforeId: "line-5:user-text",
            limit: 3
        )
        XCTAssertTrue(olderThanFiveThousand.cursorFound)
        XCTAssertEqual(olderThanFiveThousand.messages.map(\.body), ["message 2", "message 3", "message 4"])
        XCTAssertTrue(olderThanFiveThousand.truncated)

        let nearHead = TranscriptLoader.loadWindowBefore(
            from: url,
            beforeId: "line-2:user-text",
            limit: 3
        )
        XCTAssertTrue(nearHead.cursorFound)
        XCTAssertEqual(nearHead.messages.map(\.body), ["message 0", "message 1"])
        XCTAssertFalse(nearHead.truncated)
    }

    private func session(
        id: UUID = UUID(),
        status: AgentSessionStatus,
        lastEventAt: Date,
        goal: String? = nil,
        planText: String? = nil,
        archivedAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: "/tmp/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: goal,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: status,
            planText: planText,
            createdAt: lastEventAt.addingTimeInterval(-60),
            lastEventAt: lastEventAt,
            lastEventSeq: 1,
            archivedAt: archivedAt
        )
    }

    private static func jsonLine(index: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        return #"{"type":"user","uuid":"line-\#(index)","timestamp":"\#(timestamp)","message":{"content":"message \#(index)"}}"#
    }

    private func makeTempJSONL(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-chat-tail-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return url
    }

    private func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
