import Foundation

/// Routes client requests to the correct execution host transport (R1 1A).
///
/// Composes on top of the landed Track B stack (`TransportResolver`,
/// `RelayMuxRequestClient`) rather than replacing it. Remote routing is
/// wired in 1B; local host is fully functional in 1A.
public struct DaemonRouter: Sendable {

    public enum Route: Sendable, Equatable {
        case local
        case remoteDirect(host: String, port: Int)
        case remoteRelay(hostId: UUID, sid: String)
        case unreachable(hostId: UUID, reason: String)
    }

    private let hostStore: ExecutionHostStore
    private let multiHostRelayStore: MultiHostRelayStore

    public init(
        hostStore: ExecutionHostStore = .shared,
        multiHostRelayStore: MultiHostRelayStore = .shared
    ) {
        self.hostStore = hostStore
        self.multiHostRelayStore = multiHostRelayStore
    }

    public func localHost() -> ExecutionHost {
        hostStore.localHost()
    }

    public func localHostId() -> UUID {
        hostStore.localHostIdValue()
    }

    public func allHosts() -> [ExecutionHost] {
        hostStore.allHosts()
    }

    /// Resolve how a client should reach `hostId`.
    public func route(to hostId: UUID?, clientOnTailnet: Bool = false) -> Route {
        let resolvedId = hostId ?? hostStore.localHostIdValue()
        guard let host = hostStore.host(id: resolvedId) else {
            return .unreachable(hostId: resolvedId, reason: "unknown_host")
        }

        if host.kind == .localMac {
            return .local
        }

        for transport in host.preferredTransports {
            switch transport {
            case .tailscaleDirect:
                if clientOnTailnet,
                   let hostname = host.tailscaleHostname?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !hostname.isEmpty {
                    return .remoteDirect(host: hostname, port: host.tailscalePort ?? 21731)
                }
            case .relay:
                if let sid = host.relayPairingSid ?? multiHostRelayStore.record(for: host.id)?.sid,
                   !sid.isEmpty {
                    return .remoteRelay(hostId: host.id, sid: sid)
                }
            case .lanDirect, .sshTunnel:
                continue
            }
        }

        return .unreachable(hostId: host.id, reason: "no_reachable_transport")
    }
}
