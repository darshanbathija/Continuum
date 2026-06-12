import Foundation
import ClawdmeterShared
import OSLog

private let awsLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AWSCompute")

/// AWS EC2 BYOC provisioner (R2 phase 2A). Uses the local `aws` CLI.
@MainActor
public final class AWSComputeProvisioner: ComputeProvisioner {

    public enum Error: Swift.Error, Equatable {
        case cliMissing
        case credentialsInvalid(String)
        case launchFailed(String)
        case instanceNotFound
    }

    private let hostStore: ExecutionHostStore
    private let shellRunner: ShellRunner

    public init(
        hostStore: ExecutionHostStore = .shared,
        shellRunner: ShellRunner = .shared
    ) {
        self.hostStore = hostStore
        self.shellRunner = shellRunner
    }

    public func validateCredentials() async throws -> ProvisionerHealth {
        guard let aws = ShellRunner.locateBinary("aws") else {
            throw Error.cliMissing
        }
        let profileArgs = awsProfileArgs()
        do {
            let result = try await shellRunner.run(
                executable: aws,
                arguments: profileArgs + ["sts", "get-caller-identity", "--output", "json"],
                timeout: 20
            )
            let data = Data(result.stdoutString.utf8)
            struct Identity: Decodable { let Account: String; let Arn: String }
            if let identity = try? JSONDecoder().decode(Identity.self, from: data) {
                return ProvisionerHealth(
                    ok: true,
                    accountId: identity.Account,
                    accountAlias: identity.Arn,
                    message: "AWS credentials valid"
                )
            }
            return ProvisionerHealth(ok: true, message: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as ShellRunner.ShellError {
            throw Error.credentialsInvalid(error.localizedDescription)
        }
    }

    public func provision(spec: RunnerSpec) async throws -> ExecutionHost {
        _ = try await validateCredentials()
        guard let aws = ShellRunner.locateBinary("aws") else { throw Error.cliMissing }

        let hostId = UUID()
        let instanceType = spec.instanceSize.ec2InstanceType
        let userData = cloudInitUserData(displayName: spec.displayName, hostId: hostId)

        let args = awsProfileArgs(region: spec.region) + [
            "ec2", "run-instances",
            "--image-id", Self.defaultAMI(for: spec.region),
            "--instance-type", instanceType,
            "--count", "1",
            "--tag-specifications", #"ResourceType=instance,Tags=[{Key=Name,Value=clawdmeter-runner-\#(hostId.uuidString.prefix(8))}]"#,
            "--user-data", userData,
            "--output", "json"
        ]
        let result = try await shellRunner.run(executable: aws, arguments: args, timeout: 120)
        struct RunInstances: Decodable {
            struct Reservation: Decodable {
                struct Instance: Decodable { let InstanceId: String }
                let Instances: [Instance]
            }
            let Reservations: [Reservation]
        }
        guard let parsed = try? JSONDecoder().decode(RunInstances.self, from: Data(result.stdoutString.utf8)),
              let instanceId = parsed.Reservations.first?.Instances.first?.InstanceId
        else {
            throw Error.launchFailed(result.stderrString.isEmpty ? result.stdoutString : result.stderrString)
        }

        var host = ExecutionHost(
            id: hostId,
            displayName: spec.displayName,
            kind: .byocAWS,
            primaryTransport: .relay,
            preferredTransports: [.relay],
            health: .provisioning,
            relayAlsoEnabled: true,
            cloudProvider: "aws",
            cloudResourceId: instanceId,
            cloudRegion: spec.region,
            instanceType: instanceType,
            billingMode: spec.billingMode.rawValue,
            autoStopIdleMinutes: spec.autoStopIdleMinutes,
            provisionedAt: Date(),
            daemonWireVersion: AgentControlWireVersion.current
        )
        host = hostStore.upsert(host)
        awsLogger.info("Launched EC2 \(instanceId, privacy: .public) for host \(hostId.uuidString, privacy: .public)")
        return host
    }

    public func start(host: ExecutionHost) async throws {
        guard let instanceId = host.cloudResourceId, let aws = ShellRunner.locateBinary("aws") else {
            throw Error.instanceNotFound
        }
        _ = try await shellRunner.run(
            executable: aws,
            arguments: awsProfileArgs(region: host.cloudRegion) + [
                "ec2", "start-instances", "--instance-ids", instanceId
            ],
            timeout: 60
        )
    }

    public func stop(host: ExecutionHost) async throws {
        guard let instanceId = host.cloudResourceId, let aws = ShellRunner.locateBinary("aws") else {
            throw Error.instanceNotFound
        }
        _ = try await shellRunner.run(
            executable: aws,
            arguments: awsProfileArgs(region: host.cloudRegion) + [
                "ec2", "stop-instances", "--instance-ids", instanceId
            ],
            timeout: 60
        )
    }

    public func deprovision(hostId: UUID) async throws {
        guard let host = hostStore.host(id: hostId),
              let instanceId = host.cloudResourceId,
              let aws = ShellRunner.locateBinary("aws")
        else { throw Error.instanceNotFound }
        _ = try await shellRunner.run(
            executable: aws,
            arguments: awsProfileArgs(region: host.cloudRegion) + [
                "ec2", "terminate-instances", "--instance-ids", instanceId
            ],
            timeout: 60
        )
        _ = hostStore.remove(id: hostId)
        MultiHostRelayStore.shared.remove(hostId: hostId)
    }

    public func healthCheck(host: ExecutionHost) async throws -> ExecutionHostHealth {
        guard let instanceId = host.cloudResourceId, let aws = ShellRunner.locateBinary("aws") else {
            return .unreachable
        }
        let result = try await shellRunner.run(
            executable: aws,
            arguments: awsProfileArgs(region: host.cloudRegion) + [
                "ec2", "describe-instances", "--instance-ids", instanceId,
                "--query", "Reservations[0].Instances[0].State.Name", "--output", "text"
            ],
            timeout: 20
        )
        let state = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case "running": return host.health == .healthy ? .healthy : .unknown
        case "pending", "stopping", "starting": return .provisioning
        case "stopped", "terminated", "shutting-down": return .unreachable
        default: return .unknown
        }
    }

    private func awsProfileArgs(region: String? = nil) -> [String] {
        var args: [String] = []
        if let profile = ProcessInfo.processInfo.environment["AWS_PROFILE"],
           !profile.isEmpty {
            args += ["--profile", profile]
        }
        if let region = region ?? ProcessInfo.processInfo.environment["AWS_REGION"],
           !region.isEmpty {
            args += ["--region", region]
        }
        return args
    }

    private func cloudInitUserData(displayName: String, hostId: UUID) -> String {
        let script = """
        #!/bin/bash
        mkdir -p /etc/clawdmeter
        echo "HOST_DISPLAY_NAME=\(displayName)" >> /etc/clawdmeter/env
        echo "EXECUTION_HOST_ID=\(hostId.uuidString)" >> /etc/clawdmeter/env
        curl -fsSL https://raw.githubusercontent.com/clawdmeter/clawdmeter/main/tools/continuum-agent/install-linux.sh | bash
        """
        return Data(script.utf8).base64EncodedString()
    }

    /// Ubuntu 22.04 ARM64 AMIs (fallback; CloudFormation stack pins region-specific IDs).
    static func defaultAMI(for region: String) -> String {
        switch region {
        case "us-east-1": return "ami-0c7217cdde317cfec"
        case "us-west-2": return "ami-0efce993c3cfc3090"
        case "eu-west-1": return "ami-0905a3c97561e0b69"
        default: return "ami-0c7217cdde317cfec"
        }
    }
}

// MARK: - R2 D12 EC2 idle auto-stop

/// Stops BYOC AWS runners after `autoStopIdleMinutes` with zero active sessions.
@MainActor
public final class AWSCloudIdleMonitor {
    public static let shared = AWSCloudIdleMonitor()

