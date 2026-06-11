import Foundation
import ClawdmeterShared

public struct OpenCodeGoModelProbeState: Sendable {
    public let models: [ModelCatalogEntry]
    public let authenticated: Bool
    public let discoverySucceeded: Bool
    public let reason: String?
    public let probedAt: Date

    public init(
        models: [ModelCatalogEntry],
        authenticated: Bool,
        discoverySucceeded: Bool,
        reason: String?,
        probedAt: Date
    ) {
        self.models = models
        self.authenticated = authenticated
        self.discoverySucceeded = discoverySucceeded
        self.reason = reason
        self.probedAt = probedAt
    }
}

/// Live model catalog for OpenCode Go (`GET /zen/go/v1/models`).
public actor OpenCodeGoModelProbe {
    public static let shared = OpenCodeGoModelProbe()

    private struct CacheEntry {
        let state: OpenCodeGoModelProbeState
        let computedAt: Date
    }

    private static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/models")!
    public static let cacheTTL: TimeInterval = 60
    /// Failures get a much shorter TTL than successes so a single transient blip
    /// doesn't strand the provider as "discovery failed" for a full minute
    /// (ChatProviderProbe gates chat readiness on `discoverySucceeded`).
    public static let failureTTL: TimeInterval = 10

    private var cache: CacheEntry?
    private var inflight: Task<OpenCodeGoModelProbeState, Never>?
    /// Bumped by `invalidate()`. A probe that finishes after its generation was
    /// superseded discards its cache write, so a forced refresh always wins.
    private var generation = 0

    public init() {}

    public func invalidate() {
        generation &+= 1
        cache = nil
        inflight?.cancel()
        inflight = nil
    }

    public func currentModels() async -> [ModelCatalogEntry] {
        await currentState().models
    }

    public func currentState() async -> OpenCodeGoModelProbeState {
        let now = Date()
        if let cache {
            let ttl = cache.state.discoverySucceeded ? Self.cacheTTL : Self.failureTTL
            if now.timeIntervalSince(cache.computedAt) < ttl {
                return cache.state
            }
        }
        if let task = inflight {
            return await task.value
        }
        let gen = generation
        let task = Task { await self.runProbe() }
        inflight = task
        let state = await task.value
        // Commit only if no invalidate() superseded this probe while it ran;
        // otherwise leave the (already-cleared) cache/inflight for the refresh.
        if gen == generation {
            cache = CacheEntry(state: state, computedAt: Date())
            inflight = nil
        }
        return state
    }

    private func runProbe() async -> OpenCodeGoModelProbeState {
        let now = Date()
        let hasAuth = await OpenCodeGoCredentials.hasGoAuth()
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 8
        if let key = await OpenCodeGoCredentials.apiKey() {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return OpenCodeGoModelProbeState(
                    models: ModelCatalog.bundled.opencode,
                    authenticated: hasAuth,
                    discoverySucceeded: false,
                    reason: "OpenCode Go model discovery failed with HTTP \(status)",
                    probedAt: now
                )
            }
            let models = try Self.parseModelsResponse(data)
            guard !models.isEmpty else {
                return OpenCodeGoModelProbeState(
                    models: ModelCatalog.bundled.opencode,
                    authenticated: hasAuth,
                    discoverySucceeded: false,
                    reason: "OpenCode Go returned no models",
                    probedAt: now
                )
            }
            return OpenCodeGoModelProbeState(
                models: models,
                authenticated: hasAuth,
                discoverySucceeded: true,
                reason: hasAuth ? nil : "Add your OpenCode Go API key in Settings",
                probedAt: now
            )
        } catch {
            return OpenCodeGoModelProbeState(
                models: ModelCatalog.bundled.opencode,
                authenticated: hasAuth,
                discoverySucceeded: false,
                reason: "OpenCode Go model discovery failed: \(error.localizedDescription)",
                probedAt: now
            )
        }
    }

    internal static func parseModelsResponse(_ data: Data) throws -> [ModelCatalogEntry] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        let entries = decoded.data.compactMap { model -> ModelCatalogEntry? in
            let rawId = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawId.isEmpty else { return nil }
            let catalogId = rawId.hasPrefix("opencode-go/") ? String(rawId.dropFirst("opencode-go/".count)) : rawId
            let displayName = displayName(for: catalogId)
            let bundled = ModelCatalog.bundled.opencode.first(where: { $0.id == catalogId })
            return ModelCatalogEntry(
                id: catalogId,
                provider: .opencode,
                displayName: displayName,
                cliAlias: "opencode-go/\(catalogId)",
                supportsThinking: bundled?.supportsThinking ?? true,
                supportsEffort: bundled?.supportsEffort ?? false,
                contextWindow: model.contextLength ?? bundled?.contextWindow,
                recommendedFor: bundled?.recommendedFor ?? "OpenCode Go",
                badge: bundled?.badge ?? "Go"
            )
        }
        return featuredFirst(entries)
    }

    private static func displayName(for id: String) -> String {
        let bundled = ModelCatalog.bundled.opencode.first(where: { $0.id == id })
        if let bundled { return bundled.displayName }
        let words = id.split(separator: "-").map { part -> String in
            if part.count <= 3 || part.allSatisfy(\.isNumber) { return String(part) }
            return part.prefix(1).uppercased() + part.dropFirst()
        }
        return "OpenCode Go · " + words.joined(separator: " ")
    }

    private static func featuredFirst(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        var byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var ordered: [ModelCatalogEntry] = []
        for featured in ModelCatalog.bundled.opencode where featured.id != "opencode-default" {
            if let entry = byId.removeValue(forKey: featured.id) {
                ordered.append(entry)
            }
        }
        ordered.append(contentsOf: byId.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        })
        return ordered
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let contextLength: Int?
        }

        let data: [Model]
    }
}
