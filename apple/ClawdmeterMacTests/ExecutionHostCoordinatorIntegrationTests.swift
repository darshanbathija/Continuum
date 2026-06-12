import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Integration tests proving R1 multi-host hub fan-out (relay + direct).
@MainActor
final class ExecutionHostCoordinatorIntegrationTests: XCTestCase {

    private var hostStore: ExecutionHostStore!
    private var relayStore: MultiHostRelayStore!
    private var mockBackend: MockRemoteHostBackend!
    private var coordinator: ExecutionHostCoordinator!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hostStore = ExecutionHostStore(fileURL: dir.appendingPathComponent("execution-hosts.json"))
        relayStore = MultiHostRelayStore(
            fileURL: dir.appendingPathComponent("relay.json"),
            keychainService: "test.execution-host.\(UUID().uuidString)"
        )
        let backend = MockRemoteHostBackend(hostId: UUID(), label: "VPS Test")
        mockBackend = backend
        let remoteClient = RemoteExecutionHostClient(relayRequestHandler: { _, method, path, body, _ in
            let (status, data) = await backend.handle(method: method, path: path, body: body)
            guard (200..<300).contains(status) else {
                throw RemoteExecutionHostClient.Error.httpStatus(hostId: backend.hostId, status: status)
            }
            return data
        })
        coordinator = ExecutionHostCoordinator(
            hostStore: hostStore,
            relayStore: relayStore,
            remoteClient: remoteClient
        )
        registerRemoteVPS()
    }

    private func registerRemoteVPS() {
        let host = ExecutionHost(
            id: mockBackend.hostId,
            displayName: "VPS Test",
            kind: .vps,
            primaryTransport: .relay,
            preferredTransports: [.relay],
            health: .unknown,
            relayPairingSid: "sid-integration",
            relayAlsoEnabled: true
        )
        _ = hostStore.upsert(host)
        relayStore.save(
            record: MultiHostRelayStore.Record(
                hostId: mockBackend.hostId,
                sid: "sid-integration",
                relayUrl: "wss://relay.test"
            ),
            iosToken: "ios-test-token"
        )
    }

    func testRegisterTwoHostsIncludesLocalAndRemote() {
        XCTAssertEqual(hostStore.allHosts().count, 2)
        XCTAssertTrue(hostStore.allHosts().contains { $0.kind == .localMac })
        XCTAssertTrue(hostStore.allHosts().contains { $0.kind == .vps })
    }

    func testMergedSessionsIncludesRemoteRelayHost() async {
        let remoteSession = makeRemoteSession(id: UUID(), label: "VPS Test")
        await mockBackend.setSessions([remoteSession])
        let local = makeLocalSession()
        let merged = await coordinator.mergedSessions(localSessions: [local])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.id == remoteSession.id })
        XCTAssertTrue(merged.contains { $0.id == local.id })
    }

    func testForwardSessionCreateOverRelay() async throws {
        let created = try await coordinator.forwardSessionCreate(
            hostId: mockBackend.hostId,
            request: NewSessionRequest(
                repoKey: "/tmp/repo",
                agent: .claude,
                model: "claude-opus-4-7",
                goal: "test",
                useWorktree: false
            )
        )
        XCTAssertEqual(created.agent, .claude)
        XCTAssertEqual(created.executionHostLabel, "VPS Test")
        let remote = await mockBackend.snapshot()
        XCTAssertEqual(remote.count, 1)
        XCTAssertEqual(remote.first?.id, created.id)
    }

    func testHandoffSpawnIncludesParentSessionId() async throws {
        let sourceId = UUID()
        let created = try await coordinator.forwardSessionCreate(
            hostId: mockBackend.hostId,
            request: NewSessionRequest(
                repoKey: "/tmp/repo",
                agent: .claude,
                model: nil,
                goal: "handoff continue",
                useWorktree: false,
                targetHostId: mockBackend.hostId,
                parentSessionId: sourceId
            ),
            clientOnTailnet: true
        )
        XCTAssertEqual(created.parentSessionId, sourceId)
        let remote = await mockBackend.snapshot()
        XCTAssertEqual(remote.first?.parentSessionId, sourceId)
    }

    func testRefreshHealthMarksRemoteHealthy() async {
        await coordinator.refreshHealth(clientOnTailnet: true)
        let host = hostStore.host(id: mockBackend.hostId)
        XCTAssertEqual(host?.health, .healthy)
    }

    private func makeLocalSession(id: UUID = UUID()) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: "/tmp/local",
            repoDisplayName: "local",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            executionHostId: hostStore.localHostIdValue(),
            executionHostLabel: "My Mac"
        )
    }

    private func makeRemoteSession(id: UUID, label: String) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: "/tmp/remote",
            repoDisplayName: "remote",
            agent: .codex,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            executionHostId: mockBackend.hostId,
            executionHostLabel: label
        )
    }
}

/// In-memory remote daemon stub for relay-routed hub requests.
private actor MockRemoteHostBackend {
    let hostId: UUID
    let label: String
    private var sessions: [AgentSession] = []

    init(hostId: UUID, label: String) {
        self.hostId = hostId
        self.label = label
    }

    func setSessions(_ sessions: [AgentSession]) {
        self.sessions = sessions
    }

    func snapshot() -> [AgentSession] {
        sessions
    }

    func handle(method: String, path: String, body: Data?) -> (Int, Data) {
        switch (method.uppercased(), path) {
        case ("GET", "/health"):
            let payload = #"{"ok":true,"wireVersion":30}"#
            return (200, Data(payload.utf8))
        case ("GET", "/sessions"):
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = (try? encoder.encode(sessions)) ?? Data("[]".utf8)
            return (200, data)
        case ("POST", "/sessions"):
            guard let body else { return (400, Data()) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let req = try? decoder.decode(NewSessionRequest.self, from: body) else {
                return (400, Data("invalid".utf8))
            }
            let session = AgentSession(
                id: UUID(),
                repoKey: req.repoKey,
                repoDisplayName: (req.repoKey as NSString).lastPathComponent,
                agent: req.agent,
                model: req.model,
                goal: req.goal,
                worktreePath: nil,
                tmuxWindowId: nil,
                tmuxPaneId: nil,
                status: req.planMode ? .planning : .running,
                planText: nil,
                createdAt: Date(),
                lastEventAt: Date(),
                lastEventSeq: 1,
                parentSessionId: req.parentSessionId,
                executionHostId: hostId,
                executionHostLabel: label
            )
            sessions.append(session)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = (try? encoder.encode(session)) ?? Data()
            return (200, data)
        default:
            return (404, Data())
        }
    }
}
