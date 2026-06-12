import XCTest
@testable import Clawdmeter
import ClawdmeterShared

@MainActor
final class AWSComputeProvisionerTests: XCTestCase {

    private func makeHostStore() throws -> ExecutionHostStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ExecutionHostStore(fileURL: dir.appendingPathComponent("execution-hosts.json"))
    }

    func testValidateCredentialsUsesSTS() async throws {
        let runner = StubShellRunner(results: [
            ShellRunner.Result(
                exitStatus: 0,
                stdout: Data(#"{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/dev"}"#.utf8),
                stderr: Data()
            ),
        ])
        let provisioner = AWSComputeProvisioner(
            hostStore: try makeHostStore(),
            shellRunner: runner,
            awsExecutable: "/usr/bin/aws"
        )
        let health = try await provisioner.validateCredentials()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.accountId, "123456789012")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments.prefix(3), ["sts", "get-caller-identity", "--output"])
    }

    func testProvisionLaunchesSpotInstanceWithUserData() async throws {
        let identity = ShellRunner.Result(
            exitStatus: 0,
            stdout: Data(#"{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/dev"}"#.utf8),
            stderr: Data()
        )
        let launch = ShellRunner.Result(
            exitStatus: 0,
            stdout: Data(#"{"Reservations":[{"Instances":[{"InstanceId":"i-abc123"}]}]}"#.utf8),
            stderr: Data()
        )
        let runner = StubShellRunner(results: [identity, launch])
        let hostStore = try makeHostStore()
        let provisioner = AWSComputeProvisioner(hostStore: hostStore, shellRunner: runner, awsExecutable: "/usr/bin/aws")

        let spec = RunnerSpec(
            region: "us-east-1",
            instanceSize: .small,
            billingMode: .spot,
            displayName: "Test Runner",
            autoStopIdleMinutes: 15
        )
        let host = try await provisioner.provision(spec: spec)
        XCTAssertEqual(host.kind, .byocAWS)
        XCTAssertEqual(host.cloudResourceId, "i-abc123")
        XCTAssertEqual(host.billingMode, ComputeBillingMode.spot.rawValue)
        XCTAssertEqual(host.autoStopIdleMinutes, 15)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        let launchArgs = calls[1].arguments
        XCTAssertTrue(launchArgs.contains("run-instances"))
        XCTAssertTrue(launchArgs.contains("--associate-public-ip-address"))
        XCTAssertTrue(launchArgs.contains("--instance-market-options"))
        XCTAssertTrue(launchArgs.contains("--user-data"))
    }

    func testHealthCheckMapsEC2States() async throws {
        let runner = StubShellRunner(results: [
            ShellRunner.Result(exitStatus: 0, stdout: Data("running\n".utf8), stderr: Data()),
            ShellRunner.Result(exitStatus: 0, stdout: Data("stopped\n".utf8), stderr: Data()),
        ])
        let hostStore = try makeHostStore()
        let provisioner = AWSComputeProvisioner(hostStore: hostStore, shellRunner: runner, awsExecutable: "/usr/bin/aws")
        var host = ExecutionHost(
            id: UUID(),
            displayName: "Runner",
            kind: .byocAWS,
            primaryTransport: .relay,
            health: .healthy,
            cloudResourceId: "i-test"
        )
        let health = try await provisioner.healthCheck(host: host)
        XCTAssertEqual(health, .healthy)

        host.health = .unknown
        let stopped = try await provisioner.healthCheck(host: host)
        XCTAssertEqual(stopped, .unreachable)
    }
}

private actor StubShellRunner: ShellRunning {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let cwd: String?
        let environment: [String: String]?
        let timeout: TimeInterval
    }

    private var results: [ShellRunner.Result]
    private var calls: [Call] = []

    init(results: [ShellRunner.Result] = []) {
        self.results = results
    }

    func enqueue(_ result: ShellRunner.Result) {
        results.append(result)
    }

    func run(
        executable: String,
        arguments: [String],
        cwd: String?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ShellRunner.Result {
        calls.append(Call(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            timeout: timeout
        ))
        if results.isEmpty {
            return ShellRunner.Result(exitStatus: 0, stdout: Data(), stderr: Data())
        }
        return results.removeFirst()
    }

    func recordedCalls() -> [Call] {
        calls
    }
}
