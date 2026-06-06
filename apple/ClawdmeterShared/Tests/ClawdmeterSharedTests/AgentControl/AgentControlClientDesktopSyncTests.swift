import XCTest
@testable import ClawdmeterShared

final class AgentControlClientDesktopSyncTests: XCTestCase {

    private final class SentBox {
        var frames: [RelayMuxFrame] = []
    }

    @MainActor
    func testSnapshotEventReplacesSessionsAndAdvancesCursor() async throws {
        let client = AgentControlClient()
        let session = makeSession(id: UUID(), status: .running, seq: 12)
        let snapshot = AgentEventSnapshot(sessions: [session], asOfSeq: 42)
        let payload = try encodedJSONString(snapshot)
        let event = AgentEvent(
            eventSeq: 40,
            sessionId: UUID(),
            kind: .snapshot,
            at: Date(timeIntervalSince1970: 1_800_000_000),
            payload: payload
        )

        await client.applyDesktopSyncEvent(event, scheduleAuthoritativeRefresh: false)

        XCTAssertEqual(client.sessions, [session])
        XCTAssertEqual(client.desktopEventSyncLastSeq, 42)
        XCTAssertEqual(client.desktopEventSyncLastEventAt, event.at)
    }

    @MainActor
    func testSessionDeletedEventRemovesLocalSessionWithoutRoundTrip() async throws {
        let client = AgentControlClient()
        let keep = makeSession(id: UUID(), status: .running, seq: 1)
        let remove = makeSession(id: UUID(), status: .planning, seq: 2)
        let snapshot = AgentEventSnapshot(sessions: [keep, remove], asOfSeq: 10)
        await client.applyDesktopSyncEvent(
            AgentEvent(
                eventSeq: 10,
                sessionId: UUID(),
                kind: .snapshot,
                at: Date(timeIntervalSince1970: 1_800_000_010),
                payload: try encodedJSONString(snapshot)
            ),
            scheduleAuthoritativeRefresh: false
        )

        await client.applyDesktopSyncEvent(
            AgentEvent(
                eventSeq: 11,
                sessionId: remove.id,
                kind: .sessionDeleted,
                at: Date(timeIntervalSince1970: 1_800_000_011),
                payload: "{}"
            ),
            scheduleAuthoritativeRefresh: false
        )

        XCTAssertEqual(client.sessions, [keep])
        XCTAssertEqual(client.desktopEventSyncLastSeq, 11)
    }

    @MainActor
    func testIncrementalEventTracksCursorWithoutMutatingFromPartialPayload() async {
        let client = AgentControlClient()
        let session = makeSession(id: UUID(), status: .running, seq: 1)
        await client.applyDesktopSyncEvent(
            AgentEvent(
                eventSeq: 7,
                sessionId: UUID(),
                kind: .snapshot,
                at: Date(timeIntervalSince1970: 1_800_000_020),
                payload: (try? encodedJSONString(AgentEventSnapshot(sessions: [session], asOfSeq: 7))) ?? "{}"
            ),
            scheduleAuthoritativeRefresh: false
        )

        await client.applyDesktopSyncEvent(
            AgentEvent(
                eventSeq: 8,
                sessionId: session.id,
                kind: .statusChanged,
                at: Date(timeIntervalSince1970: 1_800_000_021),
                payload: #"{"status":"done"}"#
            ),
            scheduleAuthoritativeRefresh: false
        )

        XCTAssertEqual(client.sessions, [session])
        XCTAssertEqual(client.desktopEventSyncLastSeq, 8)
    }

    @MainActor
    func testRelayEventSyncUnsubscribesStaleRelayBeforeDirectFallback() async {
        let oldThreshold = AgentControlClient.desktopEventRelayStalenessThreshold
        AgentControlClient.desktopEventRelayStalenessThreshold = 0.05
        defer { AgentControlClient.desktopEventRelayStalenessThreshold = oldThreshold }

        let sent = SentBox()
        let mux = RelayMuxClient(send: { sent.frames.append($0) }, makeOpId: { "events-op" })
        let client = AgentControlClient()
        client.relayMux = mux

        client.startDesktopEventSync()

        let subscribed = await waitUntil { sent.frames.contains { $0.kind == .subscribe } }
        XCTAssertTrue(subscribed, "desktop sync must subscribe over relay first")

        let unsubscribed = await waitUntil { sent.frames.contains { $0.kind == .unsubscribe && $0.opId == "events-op" } }
        XCTAssertTrue(unsubscribed, "a stale relay events stream must unsubscribe before fallback")
        client.stopDesktopEventSync()
    }

    private func makeSession(id: UUID, status: AgentSessionStatus, seq: UInt64) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: "/Users/d/code/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: .codex,
            model: "gpt-5",
            goal: "Keep iOS synced with desktop",
            worktreePath: "/Users/d/code/Clawdmeter/.codex/worktrees/sync",
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            status: status,
            planText: status == .planning ? "Plan ready" : nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastEventAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(seq)),
            lastEventSeq: seq,
            mode: .worktree,
            runtimeCwd: "/Users/d/code/Clawdmeter/.codex/worktrees/sync",
            chatCwd: "/Users/d/code/Clawdmeter",
            effort: .high
        )
    }

    private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }
}
