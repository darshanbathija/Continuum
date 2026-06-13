import Foundation
import ClawdmeterShared

/// Hub-side coordinator for multi-host session aggregation + health (R1).
@MainActor
public final class ExecutionHostCoordinator {

    private let hostStore: ExecutionHostStore
    private let relayStore: MultiHostRelayStore
    private let router: DaemonRouter
    private let remoteClient: RemoteExecutionHostClient

    public init(
        hostStore: ExecutionHostStore = .shared,
        relayStore: MultiHostRelayStore = .shared,
        router: DaemonRouter? = nil,
        remoteClient: RemoteExecutionHostClient = RemoteExecutionHostClient()
    ) {
        self.hostStore = hostStore
        self.relayStore = relayStore
        self.router = router ?? DaemonRouter(hostStore: hostStore, multiHostRelayStore: relayStore)
        self.remoteClient = remoteClient
    }

    private func tailnetReachable(clientOnTailnet: Bool) -> Bool {
        clientOnTailnet || TailnetReachability.isOnTailnet()
    }

    public func mergedSessions(localSessions: [AgentSession], clientOnTailnet: Bool = false) async -> [AgentSession] {
        let onTailnet = tailnetReachable(clientOnTailnet: clientOnTailnet)
        var merged = localSessions
        var seen = Set(localSessions.map(\.id))
        for host in hostStore.allHosts() where host.kind != .localMac {
            let route = router.route(to: host.id, clientOnTailnet: onTailnet)
            switch route {
            case .remoteDirect, .remoteRelay:
                let token = relayStore.iosToken(for: host.id)
                guard let remote = try? await remoteClient.fetchSessions(
                    host: host,
                    route: route,
                    bearerToken: token
                ) else { continue }
                for session in remote where seen.insert(session.id).inserted {
                    merged.append(session)
                }
            default:
                continue
            }
        }
        return merged.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    public func refreshHealth(clientOnTailnet: Bool = false) async {
        let onTailnet = tailnetReachable(clientOnTailnet: clientOnTailnet)
        let now = Date()
        for host in hostStore.allHosts() {
            if host.kind == .localMac {
                var local = host
                local.health = .healthy
                local.lastHealthCheckAt = now
                hostStore.upsert(local)
                continue
            }
            let route = router.route(to: host.id, clientOnTailnet: onTailnet)
            let reachable: Bool
            switch route {
            case .remoteDirect, .remoteRelay:
                reachable = await remoteClient.probeHealth(
                    host: host,
                    route: route,
                    bearerToken: relayStore.iosToken(for: host.id)
                )
            default:
                if let hostname = host.tailscaleHostname, onTailnet {
                    reachable = await TailnetReachability.canReach(
                        hostname: hostname,
                        port: host.tailscalePort ?? 21731
                    )
                } else {
                    reachable = false
                }
            }
            var updated = host
            updated.health = reachable ? .healthy : .unreachable
            updated.lastHealthCheckAt = now
            hostStore.upsert(updated)
        }
    }

    public func route(for hostId: UUID, clientOnTailnet: Bool = false) -> DaemonRouter.Route {
        router.route(to: hostId, clientOnTailnet: tailnetReachable(clientOnTailnet: clientOnTailnet))
    }

    public func bearerToken(for hostId: UUID) -> String? {
        relayStore.iosToken(for: hostId)
    }

    public func forwardSessionCreate(
        hostId: UUID,
        request: NewSessionRequest,
        clientOnTailnet: Bool = false
    ) async throws -> AgentSession {
        guard let host = hostStore.host(id: hostId) else {
            throw RemoteExecutionHostClient.Error.unreachable(hostId: hostId, reason: "unknown_host")
        }
        let route = route(for: hostId, clientOnTailnet: clientOnTailnet)
        switch route {
        case .unreachable:
            throw RemoteExecutionHostClient.Error.unreachable(hostId: hostId, reason: "no_reachable_transport")
        default:
            break
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(request)
        let data = try await remoteClient.request(
            host: host,
            route: route,
            method: "POST",
            path: "/sessions",
            body: body,
            bearerToken: relayStore.iosToken(for: hostId),
            timeout: 45
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let session = try? decoder.decode(AgentSession.self, from: data) else {
            throw RemoteExecutionHostClient.Error.decodeFailed(hostId: hostId)
        }
        return session
    }
}
