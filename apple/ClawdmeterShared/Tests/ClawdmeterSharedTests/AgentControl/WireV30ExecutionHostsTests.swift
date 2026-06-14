import XCTest
@testable import ClawdmeterShared

/// Wire v30 — multi-device execution hosts (R1 phase 1A).
final class WireV30ExecutionHostsTests: XCTestCase {

    func testCurrentWireVersion() {
        XCTAssertEqual(AgentControlWireVersion.current, 30)
        XCTAssertEqual(AgentControlWireVersion.executionHostsMinimum, 30)
    }

    func testExecutionHostsFeatureGate() {
        XCTAssertFalse(AgentControlWireVersion.supportsExecutionHosts(serverWireVersion: 29))
        XCTAssertTrue(AgentControlWireVersion.supportsExecutionHosts(serverWireVersion: 30))
        XCTAssertFalse(AgentControlWireVersion.supportsExecutionHosts(serverWireVersion: nil))
    }

    func testExecutionHostRoundTrip() throws {
        let host = ExecutionHost(
            id: UUID(),
            displayName: "VPS Hetzner",
            kind: .vps,
            primaryTransport: .relay,
            preferredTransports: [.relay],
            health: .healthy,
            relayPairingSid: "sid-123",
            relayAlsoEnabled: true,
            daemonWireVersion: 30
        )
        let decoded = try JSONDecoder().decode(
            ExecutionHost.self,
            from: JSONEncoder().encode(host)
        )
        XCTAssertEqual(decoded, host)
    }

