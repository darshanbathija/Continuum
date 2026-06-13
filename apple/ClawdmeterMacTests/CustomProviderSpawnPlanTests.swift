import XCTest
@testable import Clawdmeter
import ClawdmeterShared

@MainActor
final class CustomProviderSpawnPlanTests: XCTestCase {
    private final class FakeSecrets: CustomProviderSecretStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        func read(account: String) -> String? { values[account] }
        func write(_ value: String, account: String) -> Bool { values[account] = value; return true }
        func delete(account: String) -> Bool { values.removeValue(forKey: account) != nil }
    }

    private func makeStore(
        kind: CustomProviderKind,
        baseURL: String = "https://deepinfra",
        key: String = "test-key"
    ) throws -> (CustomProviderStore, String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-plan-\(UUID().uuidString).json")
        let secrets = FakeSecrets()
        let store = CustomProviderStore(storeURL: url, secrets: secrets)
        let record = try store.create(
            label: "DeepInfra",
            kind: kind,
            baseURL: baseURL,
            keySource: .keychain,
            apiKey: key
        )
        return (store, record.id)
    }

    func testCodexQuintetAndEnvKey() throws {
        let (store, id) = try makeStore(kind: .openAICompatible)
        let plan = try CustomProviderSpawnPlan.resolve(
            customProviderId: id,
            agent: .codex,
            store: store
        )
        XCTAssertEqual(plan.argvExtras, [
            "-c", "model_providers.\(id).name=DeepInfra",
            "-c", "model_providers.\(id).base_url=https://deepinfra/v1",
            "-c", "model_providers.\(id).env_key=CLAWDMETER_CP_\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY",
            "-c", "model_providers.\(id).wire_api=chat",
            "-c", "model_provider=\(id)",
        ])
        XCTAssertEqual(
            plan.envOverrides["CLAWDMETER_CP_\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"],
            "test-key"
        )
    }

    func testClaudeEnvPair() throws {
        let (store, id) = try makeStore(kind: .anthropicCompatible)
        let plan = try CustomProviderSpawnPlan.resolve(
            customProviderId: id,
            agent: .claude,
            store: store
        )
        XCTAssertTrue(plan.argvExtras.isEmpty)
        XCTAssertEqual(plan.envOverrides["ANTHROPIC_BASE_URL"], "https://deepinfra")
        XCTAssertEqual(plan.envOverrides["ANTHROPIC_AUTH_TOKEN"], "test-key")
    }

    func testSanitizeBypassKeepsCustomAuthToken() throws {
        let base = [
            "ANTHROPIC_API_KEY": "ambient-key",
            "ANTHROPIC_AUTH_TOKEN": "ambient-token",
            "PATH": "/usr/bin",
        ]
        let env = try ClaudeSpawnEnv.sanitizedWithCustomProvider(
            base: base,
            customProviderOverrides: [
                "ANTHROPIC_BASE_URL": "https://gateway.example",
                "ANTHROPIC_AUTH_TOKEN": "custom-token",
            ]
        )
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "custom-token")
        XCTAssertFalse(ClaudeSpawnEnv.leaksAPICredential(env))
    }

    func testMissingCustomBaseURLThrows() {
        XCTAssertThrowsError(
            try ClaudeSpawnEnv.sanitizedWithCustomProvider(
                base: [:],
                customProviderOverrides: ["ANTHROPIC_AUTH_TOKEN": "token"]
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeSpawnEnv.CustomProviderSanitizeError, .missingCustomBaseURL)
        }
    }

    func testRepoEnvAuthTokenStrippedForSubscriptionSpawn() {
        let env = AgentSpawner.claudePtyEnv(extra: ["ANTHROPIC_AUTH_TOKEN": "repo-token"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
    }

    func testCustomModelPassthroughAndNoEffort() {
        let argv = AgentSpawner.claudeArgv(
            model: "my-model-1m",
            effort: .max,
            rawModelPassthrough: true,
            skipEffort: true
        ) ?? []
        XCTAssertTrue(argv.contains("my-model-1m"))
        XCTAssertFalse(argv.contains("--effort"))
        XCTAssertFalse(argv.contains("[1m]"))
    }

    func testResolveErrors() throws {
        let (store, id) = try makeStore(kind: .openAICompatible)
        XCTAssertThrowsError(
            try CustomProviderSpawnPlan.resolve(customProviderId: "missing", agent: .codex, store: store)
        ) { error in
            XCTAssertEqual(
                error as? CustomProviderSpawnPlan.ResolveError,
                .providerNotFound("missing")
            )
        }
        XCTAssertThrowsError(
            try CustomProviderSpawnPlan.resolve(customProviderId: id, agent: .claude, store: store)
        ) { error in
            guard case .runtimeMismatch(expected: .codex, actual: .claude) = error as? CustomProviderSpawnPlan.ResolveError else {
                return XCTFail("expected runtime mismatch")
            }
        }
    }
}
