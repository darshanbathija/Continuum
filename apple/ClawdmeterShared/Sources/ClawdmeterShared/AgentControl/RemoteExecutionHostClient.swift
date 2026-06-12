import Foundation

/// HTTP client for reaching a remote execution host's daemon (R1 hub fan-out).
public struct RemoteExecutionHostClient: Sendable {

    public enum Error: Swift.Error, Equatable {
        case unreachable(hostId: UUID, reason: String)
        case httpStatus(hostId: UUID, status: Int)
        case decodeFailed(hostId: UUID)
    }

    /// Optional relay transport for `.remoteRelay` routes (Mac hub → VPS).
    public typealias RelayRequestHandler = @Sendable (
        _ hostId: UUID,
        _ method: String,
        _ path: String,
        _ body: Data?,
        _ timeout: TimeInterval
    ) async throws -> Data

    private let urlSession: URLSession
    private let defaultPort: Int
    private let relayRequestHandler: RelayRequestHandler?

    public init(
        urlSession: URLSession = .shared,
        defaultPort: Int = 21731,
        relayRequestHandler: RelayRequestHandler? = nil
    ) {
        self.urlSession = urlSession
        self.defaultPort = defaultPort
        self.relayRequestHandler = relayRequestHandler
    }

    /// Perform one daemon HTTP request against `host` using `route` + optional bearer token.
    public func request(
        host: ExecutionHost,
        route: DaemonRouter.Route,
        method: String,
        path: String,
        body: Data? = nil,
        bearerToken: String? = nil,
        timeout: TimeInterval = 8
    ) async throws -> Data {
        if case .remoteRelay = route, let relayRequestHandler {
            let data = try await relayRequestHandler(host.id, method, path, body, timeout)
            return data
        }
        guard let url = url(for: host, route: route, path: path) else {
            throw Error.unreachable(hostId: host.id, reason: "no_reachable_transport")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let bearerToken, !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unreachable(hostId: host.id, reason: "invalid_response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.httpStatus(hostId: host.id, status: http.statusCode)
        }
        return data
    }

    public func fetchSessions(
        host: ExecutionHost,
        route: DaemonRouter.Route,
        bearerToken: String?
    ) async throws -> [AgentSession] {
        let data = try await request(
            host: host,
            route: route,
            method: "GET",
            path: "/sessions",
            bearerToken: bearerToken
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sessions = try? decoder.decode([AgentSession].self, from: data) else {
            throw Error.decodeFailed(hostId: host.id)
        }
        return sessions
    }

    public func probeHealth(
        host: ExecutionHost,
        route: DaemonRouter.Route,
        bearerToken: String?
    ) async -> Bool {
        do {
            _ = try await request(
                host: host,
                route: route,
                method: "GET",
                path: "/health",
                bearerToken: bearerToken,
                timeout: 4
            )
            return true
        } catch {
            return false
        }
    }

    private func url(for host: ExecutionHost, route: DaemonRouter.Route, path: String) -> URL? {
        switch route {
        case .local:
            return nil
        case .remoteDirect(let hostname, let port):
            let literal = AgentControlClient.urlHostLiteral(hostname)
            return URL(string: "http://\(literal):\(port)\(path)")
        case .remoteRelay:
            return nil
        case .unreachable:
            return nil
        }
    }
}
