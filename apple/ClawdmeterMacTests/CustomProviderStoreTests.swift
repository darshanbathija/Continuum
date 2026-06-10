import XCTest
@testable import Clawdmeter

@MainActor
final class CustomProviderStoreTests: XCTestCase {
    private final class FakeSecrets: CustomProviderSecretStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        var writeSucceeds = true
        var deleteSucceeds = true

        func read(account: String) -> String? { values[account] }
        func write(_ value: String, account: String) -> Bool {
            guard writeSucceeds else { return false }
            values[account] = value
            return true
        }
        func delete(account: String) -> Bool {
            guard deleteSucceeds else { return false }
            values.removeValue(forKey: account)
            return true
        }
    }

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-provider-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("custom-providers.json")
    }

    func testNormalizeBaseURLMatrix() throws {
        XCTAssertEqual(
            try CustomProviderStore.normalizeBaseURL("api.example.com"),
            "https://api.example.com"
        )
        XCTAssertEqual(
            try CustomProviderStore.normalizeBaseURL("https://api.example.com/"),
            "https://api.example.com"
        )
        XCTAssertEqual(
            try CustomProviderStore.normalizeBaseURL("http://api.example.com/v1/"),
            "https://api.example.com"
        )
        XCTAssertEqual(
            try CustomProviderStore.normalizeBaseURL("https://gateway.test/v1"),
            "https://gateway.test"
        )
    }

    func testMintIdAvoidsReservedAndCollisions() {
        let existing: Set<String> = ["claude", "api-example-com"]
        let first = CustomProviderStore.mintId(from: "https://api.example.com", existingIds: existing)
        XCTAssertEqual(first, "api-example-com-2")

        let second = CustomProviderStore.mintId(from: "https://api.example.com", existingIds: existing.union([first]))
        XCTAssertEqual(second, "api-example-com-3")
        XCTAssertEqual(CustomProviderStore.mintId(from: "https://codex", existingIds: []), "codex-2")
    }

    func testCreateWritesKeyBeforeAppend() throws {
        let secrets = FakeSecrets()
        let url = storeURL()
        let store = CustomProviderStore(storeURL: url, secrets: secrets)
        let record = try store.create(
            label: "DeepInfra",
            kind: .openAICompatible,
            baseURL: "https://api.deepinfra.com",
            keySource: .keychain,
            apiKey: "sk-test",
            models: [CustomProviderModel(id: "meta-llama/Llama-3-70b")]
        )
        XCTAssertEqual(secrets.values[record.keychainAccount], "sk-test")
        XCTAssertEqual(store.record(id: record.id)?.models.count, 1)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("sk-test"))
    }

    func testResolveAPIKeyKeychainAndEnvironment() throws {
        let secrets = FakeSecrets()
        let store = CustomProviderStore(storeURL: storeURL(), secrets: secrets)
        let record = try store.create(
            label: "Env",
            kind: .anthropicCompatible,
            baseURL: "https://gateway.example",
            keySource: .environmentVariable(name: "MY_GATEWAY_KEY"),
            apiKey: nil
        )
        XCTAssertThrowsError(try store.resolveAPIKey(for: record))

        setenv("MY_GATEWAY_KEY", "gateway-secret", 1)
        defer { unsetenv("MY_GATEWAY_KEY") }
        XCTAssertEqual(try store.resolveAPIKey(for: record), "gateway-secret")

        let keychainRecord = try store.create(
            label: "Keychain",
            kind: .openAICompatible,
            baseURL: "https://open.example",
            keySource: .keychain,
            apiKey: "open-key"
        )
        XCTAssertEqual(try store.resolveAPIKey(for: keychainRecord), "open-key")
    }

    func testDeleteRemovesKeychainFirst() throws {
        let secrets = FakeSecrets()
        let store = CustomProviderStore(storeURL: storeURL(), secrets: secrets)
        let record = try store.create(
            label: "Temp",
            kind: .openAICompatible,
            baseURL: "https://temp.example",
            keySource: .keychain,
            apiKey: "temp-key"
        )
        try store.delete(id: record.id)
        XCTAssertNil(secrets.values[record.keychainAccount])
        XCTAssertNil(store.record(id: record.id))
    }

    func testWireSummaryUsesCustomProviderEntries() throws {
        let store = CustomProviderStore(storeURL: storeURL(), secrets: FakeSecrets())
        let record = try store.create(
            label: "Gateway",
            kind: .anthropicCompatible,
            baseURL: "https://gateway.example",
            keySource: .keychain,
            apiKey: "key",
            models: [CustomProviderModel(id: "opus", displayName: "Opus")]
        )
        let summary = store.wireSummary(for: record)
        XCTAssertEqual(summary.entries.first?.customProviderId, record.id)
        XCTAssertEqual(summary.entries.first?.provider, .claude)
        XCTAssertEqual(summary.entries.first?.supportsEffort, false)
    }

    func testDecodeMinimalV1JSON() throws {
        let url = storeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion": 1,
          "records": [
            {
              "id": "deepinfra",
              "label": "DeepInfra",
              "kind": "openAICompatible",
              "baseURL": "https://api.deepinfra.com",
              "keySource": { "type": "keychain" },
              "isEnabled": true,
              "defaultModelId": "meta-llama/Llama-3-70b",
              "models": [{ "id": "meta-llama/Llama-3-70b" }],
              "createdAt": "2026-06-01T00:00:00Z",
              "updatedAt": "2026-06-01T00:00:00Z"
            }
          ]
        }
        """.data(using: .utf8)!
        try json.write(to: url)
        let store = CustomProviderStore(storeURL: url, secrets: FakeSecrets())
        XCTAssertEqual(store.allRecords().count, 1)
        XCTAssertEqual(store.allRecords().first?.id, "deepinfra")
    }
}
