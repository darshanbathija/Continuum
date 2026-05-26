import Foundation
#if canImport(Combine)
import Combine
#endif

public struct ProviderDefaultsSnapshot: Codable, Hashable, Sendable {
    public var modelByVendor: [String: String]
    public var effortByVendor: [String: String]
    /// v0.29.8 — composer model picker favorites. Per-vendor ordered list of
    /// model ids the user has starred. Order is newest-first; the picker
    /// renders favorites grouped under the "Starred" rail entry across
    /// providers. Backward-compatible: snapshots persisted before v0.29.8
    /// decode with this dictionary empty (see custom `init(from:)`).
    public var favoriteModelsByVendor: [String: [String]]
    public var updatedAt: Date

    public init(
        modelByVendor: [String: String] = [:],
        effortByVendor: [String: String] = [:],
        favoriteModelsByVendor: [String: [String]] = [:],
        updatedAt: Date = Date()
    ) {
        self.modelByVendor = modelByVendor
        self.effortByVendor = effortByVendor
        self.favoriteModelsByVendor = favoriteModelsByVendor
        self.updatedAt = updatedAt
    }

    public static let empty = ProviderDefaultsSnapshot(
        modelByVendor: [:],
        effortByVendor: [:],
        favoriteModelsByVendor: [:],
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    private enum CodingKeys: String, CodingKey {
        case modelByVendor, effortByVendor, favoriteModelsByVendor, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.modelByVendor = try c.decodeIfPresent([String: String].self, forKey: .modelByVendor) ?? [:]
        self.effortByVendor = try c.decodeIfPresent([String: String].self, forKey: .effortByVendor) ?? [:]
        self.favoriteModelsByVendor = try c.decodeIfPresent([String: [String]].self, forKey: .favoriteModelsByVendor) ?? [:]
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    public func favoriteModelIds(for vendor: ChatVendor) -> [String] {
        favoriteModelsByVendor[vendor.rawValue] ?? []
    }

    public func isFavorite(modelId: String, vendor: ChatVendor) -> Bool {
        favoriteModelIds(for: vendor).contains(modelId)
    }

    public func modelId(for vendor: ChatVendor) -> String? {
        let value = modelByVendor[vendor.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    public func effort(for vendor: ChatVendor) -> ReasoningEffort? {
        guard let raw = effortByVendor[vendor.rawValue],
              let effort = ReasoningEffort(rawValue: raw) else {
            return nil
        }
        return effort
    }

    public func modelId(for vendor: ChatVendor, catalog: ModelCatalog) -> String? {
        if let explicit = modelId(for: vendor),
           Self.catalog(catalog, contains: explicit, for: vendor) {
            return explicit
        }
        return vendor.defaultModelId(in: catalog)
    }

    public func effort(for vendor: ChatVendor, catalog: ModelCatalog) -> ReasoningEffort? {
        let model = modelId(for: vendor, catalog: catalog)
        guard ProviderModelPickerSupport.supportsEffort(
            vendor: vendor,
            modelId: model,
            catalog: catalog
        ) else {
            return nil
        }
        return effort(for: vendor)
    }

    public func decodedModelMap() -> [ChatVendor: String] {
        modelByVendor.reduce(into: [ChatVendor: String]()) { result, pair in
            guard let vendor = ChatVendor(rawValue: pair.key),
                  !pair.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            result[vendor] = pair.value
        }
    }

    public func decodedEffortMap() -> [ChatVendor: ReasoningEffort] {
        effortByVendor.reduce(into: [ChatVendor: ReasoningEffort]()) { result, pair in
            guard let vendor = ChatVendor(rawValue: pair.key),
                  let effort = ReasoningEffort(rawValue: pair.value) else {
                return
            }
            result[vendor] = effort
        }
    }

    private static func catalog(_ catalog: ModelCatalog, contains id: String, for vendor: ChatVendor) -> Bool {
        let entries = vendor.models(in: catalog)
        guard !entries.isEmpty else { return true }
        return entries.contains { $0.id == id || $0.cliAlias == id }
    }
}

public struct ProviderDefaultsResponse: Codable, Hashable, Sendable {
    public let defaults: ProviderDefaultsSnapshot

    public init(defaults: ProviderDefaultsSnapshot) {
        self.defaults = defaults
    }
}

public struct UpdateProviderDefaultRequest: Codable, Hashable, Sendable {
    public var model: String?
    public var effort: ReasoningEffort?
    public var clearModel: Bool
    public var clearEffort: Bool

    public init(
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        clearModel: Bool = false,
        clearEffort: Bool = false
    ) {
        self.model = model
        self.effort = effort
        self.clearModel = clearModel
        self.clearEffort = clearEffort
    }
}

public final class ProviderDefaultsStore: ObservableObject {
    @Published public private(set) var snapshot: ProviderDefaultsSnapshot

    private let defaults: UserDefaults
    private static let defaultsPrefix = "clawdmeter.providerDefaults."
    private static let legacyChatV2Prefix = "clawdmeter.chatv2."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyDefaultsIfNeeded(defaults: defaults)
        self.snapshot = Self.readSnapshot(defaults: defaults)
    }

    public func refresh() {
        snapshot = Self.readSnapshot(defaults: defaults)
    }

    public func modelId(for vendor: ChatVendor, catalog: ModelCatalog = .bundled) -> String? {
        snapshot.modelId(for: vendor, catalog: catalog)
    }

    public func effort(for vendor: ChatVendor, catalog: ModelCatalog = .bundled) -> ReasoningEffort? {
        snapshot.effort(for: vendor, catalog: catalog)
    }

    @discardableResult
    public func setDefault(
        for vendor: ChatVendor,
        model: String?,
        effort: ReasoningEffort?,
        clearModel: Bool = false,
        clearEffort: Bool = false,
        catalog: ModelCatalog = .bundled
    ) -> ProviderDefaultsSnapshot {
        var next = snapshot
        if clearModel {
            next.modelByVendor.removeValue(forKey: vendor.rawValue)
        } else if let model {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                next.modelByVendor.removeValue(forKey: vendor.rawValue)
            } else {
                next.modelByVendor[vendor.rawValue] = trimmed
            }
        }

        let effectiveModel = next.modelId(for: vendor, catalog: catalog)
        let supportsEffort = ProviderModelPickerSupport.supportsEffort(
            vendor: vendor,
            modelId: effectiveModel,
            catalog: catalog
        )
        if clearEffort || !supportsEffort {
            next.effortByVendor.removeValue(forKey: vendor.rawValue)
        } else if let effort {
            next.effortByVendor[vendor.rawValue] = effort.rawValue
        }

        next.updatedAt = Date()
        persist(next)
        return next
    }

    @discardableResult
    public func replace(with snapshot: ProviderDefaultsSnapshot) -> ProviderDefaultsSnapshot {
        persist(snapshot)
        return self.snapshot
    }

    /// v0.29.8 — composer model picker favorite toggle. Adds `modelId` to the
    /// front of the vendor's favorite list if it isn't present; removes it if
    /// it is. Returns the post-toggle snapshot. No-op for empty model ids.
    @discardableResult
    public func toggleFavoriteModel(_ modelId: String, for vendor: ChatVendor) -> ProviderDefaultsSnapshot {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snapshot }
        var next = snapshot
        var current = next.favoriteModelsByVendor[vendor.rawValue] ?? []
        if let index = current.firstIndex(of: trimmed) {
            current.remove(at: index)
        } else {
            current.insert(trimmed, at: 0)
        }
        if current.isEmpty {
            next.favoriteModelsByVendor.removeValue(forKey: vendor.rawValue)
        } else {
            next.favoriteModelsByVendor[vendor.rawValue] = current
        }
        next.updatedAt = Date()
        persist(next)
        return next
    }

    public func favoriteModelIds(for vendor: ChatVendor) -> [String] {
        snapshot.favoriteModelIds(for: vendor)
    }

    public func isFavorite(modelId: String, vendor: ChatVendor) -> Bool {
        snapshot.isFavorite(modelId: modelId, vendor: vendor)
    }

    private func persist(_ next: ProviderDefaultsSnapshot) {
        defaults.set(next.modelByVendor, forKey: Self.defaultsPrefix + "modelByVendor")
        defaults.set(next.effortByVendor, forKey: Self.defaultsPrefix + "effortByVendor")
        defaults.set(next.favoriteModelsByVendor, forKey: Self.defaultsPrefix + "favoriteModelsByVendor")
        defaults.set(next.updatedAt.timeIntervalSince1970, forKey: Self.defaultsPrefix + "updatedAt")
        snapshot = next
    }

    private static func readSnapshot(defaults: UserDefaults) -> ProviderDefaultsSnapshot {
        let modelMap = defaults.dictionary(forKey: defaultsPrefix + "modelByVendor") as? [String: String] ?? [:]
        let effortMap = defaults.dictionary(forKey: defaultsPrefix + "effortByVendor") as? [String: String] ?? [:]
        let favoritesMap = defaults.dictionary(forKey: defaultsPrefix + "favoriteModelsByVendor") as? [String: [String]] ?? [:]
        let updatedAtRaw = defaults.object(forKey: defaultsPrefix + "updatedAt") as? TimeInterval
        return ProviderDefaultsSnapshot(
            modelByVendor: modelMap,
            effortByVendor: effortMap,
            favoriteModelsByVendor: favoritesMap,
            updatedAt: updatedAtRaw.map(Date.init(timeIntervalSince1970:)) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private static func migrateLegacyDefaultsIfNeeded(defaults: UserDefaults) {
        let existingModels = defaults.dictionary(forKey: defaultsPrefix + "modelByVendor") as? [String: String] ?? [:]
        let existingEfforts = defaults.dictionary(forKey: defaultsPrefix + "effortByVendor") as? [String: String] ?? [:]
        let legacyModels = defaults.dictionary(forKey: legacyChatV2Prefix + "modelByVendor") as? [String: String] ?? [:]
        let legacyEfforts = defaults.dictionary(forKey: legacyChatV2Prefix + "effortByVendor") as? [String: String] ?? [:]

        var migratedModels = existingModels
        var migratedEfforts = existingEfforts
        for vendor in ChatVendor.allCases {
            if migratedModels[vendor.rawValue] == nil,
               let legacy = legacyModels[vendor.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !legacy.isEmpty {
                migratedModels[vendor.rawValue] = legacy
            }
            if migratedEfforts[vendor.rawValue] == nil,
               let legacy = legacyEfforts[vendor.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !legacy.isEmpty {
                migratedEfforts[vendor.rawValue] = legacy
            }
        }

        guard migratedModels != existingModels || migratedEfforts != existingEfforts else { return }
        defaults.set(migratedModels, forKey: defaultsPrefix + "modelByVendor")
        defaults.set(migratedEfforts, forKey: defaultsPrefix + "effortByVendor")
        defaults.set(Date().timeIntervalSince1970, forKey: defaultsPrefix + "updatedAt")
    }
}

public struct ProviderModelSection: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let entries: [ModelCatalogEntry]

    public init(title: String, entries: [ModelCatalogEntry]) {
        self.id = title
        self.title = title
        self.entries = entries
    }
}

public enum ProviderModelPickerSupport {
    public static func sections(
        for vendor: ChatVendor,
        catalog: ModelCatalog,
        query: String
    ) -> [ProviderModelSection] {
        let filtered = entries(for: vendor, catalog: catalog, query: query)
        guard vendor == .openrouter else {
            return filtered.isEmpty ? [] : [ProviderModelSection(title: "Models", entries: filtered)]
        }

        let featured = filtered.filter { isFeaturedOpenRouterModel($0) }
        let featuredIDs = Set(featured.map(\.id))
        let remaining = filtered.filter { !featuredIDs.contains($0.id) }
        var sections: [ProviderModelSection] = []
        if !featured.isEmpty {
            sections.append(ProviderModelSection(title: "Featured", entries: featured))
        }
        if !remaining.isEmpty {
            sections.append(ProviderModelSection(title: "All models", entries: remaining))
        }
        return sections
    }

    public static func entries(
        for vendor: ChatVendor,
        catalog: ModelCatalog,
        query: String = ""
    ) -> [ModelCatalogEntry] {
        let all = vendor.models(in: catalog)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            let haystack = [
                entry.displayName,
                entry.id,
                entry.cliAlias ?? "",
                entry.recommendedFor ?? "",
                entry.badge ?? "",
                contextLabel(for: entry) ?? "",
            ]
            .joined(separator: " ")
            .lowercased()
            return haystack.contains(needle)
        }
    }

    public static func contextLabel(for entry: ModelCatalogEntry) -> String? {
        guard let tokens = entry.contextWindow, tokens > 0 else { return nil }
        if tokens >= 1_000_000, tokens % 1_000_000 == 0 {
            return "\(tokens / 1_000_000)M context"
        }
        if tokens >= 1_000 {
            return "\(tokens / 1_000)K context"
        }
        return "\(tokens) context"
    }

    public static func metadataLine(for entry: ModelCatalogEntry) -> String {
        var pieces: [String] = [entry.id]
        if let context = contextLabel(for: entry) {
            pieces.append(context)
        }
        if let recommended = entry.recommendedFor, !recommended.isEmpty {
            pieces.append(recommended)
        }
        return pieces.joined(separator: " · ")
    }

    public static func badges(for entry: ModelCatalogEntry) -> [String] {
        var badges: [String] = []
        if let badge = entry.badge, !badge.isEmpty {
            badges.append(badge)
        }
        if entry.supportsEffort {
            badges.append("Effort")
        } else if entry.provider == .cursor {
            badges.append("Auto")
        }
        if entry.supportsThinking, !badges.contains("Thinking") {
            badges.append("Thinking")
        }
        return badges
    }

    public static func supportsEffort(
        vendor: ChatVendor,
        modelId: String?,
        catalog: ModelCatalog
    ) -> Bool {
        guard let modelId,
              let entry = vendor.models(in: catalog).first(where: { $0.id == modelId || $0.cliAlias == modelId }) else {
            return vendor.defaultEffort != nil
        }
        return entry.supportsEffort
    }

    public static func normalizedEffort(
        _ effort: ReasoningEffort?,
        vendor: ChatVendor,
        modelId: String?,
        catalog: ModelCatalog
    ) -> ReasoningEffort? {
        supportsEffort(vendor: vendor, modelId: modelId, catalog: catalog) ? effort : nil
    }

    private static func isFeaturedOpenRouterModel(_ entry: ModelCatalogEntry) -> Bool {
        ModelCatalog.bundled.opencode.contains(where: { $0.id == entry.id })
            || entry.recommendedFor != nil
            || entry.badge != nil
    }
}
