import Foundation

// MARK: - Tier 2 BYOC compute abstraction (R2 phase 2A)

public enum ComputeBillingMode: String, Codable, Hashable, Sendable, CaseIterable {
    case onDemand
    case spot
}

public enum RunnerInstanceSize: String, Codable, Hashable, Sendable, CaseIterable {
    case small   // t4g.small
    case medium  // t4g.medium

    public var ec2InstanceType: String {
        switch self {
        case .small: return "t4g.small"
        case .medium: return "t4g.medium"
        }
    }

    public var displayName: String {
        switch self {
        case .small: return "Small (2 GB)"
        case .medium: return "Medium (4 GB)"
        }
    }
}

public struct RunnerSpec: Codable, Hashable, Sendable {
    public let region: String
    public let instanceSize: RunnerInstanceSize
    public let billingMode: ComputeBillingMode
    public let displayName: String
    public let agents: [AgentKind]
    public let opencodeEnabled: Bool
    public let autoStopIdleMinutes: Int

    public init(
        region: String,
        instanceSize: RunnerInstanceSize = .small,
        billingMode: ComputeBillingMode = .onDemand,
        displayName: String,
        agents: [AgentKind] = [.claude, .codex],
        opencodeEnabled: Bool = true,
        autoStopIdleMinutes: Int = 30
    ) {
        self.region = region
        self.instanceSize = instanceSize
        self.billingMode = billingMode
        self.displayName = displayName
        self.agents = agents
        self.opencodeEnabled = opencodeEnabled
        self.autoStopIdleMinutes = autoStopIdleMinutes
    }
}

public struct ProvisionerHealth: Codable, Hashable, Sendable {
    public let ok: Bool
    public let accountId: String?
    public let accountAlias: String?
    public let message: String?

    public init(ok: Bool, accountId: String? = nil, accountAlias: String? = nil, message: String? = nil) {
        self.ok = ok
        self.accountId = accountId
        self.accountAlias = accountAlias
        self.message = message
    }
}

public enum CloudProvisionPhase: String, Codable, Sendable {
    case validatingCredentials
    case launching
    case waitingForDaemon
    case healthy
    case failed
}

public struct CloudProvisionStatus: Codable, Hashable, Sendable, Identifiable {
    public let hostId: UUID
    public let phase: CloudProvisionPhase
    public let message: String
    public let instanceId: String?
    public let estimatedHourlyUSD: Double?

    public var id: UUID { hostId }

    public init(
        hostId: UUID,
        phase: CloudProvisionPhase,
        message: String,
        instanceId: String? = nil,
        estimatedHourlyUSD: Double? = nil
    ) {
        self.hostId = hostId
        self.phase = phase
        self.message = message
        self.instanceId = instanceId
        self.estimatedHourlyUSD = estimatedHourlyUSD
    }
}

public struct AWSProvisionRequest: Codable, Sendable {
    public let spec: RunnerSpec
    public let awsProfile: String?
    public let awsRegion: String?

    public init(spec: RunnerSpec, awsProfile: String? = nil, awsRegion: String? = nil) {
        self.spec = spec
        self.awsProfile = awsProfile
        self.awsRegion = awsRegion
    }
}

public struct AWSProvisionResponse: Codable, Sendable {
    public let host: ExecutionHost
    public let status: CloudProvisionStatus

    public init(host: ExecutionHost, status: CloudProvisionStatus) {
        self.host = host
        self.status = status
    }
}

/// BYOC compute provisioner protocol (R2).
public protocol ComputeProvisioner: Sendable {
    func validateCredentials() async throws -> ProvisionerHealth
    func provision(spec: RunnerSpec) async throws -> ExecutionHost
    func start(host: ExecutionHost) async throws
    func stop(host: ExecutionHost) async throws
    func deprovision(hostId: UUID) async throws
    func healthCheck(host: ExecutionHost) async throws -> ExecutionHostHealth
}

// MARK: - R2 D12 idle auto-stop policy

public enum AWSCloudIdlePolicy {
    /// Returns true when an EC2 host has had zero active sessions for longer than its idle threshold.
    public static func shouldStopHost(
        now: Date,
        autoStopIdleMinutes: Int,
        activeSessionCount: Int,
        lastActivityAt: Date?
    ) -> Bool {
        guard activeSessionCount == 0, autoStopIdleMinutes > 0 else { return false }
        guard let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) >= TimeInterval(autoStopIdleMinutes * 60)
    }

    /// Most recent activity timestamp for sessions on a host (falls back to provision time).
    public static func lastActivityAt(
        sessions: [AgentSession],
        hostId: UUID,
        provisionedAt: Date?
    ) -> Date? {
        let hostSessions = sessions.filter { $0.executionHostId == hostId }
        let eventTimes = hostSessions.map(\.lastEventAt)
        if let latest = eventTimes.max() {
            return latest
        }
        return provisionedAt
    }
}
