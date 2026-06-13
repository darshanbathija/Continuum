import Foundation

// MARK: - Execution hosts (wire v30, multi-device R1)

public enum ExecutionHostKind: String, Codable, Hashable, Sendable, CaseIterable {
    case localMac
    case remoteMac
    case vps
    case tailscaleHost
    case byocAWS
    case byocRailway
}

public enum ExecutionHostTransport: String, Codable, Hashable, Sendable, CaseIterable {
    case relay
    case lanDirect
    case tailscaleDirect
    case sshTunnel
}

public enum ExecutionHostHealth: String, Codable, Hashable, Sendable, CaseIterable {
    case unknown
    case healthy
    case degraded
    case unreachable
    case provisioning
}

/// A machine that can run agent sessions (local Mac, VPS, tailnet box, …).
public struct ExecutionHost: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var displayName: String
    public let kind: ExecutionHostKind
    public var primaryTransport: ExecutionHostTransport
    public var preferredTransports: [ExecutionHostTransport]
    public var health: ExecutionHostHealth

    public var relayEndpoint: String?
    public var relayPairingSid: String?
    public var lanServiceName: String?
    public var tailscaleHostname: String?
    public var tailscalePort: Int?
    public var sshHostAlias: String?
    public var relayAlsoEnabled: Bool

    public var cloudProvider: String?
    public var cloudResourceId: String?
    public var cloudRegion: String?
    public var instanceType: String?
    public var billingMode: String?
    /// R2 D12: auto-stop EC2 after this many minutes with zero active sessions.
    public var autoStopIdleMinutes: Int?
    public var provisionedAt: Date?
    public var lastHealthCheckAt: Date?

    public var supportedAgents: [AgentKind]?
    public var opencodeAvailable: Bool
    public var daemonWireVersion: Int?

    public init(
        id: UUID,
        displayName: String,
        kind: ExecutionHostKind,
        primaryTransport: ExecutionHostTransport,
        preferredTransports: [ExecutionHostTransport]? = nil,
        health: ExecutionHostHealth = .unknown,
        relayEndpoint: String? = nil,
        relayPairingSid: String? = nil,
        lanServiceName: String? = nil,
        tailscaleHostname: String? = nil,
        tailscalePort: Int? = nil,
        sshHostAlias: String? = nil,
        relayAlsoEnabled: Bool = true,
        cloudProvider: String? = nil,
        cloudResourceId: String? = nil,
        cloudRegion: String? = nil,
        instanceType: String? = nil,
        billingMode: String? = nil,
        autoStopIdleMinutes: Int? = nil,
        provisionedAt: Date? = nil,
        lastHealthCheckAt: Date? = nil,
        supportedAgents: [AgentKind]? = nil,
        opencodeAvailable: Bool = false,
        daemonWireVersion: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.primaryTransport = primaryTransport
        self.preferredTransports = preferredTransports ?? [primaryTransport]
        self.health = health
        self.relayEndpoint = relayEndpoint
        self.relayPairingSid = relayPairingSid
        self.lanServiceName = lanServiceName
        self.tailscaleHostname = tailscaleHostname
        self.tailscalePort = tailscalePort
        self.sshHostAlias = sshHostAlias
        self.relayAlsoEnabled = relayAlsoEnabled
        self.cloudProvider = cloudProvider
        self.cloudResourceId = cloudResourceId
        self.cloudRegion = cloudRegion
        self.instanceType = instanceType
        self.billingMode = billingMode
        self.autoStopIdleMinutes = autoStopIdleMinutes
        self.provisionedAt = provisionedAt
        self.lastHealthCheckAt = lastHealthCheckAt
        self.supportedAgents = supportedAgents
        self.opencodeAvailable = opencodeAvailable
        self.daemonWireVersion = daemonWireVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        kind = try c.decode(ExecutionHostKind.self, forKey: .kind)
        primaryTransport = try c.decode(ExecutionHostTransport.self, forKey: .primaryTransport)
        preferredTransports = (try? c.decodeIfPresent([ExecutionHostTransport].self, forKey: .preferredTransports))
            ?? [primaryTransport]
        health = (try? c.decodeIfPresent(ExecutionHostHealth.self, forKey: .health)) ?? .unknown
        relayEndpoint = try c.decodeIfPresent(String.self, forKey: .relayEndpoint)
        relayPairingSid = try c.decodeIfPresent(String.self, forKey: .relayPairingSid)
        lanServiceName = try c.decodeIfPresent(String.self, forKey: .lanServiceName)
        tailscaleHostname = try c.decodeIfPresent(String.self, forKey: .tailscaleHostname)
        tailscalePort = try c.decodeIfPresent(Int.self, forKey: .tailscalePort)
        sshHostAlias = try c.decodeIfPresent(String.self, forKey: .sshHostAlias)
        relayAlsoEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .relayAlsoEnabled)) ?? true
        cloudProvider = try c.decodeIfPresent(String.self, forKey: .cloudProvider)
        cloudResourceId = try c.decodeIfPresent(String.self, forKey: .cloudResourceId)
        cloudRegion = try c.decodeIfPresent(String.self, forKey: .cloudRegion)
        instanceType = try c.decodeIfPresent(String.self, forKey: .instanceType)
        billingMode = try c.decodeIfPresent(String.self, forKey: .billingMode)
        autoStopIdleMinutes = try c.decodeIfPresent(Int.self, forKey: .autoStopIdleMinutes)
        provisionedAt = try c.decodeIfPresent(Date.self, forKey: .provisionedAt)
        lastHealthCheckAt = try c.decodeIfPresent(Date.self, forKey: .lastHealthCheckAt)
        supportedAgents = try c.decodeIfPresent([AgentKind].self, forKey: .supportedAgents)
        opencodeAvailable = (try? c.decodeIfPresent(Bool.self, forKey: .opencodeAvailable)) ?? false
        daemonWireVersion = try c.decodeIfPresent(Int.self, forKey: .daemonWireVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, primaryTransport, preferredTransports, health
        case relayEndpoint, relayPairingSid, lanServiceName
        case tailscaleHostname, tailscalePort, sshHostAlias, relayAlsoEnabled
        case cloudProvider, cloudResourceId, cloudRegion, instanceType, billingMode
        case autoStopIdleMinutes, provisionedAt, lastHealthCheckAt
        case supportedAgents, opencodeAvailable, daemonWireVersion
    }
}

