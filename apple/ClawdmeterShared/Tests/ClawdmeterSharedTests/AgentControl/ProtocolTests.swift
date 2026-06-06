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

    func testAgentRepoRecentSessionsRoundTrip() throws {
        let recent = [
            RecentSession(
                path: "/Users/d/.claude/projects/foo/abc.jsonl",
                lastModified: Date(timeIntervalSince1970: 1747000000),
                provider: .claude,
                firstPrompt: "fix the auth bug"
            ),
            RecentSession(
                path: "/Users/d/.codex/sessions/2026/05/16/def.jsonl",
                lastModified: Date(timeIntervalSince1970: 1747100000),
                provider: .codex,
                firstPrompt: nil
            ),
        ]
        let repo = AgentRepo(
            key: "/x", displayName: "x", hasActiveSessions: false,
            liveSessionCount: 1, recentSessions: recent
        )
        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(AgentRepo.self, from: data)
        XCTAssertEqual(decoded.recentSessions.count, 2)
        XCTAssertEqual(decoded.recentSessions[0].provider, .claude)
        XCTAssertEqual(decoded.recentSessions[1].provider, .codex)
        XCTAssertEqual(decoded, repo)
    }

    /// Pre-recent-sessions AgentRepo JSON has no `recentSessions` key.
    /// Decoder must default to empty array.
    func testAgentRepoBackwardCompatNoRecent() throws {
        let legacyJSON = """
        {
            "key": "/x",
            "displayName": "x",
            "hasActiveSessions": false,
            "liveSessionCount": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AgentRepo.self, from: legacyJSON)
        XCTAssertEqual(decoded.recentSessions, [])
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

    func testAgentEventUnknownKindDecodesLeniently() throws {
        let json = """
        {
          "eventSeq": 7,
          "sessionId": "\(UUID().uuidString)",
          "kind": "newDaemonOnlyKind",
          "at": "2026-06-06T00:00:00Z",
          "payload": "{}"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentEvent.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .unknown)
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
        XCTAssertEqual(AgentEventKind.snapshot.rawValue, "snapshot")
        XCTAssertEqual(AgentEventKind.unknown.rawValue, "unknown")
    }

    func testTerminalFrameTagWireValues() throws {
        XCTAssertEqual(TerminalFrameTag.output.rawValue, 0x01)
        XCTAssertEqual(TerminalFrameTag.resize.rawValue, 0x02)
        XCTAssertEqual(TerminalFrameTag.input.rawValue, 0x03)
        XCTAssertEqual(TerminalFrameTag.title.rawValue, 0x04)
    }

    // MARK: - SessionMode (G2) + AgentSession backward-compat

    func testSessionModeWireValues() throws {
        // Wire-stable: external clients depend on these strings.
        XCTAssertEqual(SessionMode.local.rawValue, "local")
        XCTAssertEqual(SessionMode.worktree.rawValue, "worktree")
        XCTAssertEqual(SessionMode.cloud.rawValue, "cloud")
    }

    func testAgentSessionWithModeRoundTrip() throws {
        let session = AgentSession(
            id: UUID(),
            repoKey: "/x", repoDisplayName: "x",
            agent: .claude, model: nil, goal: nil,
            worktreePath: "/x/.claude/worktrees/foo",
            tmuxWindowId: nil, tmuxPaneId: nil,
            status: .running, planText: nil,
            createdAt: Date(), lastEventAt: Date(), lastEventSeq: 1,
            mode: .worktree,
            archivedAt: Date(timeIntervalSince1970: 1747100000)
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.mode, .worktree)
        XCTAssertNotNil(decoded.archivedAt)
        XCTAssertEqual(decoded, session)
    }

    /// Pre-G0 sessions.json has no `mode` or `archivedAt` keys. The decoder
    /// must infer `mode` from `worktreePath` and default `archivedAt` to nil.
    func testAgentSessionBackwardCompatDecode() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "repoKey": "/Users/d/code/Clawdmeter",
            "repoDisplayName": "Clawdmeter",
            "agent": "claude",
            "status": "running",
            "createdAt": "2026-05-16T12:00:00Z",
            "lastEventAt": "2026-05-16T12:01:00Z",
            "lastEventSeq": 1,
            "worktreePath": "/Users/d/code/Clawdmeter/.claude/worktrees/foo"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: legacyJSON)
        XCTAssertEqual(session.mode, .worktree, "worktreePath != nil → infer .worktree")
        XCTAssertNil(session.archivedAt)
    }

    // G2: terminalPanes + scheduledFollowUps + parentSessionId round-trip
    func testAgentSessionG2FieldsRoundTrip() throws {
        let parentId = UUID()
        let session = AgentSession(
            id: UUID(),
            repoKey: "/x", repoDisplayName: "x",
            agent: .claude, model: nil, goal: nil,
            worktreePath: nil,
            tmuxWindowId: "@4", tmuxPaneId: "%9",
            status: .running, planText: nil,
            createdAt: Date(), lastEventAt: Date(), lastEventSeq: 1,
            mode: .local, archivedAt: nil,
            terminalPanes: [
                TerminalPaneRef(paneId: "%10", title: "scratch", isPrimary: false),
                TerminalPaneRef(paneId: "%11", title: "logs", isPrimary: false),
            ],
            scheduledFollowUps: [
                ScheduledFollowUp(
                    fireAt: Date(timeIntervalSince1970: 1747200000),
                    prompt: "check the tests again"
                )
            ],
            parentSessionId: parentId
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.terminalPanes.count, 2)
        XCTAssertEqual(decoded.terminalPanes[0].paneId, "%10")
        XCTAssertEqual(decoded.scheduledFollowUps.count, 1)
        XCTAssertEqual(decoded.scheduledFollowUps[0].prompt, "check the tests again")
        XCTAssertEqual(decoded.parentSessionId, parentId)
    }

    /// v1 sessions.json (pre-G2) had no terminalPanes/scheduledFollowUps/
    /// parentSessionId fields. Decoder must default them all.
    func testAgentSessionBackwardCompatDecodeV1NoG2Fields() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "repoKey": "/x", "repoDisplayName": "x",
            "agent": "claude", "status": "running",
            "createdAt": "2026-05-16T12:00:00Z",
            "lastEventAt": "2026-05-16T12:01:00Z",
            "lastEventSeq": 1,
            "mode": "local"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: legacyJSON)
        XCTAssertEqual(session.terminalPanes, [])
        XCTAssertEqual(session.scheduledFollowUps, [])
        XCTAssertNil(session.parentSessionId)
    }

    func testAgentSessionBackwardCompatDecodeLocal() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "repoKey": "/Users/d/code/Clawdmeter",
            "repoDisplayName": "Clawdmeter",
            "agent": "claude",
            "status": "running",
            "createdAt": "2026-05-16T12:00:00Z",
            "lastEventAt": "2026-05-16T12:01:00Z",
            "lastEventSeq": 1
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: legacyJSON)
        XCTAssertEqual(session.mode, .local, "no worktreePath → infer .local")
    }
}
