import Foundation

/// One upstream provider OpenCode can authenticate against via
/// `opencode auth login`. Names and ids mirror the Models.dev database
/// that OpenCode loads at runtime.
public struct OpencodeSupportedProvider: Sendable, Identifiable, Equatable, Hashable {
    public static let customEntryID = "__custom__"

    public static let customEntry = OpencodeSupportedProvider(
        id: customEntryID,
        name: "Custom",
        tagline: "Add an OpenAI-compatible provider by base URL."
    )

    public let id: String
    public let name: String
    public let tagline: String?

    public var isCustomEntry: Bool { id == Self.customEntryID }

    public var logoURL: URL {
        URL(string: "https://models.dev/logos/\(id).png")!
    }

    public init(id: String, name: String, tagline: String? = nil) {
        self.id = id
        self.name = name
        self.tagline = tagline ?? Self.defaultTagline(for: id)
    }

    private static func defaultTagline(for id: String) -> String? {
        switch id {
        case "github-copilot":
            return "GitHub Copilot models via OpenCode"
        case "openai":
            return "GPT models for fast, capable general AI tasks"
        case "google":
            return "Gemini models from Google AI"
        case "openrouter":
            return "Route requests through OpenRouter"
        case "vercel":
            return "Vercel AI Gateway"
        case "anthropic":
            return "Claude models from Anthropic"
        case "opencode":
            return "OpenCode Go subscription models"
        default:
            return nil
        }
    }
}

/// Loads the full OpenCode provider catalog and splits it into the same
/// featured set OpenCode surfaces first in `auth login`, plus every
/// remaining provider under "More Providers".
public enum OpencodeSupportedProviderCatalog {
    /// Priority ordering copied from upstream
    /// `packages/opencode/src/cli/cmd/providers.ts`.
    public static let featuredProviderIDs: [String] = [
        "opencode",
        "openai",
        "github-copilot",
        "google",
        "anthropic",
        "openrouter",
        "vercel",
    ]

    /// Offline fallback when Models.dev is unreachable (tests, airplane mode).
    public static let bundledFallback: [OpencodeSupportedProvider] = featuredProviderIDs.map {
        OpencodeSupportedProvider(id: $0, name: OpencodeAuthFile.defaultDisplayName(for: $0))
    }

    public struct Snapshot: Sendable, Equatable {
        public let featured: [OpencodeSupportedProvider]
        public let more: [OpencodeSupportedProvider]

        public var all: [OpencodeSupportedProvider] {
            featured + more
        }
    }

    public static func split(_ providers: [OpencodeSupportedProvider]) -> Snapshot {
        let featuredSet = Set(featuredProviderIDs)
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })

        var featured: [OpencodeSupportedProvider] = []
        for id in featuredProviderIDs {
            if let provider = byID[id] {
                featured.append(provider)
            }
        }

        let more = providers
            .filter { !featuredSet.contains($0.id) }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        return Snapshot(featured: featured, more: more)
    }
}

public actor OpencodeSupportedProviderCatalogStore {
    public static let shared = OpencodeSupportedProviderCatalogStore()

    private static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    private static let cacheTTL: TimeInterval = 60 * 60 * 6

    private var cachedSnapshot: OpencodeSupportedProviderCatalog.Snapshot?
    private var cachedAt: Date?

    public func currentSnapshot(forceRefresh: Bool = false) async -> OpencodeSupportedProviderCatalog.Snapshot {
        if !forceRefresh,
           let cachedSnapshot,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < Self.cacheTTL {
            return cachedSnapshot
        }

        if let fetched = await fetchFromModelsDev() {
            cachedSnapshot = fetched
            cachedAt = Date()
            return fetched
        }

        if let cachedSnapshot {
            return cachedSnapshot
        }

        let fallback = OpencodeSupportedProviderCatalog.split(OpencodeSupportedProviderCatalog.bundledFallback)
        cachedSnapshot = fallback
        cachedAt = Date()
        return fallback
    }

    public func invalidate() {
        cachedSnapshot = nil
        cachedAt = nil
    }

    private func fetchFromModelsDev() async -> OpencodeSupportedProviderCatalog.Snapshot? {
        var request = URLRequest(url: Self.modelsDevURL)
        request.setValue("Continuum/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode([String: ModelsDevProvider].self, from: data)
            let providers = decoded
                .map { id, entry in
                    OpencodeSupportedProvider(
                        id: id,
                        name: entry.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            ? entry.name!.trimmingCharacters(in: .whitespacesAndNewlines)
                            : OpencodeAuthFile.defaultDisplayName(for: id)
                    )
                }
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            return OpencodeSupportedProviderCatalog.split(providers)
        } catch {
            return nil
        }
    }
}

private struct ModelsDevProvider: Decodable {
    let name: String?
}
