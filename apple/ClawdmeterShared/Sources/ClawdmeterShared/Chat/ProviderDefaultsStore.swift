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
    /// Global user-defined order for the Starred rail. Each entry is a
    /// composite id `"<choice.id>|<model.id>"`. ⌘1…⌘9 bind to this order.
    /// When empty, the picker falls back to `favoriteModelsByVendor` order.
    public var favoriteOrder: [String]
    public var updatedAt: Date

    public init(
        modelByVendor: [String: String] = [:],
        effortByVendor: [String: String] = [:],
        favoriteModelsByVendor: [String: [String]] = [:],
        favoriteOrder: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.modelByVendor = modelByVendor
        self.effortByVendor = effortByVendor
        self.favoriteModelsByVendor = favoriteModelsByVendor
        self.favoriteOrder = favoriteOrder
        self.updatedAt = updatedAt
    }

    public static let empty = ProviderDefaultsSnapshot(
        modelByVendor: [:],
        effortByVendor: [:],
        favoriteModelsByVendor: [:],
        favoriteOrder: [],
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    private enum CodingKeys: String, CodingKey {
        case modelByVendor, effortByVendor, favoriteModelsByVendor, favoriteOrder, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.modelByVendor = try c.decodeIfPresent([String: String].self, forKey: .modelByVendor) ?? [:]
        self.effortByVendor = try c.decodeIfPresent([String: String].self, forKey: .effortByVendor) ?? [:]
        self.favoriteModelsByVendor = try c.decodeIfPresent([String: [String]].self, forKey: .favoriteModelsByVendor) ?? [:]
        self.favoriteOrder = try c.decodeIfPresent([String].self, forKey: .favoriteOrder) ?? []
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    public static func favoriteCompositeId(choiceId: String, modelId: String) -> String {
        "\(choiceId)|\(modelId)"
    }

    public static func parseFavoriteCompositeId(_ compositeId: String) -> (choiceId: String, modelId: String)? {
        guard let separator = compositeId.firstIndex(of: "|") else { return nil }
        let choiceId = String(compositeId[..<separator])
        let modelId = String(compositeId[compositeId.index(after: separator)...])
        guard !choiceId.isEmpty, !modelId.isEmpty else { return nil }
        return (choiceId, modelId)
    }

    /// Resolved Starred-rail order. Prunes stale entries and falls back to the
    /// legacy per-vendor ordering when `favoriteOrder` has not been written yet.
    public func resolvedFavoriteOrder(enabledVendors: [ChatVendor]) -> [String] {
        let active = activeFavoriteCompositeIds()
        if !favoriteOrder.isEmpty {
            let pruned = favoriteOrder.filter { active.contains($0) }
            let missing = active.filter { !pruned.contains($0) }
            return pruned + missing
        }
        var out: [String] = []
        for vendor in enabledVendors {
            for modelId in favoriteModelIds(for: vendor) {
                out.append(Self.favoriteCompositeId(choiceId: vendor.rawValue, modelId: modelId))
            }
        }
        return out
    }

    private func activeFavoriteCompositeIds() -> Set<String> {
        favoriteModelsByVendor.reduce(into: Set<String>()) { result, pair in
            for modelId in pair.value {
                result.insert(Self.favoriteCompositeId(choiceId: pair.key, modelId: modelId))
            }
        }
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

    public func modelId(forChoice choice: ProviderChoice) -> String? {
        let value = modelByVendor[choice.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    public func modelId(forChoice choice: ProviderChoice, catalog: ModelCatalog) -> String? {
        if let explicit = modelId(forChoice: choice),
           Self.catalog(catalog, contains: explicit, for: choice) {
            return explicit
        }
        return choice.defaultModelId(in: catalog)
    }

    public mutating func setDefault(forChoice choice: ProviderChoice, model: String?) {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            modelByVendor.removeValue(forKey: choice.id)
        } else {
            modelByVendor[choice.id] = trimmed
        }
        updatedAt = Date()
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

    private static func catalog(_ catalog: ModelCatalog, contains id: String, for choice: ProviderChoice) -> Bool {
        let entries = choice.models(in: catalog)
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

@MainActor
public final class ProviderDefaultsStore: ObservableObject {
    /// Posted after any persist write so sibling store instances (Settings,
    /// Chat, SessionLauncher, loopback client) can refresh without an HTTP
    /// round trip through the daemon.
    public static let changedNotification = Notification.Name("clawdmeter.providerDefaults.changed")

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

    public func modelId(forChoice choice: ProviderChoice, catalog: ModelCatalog = .bundled) -> String? {
        snapshot.modelId(forChoice: choice, catalog: catalog)
    }

    public func effort(for vendor: ChatVendor, catalog: ModelCatalog = .bundled) -> ReasoningEffort? {
        snapshot.effort(for: vendor, catalog: catalog)
    }

    @discardableResult
    public func setDefault(
        forChoice choice: ProviderChoice,
        model: String?,
        effort: ReasoningEffort?,
        clearModel: Bool = false,
        clearEffort: Bool = false,
        catalog: ModelCatalog = .bundled
    ) -> ProviderDefaultsSnapshot {
        var next = snapshot
        if clearModel {
            next.modelByVendor.removeValue(forKey: choice.id)
        } else if let model {
            next.setDefault(forChoice: choice, model: model)
        }

        let effectiveModel = next.modelId(forChoice: choice, catalog: catalog)
        let supportsEffort = ProviderModelPickerSupport.supportsEffort(
            choice: choice,
            modelId: effectiveModel,
            catalog: catalog
        )
        if clearEffort || !supportsEffort {
            next.effortByVendor.removeValue(forKey: choice.id)
        } else if let effort {
            next.effortByVendor[choice.id] = effort.rawValue
        }

        next.updatedAt = Date()
        persist(next)
        return next
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
        let compositeId = ProviderDefaultsSnapshot.favoriteCompositeId(
            choiceId: vendor.rawValue,
            modelId: trimmed
        )
        var current = next.favoriteModelsByVendor[vendor.rawValue] ?? []
        if let index = current.firstIndex(of: trimmed) {
            current.remove(at: index)
            next.favoriteOrder.removeAll { $0 == compositeId }
        } else {
            current.insert(trimmed, at: 0)
            if !next.favoriteOrder.contains(compositeId) {
                next.favoriteOrder.append(compositeId)
            }
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

    /// Reorders the Starred rail. `destinationIndex` is the row index the
    /// dragged item should land on (SwiftUI drop-target semantics).
    @discardableResult
    public func moveFavorite(
        dragId: String,
        to destinationIndex: Int,
        enabledVendors: [ChatVendor]
    ) -> ProviderDefaultsSnapshot {
        var next = snapshot
        var order = next.resolvedFavoriteOrder(enabledVendors: enabledVendors)
        guard let sourceIndex = order.firstIndex(of: dragId),
              sourceIndex != destinationIndex,
              destinationIndex >= 0,
              destinationIndex < order.count else {
            return snapshot
        }
        order.remove(at: sourceIndex)
        order.insert(dragId, at: destinationIndex)
        next.favoriteOrder = order
        next.updatedAt = Date()
        persist(next)
        return next
    }

    public func favoriteModelIds(for vendor: ChatVendor) -> [String] {
        snapshot.favoriteModelIds(for: vendor)
    }

    public func resolvedFavoriteOrder(enabledVendors: [ChatVendor]) -> [String] {
        snapshot.resolvedFavoriteOrder(enabledVendors: enabledVendors)
    }

    public func isFavorite(modelId: String, vendor: ChatVendor) -> Bool {
        snapshot.isFavorite(modelId: modelId, vendor: vendor)
    }

    private func persist(_ next: ProviderDefaultsSnapshot) {
        defaults.set(next.modelByVendor, forKey: Self.defaultsPrefix + "modelByVendor")
        defaults.set(next.effortByVendor, forKey: Self.defaultsPrefix + "effortByVendor")
        defaults.set(next.favoriteModelsByVendor, forKey: Self.defaultsPrefix + "favoriteModelsByVendor")
        defaults.set(next.favoriteOrder, forKey: Self.defaultsPrefix + "favoriteOrder")
        defaults.set(next.updatedAt.timeIntervalSince1970, forKey: Self.defaultsPrefix + "updatedAt")
        snapshot = next
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    private static func readSnapshot(defaults: UserDefaults) -> ProviderDefaultsSnapshot {
        let modelMap = defaults.dictionary(forKey: defaultsPrefix + "modelByVendor") as? [String: String] ?? [:]
        let effortMap = defaults.dictionary(forKey: defaultsPrefix + "effortByVendor") as? [String: String] ?? [:]
        let favoritesMap = defaults.dictionary(forKey: defaultsPrefix + "favoriteModelsByVendor") as? [String: [String]] ?? [:]
        let favoriteOrder = defaults.array(forKey: defaultsPrefix + "favoriteOrder") as? [String] ?? []
        let updatedAtRaw = defaults.object(forKey: defaultsPrefix + "updatedAt") as? TimeInterval
        return ProviderDefaultsSnapshot(
            modelByVendor: modelMap,
            effortByVendor: effortMap,
            favoriteModelsByVendor: favoritesMap,
            favoriteOrder: favoriteOrder,
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

    public static func sections(
        for choice: ProviderChoice,
        catalog: ModelCatalog,
        query: String
    ) -> [ProviderModelSection] {
        if case .builtin(let vendor) = choice {
            return sections(for: vendor, catalog: catalog, query: query)
        }
        let filtered = entries(for: choice, catalog: catalog, query: query)
        return filtered.isEmpty ? [] : [ProviderModelSection(title: "Models", entries: filtered)]
    }

    public static func entries(
        for choice: ProviderChoice,
        catalog: ModelCatalog,
        query: String = ""
    ) -> [ModelCatalogEntry] {
        if case .builtin(let vendor) = choice {
            return entries(for: vendor, catalog: catalog, query: query)
        }
        let all = choice.models(in: catalog)
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

    public static func supportsEffort(
        choice: ProviderChoice,
        modelId: String?,
        catalog: ModelCatalog
    ) -> Bool {
        if case .custom = choice { return false }
        guard case .builtin(let vendor) = choice else { return false }
        guard let modelId,
              let entry = vendor.models(in: catalog).first(where: { $0.id == modelId || $0.cliAlias == modelId }) else {
            return vendor.defaultEffort != nil
        }
        return entry.supportsEffort
    }

    public static func normalizedEffort(
        _ effort: ReasoningEffort?,
        choice: ProviderChoice,
        modelId: String?,
        catalog: ModelCatalog
    ) -> ReasoningEffort? {
        supportsEffort(choice: choice, modelId: modelId, catalog: catalog) ? effort : nil
    }

    private static func isFeaturedOpenRouterModel(_ entry: ModelCatalogEntry) -> Bool {
        ModelCatalog.bundled.opencode.contains(where: { $0.id == entry.id })
            || entry.recommendedFor != nil
            || entry.badge != nil
    }
}
