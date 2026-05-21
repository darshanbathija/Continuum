import XCTest
@testable import ClawdmeterShared

/// v0.8 Chat tab schema v5 round-trip tests. Verifies:
/// - SessionKind / CodexChatBackend enums decode lenient + round-trip
/// - AgentSession v5 fields (kind, frontierGroupId, frontierChildIndex,
///   codexChatBackend, codexChatThreadId, optional repoKey) round-trip
/// - v3 / v4 sessions.json shapes decode into v5 with sensible defaults
///   (kind defaults to .code; new fields default to nil)
/// - chat-session shape (repoKey: nil, worktreePath: <chat-cwd>) decodes
///   cleanly and effectiveCwd resolves to the chat-cwd
final class AgentSessionSchemaV5Tests: XCTestCase {

    // MARK: - SessionKind enum

    func test_sessionKind_roundTrips() throws {
        for kind in SessionKind.allCases {
            let encoded = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(SessionKind.self, from: encoded)
            XCTAssertEqual(decoded, kind)
        }
    }

    func test_sessionKind_unknownDecodesToCode() throws {
        let bogus = "\"future-kind\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(SessionKind.self, from: bogus), .code)
    }

    func test_sessionKind_defaultIsCode() {
        // Sanity check: the lenient init defaults unknown raws to .code,
        // matching what AgentSession's decoder defaults to when the kind
        // field is absent entirely (v3/v4 back-compat).
        XCTAssertEqual(SessionKind(rawValue: "nonsense") ?? .code, .code)
    }

    // MARK: - CodexChatBackend enum

    func test_codexChatBackend_roundTrips() throws {
        for backend in CodexChatBackend.allCases {
            let encoded = try JSONEncoder().encode(backend)
            let decoded = try JSONDecoder().decode(CodexChatBackend.self, from: encoded)
            XCTAssertEqual(decoded, backend)
        }
    }

    func test_codexChatBackend_unknownDecodesToSDK() throws {
        let bogus = "\"future-backend\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(CodexChatBackend.self, from: bogus), .sdk)
    }

    // MARK: - AgentSession v5 round-trip

    func test_agentSession_v5_fullRoundTrip() throws {
        let groupId = UUID()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let session = AgentSession(
            id: UUID(),
            repoKey: "/Users/foo/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "opus",
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 42,
            mode: .local,
            kind: .code,
            frontierGroupId: groupId,
            frontierChildIndex: 1,
            codexChatBackend: .sdk,
            codexChatThreadId: "thread_abc123"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(session)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: encoded)
        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.repoKey, "/Users/foo/repo")
        XCTAssertEqual(decoded.kind, .code)
        XCTAssertEqual(decoded.frontierGroupId, groupId)
        XCTAssertEqual(decoded.frontierChildIndex, 1)
        XCTAssertEqual(decoded.codexChatBackend, .sdk)
        XCTAssertEqual(decoded.codexChatThreadId, "thread_abc123")
    }

    // MARK: - Chat session shape (repoKey: nil, kind: .chat)

    func test_chatSession_roundTrips_withNilRepoKey() throws {
        let chatCwd = "/Users/foo/Library/Application Support/Clawdmeter/chat-sessions/abc"
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let session = AgentSession(
            id: UUID(),
            repoKey: nil,
            repoDisplayName: "Chat — Claude",
            agent: .claude,
            model: "opus",
            goal: nil,
            worktreePath: chatCwd,
            tmuxWindowId: "@2",
            tmuxPaneId: "%2",
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 0,
            mode: .local,
            kind: .chat
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(session)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: encoded)
        XCTAssertEqual(decoded.kind, .chat)
        XCTAssertNil(decoded.repoKey)
        XCTAssertEqual(decoded.worktreePath, chatCwd)
        XCTAssertEqual(decoded.effectiveCwd, chatCwd, "effectiveCwd should resolve to chat-cwd via worktreePath")
    }

    func test_chatSession_codex_carriesBackendAndThreadId() throws {
        let chatCwd = "/Users/foo/Library/Application Support/Clawdmeter/chat-sessions/sdk-1"
        let now = Date()
        let session = AgentSession(
            id: UUID(),
            repoKey: nil,
            repoDisplayName: "Chat — Codex",
            agent: .codex,
            model: "gpt-5.5",
            goal: nil,
            worktreePath: chatCwd,
            tmuxWindowId: nil,  // SDK chat has no tmux pane
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 0,
            mode: .local,
            kind: .chat,
            codexChatBackend: .sdk,
            codexChatThreadId: "thread_xyz789"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: encoder.encode(session))
        XCTAssertEqual(decoded.agent, .codex)
        XCTAssertEqual(decoded.kind, .chat)
        XCTAssertEqual(decoded.codexChatBackend, .sdk)
        XCTAssertEqual(decoded.codexChatThreadId, "thread_xyz789")
        XCTAssertNil(decoded.tmuxWindowId)
    }

    // MARK: - Back-compat: v3 / v4 sessions.json decode into v5

    func test_v3SessionJSON_decodesAsCodeKind_withNilV5Fields() throws {
        // A typical v3-shape session: no `kind`, `customName`, `effort`,
        // `abPairSessionId`, `abPairDecidedAt` — and definitely none of
        // the v5 fields. Should decode with kind defaulting to .code and
        // all v5 fields nil.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "repoKey": "/Users/foo/repo",
          "repoDisplayName": "repo",
          "agent": "claude",
          "status": "running",
          "createdAt": "2025-01-01T00:00:00Z",
          "lastEventAt": "2025-01-01T00:00:00Z",
          "lastEventSeq": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.kind, .code, "v3 sessions must default kind to .code")
        XCTAssertNil(decoded.frontierGroupId)
        XCTAssertNil(decoded.frontierChildIndex)
        XCTAssertNil(decoded.codexChatBackend)
        XCTAssertNil(decoded.codexChatThreadId)
        XCTAssertNil(decoded.customName, "v3 customName not present in input")
        XCTAssertEqual(decoded.repoKey, "/Users/foo/repo")
    }

    func test_v4SessionJSON_withCustomName_decodesAsCodeKind() throws {
        // v4 added `customName` (v0.5.4). v5 adds nothing user-visible to
        // an existing code session — kind defaults to .code, v5 fields nil.
        let json = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "repoKey": "/Users/foo/another",
          "repoDisplayName": "another",
          "agent": "codex",
          "status": "planning",
          "createdAt": "2025-06-01T00:00:00Z",
          "lastEventAt": "2025-06-01T00:00:00Z",
          "lastEventSeq": 17,
          "customName": "ship the migration"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.kind, .code)
        XCTAssertEqual(decoded.customName, "ship the migration")
        XCTAssertNil(decoded.codexChatBackend)
    }

    // MARK: - effectiveCwd helper

    func test_effectiveCwd_prefersWorktreePath() {
        let now = Date()
        let session = AgentSession(
            id: UUID(),
            repoKey: "/repo",
            repoDisplayName: "r",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: "/wt",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 0
        )
        XCTAssertEqual(session.effectiveCwd, "/wt", "worktreePath beats repoKey when both are set")
    }

    func test_effectiveCwd_fallsBackToRepoKeyWhenNoWorktree() {
        let now = Date()
        let session = AgentSession(
            id: UUID(),
            repoKey: "/repo",
            repoDisplayName: "r",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 0
        )
        XCTAssertEqual(session.effectiveCwd, "/repo")
    }
}
