import Foundation
import ClawdmeterShared

/// Live model catalog for authenticated OpenCode upstream partners by running
/// `opencode models` and grouping slash-delimited ids by provider prefix.
public actor OpenCodePartnerModelProbe {
    public static let shared = OpenCodePartnerModelProbe()

    private struct CacheEntry {
        let partners: [OpenCodePartnerWireSummary]
        let computedAt: Date
    }

    public static let cacheTTL: TimeInterval = 60
    public static let failureTTL: TimeInterval = 10

    private var cache: CacheEntry?
    private var inflight: Task<[OpenCodePartnerWireSummary], Never>?
    private var generation = 0

    public init() {}

    public func invalidate() {
        generation &+= 1
        cache = nil
        inflight?.cancel()
        inflight = nil
    }

    public func summaries() async -> [OpenCodePartnerWireSummary] {
        await currentSummaries()
    }

    public func currentSummaries() async -> [OpenCodePartnerWireSummary] {
        let now = Date()
        if let cache {
            let ttl = cache.partners.isEmpty ? Self.failureTTL : Self.cacheTTL
            if now.timeIntervalSince(cache.computedAt) < ttl {
                return cache.partners
            }
        }
        if let task = inflight {
            return await task.value
        }
        let gen = generation
        let task = Task { await self.runProbe() }
        inflight = task
        let partners = await task.value
        if gen == generation {
            cache = CacheEntry(partners: partners, computedAt: Date())
            inflight = nil
        }
        return partners
    }

    private func runProbe() async -> [OpenCodePartnerWireSummary] {
        let authenticated = await authenticatedPartnerIDs()
        guard !authenticated.isEmpty else { return [] }

        let modelsByPartner = await fetchModelsByPartner(authenticated: authenticated)
        return authenticated.sorted().map { partnerId in
            OpenCodePartnerWireSummary(
                id: partnerId,
                label: OpenCodePartnerSupport.displayName(for: partnerId),
                enabled: ProviderEnablement.isEnabled(
                    OpenCodePartnerSupport.enablementId(for: partnerId)
                ),
                entries: modelsByPartner[partnerId] ?? []
            )
        }
    }

    private func authenticatedPartnerIDs() async -> [String] {
        let providers = await OpencodeAuthFile.shared.enumeratedProviders()
        return providers
            .map(\.id)
            .filter(OpenCodePartnerSupport.isUpstreamPartnerAuthId)
    }

    private func fetchModelsByPartner(authenticated: [String]) async -> [String: [ModelCatalogEntry]] {
        let allowed = Set(authenticated.map { $0.lowercased() })
        if let binary = await MainActor.run(body: {
            OpencodeProcessManager.shared.binaryPath
                ?? OpencodeProcessManager.shared.locateBinary()
        }) {
            if let output = runOpencodeModels(binary: binary) {
                return Self.parseModelsOutput(output, allowedPartnerIDs: allowed)
            }
        }
        return await modelsFromCatalogFallback(authenticated: authenticated)
    }

    private func runOpencodeModels(binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["models"]
        process.environment = ProcessInfo.processInfo.environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    internal static func parseModelsOutput(
        _ output: String,
        allowedPartnerIDs: Set<String>
    ) -> [String: [ModelCatalogEntry]] {
        var grouped: [String: [ModelCatalogEntry]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let slash = trimmed.firstIndex(of: "/") else { continue }
            let providerId = String(trimmed[..<slash])
            let modelId = String(trimmed[trimmed.index(after: slash)...])
            guard !providerId.isEmpty, !modelId.isEmpty else { continue }
            guard OpenCodePartnerSupport.isUpstreamPartnerAuthId(providerId) else { continue }
            guard allowedPartnerIDs.contains(providerId.lowercased()) else { continue }

            let catalogId = "\(providerId)/\(modelId)"
            let label = OpenCodePartnerSupport.displayName(for: providerId)
            let entry = ModelCatalogEntry(
                id: catalogId,
                provider: .opencode,
                displayName: "\(label) · \(displayModelName(modelId))",
                cliAlias: catalogId,
                supportsThinking: true,
                supportsEffort: false,
                contextWindow: nil,
                recommendedFor: nil,
                badge: nil
            )
            grouped[providerId, default: []].append(entry)
        }
        for key in grouped.keys {
            grouped[key] = grouped[key]?.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        return grouped
    }

    private func modelsFromCatalogFallback(authenticated: [String]) async -> [String: [ModelCatalogEntry]] {
        guard let url = URL(string: "https://models.dev/api.json") else { return [:] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return [:]
            }
            let raw = try JSONDecoder().decode([String: CatalogProvider].self, from: data)
            var grouped: [String: [ModelCatalogEntry]] = [:]
            for partnerId in authenticated {
                let lookup = raw[partnerId] ?? raw[partnerId.lowercased()]
                guard let provider = lookup else { continue }
                let label = provider.name ?? OpenCodePartnerSupport.displayName(for: partnerId)
                let entries = provider.models?.keys.sorted().map { modelId -> ModelCatalogEntry in
                    let catalogId = "\(partnerId)/\(modelId)"
                    return ModelCatalogEntry(
                        id: catalogId,
                        provider: .opencode,
                        displayName: "\(label) · \(Self.displayModelName(modelId))",
                        cliAlias: catalogId,
                        supportsThinking: true,
                        supportsEffort: false,
                        contextWindow: nil,
                        recommendedFor: nil,
                        badge: nil
                    )
                } ?? []
                if !entries.isEmpty {
                    grouped[partnerId] = entries
                }
            }
            return grouped
        } catch {
            return [:]
        }
    }

    private static func displayModelName(_ raw: String) -> String {
        let tail = raw.split(separator: "/").last.map(String.init) ?? raw
        return tail.split(separator: "-").map { part -> String in
            if part.count <= 3 || part.allSatisfy(\.isNumber) { return String(part) }
            return part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    private struct CatalogProvider: Decodable {
        let name: String?
        let models: [String: CatalogModel]?
    }

    private struct CatalogModel: Decodable {
        let name: String?
    }
}
