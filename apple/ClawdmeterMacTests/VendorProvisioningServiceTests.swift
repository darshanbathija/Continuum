import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class VendorProvisioningServiceTests: XCTestCase {
    private final class FakeSecrets: RepoEnvSecretStoring, @unchecked Sendable {
        var values: [String: String] = [:]

        func read(account: String) -> String? {
            values[account]
        }

        func write(_ value: String, account: String) -> Bool {
            values[account] = value
            return true
        }

        func delete(account: String) -> Bool {
            values.removeValue(forKey: account)
            return true
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vendor-provisioning-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCatalogCoversRequestedVendorsAndActionCommandsAreAllowlisted() throws {
        let temp = try makeTempDirectory()
        let service = makeService(temp: temp)
        let vendors = VendorProvisioningCatalog.vendors
        let ids = Set(vendors.map(\.id))

        XCTAssertTrue(ids.isSuperset(of: [
            "mongodb-atlas",
            "upstash",
            "supabase",
            "fly",
            "railway",
            "hetzner",
            "aws",
            "gcp",
            "azure",
            "cloudflare",
        ]))

        for vendor in vendors {
            XCTAssertFalse(vendor.cliNames.isEmpty, vendor.id)
            XCTAssertFalse(vendor.envTemplates.isEmpty, vendor.id)
            for action in vendor.actions where action.kind == .install || action.kind == .authenticate {
                let command = try XCTUnwrap(action.command, vendor.id)
                XCTAssertFalse(command.contains("\n"), vendor.id)
                XCTAssertTrue(service.isAllowlisted(command: command, vendor: vendor), "\(vendor.id): \(command)")
            }
        }
    }

    func testDefaultActionLauncherUsesDirectPtyAndReturnsTerminalId() async throws {
        let temp = try makeTempDirectory()
        let vendor = VendorProvisioningVendor(
            id: "pty-vendor",
            displayName: "PTY Vendor",
            category: .computeHosting,
            cliNames: ["pty-vendor"],
            mcpAliases: [],
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: "printf 'VENDOR_READY\\n'")
            ],
            envTemplates: [.init(key: "PTY_VENDOR_TOKEN", label: "Token")]
        )
        let service = makeService(temp: temp, catalog: [vendor])

        let response = try await service.performAction(vendorId: vendor.id, actionId: "install")

        XCTAssertTrue(response.launched)
        XCTAssertEqual(response.message, "Started a direct terminal for this command.")
        XCTAssertNil(response.terminalWindowId)
        let paneId = try XCTUnwrap(response.terminalPaneId)
        addTeardownBlock {
            Task { await TerminalPtyRegistry.shared.kill(id: paneId) }
        }
        let maybeHost = await waitForTerminalHost(id: paneId)
        let host = try XCTUnwrap(maybeHost)
        let sawReady = await waitForOutput(host, contains: "VENDOR_READY")
        XCTAssertTrue(sawReady)
    }

    func testCheckDeviceIncludesMCPMatchesFromFakeAgentConfigs() async throws {
        let temp = try makeTempDirectory()
        let vendor = VendorProvisioningVendor(
            id: "supabase",
            displayName: "Supabase",
            category: .storageDatabase,
            cliNames: ["definitely-not-installed-\(UUID().uuidString)"],
            mcpAliases: ["supabase"],
            actions: [],
            envTemplates: [.init(key: "SUPABASE_URL", label: "Project URL", kind: .plain)]
        )
        let service = makeService(
            temp: temp,
            catalog: [vendor],
            pluginDiscovery: {
                [
                    PluginInfo(name: "supabase", kind: .codexMCP, source: "~/.codex/config.toml"),
                    PluginInfo(name: "other", kind: .claudeMCP, source: "~/.claude/settings.json"),
                ]
            }
        )

        let response = await service.checkDevice()
        let status = try XCTUnwrap(response.statuses.first)

        XCTAssertEqual(status.vendorId, "supabase")
        XCTAssertEqual(status.cliStatus, .notInstalled)
        XCTAssertEqual(status.mcpMatches.map(\.name), ["supabase"])
    }

    func testVendorsNeedingInstallIncludesOnlyMissingOrUncheckedStatuses() throws {
        let vendors = [
            makeVendor(id: "missing", cliName: "missing-cli"),
            makeVendor(id: "installed", cliName: "installed-cli"),
            makeVendor(id: "unchecked", cliName: "unchecked-cli"),
        ]
        let statuses = [
            VendorProvisioningStatus(vendorId: "missing", cliStatus: .notInstalled),
            VendorProvisioningStatus(vendorId: "installed", cliStatus: .installed),
        ]

        let targets = VendorProvisioningService.vendorsNeedingInstall(
            catalog: vendors,
            statuses: statuses
        )

        XCTAssertEqual(Set(targets.map(\.id)), Set(["missing", "unchecked"]))
    }

    func testInstallAllMissingRunsAllowlistedCommandsInBackgroundAndReportsProgress() async throws {
        let temp = try makeTempDirectory()
        let vendors = [
            makeVendor(id: "alpha", cliName: "alpha-cli", installCommand: "printf 'ALPHA_OK\\n'"),
            makeVendor(id: "beta", cliName: "beta-cli", installCommand: "printf 'BETA_OK\\n' && exit 2"),
        ]
        var progress: [VendorInstallProgressUpdate] = []
        let service = makeService(
            temp: temp,
            catalog: vendors,
            runBackgroundInstall: { command in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return ShellRunner.Result(
                    exitStatus: process.terminationStatus,
                    stdout: data,
                    stderr: Data()
                )
            }
        )

        let result = try await service.installAllMissing(
            statuses: [
                VendorProvisioningStatus(vendorId: "alpha", cliStatus: .notInstalled),
                VendorProvisioningStatus(vendorId: "beta", cliStatus: .notInstalled),
            ],
            onProgress: { update in
                progress.append(update)
            }
        )

        XCTAssertEqual(result.succeededVendorIds, ["alpha"])
        XCTAssertEqual(Set(result.failedVendorIds.keys), Set(["beta"]))
        XCTAssertTrue(progress.contains { $0.vendorId == "alpha" && $0.phase == .installing })
        XCTAssertTrue(progress.contains { $0.vendorId == "alpha" && $0.phase == .succeeded })
        XCTAssertTrue(progress.contains { $0.vendorId == "beta" && ifCaseFailed($0.phase) })
        XCTAssertEqual(progress.last?.completedCount, 2)
    }

    func testVendorsNeedingInstallExcludesAuthenticatedAndInstalledStatuses() throws {
        let vendors = [
            makeVendor(id: "missing", cliName: "missing-cli"),
            makeVendor(id: "needs-auth", cliName: "needs-auth-cli"),
            makeVendor(id: "installed", cliName: "installed-cli"),
        ]
        let statuses = [
            VendorProvisioningStatus(vendorId: "missing", cliStatus: .notInstalled),
            VendorProvisioningStatus(vendorId: "needs-auth", cliStatus: .unauthenticated),
            VendorProvisioningStatus(vendorId: "installed", cliStatus: .installed),
        ]

        let targets = VendorProvisioningService.vendorsNeedingInstall(
            catalog: vendors,
            statuses: statuses
        )

        XCTAssertEqual(targets.map(\.id), ["missing"])
    }

    func testInstallAllMissingRespectsVendorScope() async throws {
        let temp = try makeTempDirectory()
        let vendors = [
            makeVendor(id: "alpha", cliName: "alpha-cli", installCommand: "printf 'ALPHA\\n'"),
            makeVendor(id: "beta", cliName: "beta-cli", installCommand: "printf 'BETA\\n'"),
        ]
        var installed: [String] = []
        let service = makeService(
            temp: temp,
            catalog: vendors,
            runBackgroundInstall: { command in
                installed.append(command)
                return ShellRunner.Result(exitStatus: 0, stdout: Data(), stderr: Data())
            }
        )

        _ = try await service.installAllMissing(
            statuses: [
                VendorProvisioningStatus(vendorId: "alpha", cliStatus: .notInstalled),
                VendorProvisioningStatus(vendorId: "beta", cliStatus: .notInstalled),
            ],
            vendors: [vendors[0]]
        )

        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed[0], "printf 'ALPHA\\n'")
    }

    func testInstallTimeoutUsesLongerBudgetForCasks() {
        XCTAssertEqual(
            VendorProvisioningService.installTimeout(for: "brew install --cask google-cloud-sdk"),
            1_800
        )
        XCTAssertEqual(
            VendorProvisioningService.installTimeout(for: "brew install flyctl"),
            900
        )
        XCTAssertEqual(
            VendorProvisioningService.installTimeout(for: "printf ok"),
            600
        )
    }

    func testInstallAllMissingPropagatesCancellation() async throws {
        let temp = try makeTempDirectory()
        let vendor = makeVendor(id: "alpha", cliName: "alpha-cli")
        let service = makeService(
            temp: temp,
            catalog: [vendor],
            runBackgroundInstall: { _ in
                throw CancellationError()
            }
        )

        do {
            _ = try await service.installAllMissing(
                statuses: [VendorProvisioningStatus(vendorId: vendor.id, cliStatus: .notInstalled)]
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        }
    }

    func testInstallAllMissingThrowsWhenNothingNeedsInstallation() async throws {
        let temp = try makeTempDirectory()
        let vendor = makeVendor(id: "ready", cliName: "ready-cli")
        let service = makeService(temp: temp, catalog: [vendor])

        do {
            _ = try await service.installAllMissing(
                statuses: [VendorProvisioningStatus(vendorId: vendor.id, cliStatus: .authenticated)]
            )
            XCTFail("Expected noInstallTargets")
        } catch VendorProvisioningError.noInstallTargets {
            // A pattern `catch` doesn't bind `error`; reference the case directly.
            XCTAssertEqual(
                VendorProvisioningError.noInstallTargets.localizedDescription,
                "No vendor CLIs need installation."
            )
        }
    }

    func testCheckDeviceRunsVendorProbesConcurrently() async throws {
        let temp = try makeTempDirectory()
        let vendors = (0..<4).map { index in
            VendorProvisioningVendor(
                id: "vendor-\(index)",
                displayName: "Vendor \(index)",
                category: .computeHosting,
                cliNames: ["vendor-\(index)"],
                mcpAliases: [],
                actions: [],
                envTemplates: [.init(key: "VENDOR_\(index)_TOKEN", label: "Token")]
            )
        }
        let service = makeService(
            temp: temp,
            catalog: vendors,
            deviceProbe: { vendor, _ in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return VendorProvisioningStatus(vendorId: vendor.id, cliStatus: .installed)
            }
        )

        let startedAt = Date()
        let response = await service.checkDevice()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(response.statuses.map(\.vendorId), vendors.map(\.id))
        XCTAssertLessThan(elapsed, 0.65, "Check Device should not serialize every vendor probe.")
    }

    func testEnvImportUsesRepoEnvStoreForAllReposWithoutPersistingSecretsInJSON() throws {
        let temp = try makeTempDirectory()
        let repoA = temp.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = temp.appendingPathComponent("repo-b", isDirectory: true)
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)

        let workspaces = WorkspaceStore(
            storeURL: temp.appendingPathComponent("workspaces.json"),
            sessionsURL: temp.appendingPathComponent("sessions.json")
        )
        let workspaceA = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: repoA.path,
            repoDisplayName: "repo-a",
            runtimeCwd: repoA.path
        )
        let workspaceB = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: repoB.path,
            repoDisplayName: "repo-b",
            runtimeCwd: repoB.path
        )
        workspaces.upsert(workspaceA)
        workspaces.upsert(workspaceB)

        let secrets = FakeSecrets()
        let storeURL = temp.appendingPathComponent("repo-env.json")
        let envStore = RepoEnvStore(storeURL: storeURL, secrets: secrets)
        let activeSet = envStore.ensureDefaultSet(workspaceId: workspaceA.id)
        let resolver = RepoEnvRuntimeResolver(workspaceStore: workspaces, envStore: envStore)
        let service = VendorProvisioningService(
            workspaceStore: workspaces,
            envStore: envStore,
            repoEnvResolver: resolver,
            catalog: VendorProvisioningCatalog.vendors,
            pluginDiscovery: { [] }
        )

        let response = try service.importEnv(
            vendorId: "supabase",
            request: VendorEnvImportRequest(
                currentWorkspaceId: workspaceA.id,
                workspaceIds: [workspaceA.id, workspaceB.id],
                selectedSetIds: [activeSet.id],
                candidates: [
                    VendorEnvCandidate(key: "SUPABASE_URL", value: "https://example.supabase.co"),
                    VendorEnvCandidate(key: "SUPABASE_ANON_KEY", value: "anon-secret-value"),
                ],
                conflictStrategy: .skip
            )
        )

        XCTAssertEqual(response.vendorId, "supabase")
        XCTAssertEqual(response.importedCount, 2)
        XCTAssertEqual(Set(response.workspaceIds), Set([workspaceA.id, workspaceB.id]))
        XCTAssertTrue(response.materializedCurrentRepo)

        let variables = envStore.variables.sorted { $0.key < $1.key }
        XCTAssertEqual(variables.map(\.key), ["SUPABASE_ANON_KEY", "SUPABASE_URL"])
        XCTAssertEqual(Set(variables.map(\.kind)), [.sensitive])
        XCTAssertEqual(variables.map(\.createdBy), ["vendor:supabase", "vendor:supabase"])
        XCTAssertEqual(envStore.assignedWorkspaceIds(variableId: variables[0].id), Set([workspaceA.id, workspaceB.id]))
        XCTAssertEqual(secrets.values.values.sorted(), ["anon-secret-value", "https://example.supabase.co"])

        let metadataJSON = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(metadataJSON.contains("SUPABASE_ANON_KEY"))
        XCTAssertFalse(metadataJSON.contains("anon-secret-value"))
        XCTAssertFalse(metadataJSON.contains("https://example.supabase.co"))

        let envLocal = try String(contentsOf: repoA.appendingPathComponent(".env.local"), encoding: .utf8)
        XCTAssertTrue(envLocal.contains("SUPABASE_ANON_KEY"))
        XCTAssertTrue(envLocal.contains(RepoEnvFileMaterializer.beginMarker))
    }

    func testEnvPreviewUsesAllSelectedReposForDuplicateDetection() throws {
        let temp = try makeTempDirectory()
        let repoA = temp.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = temp.appendingPathComponent("repo-b", isDirectory: true)
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)

        let workspaces = WorkspaceStore(
            storeURL: temp.appendingPathComponent("workspaces.json"),
            sessionsURL: temp.appendingPathComponent("sessions.json")
        )
        let workspaceA = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: repoA.path,
            repoDisplayName: "repo-a",
            runtimeCwd: repoA.path
        )
        let workspaceB = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: repoB.path,
            repoDisplayName: "repo-b",
            runtimeCwd: repoB.path
        )
        workspaces.upsert(workspaceA)
        workspaces.upsert(workspaceB)

        let envStore = RepoEnvStore(
            storeURL: temp.appendingPathComponent("repo-env.json"),
            secrets: FakeSecrets()
        )
        _ = try envStore.createVariable(
            key: "SUPABASE_URL",
            value: "https://existing.supabase.co",
            workspaceIds: [workspaceB.id],
            kind: .sensitive
        )
        let service = VendorProvisioningService(
            workspaceStore: workspaces,
            envStore: envStore,
            repoEnvResolver: RepoEnvRuntimeResolver(workspaceStore: workspaces, envStore: envStore),
            catalog: VendorProvisioningCatalog.vendors,
            pluginDiscovery: { [] }
        )

        let response = try service.previewEnv(
            vendorId: "supabase",
            request: VendorEnvPreviewRequest(
                currentWorkspaceId: workspaceA.id,
                workspaceIds: [workspaceA.id, workspaceB.id],
                candidates: [
                    VendorEnvCandidate(key: "SUPABASE_URL", value: "https://new.supabase.co")
                ]
            )
        )

        XCTAssertEqual(response.previews.first?.status, "duplicate")
        XCTAssertEqual(response.previews.first?.canImport, true)
        XCTAssertTrue(response.previews.first?.message.contains("selected repo targets") == true)
    }

    private func makeVendor(
        id: String,
        cliName: String,
        installCommand: String = "printf 'installed\\n'"
    ) -> VendorProvisioningVendor {
        VendorProvisioningVendor(
            id: id,
            displayName: id,
            category: .computeHosting,
            cliNames: [cliName],
            mcpAliases: [],
            actions: [
                .init(id: "install", kind: .install, label: "Install CLI", command: installCommand)
            ],
            envTemplates: [.init(key: "\(id.uppercased())_TOKEN", label: "Token")]
        )
    }

    private func ifCaseFailed(_ phase: VendorInstallProgressUpdate.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func makeService(
        temp: URL,
        catalog: [VendorProvisioningVendor] = VendorProvisioningCatalog.vendors,
        pluginDiscovery: @escaping () -> [PluginInfo] = { [] },
        runBackgroundInstall: ((String) async throws -> ShellRunner.Result)? = nil,
        deviceProbe: ((VendorProvisioningVendor, [PluginInfo]) async -> VendorProvisioningStatus)? = nil
    ) -> VendorProvisioningService {
        let workspaceStore = WorkspaceStore(
            storeURL: temp.appendingPathComponent("workspaces.json"),
            sessionsURL: temp.appendingPathComponent("sessions.json")
        )
        let envStore = RepoEnvStore(
            storeURL: temp.appendingPathComponent("repo-env.json"),
            secrets: FakeSecrets()
        )
        return VendorProvisioningService(
            workspaceStore: workspaceStore,
            envStore: envStore,
            repoEnvResolver: RepoEnvRuntimeResolver(workspaceStore: workspaceStore, envStore: envStore),
            catalog: catalog,
            pluginDiscovery: pluginDiscovery,
            runBackgroundInstall: runBackgroundInstall,
            deviceProbe: deviceProbe
        )
    }

    private func waitForTerminalHost(id: String, timeout: TimeInterval = 4) async -> TerminalPtyHost? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let host = await TerminalPtyRegistry.shared.host(id: id) {
                return host
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await TerminalPtyRegistry.shared.host(id: id)
    }

    private func waitForOutput(
        _ host: TerminalPtyHost,
        contains needle: String,
        timeout: TimeInterval = 4
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let output = String(data: await host.snapshot(), encoding: .utf8) ?? ""
            if output.contains(needle) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let output = String(data: await host.snapshot(), encoding: .utf8) ?? ""
        return output.contains(needle)
    }
}