    func testAgentSessionExecutionHostFieldsRoundTrip() throws {
        let hostId = UUID()
        let session = AgentSession(
            id: UUID(),
            repoKey: "/tmp/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "sonnet",
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            executionHostId: hostId,
            executionHostLabel: "My Mac"
        )
        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )
        XCTAssertEqual(decoded.executionHostId, hostId)
        XCTAssertEqual(decoded.executionHostLabel, "My Mac")
    }

    func testAgentSessionBackCompatMissingExecutionHostFields() throws {
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "repoKey": "/tmp/repo",
          "repoDisplayName": "repo",
          "agent": "claude",
          "model": null,
          "goal": null,
          "worktreePath": null,
          "tmuxWindowId": null,
          "tmuxPaneId": null,
          "status": "running",
          "planText": null,
          "createdAt": "2026-06-12T00:00:00Z",
          "lastEventAt": "2026-06-12T00:00:00Z",
          "lastEventSeq": 1
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: legacy)
        XCTAssertNil(session.executionHostId)
        XCTAssertNil(session.executionHostLabel)
        XCTAssertNil(session.handoff)
    }

    func testExecutionHostStoreBootstrapsLocalMac() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("execution-hosts.json")
        let store = ExecutionHostStore(fileURL: fileURL)
        let local = store.localHost()
        XCTAssertEqual(local.kind, .localMac)
        XCTAssertEqual(local.displayName, "My Mac")
        XCTAssertEqual(store.allHosts().count, 1)
        XCTAssertEqual(store.localHostIdValue(), local.id)

        let reloaded = ExecutionHostStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.localHostIdValue(), local.id)
        XCTAssertEqual(reloaded.allHosts().count, 1)
    }

    func testExecutionHostStoreUpsertRemoteHost() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ExecutionHostStore(fileURL: dir.appendingPathComponent("execution-hosts.json"))
        let remoteId = UUID()
        let remote = ExecutionHost(
            id: remoteId,
            displayName: "GPU Box",
            kind: .tailscaleHost,
            primaryTransport: .tailscaleDirect,
            preferredTransports: [.tailscaleDirect, .relay],
            health: .unknown,
            tailscaleHostname: "gpu-box.example.ts.net",
            tailscalePort: 21731,
            relayAlsoEnabled: true
        )
        store.upsert(remote)
        XCTAssertEqual(store.allHosts().count, 2)
        XCTAssertEqual(store.host(id: remoteId)?.displayName, "GPU Box")
        XCTAssertFalse(store.remove(id: store.localHostIdValue()))
        XCTAssertTrue(store.remove(id: remoteId))
        XCTAssertEqual(store.allHosts().count, 1)
    }

    func testDaemonRouterLocalAndRemoteRoutes() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hostStore = ExecutionHostStore(fileURL: dir.appendingPathComponent("execution-hosts.json"))
        let relayStore = MultiHostRelayStore(fileURL: dir.appendingPathComponent("execution-relay-pairings.json"))
        let router = DaemonRouter(hostStore: hostStore, multiHostRelayStore: relayStore)

        let localId = hostStore.localHostIdValue()
        XCTAssertEqual(router.route(to: nil), .local)
        XCTAssertEqual(router.route(to: localId), .local)

        let remoteId = UUID()
        hostStore.upsert(ExecutionHost(
            id: remoteId,
            displayName: "VPS",
            kind: .vps,
            primaryTransport: .relay,
            preferredTransports: [.relay],
            health: .healthy,
            relayPairingSid: "relay-sid"
        ))
        XCTAssertEqual(
            router.route(to: remoteId),
            .remoteRelay(hostId: remoteId, sid: "relay-sid")
        )

        let tailscaleId = UUID()
        hostStore.upsert(ExecutionHost(
            id: tailscaleId,
            displayName: "GPU Box",
            kind: .tailscaleHost,
            primaryTransport: .tailscaleDirect,
            preferredTransports: [.tailscaleDirect, .relay],
            health: .healthy,
            tailscaleHostname: "gpu-box.example.ts.net",
            tailscalePort: 21731,
            relayAlsoEnabled: true
        ))
        XCTAssertEqual(
            router.route(to: tailscaleId, clientOnTailnet: true),
            .remoteDirect(host: "gpu-box.example.ts.net", port: 21731)
        )
        let offTailnet = router.route(to: tailscaleId, clientOnTailnet: false)
        if case .unreachable = offTailnet {
            // Expected when relay sid not set on tailscale-only host off-tailnet.
        } else if case .remoteRelay = offTailnet {
            // Acceptable when relay fallback is configured.
        } else {
            XCTFail("unexpected route off tailnet: \(offTailnet)")
        }
    }

    func testTailnetReachabilityCacheRoundTrip() {
        TailnetReachability.invalidateCache()
        let first = TailnetReachability.isOnTailnet()
        let second = TailnetReachability.isOnTailnet()
        XCTAssertEqual(first, second)
        TailnetReachability.invalidateCache()
    }

    func testMultiHostRelayStoreRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MultiHostRelayStore(
            fileURL: dir.appendingPathComponent("execution-relay-pairings.json"),
            keychainService: "com.clawdmeter.tests.execution-host"
        )
        let hostId = UUID()
        let record = MultiHostRelayStore.Record(
            hostId: hostId,
            sid: "sid-abc",
            relayUrl: "https://relay.example/worker"
        )
        store.save(record: record, iosToken: "ios-token")
        XCTAssertEqual(store.record(for: hostId)?.sid, "sid-abc")
        XCTAssertEqual(store.allRecords().count, 1)
        store.remove(hostId: hostId)
        XCTAssertNil(store.record(for: hostId))
    }

    func testNewSessionRequestTargetHostIdRoundTrip() throws {
        let hostId = UUID()
        let req = NewSessionRequest(
            repoKey: "/tmp/repo",
            agent: .claude,
            targetHostId: hostId
        )
        let decoded = try JSONDecoder().decode(
            NewSessionRequest.self,
            from: JSONEncoder().encode(req)
        )
        XCTAssertEqual(decoded.targetHostId, hostId)
    }

    func testHostRunMinuteStoreTracksSessions() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HostRunMinuteStore(fileURL: dir.appendingPathComponent("host-run-minutes.json"))
        let hostId = UUID()
        let session = AgentSession(
            id: UUID(),
            repoKey: "/tmp/repo",
            repoDisplayName: "repo",
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
            executionHostId: hostId,
            executionHostLabel: "My Mac"
        )
        store.sessionStarted(session)
        store.tickOpenSessions(activeSessionIds: [session.id])
        let summary = store.summaries(activeCountsByHost: [hostId: 1])
        XCTAssertEqual(summary.first?.executionHostId, hostId)
        store.sessionStopped(session.id)
        XCTAssertEqual(store.allRecords().count, 1)
    }

    func testHandoffRequestRoundTrip() throws {
        let target = UUID()
        let req = HandoffSessionRequest(targetHostId: target)
        let decoded = try JSONDecoder().decode(
            HandoffSessionRequest.self,
            from: JSONEncoder().encode(req)
        )
        XCTAssertEqual(decoded.targetHostId, target)
    }

    func testNewSessionRequestParentSessionIdRoundTrip() throws {
        let parentId = UUID()
        let req = NewSessionRequest(
            repoKey: "/tmp/repo",
            agent: .claude,
            model: "claude-opus-4-7",
            goal: "continue",
            useWorktree: false,
            parentSessionId: parentId
        )
        let decoded = try JSONDecoder().decode(
            NewSessionRequest.self,
            from: JSONEncoder().encode(req)
        )
        XCTAssertEqual(decoded.parentSessionId, parentId)
    }

    func testNewSessionRequestSourceRepositoryRoundTrip() throws {
        let req = NewSessionRequest(
            repoKey: "/Users/me/repo",
            agent: .opencode,
            targetHostId: UUID(),
            sourceRemoteURL: "git@github.com:example/repo.git",
            sourceBranch: "feature/remote-hosts",
            sourceCommit: "0123456789abcdef0123456789abcdef01234567"
        )
        let decoded = try JSONDecoder().decode(
            NewSessionRequest.self,
            from: JSONEncoder().encode(req)
        )
        XCTAssertEqual(decoded.sourceRemoteURL, "git@github.com:example/repo.git")
        XCTAssertEqual(decoded.sourceBranch, "feature/remote-hosts")
        XCTAssertEqual(decoded.sourceCommit, "0123456789abcdef0123456789abcdef01234567")
    }

    func testHostRunMinuteCSVIncludesExecutionHostId() {
        let hostId = UUID()
        let sessionId = UUID()
        let csv = HostRunMinuteCSV.export(records: [
            HostRunRecord(
                sessionId: sessionId,
                executionHostId: hostId,
                executionHostLabel: "VPS 1",
                startedAt: Date(timeIntervalSince1970: 0),
                stoppedAt: Date(timeIntervalSince1970: 3600),
                billableMinutes: 60
            )
        ])
        XCTAssertTrue(csv.contains("execution_host_id"))
        XCTAssertTrue(csv.contains(hostId.uuidString))
        XCTAssertTrue(csv.contains(sessionId.uuidString))
        XCTAssertTrue(csv.contains("VPS 1"))
    }

    func testBillableMinutesForOpenSession() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = HostRunMinuteStore(fileURL: dir.appendingPathComponent("host-run-minutes.json"))
        let hostId = UUID()
        let sessionId = UUID()
        let session = AgentSession(
            id: sessionId,
            repoKey: "/tmp",
            repoDisplayName: "tmp",
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
            executionHostId: hostId,
            executionHostLabel: "VPS"
        )
        store.sessionStarted(session, at: Date(timeIntervalSince1970: 0))
        let minutes = store.billableMinutes(forSession: sessionId, now: Date(timeIntervalSince1970: 2520))
        XCTAssertEqual(minutes, 42)
    }

    func testPairRelayExecutionHostRequestRoundTrip() throws {
        let req = PairRelayExecutionHostRequest(
            displayName: "VPS",
            relayUrl: "wss://relay.example.com",
            sid: "sid-abc",
            pairingToken: "tok",
            derivedSymmetricKeyBase64URL: "key-b64",
            sshHostAlias: "vps1"
        )
        let decoded = try JSONDecoder().decode(
            PairRelayExecutionHostRequest.self,
            from: JSONEncoder().encode(req)
        )
        XCTAssertEqual(decoded.sid, "sid-abc")
        XCTAssertEqual(decoded.sshHostAlias, "vps1")
    }

    func testMultiHostRelayStoreSymmetricKeyRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MultiHostRelayStore(
            fileURL: dir.appendingPathComponent("execution-relay-pairings.json"),
            keychainService: "com.clawdmeter.test.execution-host.\(UUID().uuidString)"
        )
        let hostId = UUID()
        let keyB64 = RelayPairingBase64URL.encode(Data(repeating: 0xAB, count: 32))
        store.save(
            record: MultiHostRelayStore.Record(
                hostId: hostId,
                sid: "sid-1",
                relayUrl: "wss://relay.example.com"
            ),
            iosToken: "ios-tok",
            derivedSymmetricKeyBase64URL: keyB64
        )
        XCTAssertEqual(store.derivedSymmetricKeyBase64URL(for: hostId), keyB64)
        XCTAssertEqual(store.iosToken(for: hostId), "ios-tok")
    }

    func testHostRunMinutesResponseBillableMinutesForSession() {
        let sessionId = UUID()
        let hostId = UUID()
        let response = HostRunMinutesResponse(
            hosts: [],
            records: [
                HostRunRecord(
                    sessionId: sessionId,
                    executionHostId: hostId,
                    executionHostLabel: "VPS",
                    billableMinutes: 42
                )
            ]
        )
        XCTAssertEqual(response.billableMinutes(forSession: sessionId), 42)
        XCTAssertNil(response.billableMinutes(forSession: UUID()))
    }

    func testAWSCloudIdlePolicyStopsAfterThreshold() {
        let now = Date(timeIntervalSince1970: 3600)
        let lastActivity = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(
            AWSCloudIdlePolicy.shouldStopHost(
                now: now,
                autoStopIdleMinutes: 30,
                activeSessionCount: 0,
                lastActivityAt: lastActivity
            )
        )
        XCTAssertFalse(
            AWSCloudIdlePolicy.shouldStopHost(
                now: now,
                autoStopIdleMinutes: 30,
                activeSessionCount: 1,
                lastActivityAt: lastActivity
            )
        )
        XCTAssertFalse(
            AWSCloudIdlePolicy.shouldStopHost(
                now: Date(timeIntervalSince1970: 900),
                autoStopIdleMinutes: 30,
                activeSessionCount: 0,
                lastActivityAt: lastActivity
            )
        )
    }

    func testAWSCloudIdlePolicyLastActivityFromSessions() {
        let hostId = UUID()
        let provisioned = Date(timeIntervalSince1970: 100)
        let session = AgentSession(
            id: UUID(),
            repoKey: "/tmp",
            repoDisplayName: "tmp",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .done,
            planText: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            lastEventAt: Date(timeIntervalSince1970: 500),
            lastEventSeq: 0,
            executionHostId: hostId
        )
        let last = AWSCloudIdlePolicy.lastActivityAt(
            sessions: [session],
            hostId: hostId,
            provisionedAt: provisioned
        )
        XCTAssertEqual(last, session.lastEventAt)
    }

    func testExecutionHostAutoStopIdleMinutesRoundTrip() throws {
        let hostId = UUID()
        let host = ExecutionHost(
            id: hostId,
            displayName: "AWS Runner",
            kind: .byocAWS,
            primaryTransport: .relay,
            cloudProvider: "aws",
            autoStopIdleMinutes: 45
        )
        let decoded = try JSONDecoder().decode(
            ExecutionHost.self,
            from: JSONEncoder().encode(host)
        )
        XCTAssertEqual(decoded.autoStopIdleMinutes, 45)
    }

    /// Regression: the Mac loopback client never runs `refreshAll()`, so its
    /// `serverWireVersion` only learns the in-process daemon's version when
    /// seeded at construction. Without the seed every Mac multi-host surface
    /// (Settings → Devices, host pickers) renders the "Update Clawdmeter to
    /// wire v30" fallback even though the local daemon IS v30. This locks the
    /// seed → `supportsExecutionHosts` path the loopback factory relies on.
    @MainActor
    func testLoopbackClientSeedsExecutionHostSupport() {
        let seeded = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback",
            assumeServerWireVersion: AgentControlWireVersion.current
        )
        XCTAssertEqual(seeded.serverWireVersion, AgentControlWireVersion.current)
        XCTAssertTrue(seeded.supportsExecutionHosts)

        // Default (iOS / UserDefaults path) stays byte-identical: nil until a
        // /health refresh, gate false.
        let unseeded = AgentControlClient(
            host: "127.0.0.1",
            httpPort: 21731,
            wsPort: 21732,
            token: "loopback"
        )
        XCTAssertNil(unseeded.serverWireVersion)
        XCTAssertFalse(unseeded.supportsExecutionHosts)
    }
}
