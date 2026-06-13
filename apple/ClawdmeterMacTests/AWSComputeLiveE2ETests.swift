import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Opt-in live AWS BYOC verification. Provisions a real t4g.small, waits for EC2
/// running state, then terminates. Requires configured AWS CLI credentials.
///
/// Run:
///   CLAWDMETER_AWS_E2E=1 xcodebuild test \
///     -project apple/Clawdmeter.xcodeproj -scheme "Clawdmeter (Mac)" \
///     -destination 'platform=macOS' \
///     -only-testing:ClawdmeterMacTests/AWSComputeLiveE2ETests
@MainActor
final class AWSComputeLiveE2ETests: XCTestCase {

    private var hostStore: ExecutionHostStore?
    private var provisionedHostId: UUID?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CLAWDMETER_AWS_E2E"] == "1" else {
            throw XCTSkip("Set CLAWDMETER_AWS_E2E=1 to run live AWS BYOC tests (creates real EC2).")
        }
        guard ShellRunner.locateBinary("aws") != nil else {
            throw XCTSkip("aws CLI not found on PATH.")
        }
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".continuum-aws-e2e")
        guard FileManager.default.fileExists(atPath: marker) else {
            throw XCTSkip("Create ~/.continuum-aws-e2e after setting CLAWDMETER_AWS_E2E=1 to acknowledge spend.")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aws-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hostStore = ExecutionHostStore(fileURL: dir.appendingPathComponent("execution-hosts.json"))
    }

    override func tearDown() async throws {
        if let hostStore, let hostId = provisionedHostId {
            let provisioner = AWSComputeProvisioner(hostStore: hostStore)
            try? await provisioner.deprovision(hostId: hostId)
        }
        provisionedHostId = nil
        hostStore = nil
    }

    func testValidateCredentialsLive() async throws {
        let hostStore = try XCTUnwrap(hostStore)
        let provisioner = AWSComputeProvisioner(hostStore: hostStore)
        let health = try await provisioner.validateCredentials()
        XCTAssertTrue(health.ok, health.message ?? "expected valid AWS credentials")
        XCTAssertFalse(health.accountId?.isEmpty ?? true)
    }

    func testProvisionStartStopTerminateLive() async throws {
        let hostStore = try XCTUnwrap(hostStore)
        let provisioner = AWSComputeProvisioner(hostStore: hostStore)
        let region = ProcessInfo.processInfo.environment["CLAWDMETER_AWS_REGION"] ?? "us-east-1"
        let spec = RunnerSpec(
            region: region,
            instanceSize: .small,
            billingMode: .onDemand,
            displayName: "E2E Runner \(UUID().uuidString.prefix(8))",
            autoStopIdleMinutes: 30
        )

        let host = try await provisioner.provision(spec: spec)
        provisionedHostId = host.id
        XCTAssertEqual(host.kind, .byocAWS)
        XCTAssertNotNil(host.cloudResourceId)

        let deadline = Date().addingTimeInterval(300)
        var sawRunning = false
        while Date() < deadline {
            let health = try await provisioner.healthCheck(host: host)
            if health == .healthy || health == .unknown {
                sawRunning = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        XCTAssertTrue(sawRunning, "EC2 instance should reach running state within 5 minutes")

        try await provisioner.stop(host: host)
        let stoppedDeadline = Date().addingTimeInterval(180)
        while Date() < stoppedDeadline {
            let health = try await provisioner.healthCheck(host: host)
            if health == .unreachable {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }

        try await provisioner.deprovision(hostId: host.id)
        provisionedHostId = nil
        XCTAssertNil(hostStore.host(id: host.id))
    }
}
