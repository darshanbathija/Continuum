import Foundation
import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class AgentControlServerVendorProvisioningRouteTests: XCTestCase {
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

    private var tempDir: URL!
    private var repoRoot: URL!
    private var server: AgentControlServer!
    private var tmux: TmuxControlClient!
    private var workspace: CodeWorkspaceRecord!
    private var envStore: RepoEnvStore!
    private var launchedCommand: String?
    private var openedURL: URL?

    override func setUp() async throws {
        try await super.setUp()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vendor-provisioning-route-tests-\(UUID().uuidString)", isDirectory: true)
        repoRoot = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

        let sessionsURL = tempDir.appendingPathComponent("sessions.json")
        let workspaceStore = WorkspaceStore(
            storeURL: tempDir.appendingPathComponent("workspaces.json"),
            sessionsURL: sessionsURL
        )
        workspace = CodeWorkspaceRecord(
            projectId: UUID(),
            repoRoot: repoRoot.path,
            repoDisplayName: "vendor-route-repo",
            runtimeCwd: repoRoot.path
        )
        workspaceStore.upsert(workspace)

        envStore = RepoEnvStore(
            storeURL: tempDir.appendingPathComponent("repo-env.json"),
            secrets: FakeSecrets()
        )
        let activeSet = envStore.ensureDefaultSet(workspaceId: workspace.id)
        envStore.setActiveSet(workspaceId: workspace.id, setId: activeSet.id)

        let resolver = RepoEnvRuntimeResolver(workspaceStore: workspaceStore, envStore: envStore)
        let vendorService = VendorProvisioningService(
            workspaceStore: workspaceStore,
            envStore: envStore,
            repoEnvResolver: resolver,
            catalog: [Self.routeVendor],
            pluginDiscovery: {
                [PluginInfo(name: "test-vendor-mcp", kind: .codexMCP, source: "~/.codex/config.toml")]
            },
            openURL: { [weak self] url in
                self?.openedURL = url
                return true
            },
            launchTerminalCommand: { [weak self] command in
                self?.launchedCommand = command
                return VendorProvisioningService.TerminalLaunchResult(
                    launched: true,
                    message: "test terminal launch",
                    windowId: "@vendor",
                    paneId: "%vendor"
                )
            }
        )

        tmux = TmuxControlClient(configuration: .init(socketName: "clawdmeter-vendor-route-\(UUID().uuidString)"))
        let portBase = UInt16(Int.random(in: 30_000...60_000))
        server = AgentControlServer(
            repoIndex: RepoIndex(),
            registry: AgentSessionRegistry(storeURL: sessionsURL),
            tmux: tmux,
            notifications: NotificationDispatcher(),
            chatStoreRegistry: DaemonChatStoreRegistry(resolveURL: { _, _ in nil }),
            chatFileResolver: SessionFileResolver(
                codexSessionsRoot: tempDir.appendingPathComponent("codex-sessions", isDirectory: true),
                geminiTmpRoot: tempDir.appendingPathComponent("gemini-tmp", isDirectory: true),
                resolveClaudeURL: { _ in nil }
            ),
            workspaceStore: workspaceStore,
            repoEnvResolver: resolver,
            vendorProvisioningService: vendorService,
            mobileCommandOutbox: MobileCommandOutbox(),
            listenPortRange: portBase...(portBase + 20),
            writesServerMetadata: false
        )
        server.start()
        XCTAssertNotNil(server.boundPort, "test AgentControlServer must bind an HTTP port")
    }

    override func tearDown() async throws {
        server?.stop()
        await tmux?.stop()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testVendorProvisioningV24RoutesRoundTripThroughHTTP() async throws {
        let vendorsRaw = try await requestRaw(path: "/vendor-provisioning/vendors", method: "GET")
        XCTAssertEqual(vendorsRaw.status, 200)
        let vendors = try decode(VendorProvisioningVendorsResponse.self, from: vendorsRaw.data)
        XCTAssertEqual(vendors.vendors.map(\.id), ["test-vendor"])

        let checkRaw = try await requestRaw(
            path: "/vendor-provisioning/check-device",
            method: "POST",
            body: Data("{}".utf8),
            timeout: 20
        )
        XCTAssertEqual(checkRaw.status, 200)
        let check = try decode(VendorProvisioningCheckResponse.self, from: checkRaw.data)
        let status = try XCTUnwrap(check.statuses.first)
        XCTAssertEqual(status.cliStatus, .notInstalled)
        XCTAssertEqual(status.mcpMatches.map(\.name), ["test-vendor-mcp"])

        let actionRaw = try await postJSON(
            "/vendor-provisioning/vendors/test-vendor/actions",
            VendorProvisioningActionRequest(actionId: "install")
        )
        XCTAssertEqual(actionRaw.status, 200)
        let action = try decode(VendorProvisioningActionResponse.self, from: actionRaw.data)
        XCTAssertTrue(action.launched)
        XCTAssertEqual(action.command, "echo vendor-install")
        XCTAssertEqual(action.terminalWindowId, "@vendor")
        XCTAssertEqual(action.terminalPaneId, "%vendor")
        XCTAssertEqual(launchedCommand, "echo vendor-install")

        let previewRequest = VendorEnvPreviewRequest(
            currentWorkspaceId: workspace.id,
            candidates: [
                VendorEnvCandidate(key: "TEST_VENDOR_TOKEN", value: "route-secret-token")
            ]
        )
        let previewRaw = try await postJSON(
            "/vendor-provisioning/vendors/test-vendor/env/preview",
            previewRequest
        )
        XCTAssertEqual(previewRaw.status, 200)
        XCTAssertFalse(String(data: previewRaw.data, encoding: .utf8)?.contains("route-secret-token") ?? true)
        let preview = try decode(VendorEnvPreviewResponse.self, from: previewRaw.data)
        XCTAssertEqual(preview.previews.first?.key, "TEST_VENDOR_TOKEN")
        XCTAssertEqual(preview.previews.first?.canImport, true)

        let setIds = envStore.sets(for: workspace.id).map { "\"\($0.id.uuidString)\"" }.joined(separator: ",")
        let importBody = Data("""
        {
          "currentWorkspaceId": "\(workspace.id.uuidString)",
          "workspaceIds": ["\(workspace.id.uuidString)"],
          "selectedSetIds": [\(setIds)],
          "candidates": [{"key": "TEST_VENDOR_TOKEN", "value": "route-secret-token"}],
          "conflictStrategy": "skip",
          "kind": "plain"
        }
        """.utf8)
        let importRaw = try await requestRaw(
            path: "/vendor-provisioning/vendors/test-vendor/env/import",
            method: "POST",
            body: importBody
        )
        XCTAssertEqual(importRaw.status, 200)
        XCTAssertFalse(String(data: importRaw.data, encoding: .utf8)?.contains("route-secret-token") ?? true)
        let imported = try decode(VendorEnvImportResponse.self, from: importRaw.data)
        XCTAssertEqual(imported.importedCount, 1)
        XCTAssertEqual(imported.actor, "vendor:test-vendor")
        XCTAssertTrue(imported.materializedCurrentRepo)
        XCTAssertEqual(envStore.variables.first?.kind, .sensitive)
    }

    private static let routeVendor = VendorProvisioningVendor(
        id: "test-vendor",
        displayName: "Test Vendor",
        category: .storageDatabase,
        cliNames: ["definitely-not-installed-vendor-route"],
        mcpAliases: ["test-vendor"],
        signupURL: URL(string: "https://example.test/signup"),
        actions: [
            .init(id: "install", kind: .install, label: "Install CLI", command: "echo vendor-install"),
            .init(id: "authenticate", kind: .authenticate, label: "Authenticate", command: "echo vendor-auth"),
            .init(id: "signup", kind: .signup, label: "Sign up", url: URL(string: "https://example.test/signup")),
        ],
        envTemplates: [
            .init(key: "TEST_VENDOR_TOKEN", label: "Token", kind: .sensitive)
        ]
    )

    private struct RawResponse {
        let status: Int
        let data: Data
    }

    private func postJSON<T: Encodable>(_ path: String, _ body: T) async throws -> RawResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try await requestRaw(path: path, method: "POST", body: try encoder.encode(body))
    }

    private func requestRaw(
        path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval = 8
    ) async throws -> RawResponse {
        let port = try XCTUnwrap(server.boundPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(server.localLoopbackToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var lastError: Error?
        for attempt in 0..<20 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return RawResponse(status: status, data: data)
            } catch {
                lastError = error
                if attempt < 19 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
