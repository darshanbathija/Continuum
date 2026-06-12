import Foundation

struct OpenCodeProviderEntry: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let name: String
}

enum OpenCodeProviderCatalog {
    private static let catalogURL = URL(string: "https://models.dev/api.json")!
    private static let cacheKey = "clawdmeter.opencode.providerCatalog.v1"
    private static let cacheDateKey = "clawdmeter.opencode.providerCatalogDate.v1"
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    static func fetchProviders() async -> [OpenCodeProviderEntry] {
        if let cached = loadCached(), !cached.isEmpty, !cacheIsStale() {
            return cached
        }
        if let remote = await fetchRemote() {
            storeCache(remote)
            return remote
        }
        return loadCached() ?? fallbackProviders()
    }

    private static func fetchRemote() async -> [OpenCodeProviderEntry]? {
        do {
            let (data, response) = try await URLSession.shared.data(from: catalogURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try parseCatalog(data)
        } catch {
            return nil
        }
    }

    private static func parseCatalog(_ data: Data) throws -> [OpenCodeProviderEntry] {
        let raw = try JSONDecoder().decode([String: CatalogProvider].self, from: data)
        return raw.map { id, provider in
            OpenCodeProviderEntry(id: id, name: provider.name ?? id)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private struct CatalogProvider: Decodable {
        let name: String?
    }

    private static func cacheIsStale() -> Bool {
        let fetchedAt = UserDefaults.standard.double(forKey: cacheDateKey)
        guard fetchedAt > 0 else { return true }
        return Date().timeIntervalSince1970 - fetchedAt > cacheTTL
    }

    private static func loadCached() -> [OpenCodeProviderEntry]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode([OpenCodeProviderEntry].self, from: data)
    }

    private static func storeCache(_ providers: [OpenCodeProviderEntry]) {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheDateKey)
    }

    private static func fallbackProviders() -> [OpenCodeProviderEntry] {
        [
            OpenCodeProviderEntry(id: "anthropic", name: "Anthropic"),
            OpenCodeProviderEntry(id: "openai", name: "OpenAI"),
            OpenCodeProviderEntry(id: "google", name: "Google"),
            OpenCodeProviderEntry(id: "amazon-bedrock", name: "Amazon Bedrock"),
            OpenCodeProviderEntry(id: "opencode", name: "OpenCode"),
        ]
    }
}
