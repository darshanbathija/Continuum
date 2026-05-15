import XCTest
@testable import ClawdmeterShared

/// Round-trip Codable for every AgentControl DTO. The iOS client and the
/// Mac daemon both serialize through these structs; any field-order or
/// case-spelling drift between encoder/decoder shows up here.
final class AgentControlProtocolTests: XCTestCase {

    func testAgentRepoRoundTrip() throws {
        let repo = AgentRepo(
            key: "/Users/d/code/Defx V3",
            displayName: "Defx V3",
            hasActiveSessions: true
        )
        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(AgentRepo.self, from: data)
        XCTAssertEqual(repo, decoded)
    }

    func testAgentSessionRoundTrip() throws {
        let session = AgentSession(
            id: UUID(),
            repoKey: "/Users/d/code/Clawdmeter",
            repoDisplayName: "Clawdmeter",
            agent: .claude,
            model: "sonnet",
            goal: "fix auth bug",
            worktreePath: "/Users/d/code/Clawdmeter/.claude/worktrees/fix-auth-bug-abc123",
            tmuxWindowId: "@3",
            tmuxPaneId: "%5",
            status: .planning,
            planText: "Will update auth.swift and tests.swift to handle expired sessions.",
            createdAt: Date(timeIntervalSince1970: 1747000000),
            lastEventAt: Date(timeIntervalSince1970: 1747000123),
            lastEventSeq: 42
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(session, decoded)
    }

    func testNewSessionRequestRoundTrip() throws {
        let req = NewSessionRequest(
            repoKey: "/Users/d/code/Clawdmeter",
            agent: .codex,
            model: nil,
            planMode: false,
            goal: "ship the refactor",
            useWorktree: true,
            baseBranch: "main"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(NewSessionRequest.self, from: data)
        XCTAssertEqual(decoded.repoKey, req.repoKey)
        XCTAssertEqual(decoded.agent, .codex)
        XCTAssertEqual(decoded.useWorktree, true)
        XCTAssertEqual(decoded.baseBranch, "main")
    }

    func testPairingChallengeRoundTrip() throws {
        let challenge = PairingChallenge(
            host: "darshans-macbook-pro.tail87a721.ts.net",
            port: 21731,
            wsPort: 21732,
            token: "abcd1234ABCD-_=="
        )
        let data = try JSONEncoder().encode(challenge)
        let decoded = try JSONDecoder().decode(PairingChallenge.self, from: data)
        XCTAssertEqual(challenge.host, decoded.host)
        XCTAssertEqual(challenge.port, decoded.port)
        XCTAssertEqual(challenge.wsPort, decoded.wsPort)
        XCTAssertEqual(challenge.token, decoded.token)
    }

    func testAgentEventRoundTrip() throws {
        let event = AgentEvent(
            eventSeq: 1024,
            sessionId: UUID(),
            kind: .planReady,
            at: Date(timeIntervalSince1970: 1747000456),
            payload: #"{"planText":"do the thing"}"#
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        XCTAssertEqual(event, decoded)
        XCTAssertEqual(decoded.id, "\(event.sessionId.uuidString):1024")
    }

    func testNeedsAttentionResponseRoundTrip() throws {
        let now = Date()
        let events: [NotificationEvent] = [
            NotificationEvent(
                id: 1, sessionId: UUID(),
                kind: "plan-ready",
                title: "Plan ready",
                body: "fix auth bug — 3 files",
                at: now
            ),
            NotificationEvent(
                id: 2, sessionId: UUID(),
                kind: "session-done",
                title: "Session done",
                body: "ship the refactor",
                at: now
            ),
        ]
        let response = NeedsAttentionResponse(events: events, serverTime: now)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(NeedsAttentionResponse.self, from: data)
        XCTAssertEqual(decoded.events.count, 2)
        XCTAssertEqual(decoded.events[0].kind, "plan-ready")
        XCTAssertEqual(decoded.events[1].id, 2)
    }

    func testSnapshotFrameRoundTrip() throws {
        let session = AgentSession(
            id: UUID(),
            repoKey: "/Users/d/code/X",
            repoDisplayName: "X",
            agent: .claude,
            model: nil, goal: nil, worktreePath: nil,
            tmuxWindowId: nil, tmuxPaneId: nil,
            status: .running, planText: nil,
            createdAt: Date(), lastEventAt: Date(),
            lastEventSeq: 7
        )
        let snapshot = AgentEventSnapshot(sessions: [session], asOfSeq: 1024)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AgentEventSnapshot.self, from: data)
        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.asOfSeq, 1024)
    }

    func testTerminalResizeRoundTrip() throws {
        let resize = TerminalResize(cols: 120, rows: 40)
        let data = try JSONEncoder().encode(resize)
        let decoded = try JSONDecoder().decode(TerminalResize.self, from: data)
        XCTAssertEqual(decoded.cols, 120)
        XCTAssertEqual(decoded.rows, 40)
    }

    // MARK: - Status + Kind enums are wire-stable

    func testAgentKindWireValues() throws {
        // Wire values must NEVER change without protocol bump.
        XCTAssertEqual(AgentKind.claude.rawValue, "claude")
        XCTAssertEqual(AgentKind.codex.rawValue, "codex")
    }

    func testAgentSessionStatusWireValues() throws {
        XCTAssertEqual(AgentSessionStatus.planning.rawValue, "planning")
        XCTAssertEqual(AgentSessionStatus.running.rawValue, "running")
        XCTAssertEqual(AgentSessionStatus.paused.rawValue, "paused")
        XCTAssertEqual(AgentSessionStatus.done.rawValue, "done")
        XCTAssertEqual(AgentSessionStatus.degraded.rawValue, "degraded")
    }

    func testAgentEventKindWireValues() throws {
        XCTAssertEqual(AgentEventKind.sessionCreated.rawValue, "sessionCreated")
        XCTAssertEqual(AgentEventKind.planReady.rawValue, "planReady")
        XCTAssertEqual(AgentEventKind.doneDetected.rawValue, "doneDetected")
        XCTAssertEqual(AgentEventKind.tmuxServerLost.rawValue, "tmuxServerLost")
        XCTAssertEqual(AgentEventKind.snapshot.rawValue, "snapshot")
    }

    func testTerminalFrameTagWireValues() throws {
        XCTAssertEqual(TerminalFrameTag.output.rawValue, 0x01)
        XCTAssertEqual(TerminalFrameTag.resize.rawValue, 0x02)
        XCTAssertEqual(TerminalFrameTag.input.rawValue, 0x03)
        XCTAssertEqual(TerminalFrameTag.title.rawValue, 0x04)
    }
}
