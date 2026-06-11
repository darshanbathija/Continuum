import XCTest
@testable import Clawdmeter

final class RepoEnvVendorSecretsImporterTests: XCTestCase {
    // Inject binary resolution so tests don't depend on which CLIs are on the host PATH.
    // Default: every CLI "resolves" to /usr/local/bin/<name>.
    private func makeImporter(
        locateBinary: @escaping @Sendable (String) -> String? = { "/usr/local/bin/\($0)" },
        handler: @escaping @Sendable (String, [String], String?, [String: String]?, TimeInterval) async throws -> ShellRunner.Result
    ) -> RepoEnvVendorSecretsImporter {
        RepoEnvVendorSecretsImporter(shellRun: handler, locateBinary: locateBinary)
    }

    private func result(stdout: String, stderr: String = "", exitStatus: Int32 = 0) -> ShellRunner.Result {
        ShellRunner.Result(
            exitStatus: exitStatus,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8)
        )
    }

    func testEnvKeyNormalizesSecretNames() {
        XCTAssertEqual(RepoEnvVendorSecretsImporter.envKey(fromSecretName: "prod/database-url"), "PROD_DATABASE_URL")
        XCTAssertEqual(RepoEnvVendorSecretsImporter.envKey(fromSecretName: "my.secret"), "MY_SECRET")
    }

    func testEnvLinesExpandsJSONSecretPayload() {
        let lines = RepoEnvVendorSecretsImporter.envLines(
            fromSecretName: "app/config",
            secretString: #"{"API_TOKEN":"abc123","DEBUG":"true"}"#
        )
        XCTAssertEqual(lines, ["API_TOKEN=abc123", "DEBUG=true"])
    }

    func testEnvLinesUsesSecretNameForPlainString() {
        let lines = RepoEnvVendorSecretsImporter.envLines(
            fromSecretName: "database/password",
            secretString: "super-secret"
        )
        XCTAssertEqual(lines, ["DATABASE_PASSWORD=super-secret"])
    }

    func testEnvLinesEncodesJSONBooleansAsTrueFalse() {
        let lines = RepoEnvVendorSecretsImporter.envLines(
            fromSecretName: "app/config",
            secretString: #"{"FLAG":true,"OFF":false,"NUM":3}"#
        )
        // Booleans must render true/false (not 1/0); numbers keep their string form.
        XCTAssertEqual(lines, ["FLAG=true", "NUM=3", "OFF=false"])
    }

    func testEnvLinesDropsInvalidJSONKeysAndEmptyValues() {
        let lines = RepoEnvVendorSecretsImporter.envLines(
            fromSecretName: "app/config",
            secretString: #"{"VALID":"x","1BAD":"y","HAS-DASH":"z","BLANK":"  "}"#
        )
        XCTAssertEqual(lines, ["VALID=x"])
    }

    func testDedupedByKeyKeepsLastOccurrence() {
        XCTAssertEqual(
            RepoEnvVendorSecretsImporter.dedupedByKey(["A=1", "B=2", "A=3"]),
            ["A=3", "B=2"]
        )
    }

    func testFetchAWSSecretsBuildsEnvTextWithProgress() async throws {
        let importer = makeImporter { executable, arguments, _, _, _ in
            XCTAssertEqual(executable, "/usr/local/bin/aws")
            if arguments.contains("list-secrets") {
                return self.result(stdout: """
                {"SecretList":[{"Name":"prod/api-key"},{"Name":"prod/db-url"}]}
                """)
            }
            if arguments.contains("get-secret-value") {
                let secretIdIndex = arguments.firstIndex(of: "--secret-id")
                let secretId = arguments[secretIdIndex! + 1]
                switch secretId {
                case "prod/api-key":
                    return self.result(stdout: #"{"SecretString":"token-value"}"#)
                case "prod/db-url":
                    return self.result(stdout: #"{"SecretString":"postgres://example"}"#)
                default:
                    XCTFail("Unexpected secret id \(secretId)")
                    return self.result(stdout: "", exitStatus: 1)
                }
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        var progressUpdates: [RepoEnvVendorImportProgress] = []
        let fetch = try await importer.fetchSecrets(
            source: .aws,
            options: RepoEnvVendorImportOptions(awsRegion: "us-east-1")
        ) { progress in
            progressUpdates.append(progress)
        }

        XCTAssertEqual(fetch.secretCount, 2)
        XCTAssertEqual(fetch.variableCount, 2)
        XCTAssertEqual(fetch.sourceLabel, "AWS Secrets Manager")
        XCTAssertTrue(fetch.envText.contains("PROD_API_KEY=token-value"))
        XCTAssertTrue(fetch.envText.contains("PROD_DB_URL=postgres://example"))
        XCTAssertTrue(progressUpdates.contains(where: {
            if case .fetching(let current, let total, _) = $0.phase {
                return current == 1 && total == 2
            }
            return false
        }))
        XCTAssertFalse(progressUpdates.contains(where: {
            if case .complete = $0.phase { return true }
            return false
        }))
    }

    func testFetchAWSSecretsCountsExpandedJSONVariables() async throws {
        let importer = makeImporter { _, arguments, _, _, _ in
            if arguments.contains("list-secrets") {
                return self.result(stdout: #"{"SecretList":[{"Name":"app/config"}]}"#)
            }
            if arguments.contains("get-secret-value") {
                return self.result(stdout: #"{"SecretString":"{\"API_TOKEN\":\"abc123\",\"DEBUG\":\"true\"}"}"#)
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        let fetch = try await importer.fetchSecrets(source: .aws, options: .init())
        XCTAssertEqual(fetch.secretCount, 1)
        XCTAssertEqual(fetch.variableCount, 2)
    }

    func testFetchAWSSecretsSkipsUnreadableSecretAndContinues() async throws {
        let importer = makeImporter { _, arguments, _, _, _ in
            if arguments.contains("list-secrets") {
                return self.result(stdout: #"{"SecretList":[{"Name":"good"},{"Name":"bad"}]}"#)
            }
            if arguments.contains("get-secret-value") {
                let idx = arguments.firstIndex(of: "--secret-id")!
                switch arguments[idx + 1] {
                case "good":
                    return self.result(stdout: #"{"SecretString":"value"}"#)
                default:
                    // Simulate an IAM denial — must skip, not abort the whole batch.
                    return self.result(stdout: "", stderr: "AccessDeniedException", exitStatus: 1)
                }
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        let fetch = try await importer.fetchSecrets(source: .aws, options: .init())
        XCTAssertTrue(fetch.envText.contains("GOOD=value"))
        XCTAssertEqual(fetch.skippedSecretNames, ["bad"])
        XCTAssertEqual(fetch.variableCount, 1)
        XCTAssertEqual(fetch.secretCount, 1)
    }

    func testFetchAWSSecretDecodesBinaryUTF8Payload() async throws {
        let payload = Data("binary-secret".utf8).base64EncodedString()
        let importer = makeImporter { _, arguments, _, _, _ in
            if arguments.contains("list-secrets") {
                return self.result(stdout: #"{"SecretList":[{"Name":"binary-secret"}]}"#)
            }
            if arguments.contains("get-secret-value") {
                return self.result(stdout: #"{"SecretBinary":"\#(payload)"}"#)
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        let fetch = try await importer.fetchSecrets(source: .aws, options: .init())
        XCTAssertTrue(fetch.envText.contains("BINARY_SECRET=binary-secret"))
    }

    func testFetchAWSSecretSkipsNonUTF8BinaryPayload() async throws {
        let bytes: [UInt8] = [0xFF, 0xFE, 0xFD]
        let payload = Data(bytes).base64EncodedString()
        let importer = makeImporter { _, arguments, _, _, _ in
            if arguments.contains("list-secrets") {
                return self.result(stdout: #"{"SecretList":[{"Name":"good"},{"Name":"binary-secret"}]}"#)
            }
            if arguments.contains("get-secret-value") {
                let idx = arguments.firstIndex(of: "--secret-id")!
                switch arguments[idx + 1] {
                case "good":
                    return self.result(stdout: #"{"SecretString":"value"}"#)
                default:
                    // Non-UTF-8 binary: skipped, not fatal to the rest of the batch.
                    return self.result(stdout: #"{"SecretBinary":"\#(payload)"}"#)
                }
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        let fetch = try await importer.fetchSecrets(source: .aws, options: .init())
        XCTAssertTrue(fetch.envText.contains("GOOD=value"))
        XCTAssertEqual(fetch.skippedSecretNames, ["binary-secret"])
    }

    func testFetchVercelSecretsUsesRepoRootAndPullCommand() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vercel-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let importer = makeImporter { executable, arguments, cwd, _, _ in
            XCTAssertEqual(executable, "/usr/local/bin/vercel")
            XCTAssertEqual(cwd, tempRoot.path)
            XCTAssertEqual(Array(arguments.prefix(2)), ["env", "pull"])
            XCTAssertTrue(arguments.contains("--environment"))
            XCTAssertTrue(arguments.contains("production"))
            let outputPath = arguments[2]
            try "API_TOKEN=from-vercel\n".write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
            return self.result(stdout: "Downloaded env\n")
        }

        let fetch = try await importer.fetchSecrets(
            source: .vercel,
            options: RepoEnvVendorImportOptions(
                vercelEnvironment: .production,
                repoRoot: tempRoot.path
            )
        )

        XCTAssertEqual(fetch.sourceLabel, "Vercel (Production)")
        XCTAssertTrue(fetch.envText.contains("API_TOKEN=from-vercel"))
        XCTAssertEqual(fetch.variableCount, 1)
    }

    func testFetchGCPSecretsBuildsEnvText() async throws {
        let importer = makeImporter { executable, arguments, _, _, _ in
            XCTAssertEqual(executable, "/usr/local/bin/gcloud")
            if arguments.contains("list") {
                return self.result(stdout: """
                [{"name":"projects/demo/secrets/API_TOKEN"}]
                """)
            }
            if arguments.contains("access") {
                return self.result(stdout: "gcp-secret-value")
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        let fetch = try await importer.fetchSecrets(
            source: .gcp,
            options: RepoEnvVendorImportOptions(gcpProject: "demo")
        )

        XCTAssertEqual(fetch.secretCount, 1)
        XCTAssertEqual(fetch.variableCount, 1)
        XCTAssertTrue(fetch.envText.contains("API_TOKEN=gcp-secret-value"))
    }

    func testFetchGCPSecretsReturnsAllSecretsInSingleCall() async throws {
        // gcloud secrets list --format=json returns every secret in one call. The importer
        // must NOT pass --limit/--page-token (no such resumable flag exists; --limit caps
        // the result). A >100-secret account must come back whole in one list call.
        var listCalls = 0
        let allSecrets = (1...150).map { #"{"name":"projects/demo/secrets/SECRET_\#($0)"}"# }.joined(separator: ",")
        let importer = makeImporter { _, arguments, _, _, _ in
            if arguments.contains("list") {
                listCalls += 1
                XCTAssertFalse(arguments.contains { $0.hasPrefix("--limit") })
                XCTAssertFalse(arguments.contains("--page-token"))
                XCTAssertTrue(arguments.contains("--project"))
                XCTAssertTrue(arguments.contains("demo"))
                return self.result(stdout: "[\(allSecrets)]")
            }
            if arguments.contains("access") {
                return self.result(stdout: "value")
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        let fetch = try await importer.fetchSecrets(
            source: .gcp,
            options: RepoEnvVendorImportOptions(gcpProject: "demo")
        )

        XCTAssertEqual(listCalls, 1)
        XCTAssertEqual(fetch.secretCount, 150)
        XCTAssertEqual(fetch.variableCount, 150)
    }

    func testFetchGCPSecretSkipsNonUTF8Value() async throws {
        let nonUTF8 = Data([0xFF, 0xFE, 0xFD])
        let importer = makeImporter { _, arguments, _, _, _ in
            if arguments.contains("list") {
                return self.result(stdout: #"[{"name":"projects/demo/secrets/GOOD"},{"name":"projects/demo/secrets/BINARY"}]"#)
            }
            if arguments.contains("access") {
                let idx = arguments.firstIndex(of: "--secret")!
                if arguments[idx + 1] == "GOOD" {
                    return self.result(stdout: "value")
                }
                // gcloud emits raw bytes; a non-UTF-8 secret must be skipped, not corrupted.
                return ShellRunner.Result(exitStatus: 0, stdout: nonUTF8, stderr: Data())
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        let fetch = try await importer.fetchSecrets(
            source: .gcp,
            options: RepoEnvVendorImportOptions(gcpProject: "demo")
        )
        XCTAssertTrue(fetch.envText.contains("GOOD=value"))
        XCTAssertEqual(fetch.skippedSecretNames, ["BINARY"])
    }

    func testFetchRequiresCLIBinary() async {
        let importer = makeImporter(locateBinary: { _ in nil }) { _, _, _, _, _ in
            self.result(stdout: "")
        }

        do {
            _ = try await importer.fetchSecrets(source: .aws, options: .init())
            XCTFail("Expected missing CLI error")
        } catch let error as RepoEnvVendorSecretsImportError {
            XCTAssertEqual(error, .cliNotInstalled("aws"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testFetchVercelRequiresRepoRoot() async {
        let importer = makeImporter { _, _, _, _, _ in
            self.result(stdout: "")
        }

        do {
            _ = try await importer.fetchSecrets(source: .vercel, options: .init())
            XCTFail("Expected repo root error")
        } catch let error as RepoEnvVendorSecretsImportError {
            XCTAssertEqual(error, .repoRootRequired)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testFetchAWSSecretsHonorsCancellation() async {
        let importer = makeImporter { _, arguments, _, _, _ in
            if arguments.contains("list-secrets") {
                return self.result(stdout: """
                {"SecretList":[{"Name":"one"},{"Name":"two"},{"Name":"three"}]}
                """)
            }
            if arguments.contains("get-secret-value") {
                return self.result(stdout: #"{"SecretString":"value"}"#)
            }
            XCTFail("Unexpected command: \(arguments)")
            return self.result(stdout: "", exitStatus: 1)
        }

        let task = Task {
            try await importer.fetchSecrets(source: .aws, options: .init()) { _ in }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}
