import XCTest
@testable import ClawdmeterShared

/// Wire v28 — custom OpenAI/Anthropic-compatible providers.
final class WireV28CustomProvidersTests: XCTestCase {

    func testCurrentWireVersion() {
        XCTAssertEqual(AgentControlWireVersion.current, 28)
        XCTAssertEqual(AgentControlWireVersion.customProvidersMinimum, 28)
    }

    func testCustomProvidersFeatureGate() {
        XCTAssertFalse(AgentControlWireVersion.supportsCustomProviders(serverWireVersion: 27))
        XCTAssertTrue(AgentControlWireVersion.supportsCustomProviders(serverWireVersion: 28))
        XCTAssertFalse(AgentControlWireVersion.supportsCustomProviders(serverWireVersion: nil))
    }

    func testCustomProviderKindLenientDecode() throws {
        let unknown = "\"someFutureKind\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(CustomProviderKind.self, from: unknown), .openAICompatible)
    }

    func testCustomProviderKeySourceRoundTrip() throws {
        let sources: [CustomProviderKeySource] = [
            .keychain,
            .environmentVariable(name: "MY_API_KEY"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for source in sources {
            let decoded = try decoder.decode(CustomProviderKeySource.self, from: encoder.encode(source))
            XCTAssertEqual(decoded, source)
        }
    }

    func testModelCatalogCustomProvidersRoundTrip() throws {
        let summary = CustomProviderWireSummary(
            id: "deepinfra",
            label: "DeepInfra",
            kind: .openAICompatible,
            baseURL: "https://api.deepinfra.com",
            defaultModelId: "meta-llama/Llama-3-70b",
            enabled: true,
            entries: [
                ModelCatalogEntry(
                    id: "meta-llama/Llama-3-70b",
                    provider: .codex,
                    displayName: "DeepInfra · Llama 3 70B",
                    supportsEffort: false,
                    badge: "Custom",
                    customProviderId: "deepinfra"
                ),
            ]
        )
        var catalog = ModelCatalog.bundled
        catalog = ModelCatalog(
            claude: catalog.claude,
            codex: catalog.codex,
            gemini: catalog.gemini,
            opencode: catalog.opencode,
            cursor: catalog.cursor,
            grok: catalog.grok,
            enabledProviderIDs: catalog.enabledProviderIDs,
            customProviders: [summary],
            updatedAt: catalog.updatedAt
        )

        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(ModelCatalog.self, from: data)
        XCTAssertEqual(decoded.customProviders.count, 1)
        XCTAssertEqual(decoded.customProviders.first?.id, "deepinfra")
        XCTAssertEqual(decoded.entry(forId: "meta-llama/Llama-3-70b")?.customProviderId, "deepinfra")
    }

    func testModelCatalogBackCompatMissingCustomProviders() throws {
        let legacy = """
        {"claude":[],"codex":[],"updatedAt":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelCatalog.self, from: legacy)
        XCTAssertEqual(decoded.customProviders, [])
    }

    func testEntryLookupScopedByCustomProviderId() {
        let bundledGPT = ModelCatalog.bundled.entry(forId: "gpt-5.5")
        XCTAssertNotNil(bundledGPT)

        let customEntry = ModelCatalogEntry(
            id: "gpt-5.5",
            provider: .codex,
            displayName: "Gateway · GPT-5.5",
            supportsEffort: false,
            customProviderId: "gateway"
        )
        let catalog = ModelCatalog(
            claude: [],
            codex: ModelCatalog.bundled.codex,
            customProviders: [
                CustomProviderWireSummary(
                    id: "gateway",
                    label: "Gateway",
                    kind: .openAICompatible,
                    baseURL: "https://gateway.example",
                    entries: [customEntry]
                ),
            ],
            updatedAt: Date()
        )

        XCTAssertEqual(catalog.entry(forId: "gpt-5.5", customProviderId: "gateway")?.displayName, "Gateway · GPT-5.5")
        XCTAssertEqual(catalog.entry(forId: "gpt-5.5", customProviderId: nil)?.displayName, bundledGPT?.displayName)
    }

    func testAgentSessionCustomProviderIdRoundTrip() throws {
        let session = AgentSession(
            id: UUID(),
            repoKey: "/tmp/repo",
            repoDisplayName: "repo",
            agent: .codex,
            model: "my-model",
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0,
            customProviderId: "deepinfra"
        )
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.customProviderId, "deepinfra")
    }

    func testChatProvidersResponseCustomProvidersBackCompat() throws {
        let json = """
        {
          "providers": [
            {
              "provider": "codex",
              "available": true,
              "authenticated": true,
              "capabilityProbePassed": true
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(ChatProvidersResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.customProviders, [])
    }

    func testProviderChoiceDecodeAndPersistKeys() {
        XCTAssertEqual(ProviderChoice.decode("claude"), .builtin(.claude))
        XCTAssertEqual(ProviderChoice.decode("custom:deepinfra"), .custom("deepinfra"))
        XCTAssertNil(ProviderChoice.decode("custom:"))
        XCTAssertNil(ProviderChoice.decode("not-a-vendor"))

        XCTAssertEqual(ProviderChoice.builtin(.claude).id, "claude")
        XCTAssertEqual(ProviderChoice.custom("deepinfra").id, "custom:deepinfra")
    }

    func testProviderRegistryCustomNamespace() {
        XCTAssertEqual(ProviderRegistry.customProviderId(from: "custom/deepinfra"), "deepinfra")
        XCTAssertNil(ProviderRegistry.customProviderId(from: "codex"))
        XCTAssertEqual(ProviderRegistry.wireId(forCustomProviderId: "deepinfra"), "custom/deepinfra")
    }

    @MainActor
    func testChatV2StorePersistsCustomChoiceKeys() {
        let suiteName = "WireV28CustomProvidersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ChatV2Store(defaults: defaults)
        store.applyEnabledChoiceScope([.builtin(.claude), .custom("deepinfra")])
        store.selectedChoices = [.builtin(.claude), .custom("deepinfra")]
        store.selectModel("my-model", forChoice: .custom("deepinfra"))
        store.persist()

        let raw = defaults.stringArray(forKey: "clawdmeter.chatv2.vendors") ?? []
        XCTAssertEqual(raw, ["claude", "custom:deepinfra"])

        let reloaded = ChatV2Store(defaults: defaults)
        reloaded.applyEnabledChoiceScope([.builtin(.claude), .custom("deepinfra")])
        XCTAssertEqual(reloaded.selectedChoices, [.builtin(.claude), .custom("deepinfra")])
        XCTAssertEqual(reloaded.model(forChoice: .custom("deepinfra")), "my-model")
    }

    func testProviderModelPickerSupportCustomEffortDisabled() {
        let catalog = ModelCatalog(
            claude: [],
            codex: [],
            customProviders: [
                CustomProviderWireSummary(
                    id: "gateway",
                    label: "Gateway",
                    kind: .anthropicCompatible,
                    baseURL: "https://gateway.example",
                    entries: [
                        ModelCatalogEntry(
                            id: "opus",
                            provider: .claude,
                            displayName: "Gateway · Opus",
                            supportsEffort: false,
                            customProviderId: "gateway"
                        ),
                    ]
                ),
            ],
            updatedAt: Date()
        )
        XCTAssertFalse(
            ProviderModelPickerSupport.supportsEffort(
                choice: .custom("gateway"),
                modelId: "opus",
                catalog: catalog
            )
        )
    }
}
