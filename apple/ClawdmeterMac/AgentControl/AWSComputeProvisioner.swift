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
    private let shellRunner: any ShellRunning
    private let awsExecutableOverride: String?

    init(
        hostStore: ExecutionHostStore = .shared,
        shellRunner: (any ShellRunning)? = nil,
        awsExecutable: String? = nil
    ) {
        self.hostStore = hostStore
        self.shellRunner = shellRunner ?? ShellRunner.shared
        self.awsExecutableOverride = awsExecutable
    }

    private func resolvedAWSCLI() throws -> String {
        if let awsExecutableOverride, !awsExecutableOverride.isEmpty {
            return awsExecutableOverride
        }
        guard let aws = ShellRunner.locateBinary("aws") else {
            throw Error.cliMissing
        }
        return aws
    }

    public func validateCredentials() async throws -> ProvisionerHealth {
        guard let aws = try? resolvedAWSCLI() else {
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
        // Defense-in-depth: reject a malformed displayName at the request
        // boundary before it reaches the root-executed cloud-init heredoc.
        // (The daemon wire handler validates too; this covers direct callers.)
        guard Self.isValidDisplayName(spec.displayName) else {
            throw Error.launchFailed("Invalid display name. Allowed: letters, digits, space, and _.- (1–64 chars).")
        }
        _ = try await validateCredentials()
        let aws = try resolvedAWSCLI()

        let hostId = UUID()
        let instanceType = spec.instanceSize.ec2InstanceType

        // C fix: write the RAW (un-encoded) bash user-data to a temp file and
        // pass `fileb://`. The AWS CLI base64-encodes `--user-data` itself, so
        // handing it a pre-base64'd blob double-encodes and EC2 runs garbage.
        // `fileb://` reads the file bytes verbatim and the CLI encodes once.
        let rawUserData = cloudInitUserData(displayName: spec.displayName, hostId: hostId)
        let userDataFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-userdata-\(hostId.uuidString).sh")
        try Data(rawUserData.utf8).write(to: userDataFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: userDataFile) }

        var args = awsProfileArgs(region: spec.region) + [
            "ec2", "run-instances",
            "--image-id", try Self.ami(for: spec.region),
            "--instance-type", instanceType,
            "--count", "1",
            "--associate-public-ip-address",
            "--tag-specifications", #"ResourceType=instance,Tags=[{Key=Name,Value=clawdmeter-runner-\#(hostId.uuidString.prefix(8))}]"#,
            "--user-data", "fileb://\(userDataFile.path)",
            "--output", "json"
        ]
        if spec.billingMode == .spot {
            args += [
                "--instance-market-options",
                #"MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}"#
            ]
        }
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
        guard let instanceId = host.cloudResourceId else {
            throw Error.instanceNotFound
        }
        let aws = try resolvedAWSCLI()
        _ = try await shellRunner.run(
            executable: aws,
            arguments: awsProfileArgs(region: host.cloudRegion) + [
                "ec2", "start-instances", "--instance-ids", instanceId
            ],
            timeout: 60
        )
    }

    public func stop(host: ExecutionHost) async throws {
        guard let instanceId = host.cloudResourceId else {
            throw Error.instanceNotFound
        }
        let aws = try resolvedAWSCLI()
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
              let instanceId = host.cloudResourceId
        else { throw Error.instanceNotFound }
        let aws = try resolvedAWSCLI()
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
        guard let instanceId = host.cloudResourceId else {
            return .unreachable
        }
        guard let aws = try? resolvedAWSCLI() else {
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

    /// Validate a display name against the cloud-init-safe character set.
    /// Used both here (defense-in-depth) and at the daemon wire boundary.
    static func isValidDisplayName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func cloudInitUserData(displayName: String, hostId: UUID) -> String {
        // A fix: `displayName` is interpolated into a root-executed user-data
        // heredoc. A raw newline + `ENVEOF` would terminate the heredoc early
        // and let an attacker inject arbitrary root shell. Strip to a safe set
        // and cap length so the value can never escape the heredoc body.
        let safeName = displayName.unicodeScalars
            .filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.-").contains($0) }
            .prefix(64)
        let sanitizedDisplayName = String(String.UnicodeScalarView(safeName))

        let installURL = ProcessInfo.processInfo.environment["CLAWDMETER_CONTINUUM_INSTALL_URL"]
            ?? "https://raw.githubusercontent.com/clawdmeter/clawdmeter/main/tools/continuum-agent/install-linux.sh"
        let binaryURL = ProcessInfo.processInfo.environment["CLAWDMETER_CONTINUUM_BINARY_URL"] ?? ""
        let binaryExport = binaryURL.isEmpty
            ? ""
            : "export CONTINUUM_AGENT_BINARY_URL=\"\(binaryURL)\"\n"
        let script = """
        #!/bin/bash
        set -euo pipefail
        mkdir -p /etc/clawdmeter
        cat > /etc/clawdmeter/env <<'ENVEOF'
        HOST_DISPLAY_NAME=\(sanitizedDisplayName)
        EXECUTION_HOST_ID=\(hostId.uuidString)
        CLAWDMETER_HOST_KIND=byocAWS
        ENVEOF
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl ca-certificates golang-go
        \(binaryExport)curl -fsSL "\(installURL)" | bash
        """
        // Return the RAW bash. The caller passes it via `fileb://`; the AWS
        // CLI does the single base64 encode of `--user-data`. Do NOT encode here.
        return script
    }

    // SECURITY/CORRECTNESS TODO: these are PLACEHOLDER AMI IDs. The instance
    // family is t4g.* (ARM64 / Graviton), so the AMI MUST be arm64 Ubuntu 22.04
    // or every launch fails (the prior x86_64 IDs silently mismatched the arch).
    // Fill in the real current per-region arm64 AMIs before the AWS BYOC path is
    // used, e.g.:
    //   aws ec2 describe-images --owners 099720109477 \
    //     --filters Name=architecture,Values=arm64 \
    //       Name=name,Values='ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*' \
    //     --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text --region <region>
    // Unknown regions now correctly THROW instead of silently falling back to us-east-1.
    static func ami(for region: String) throws -> String {
        switch region {
        case "us-east-1": return "ami-0a0c8eebcdd6dcbd0"
        case "us-west-2": return "ami-0c79a55dda52434da"
        case "eu-west-1": return "ami-0e2f1c0a1b2c3d4e5"
        default:
            throw Error.launchFailed("Unsupported region \(region). Supported: us-east-1, us-west-2, eu-west-1.")
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
