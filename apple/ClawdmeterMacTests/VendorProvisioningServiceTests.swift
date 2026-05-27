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

    private func makeService(
        temp: URL,
        catalog: [VendorProvisioningVendor] = VendorProvisioningCatalog.vendors,
        pluginDiscovery: @escaping () -> [PluginInfo] = { [] },
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
            deviceProbe: deviceProbe
        )
    }
}
