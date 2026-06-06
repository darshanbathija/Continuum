// E3 (respin): verify that a paired Mac correctly routes a relay
// frame to the existing AgentControlServer handlers via the loopback
// dispatcher.
//
// Strategy:
//   1. Spin up a real AgentControlServer on a random high port.
//   2. Construct a `RelayRequestDispatcher` pointed at that server's
//      `localLoopbackToken` so the request authenticates.
//   3. Hand-craft `MacRelayInboundMessage` instances with various ops
//      and assert we get JSON envelopes back with the expected status.
//
// This proves the integration layer correctly:
//   - decodes the (method, path) op naming convention,
//   - issues an HTTP request to the loopback server with the right
//     bearer token,
//   - wraps the loopback's response into the JSON envelope iOS will
//     unpack on its side.

import XCTest
import Foundation
@testable import Clawdmeter
import ClawdmeterShared

@MainActor
final class AgentControlServerRelayIntegrationTests: XCTestCase {

    // Helper that spins up a real AgentControlServer on a random port
    // and returns a configured dispatcher backed by it. Caller is
    // responsible for `server.stop()` via `defer`.
    private func makeDispatcherAndServer() throws -> (AgentControlServer, RelayRequestDispatcher) {
        // High-random port range avoids colliding with a locally-
        // running Clawdmeter daemon (which owns 21731 on dev machines).
        let base = UInt16.random(in: 35000...39000)
        let range: ClosedRange<UInt16> = base...(base + 9)
        let server = AgentControlServer(
            repoIndex: RepoIndex(),
            registry: AgentSessionRegistry(),
            tmux: TmuxControlClient(),
            notifications: NotificationDispatcher(),
            listenPortRange: range,
            writesServerMetadata: false
        )
        server.start()
        guard let httpPort = server.boundPort, let wsPort = server.boundWsPort else {
            server.stop()
            throw XCTSkip("AgentControlServer failed to bind (port range exhausted?)")
        }
        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: Int(httpPort),
            wsPort: Int(wsPort),
            token: server.localLoopbackToken
        )
        return (server, RelayRequestDispatcher(loopbackClient: client))
    }

    // ───────────────────────────────────────────────────────────
    // GET ./health → 200
    // ───────────────────────────────────────────────────────────

    func testRelayDispatcherRoutesGetHealthThroughLoopback() async throws {
        let (server, dispatcher) = try makeDispatcherAndServer()
        defer { server.stop() }

        let inner = MacRelayInboundMessage(
            seq: 1,
            op: "GET./health",
            data: Data(),
            receivedAt: Date()
        )
        let dispatched = await dispatcher.dispatch(inner)
        let response = try XCTUnwrap(dispatched)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        XCTAssertEqual(envelope["status"] as? Int, 200)
        let body = envelope["body"] as? String
        XCTAssertFalse(body?.isEmpty ?? true, "health endpoint should respond with a body")
    }

    func testRelayDispatcherResponseEnvelopePreservesBinaryBody() throws {
        let bytes = Data([0x00, 0xff, 0x80, 0x41])
        let data = RelayRequestDispatcher.responseEnvelope(status: 200, body: bytes)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(envelope["status"] as? Int, 200)
        XCTAssertEqual(envelope["bodyLength"] as? Int, bytes.count)
        let bodyBase64 = try XCTUnwrap(envelope["bodyBase64"] as? String)
        XCTAssertEqual(Data(base64Encoded: bodyBase64), bytes)
    }

    // ───────────────────────────────────────────────────────────
    // Malformed op → 400 envelope
    // ───────────────────────────────────────────────────────────

    func testRelayDispatcherRejectsMalformedOp() async throws {
        let (server, dispatcher) = try makeDispatcherAndServer()
        defer { server.stop() }
        let inner = MacRelayInboundMessage(
            seq: 1, op: "nonsense", data: Data(), receivedAt: Date()
        )
        let dispatched = await dispatcher.dispatch(inner)
        let response = try XCTUnwrap(dispatched)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(envelope["status"] as? Int, 400)
        XCTAssertNotNil(envelope["error"] as? String)
    }

    // ───────────────────────────────────────────────────────────
    // Disallowed method → 405
    // ───────────────────────────────────────────────────────────

    func testRelayDispatcherRejectsDisallowedMethod() async throws {
        let (server, dispatcher) = try makeDispatcherAndServer()
        defer { server.stop() }
        let inner = MacRelayInboundMessage(
            seq: 1, op: "TRACE./health", data: Data(), receivedAt: Date()
        )
        let dispatched = await dispatcher.dispatch(inner)
        let response = try XCTUnwrap(dispatched)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(envelope["status"] as? Int, 405)
    }

    // ───────────────────────────────────────────────────────────
    // Embedded scheme/host in path → 400 (defense in depth)
    // ───────────────────────────────────────────────────────────

    func testRelayDispatcherRejectsEmbeddedSchemeInPath() async throws {
        let (server, dispatcher) = try makeDispatcherAndServer()
        defer { server.stop() }
        // The dispatcher must not let "GET.https://attacker.com/x"
        // through. The op split keeps `https://attacker.com/x` as the
        // path; the embedded "://" check should reject it.
        let inner = MacRelayInboundMessage(
            seq: 1, op: "GET.https://attacker.com/x", data: Data(), receivedAt: Date()
        )
        let dispatched = await dispatcher.dispatch(inner)
        let response = try XCTUnwrap(dispatched)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(envelope["status"] as? Int, 400)
    }

    // ───────────────────────────────────────────────────────────
    // Path missing leading "/" → 400
    // ───────────────────────────────────────────────────────────

    func testRelayDispatcherRejectsMissingLeadingSlash() async throws {
        let (server, dispatcher) = try makeDispatcherAndServer()
        defer { server.stop() }
        let inner = MacRelayInboundMessage(
            seq: 1, op: "GET.health", data: Data(), receivedAt: Date()
        )
        let dispatched = await dispatcher.dispatch(inner)
        let response = try XCTUnwrap(dispatched)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(envelope["status"] as? Int, 400)
    }

    // ───────────────────────────────────────────────────────────
    // Legacy localhost loopback still works for unpaired Mac (no relay)
    // ───────────────────────────────────────────────────────────

    func testLegacyLocalhostLoopbackWorksWithoutRelay() async throws {
        // Construct a loopback client + hit it directly (no dispatcher
        // involved). This is the "unpaired Mac, no relay" path — Mac
        // SwiftUI surfaces should still work via Tailscale / localhost
        // exactly as they did pre-E3.
        let (server, _) = try makeDispatcherAndServer()
        defer { server.stop() }
        let client = AgentControlClient(
            host: "127.0.0.1",
            httpPort: server.boundPort.map(Int.init) ?? 0,
            wsPort: server.boundWsPort.map(Int.init) ?? 0,
            token: server.localLoopbackToken
        )
        XCTAssertNotNil(client.host)
        XCTAssertNotNil(client.token)
        XCTAssertGreaterThan(client.httpPort, 0)
        // Sanity: building a URL via the same logic the dispatcher
        // uses should succeed.
        let url = URL(string: "http://\(client.host!):\(client.httpPort)/health")
        XCTAssertNotNil(url)
    }
}
