import XCTest
import Foundation
@testable import Clawdmeter
import ClawdmeterShared

/// Server-level tests for wire v30 execution-host routes (R1 phase 1).
@MainActor
final class ExecutionHostServerRouteTests: XCTestCase {

    private func makeServer() throws -> AgentControlServer {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hostStore = ExecutionHostStore(fileURL: dir.appendingPathComponent("execution-hosts.json"))
        let base = UInt16.random(in: 35000...39000)
        let server = AgentControlServer(
            repoIndex: RepoIndex(),
            registry: AgentSessionRegistry(storeURL: dir.appendingPathComponent("sessions.json")),
            notifications: NotificationDispatcher(),
            executionHostStore: hostStore,
            hostRunMinuteStore: HostRunMinuteStore(fileURL: dir.appendingPathComponent("host-run-minutes.json")),
            listenPortRange: base...(base + 9),
            writesServerMetadata: false
        )
        server.start()
        return server
    }

    private func loopbackRequest(
        server: AgentControlServer,
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> (Int, Data) {
        guard let port = server.boundPort else {
            throw XCTSkip("Server did not bind a port")
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(server.localLoopbackToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    func testGetExecutionHostsIncludesLocalMac() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let (status, data) = try await loopbackRequest(server: server, method: "GET", path: "/execution-hosts")
        XCTAssertEqual(status, 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(ExecutionHostListResponse.self, from: data)
        XCTAssertEqual(response.hosts.count, 1)
        XCTAssertEqual(response.hosts.first?.kind, .localMac)
        XCTAssertEqual(response.localHostId, response.hosts.first?.id)
    }

    func testRegisterRemoteExecutionHost() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let remoteId = UUID()
        let host = ExecutionHost(
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
        let body = try JSONEncoder().encode(RegisterExecutionHostRequest(host: host))
        let (status, data) = try await loopbackRequest(
            server: server,
            method: "POST",
            path: "/execution-hosts",
            body: body
        )
        XCTAssertEqual(status, 200)
        let saved = try JSONDecoder().decode(ExecutionHost.self, from: data)
        XCTAssertEqual(saved.displayName, "GPU Box")
        let (listStatus, listData) = try await loopbackRequest(server: server, method: "GET", path: "/execution-hosts")
        XCTAssertEqual(listStatus, 200)
        let list = try JSONDecoder().decode(ExecutionHostListResponse.self, from: listData)
        XCTAssertEqual(list.hosts.count, 2)
    }

    func testGetHostRunMinutesEmpty() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let (status, data) = try await loopbackRequest(server: server, method: "GET", path: "/usage/host-minutes")
        XCTAssertEqual(status, 200)
        let response = try JSONDecoder().decode(HostRunMinutesResponse.self, from: data)
        XCTAssertTrue(response.hosts.isEmpty)
    }

    func testGetExecutionHostSelf() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let (status, data) = try await loopbackRequest(server: server, method: "GET", path: "/execution-hosts/self")
        XCTAssertEqual(status, 200)
        let host = try JSONDecoder().decode(ExecutionHost.self, from: data)
        XCTAssertEqual(host.kind, .localMac)
    }

    func testPairRelayExecutionHost() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let req = PairRelayExecutionHostRequest(
            displayName: "VPS 1",
            relayUrl: "wss://relay.example.com",
            sid: "sid-test-123",
            pairingToken: "ios-token-test",
            derivedSymmetricKeyBase64URL: RelayPairingBase64URL.encode(Data(repeating: 7, count: RelayFrameCodec.keyLength)),
            sshHostAlias: "my-vps"
        )
        let body = try JSONEncoder().encode(req)
        let (status, data) = try await loopbackRequest(
            server: server,
            method: "POST",
            path: "/execution-hosts/pair/relay",
            body: body
        )
        XCTAssertEqual(status, 200)
        let host = try JSONDecoder().decode(ExecutionHost.self, from: data)
        XCTAssertEqual(host.displayName, "VPS 1")
        XCTAssertEqual(host.kind, .vps)
        XCTAssertEqual(host.relayPairingSid, "sid-test-123")
        let (listStatus, listData) = try await loopbackRequest(server: server, method: "GET", path: "/execution-hosts")
        XCTAssertEqual(listStatus, 200)
        let list = try JSONDecoder().decode(ExecutionHostListResponse.self, from: listData)
        XCTAssertTrue(list.hosts.contains { $0.displayName == "VPS 1" })
    }

    func testPairRelayExecutionHostRejectsMalformedSymmetricKey() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let req = PairRelayExecutionHostRequest(
            displayName: "VPS 1",
            relayUrl: "wss://relay.example.com",
            sid: "sid-test-123",
            pairingToken: "ios-token-test",
            derivedSymmetricKeyBase64URL: "abc123",
            sshHostAlias: nil
        )
        let body = try JSONEncoder().encode(req)
        let (status, data) = try await loopbackRequest(
            server: server,
            method: "POST",
            path: "/execution-hosts/pair/relay",
            body: body
        )
        XCTAssertEqual(status, 400)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("invalid_relay_key"))
    }

    func testPairRelayExecutionHostRequiresSymmetricKey() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let req = PairRelayExecutionHostRequest(
            displayName: "VPS 1",
            relayUrl: "wss://relay.example.com",
            sid: "sid-test-123",
            pairingToken: "ios-token-test",
            derivedSymmetricKeyBase64URL: nil,
            sshHostAlias: nil
        )
        let body = try JSONEncoder().encode(req)
        let (status, data) = try await loopbackRequest(
            server: server,
            method: "POST",
            path: "/execution-hosts/pair/relay",
            body: body
        )
        XCTAssertEqual(status, 400)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("relay_key_required"))
    }

    func testValidateAWSComputeMissingCLI() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let savedPath = ProcessInfo.processInfo.environment["PATH"]
        defer {
            if let savedPath {
                setenv("PATH", savedPath, 1)
            }
        }
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        let (status, data) = try await loopbackRequest(
            server: server,
            method: "POST",
            path: "/compute/aws/validate",
            body: Data("{}".utf8)
        )
        XCTAssertEqual(status, 200)
        let health = try JSONDecoder().decode(ProvisionerHealth.self, from: data)
        if ShellRunner.locateBinary("aws") == nil {
            XCTAssertFalse(health.ok)
        }
    }

    func testTailnetReachabilityInvalidateCache() {
        TailnetReachability.invalidateCache()
        _ = TailnetReachability.isOnTailnet()
        TailnetReachability.invalidateCache()
    }

    func testProbeExecutionHostHealth() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let remoteId = UUID()
        let host = ExecutionHost(
            id: remoteId,
            displayName: "Probe Host",
            kind: .vps,
            primaryTransport: .relay,
            preferredTransports: [.relay],
            health: .unknown,
            relayPairingSid: "sid-probe"
        )
        let registerBody = try JSONEncoder().encode(RegisterExecutionHostRequest(host: host))
        let (regStatus, _) = try await loopbackRequest(
            server: server,
            method: "POST",
            path: "/execution-hosts",
            body: registerBody
        )
        XCTAssertEqual(regStatus, 200)
        MultiHostRelayStore.shared.save(
            record: MultiHostRelayStore.Record(hostId: remoteId, sid: "sid-probe", relayUrl: "wss://relay.test"),
            iosToken: "probe-token"
        )
        let (status, data) = try await loopbackRequest(
            server: server,
            method: "POST",
            path: "/execution-hosts/\(remoteId.uuidString)/health"
        )
        XCTAssertEqual(status, 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probed = try decoder.decode(ExecutionHost.self, from: data)
        XCTAssertEqual(probed.id, remoteId)
        XCTAssertNotNil(probed.lastHealthCheckAt)
    }
}