// MARK: - Handoff (D1)

public struct HandoffState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case requested
        case pushingBranch
        case spawningRemote
        case attached
        case failed
    }

    public let targetHostId: UUID
    public let sourceHostId: UUID
    public let phase: Phase
    public let startedAt: Date
    public let error: String?

    public init(
        targetHostId: UUID,
        sourceHostId: UUID,
        phase: Phase,
        startedAt: Date = Date(),
        error: String? = nil
    ) {
        self.targetHostId = targetHostId
        self.sourceHostId = sourceHostId
        self.phase = phase
        self.startedAt = startedAt
        self.error = error
    }
}

// MARK: - API bodies

public struct ExecutionHostListResponse: Codable, Sendable {
    public let hosts: [ExecutionHost]
    public let localHostId: UUID

    public init(hosts: [ExecutionHost], localHostId: UUID) {
        self.hosts = hosts
        self.localHostId = localHostId
    }
}

public struct RegisterExecutionHostRequest: Codable, Sendable {
    public let host: ExecutionHost

    public init(host: ExecutionHost) {
        self.host = host
    }
}

public struct PatchExecutionHostRequest: Codable, Sendable {
    public var displayName: String?
    public var health: ExecutionHostHealth?
    public var lastHealthCheckAt: Date?

    public init(
        displayName: String? = nil,
        health: ExecutionHostHealth? = nil,
        lastHealthCheckAt: Date? = nil
    ) {
        self.displayName = displayName
        self.health = health
        self.lastHealthCheckAt = lastHealthCheckAt
    }
}

public struct HandoffSessionRequest: Codable, Sendable {
    public let targetHostId: UUID
    /// Reserved for future strategies; R1 uses branch-push migrate only.
    public let strategy: String?

    public init(targetHostId: UUID, strategy: String? = nil) {
        self.targetHostId = targetHostId
        self.strategy = strategy
    }
}

public struct HandoffSessionResponse: Codable, Sendable {
    public let sourceSessionId: UUID
    public let newSessionId: UUID
    public let targetHostId: UUID

    public init(sourceSessionId: UUID, newSessionId: UUID, targetHostId: UUID) {
        self.sourceSessionId = sourceSessionId
        self.newSessionId = newSessionId
        self.targetHostId = targetHostId
    }
}

public struct PairTailscaleExecutionHostRequest: Codable, Sendable {
    public let displayName: String
    public let tailscaleHostname: String
    public let port: Int
    public let pairingToken: String
    public let relayAlsoEnabled: Bool

    public init(
        displayName: String,
        tailscaleHostname: String,
        port: Int = 21731,
        pairingToken: String,
        relayAlsoEnabled: Bool = true
    ) {
        self.displayName = displayName
        self.tailscaleHostname = tailscaleHostname
        self.port = port
        self.pairingToken = pairingToken
        self.relayAlsoEnabled = relayAlsoEnabled
    }
}

/// Pair a VPS / cloud runner that dials outbound relay (R1 1B-b).
public struct PairRelayExecutionHostRequest: Codable, Sendable {
    public let displayName: String
    public let relayUrl: String
    public let sid: String
    public let pairingToken: String
    public let derivedSymmetricKeyBase64URL: String?
    public let sshHostAlias: String?

    public init(
        displayName: String,
        relayUrl: String,
        sid: String,
        pairingToken: String,
        derivedSymmetricKeyBase64URL: String? = nil,
        sshHostAlias: String? = nil
    ) {
        self.displayName = displayName
        self.relayUrl = relayUrl
        self.sid = sid
        self.pairingToken = pairingToken
        self.derivedSymmetricKeyBase64URL = derivedSymmetricKeyBase64URL
        self.sshHostAlias = sshHostAlias
    }
}
