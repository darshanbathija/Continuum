import Foundation
import ClawdmeterShared

/// Linux daemon transport — Hummingbird 2.x HTTP+WS server backing the
/// shared route handlers in `ClawdmeterShared.AgentControl`.
///
/// Phase 3 build-out adds the Hummingbird dep to `linux/Package.swift`:
///     .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0")
///     .package(url: "https://github.com/hummingbird-project/hummingbird-websocket", from: "2.0.0")
///     .package(url: "https://github.com/hummingbird-project/hummingbird-auth", from: "2.0.0")
///
/// Until then, this file is the scaffold structure + TODO markers so the
/// daemon binary still builds. Adding the dep + filling in TODOs is one
/// focused PR.
public final class HummingbirdTransport: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let httpPort: Int       // 21731 (matches Mac)
        public let wsPort: Int         // 21732 (matches Mac)
        public let bindHost: String    // "0.0.0.0" — peer-filter middleware enforces loopback + Tailscale

        public init(httpPort: Int = 21731, wsPort: Int = 21732, bindHost: String = "0.0.0.0") {
            self.httpPort = httpPort
            self.wsPort = wsPort
            self.bindHost = bindHost
        }
    }

    public let configuration: Configuration
    private let bearerStore: BearerTokenStore

    public init(configuration: Configuration = .init(), bearerStore: BearerTokenStore) {
        self.configuration = configuration
        self.bearerStore = bearerStore
    }

    /// Start the HTTP + WS listeners. Blocks until the server is shut down
    /// via `stop()`.
    public func start() async throws {
        #if os(Linux)
        // TODO(Phase 3):
        //   let app = HBApplication(configuration: HBApplicationConfiguration(
        //       address: .hostname(configuration.bindHost, port: configuration.httpPort)))
        //   app.middleware.add(HummingbirdPeerFilter())     // 127/8 + ::1 + 100.64/10 + fd7a:115c:a1e0::/48
        //   app.middleware.add(HummingbirdBearerAuth(store: bearerStore))
        //   wireRoutes(app)
        //   try await app.runService()
        #else
        // macOS dev: just log + sleep so the dev binary works.
        print("HummingbirdTransport: scaffolded; Phase 3 wires Hummingbird")
        try await Task.sleep(for: .seconds(1))
        #endif
    }

    public func stop() async {
        #if os(Linux)
        // TODO(Phase 3): app.shutdown()
        #endif
    }

    /// Register every route from the shared RouteTable, constructing a
    /// `RouteContext` per request (transport-agnostic).
    private func wireRoutes() {
        #if os(Linux)
        // TODO(Phase 3): for each route in RouteTable.routes
        //   app.router.add(method: route.method, path: route.pattern.literal) { req, context in
        //       let ctx = RouteContext(
        //           request: HTTPRequest(from: req),
        //           params: req.parameters.asDictionary(),
        //           peer: PeerInfo(remoteAddress: req.remoteAddress),
        //           writeResponse: { resp in await req.responder.write(resp) },
        //           upgradeWebSocket: nil  // wired separately for /sessions/:id/terminals
        //       )
        //       await route.handler(ctx)
        //   }
        #endif
    }

    /// Wire the WebSocket upgrade routes — `/sessions/:id/terminals` and
    /// `/events`. These are the bidirectional streams the iOS app
    /// consumes for live chat snapshots + terminal output.
    private func wireWebSockets() {
        #if os(Linux)
        // TODO(Phase 3): app.ws.on("/events") { ws in ... }
        #endif
    }
}
