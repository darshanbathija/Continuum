import XCTest
import Foundation
import Network
@testable import Clawdmeter
import ClawdmeterShared
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// E3 — Verify that a paired Mac correctly routes a relay frame to the
/// existing AgentControlServer handlers via the loopback dispatcher.
///
/// The strategy:
///   1. Spin up a real AgentControlServer on a loopback port (the same
///      port range the live daemon uses).
///   2. Construct a `RelayRequestDispatcher` pointing at that server's
///      `localLoopbackToken`.
///   3. Hand-craft an inbound `RelayInnerFrame` with `op = "GET./health"`.
///   4. Dispatch and assert we get a JSON envelope back with status=200.
///
/// This proves the integration layer correctly:
///   - decodes the (method, path) op naming convention
///   - issues an HTTP request to the loopback server with the right
///     bearer token
///   - wraps the loopback's response into the JSON envelope iOS will
///     unpack on its side
@MainActor
final class AgentControlServerRelayIntegrationTests: XCTestCase {

    func testRelayDispatcherRoutesGetHealthThroughLoopback() async throws {
        // Spin up a minimal AgentControlServer on a random high port so we
        // don't collide with any locally-running Clawdmeter daemon (the
        // user's real app likely owns 21731 if this is a dev machine).
        let testPortBase = UInt16.random(in: 35000...39000)
        let portRange: ClosedRange<UInt16> = testPortBase...(testPortBase + 9)
        let server = AgentControlServer(
            repoIndex: RepoIndex(),
            registry: AgentSessionRegistry(),
            tmux: TmuxControlClient(),
            notifications: NotificationDispatcher(),
            listenPortRange: portRange,
            writesServerMetadata: false
        )
        server.start()
        defer { server.stop() }

        // Wait briefly for the listener to bind. AgentControlServer.start()
        // is synchronous; boundPort should be populated immediately.
        guard let httpPort = server.boundPort, let wsPort = server.boundWsPort else {
            throw XCTSkip("AgentControlServer failed to bind (port range exhausted?)")
        }

        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: Int(httpPort),
            wsPort: Int(wsPort),
            token: server.localLoopbackToken
        )

        let dispatcher = RelayRequestDispatcher(loopbackClient: client)

        // Hand-craft an inner frame as if the iPhone had sent us
        // `GET ./health`.
        let inner = RelayInnerFrame(seq: 1, op: "GET./health", data: Data())

        let dispatched = await dispatcher.dispatch(inner)
        let response = try XCTUnwrap(dispatched)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        let status = envelope["status"] as? Int
        XCTAssertEqual(status, 200, "GET /health must succeed")
        // Body is JSON the AgentControlServer encoded.
        let body = envelope["body"] as? String
        XCTAssertFalse(body?.isEmpty ?? true, "Health response should have a body")
    }

    func testRelayDispatcherRejectsMalformedOp() async throws {
        let testPortBase = UInt16.random(in: 35000...39000)
        let portRange: ClosedRange<UInt16> = testPortBase...(testPortBase + 9)
        let server = AgentControlServer(
            repoIndex: RepoIndex(),
            registry: AgentSessionRegistry(),
            tmux: TmuxControlClient(),
            notifications: NotificationDispatcher(),
            listenPortRange: portRange,
            writesServerMetadata: false
        )
        server.start()
        defer { server.stop() }
        let httpPort = server.boundPort ?? 0
        guard httpPort > 0 else { throw XCTSkip("port bind failed") }
        let wsPort = server.boundWsPort ?? 0

        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: Int(httpPort),
            wsPort: Int(wsPort),
            token: server.localLoopbackToken
        )

        let dispatcher = RelayRequestDispatcher(loopbackClient: client)

        // No "." separator → malformed.
        let malformed = RelayInnerFrame(seq: 1, op: "nonsense", data: Data())
        let dispatched = await dispatcher.dispatch(malformed)
        let response = try XCTUnwrap(dispatched)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(envelope["status"] as? Int, 400)
    }

    func testRelayDispatcherRejectsDisallowedMethod() async throws {
        let testPortBase = UInt16.random(in: 35000...39000)
        let portRange: ClosedRange<UInt16> = testPortBase...(testPortBase + 9)
        let server = AgentControlServer(
            repoIndex: RepoIndex(),
            registry: AgentSessionRegistry(),
            tmux: TmuxControlClient(),
            notifications: NotificationDispatcher(),
            listenPortRange: portRange,
            writesServerMetadata: false
        )
        server.start()
        defer { server.stop() }
        let httpPort = server.boundPort ?? 0
        guard httpPort > 0 else { throw XCTSkip("port bind failed") }
        let wsPort = server.boundWsPort ?? 0
        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: Int(httpPort),
            wsPort: Int(wsPort),
            token: server.localLoopbackToken
        )
        let dispatcher = RelayRequestDispatcher(loopbackClient: client)

        // TRACE is not in our allowlist.
        let trace = RelayInnerFrame(seq: 1, op: "TRACE./health", data: Data())
        let dispatched = await dispatcher.dispatch(trace)
        let response = try XCTUnwrap(dispatched)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(envelope["status"] as? Int, 405)
    }
}
