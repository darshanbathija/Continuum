import XCTest
@testable import ClawdmeterShared

final class ProviderRegistryTests: XCTestCase {
    private struct SavedDefault {
        let defaults: UserDefaults
        let key: String
        let value: Any?
    }

    private func usage(sessionPct: Int) -> UsageData {
        UsageData(
            sessionPct: sessionPct,
            sessionResetMins: 60,
            sessionEpoch: 1_715_000_000,
            weeklyPct: 0,
            weeklyResetMins: 0,
            weeklyEpoch: 0,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1_715_000_000),
            organizationID: nil
        )
    }

    private func providerDefaultStores() -> [UserDefaults] {
        var stores = [UserDefaults.standard]
        stores.append(contentsOf: UsageStore.appGroups.compactMap { UserDefaults(suiteName: $0) })
        return stores
    }

    private func saveProviderFlags(_ ids: [String] = ProviderRegistry.allProviderIDs) -> [SavedDefault] {
        providerDefaultStores().flatMap { defaults in
            ids.map { id in
                let key = ProviderEnablement.key(for: id)
                return SavedDefault(defaults: defaults, key: key, value: defaults.object(forKey: key))
            }
        }
    }

    private func restoreProviderFlags(_ saved: [SavedDefault]) {
        for item in saved {
            if let value = item.value {
                item.defaults.set(value, forKey: item.key)
            } else {
                item.defaults.removeObject(forKey: item.key)
            }
        }
    }

    func testCanonicalProviderRegistryMappings() {
        XCTAssertEqual(ProviderRegistry.allProviderIDs, ["claude", "codex", "gemini", "cursor", "opencode", "grok"])
        XCTAssertEqual(ProviderRegistry.rootProviderID(for: "claude/personal"), "claude")
        XCTAssertEqual(ProviderRegistry.rootProviderID(for: "antigravity"), "gemini")
        XCTAssertEqual(ProviderRegistry.rootProviderID(for: "openrouter"), "opencode")
        XCTAssertEqual(ProviderRegistry.descriptor(chatVendor: .chatgpt)?.id, "codex")
        XCTAssertEqual(ProviderRegistry.descriptor(agentKind: .gemini)?.id, "gemini")
        XCTAssertEqual(ProviderRegistry.descriptor(usageProvider: .opencode)?.id, "opencode")
    }

    func testProviderEnablementDefaultsOffForAbsentKeys() {
        let id = "provider-registry-test-\(UUID().uuidString)"
        XCTAssertFalse(ProviderEnablement.isEnabled(id))
    }

    func testEnabledProviderHelpersHonorCanonicalIdsAndCapabilities() {
        let saved = saveProviderFlags()
        defer { restoreProviderFlags(saved) }

        for id in ProviderRegistry.allProviderIDs {
            ProviderEnablement.setEnabled(id, false)
        }
        ProviderEnablement.setEnabled("claude/personal", true)
        ProviderEnablement.setEnabled("codex", true)
        ProviderEnablement.setEnabled("opencode", true)

        XCTAssertEqual(ProviderEnablement.enabledProviderIDs(), ["claude", "codex", "opencode"])
        XCTAssertEqual(
            ProviderRegistry.enabledProviders(for: .code).map(\.id),
            ["claude", "codex", "opencode"]
        )
        XCTAssertEqual(ProviderRegistry.firstEnabledProvider(for: .code)?.id, "claude")
        // OpenCode Go is now a first-class provider with the full capability set
        // (live usage gauge + menu-bar + widget), so it appears alongside
        // claude/codex for widget visibility.
        XCTAssertEqual(ProviderEnablement.enabledProviderIDs(for: .widget), ["claude", "codex", "opencode"])
        XCTAssertTrue(ProviderRegistry.isVisible(id: "claude/personal", capability: .code))
        XCTAssertTrue(ProviderRegistry.isVisible(id: "opencode", capability: .widget))
    }

    @MainActor
    func testChatVendorScopeUsesEnabledProviderEnvelopeWithLegacyFallback() {
        XCTAssertEqual(
            ChatV2Store.enabledChatVendors(from: ["codex", "gemini", "cursor"]),
            [.chatgpt, .antigravity, .cursor]
        )
        XCTAssertEqual(
            ChatV2Store.enabledChatVendors(from: nil),
            ChatV2Store.defaultChatVendorOrder
        )
        XCTAssertEqual(
            ChatV2Store.normalizedVendors([.claude, .chatgpt, .claude], enabledVendors: [.chatgpt, .cursor]),
            [.chatgpt]
        )
        XCTAssertEqual(
            ChatV2Store.normalizedVendors([], enabledVendors: [.cursor]),
            [.cursor]
        )
        XCTAssertTrue(ChatV2Store.normalizedVendors([.claude], enabledVendors: []).isEmpty)
    }

    func testUsageEnvelopeFiltersDisabledProviderInstancesButMissingEnvelopeIsLegacyAllProviders() {
        let disabled = UsageEnvelope(
            claude: nil,
            codex: nil,
            usage: [
                "claude/personal": usage(sessionPct: 11),
                "codex": usage(sessionPct: 22),
            ],
            enabledProviderIDs: ["codex"],
            lastChecked: Date(timeIntervalSince1970: 1_715_000_100)
        )
        XCTAssertNil(disabled.usageData(for: "claude/personal"))
        XCTAssertEqual(disabled.usageData(for: "codex")?.sessionPct, 22)

        let legacy = UsageEnvelope(
            claude: nil,
            codex: nil,
            usage: ["claude/personal": usage(sessionPct: 11)],
            enabledProviderIDs: nil,
            lastChecked: Date(timeIntervalSince1970: 1_715_000_100)
        )
        XCTAssertEqual(legacy.usageData(for: "claude/personal")?.sessionPct, 11)
    }

    func testModelCatalogFiltersByEnabledProviderEnvelopeAndDecodesMissingEnvelopeAsLegacy() throws {
        let catalog = ModelCatalog(
            claude: [ModelCatalogEntry(id: "claude-test", provider: .claude, displayName: "Claude Test")],
            codex: [ModelCatalogEntry(id: "gpt-test", provider: .codex, displayName: "GPT Test")],
            gemini: [ModelCatalogEntry(id: "gemini-test", provider: .gemini, displayName: "Gemini Test")],
            enabledProviderIDs: ["codex"],
            updatedAt: Date(timeIntervalSince1970: 1_715_000_200)
        )

        XCTAssertTrue(catalog.entries(for: .claude).isEmpty)
        XCTAssertEqual(catalog.entries(for: .codex).map(\.id), ["gpt-test"])
        XCTAssertTrue(catalog.entries(for: .gemini).isEmpty)

        let legacyJSON = """
        {
          "claude": [{
            "id": "claude-test",
            "provider": "claude",
            "displayName": "Claude Test",
            "supportsThinking": true,
            "supportsEffort": true
          }],
          "codex": [{
            "id": "gpt-test",
            "provider": "codex",
            "displayName": "GPT Test",
            "supportsThinking": false,
            "supportsEffort": true
          }],
          "updatedAt": "2026-06-07T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(ModelCatalog.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.enabledProviderIDs)
        XCTAssertEqual(legacy.entries(for: .claude).map(\.id), ["claude-test"])
        XCTAssertEqual(legacy.entries(for: .codex).map(\.id), ["gpt-test"])
    }

    func testChatProvidersResponseDecodesMissingEnabledProviderIDs() throws {
        let json = """
        {
          "providers": [
            {
              "provider": "codex",
              "codexBackend": "sdk",
              "available": true,
              "authenticated": true,
              "capabilityProbePassed": true
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(ChatProvidersResponse.self, from: Data(json.utf8))
        XCTAssertNil(decoded.enabledProviderIDs)
        XCTAssertEqual(decoded.providers.map(\.provider), [.codex])
    }

    func testUsageHistorySnapshotFiltersModelRollupsByEnabledProvider() {
        let day = Date(timeIntervalSince1970: 1_715_000_000)
        let claude = TokenTotals(inputTokens: 10)
        let codex = TokenTotals(inputTokens: 20)
        let gemini = TokenTotals(requestCount: 3)
        let cursor = TokenTotals(inputTokens: 40)
        let opencode = TokenTotals(inputTokens: 45)
        let unknown = TokenTotals(inputTokens: 50)
        let rollups = [
            "claude-haiku": claude,
            "codex:gpt-5.5": codex,
            "gemini-3-pro": gemini,
            "cursor/composer-2.5-fast": cursor,
            "anthropic/claude-sonnet-4.6": opencode,
            "unknown-model": unknown,
        ]
        let snapshot = UsageHistorySnapshot(
            byProvider: [:],
            computedAt: Date(timeIntervalSince1970: 1_715_000_100),
            sequenceNumber: 42,
            sessionCount: 0,
            unpricedModelTokens: rollups,
            tokensByModel: rollups,
            byDayByModel: [day: rollups]
        )

        let filtered = snapshot.filtered(toEnabledProviderIDs: ["codex", "cursor"])
        let filteredDay = filtered.byDayByModel[day] ?? [:]

        XCTAssertEqual(Set(filtered.tokensByModel.keys), Set(["codex:gpt-5.5", "cursor/composer-2.5-fast"]))
        XCTAssertEqual(Set(filtered.unpricedModelTokens.keys), Set(["codex:gpt-5.5", "cursor/composer-2.5-fast"]))
        XCTAssertEqual(Set(filteredDay.keys), Set(["codex:gpt-5.5", "cursor/composer-2.5-fast"]))
        XCTAssertEqual(UsageHistorySnapshot.displayModelName(forModelKey: "codex:gpt-5.5"), "gpt-5.5")

        let filteredOpenCode = snapshot.filtered(toEnabledProviderIDs: ["opencode"])
        XCTAssertEqual(Set(filteredOpenCode.tokensByModel.keys), Set(["anthropic/claude-sonnet-4.6"]))
    }
}