    private var timer: Timer?
    private var provisioner: AWSComputeProvisioner?
    private var sessionsProvider: (() -> [AgentSession])?
    private let tickInterval: TimeInterval

    init(tickInterval: TimeInterval = 60) {
        self.tickInterval = tickInterval
    }

    public func start(
        provisioner: AWSComputeProvisioner,
        sessionsProvider: @escaping () -> [AgentSession]
    ) {
        self.provisioner = provisioner
        self.sessionsProvider = sessionsProvider
        timer?.invalidate()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task { @MainActor in await tick() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick(now: Date = Date()) async {
        guard let provisioner, let sessionsProvider else { return }
        let sessions = sessionsProvider()
        var activeCounts: [UUID: Int] = [:]
        for session in sessions where session.archivedAt == nil && session.status != .done {
            if let hostId = session.executionHostId {
                activeCounts[hostId, default: 0] += 1
            }
        }
        for host in ExecutionHostStore.shared.allHosts() where host.kind == .byocAWS {
            guard let idleMinutes = host.autoStopIdleMinutes, idleMinutes > 0 else { continue }
            let active = activeCounts[host.id, default: 0]
            let lastActivity = AWSCloudIdlePolicy.lastActivityAt(
                sessions: sessions,
                hostId: host.id,
                provisionedAt: host.provisionedAt
            )
            guard AWSCloudIdlePolicy.shouldStopHost(
                now: now,
                autoStopIdleMinutes: idleMinutes,
                activeSessionCount: active,
                lastActivityAt: lastActivity
            ) else { continue }
            do {
                let health = try await provisioner.healthCheck(host: host)
                guard health != .unreachable else { continue }
                try await provisioner.stop(host: host)
                awsLogger.info("Auto-stopped idle EC2 host \(host.id.uuidString, privacy: .public)")
            } catch {
                awsLogger.error("Auto-stop failed for \(host.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Start a stopped EC2 instance and poll until running or timeout (R2 cold start).
    public func ensureRunning(
        host: ExecutionHost,
        provisioner: AWSComputeProvisioner,
        timeout: TimeInterval = 180
    ) async throws {
        guard host.kind == .byocAWS else { return }
        let health = try await provisioner.healthCheck(host: host)
        if health == .unreachable {
            try await provisioner.start(host: host)
        } else {
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let next = try await provisioner.healthCheck(host: host)
            if next != .unreachable && next != .provisioning {
                return
            }
        }
        throw AWSComputeProvisioner.Error.launchFailed("EC2 instance did not reach running state in time")
    }
}
