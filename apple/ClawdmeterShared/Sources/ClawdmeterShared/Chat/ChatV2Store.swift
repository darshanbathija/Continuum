import Foundation
#if canImport(Combine)
import Combine
#endif

public enum ChatVendor: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case chatgpt
    case claude
    case antigravity
    case cursor
    case openrouter
    case grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .openrouter: return "OpenCode"
        case .grok: return "Grok"
        }
    }

    public var backingProvider: AgentKind {
        switch self {
        case .chatgpt: return .codex
        case .claude: return .claude
        case .antigravity: return .gemini
        case .cursor: return .cursor
        case .openrouter: return .opencode
        case .grok: return .grok
        }
    }

    public var billingProvider: String? {
        switch self {
        case .openrouter: return "opencode-go"
        default: return nil
        }
    }

    public var defaultEffort: ReasoningEffort? {
        switch self {
        case .chatgpt, .claude: return .high
        case .openrouter, .antigravity, .cursor, .grok: return nil
        }
    }

    public func models(in catalog: ModelCatalog) -> [ModelCatalogEntry] {
        switch self {
        case .chatgpt: return catalog.codex
        case .claude: return catalog.claude
        case .antigravity: return catalog.gemini
        case .cursor: return catalog.cursor
        case .openrouter: return catalog.opencode
        case .grok: return catalog.grok
        }
    }

    public func defaultModelId(in catalog: ModelCatalog) -> String? {
        models(in: catalog).first?.id
    }

    public static func migrated(from provider: AgentKind) -> ChatVendor? {
        switch provider {
        case .claude: return .claude
        case .codex: return .chatgpt
        case .gemini: return .antigravity
        case .cursor: return .cursor
        case .opencode: return .openrouter
        case .grok: return .grok
        case .unknown: return nil
        }
    }
}

public struct ChatVendorSelection: Codable, Hashable, Sendable, Identifiable {
    public let vendor: ChatVendor
    public var modelId: String?
    public var effort: ReasoningEffort?

    public var id: ChatVendor { vendor }

    public init(vendor: ChatVendor, modelId: String? = nil, effort: ReasoningEffort? = nil) {
        self.vendor = vendor
        self.modelId = modelId
        self.effort = effort
    }
}

/// v0.23 (Chat V2 — T10): cross-platform observable for the V2 chat
/// composer's pick state. Mac and iOS both bind their composer chips
/// to this; the underlying `ComposerSendController` (DRY — eng-review
/// D5) handles the actual text + sending state. ChatV2Store layers
/// the picker + attachment + Deep Research state on top + persists
/// the last-used picks across launches via UserDefaults.
///
/// Why this is small: the heavy lifting (snapshot streaming) goes
/// through `ChatSnapshotSource` (T1) on each platform's local store.
/// The heavy composer plumbing goes through `ComposerSendController`.
/// What's left — the V2-specific selection state — lives here so both
/// platforms share the persistence keys + the deep-research-aware
/// first-send dispatch helper.
@MainActor
public final class ChatV2Store: ObservableObject {
    @Published public var selectedChoices: [ProviderChoice]
    @Published public var selectedModelByVendor: [ChatVendor: String]
    @Published public var selectedEffortByVendor: [ChatVendor: ReasoningEffort]
    @Published public var selectedModelByChoice: [ProviderChoice: String]
    @Published public var selectedEffortByChoice: [ProviderChoice: ReasoningEffort]

    /// Read-only bridge for legacy call sites that only understand built-ins.
    public var selectedVendors: [ChatVendor] {
        selectedChoices.compactMap(\.chatVendor)
    }

    /// Multi-account (wire v28): per-vendor pinned account
    /// (`ProviderInstanceId.wireId`). Keyed by stock vendor — custom
    /// providers carry their own credentials and have no account axis.
    /// Absent / unknown ⇒ the primary account. Views validate the stored
    /// value against the fetched `/provider-instances` list before
    /// sending so a removed account degrades to Default instead of a
    /// create-time 422.
    @Published public var selectedAccountByVendor: [ChatVendor: String]

    // Legacy provider-mode fields remain public for older call sites and
    // migration, but Chat V2 now derives runtime behavior from
    // `selectedVendors.count`.
    @Published public var mode: ChatV2Mode
    @Published public var selectedProvider: AgentKind
    @Published public var broadcastProviders: Set<AgentKind>
    @Published public var selectedReplyProvider: AgentKind
    @Published public var selectedModelByProvider: [AgentKind: String]
    @Published public var selectedEffortByProvider: [AgentKind: ReasoningEffort]
    @Published public var deepResearch: Bool
    @Published public var attachments: [ChatV2Attachment] = []

    private let defaults: UserDefaults
    private let providerDefaults: ProviderDefaultsStore
    private var enabledChoiceScope: [ProviderChoice]?
    private var persistedChoiceSelection: [ProviderChoice]
    private static let defaultsPrefix = "clawdmeter.chatv2."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let providerDefaults = ProviderDefaultsStore(defaults: defaults)
        self.providerDefaults = providerDefaults
        let hasVendorSelection = defaults.object(forKey: Self.defaultsPrefix + "vendors") != nil
        let persistedChoices = Self.restorePersistedChoices(defaults: defaults)
        let restoredChoices = Self.restoreChoices(persistedChoices: persistedChoices)
        self.selectedChoices = restoredChoices
        self.persistedChoiceSelection = persistedChoices
        let restoredModelByVendor = providerDefaults.snapshot.decodedModelMap()
        let restoredEffortByVendor = providerDefaults.snapshot.decodedEffortMap()
        var restoredModelByChoice = Self.decodeChoiceStringMap(
            defaults.dictionary(forKey: Self.defaultsPrefix + "modelByVendor") ?? [:]
        )
        if restoredModelByChoice.isEmpty {
            restoredModelByChoice = Dictionary(
                uniqueKeysWithValues: restoredModelByVendor.map { (.builtin($0.key), $0.value) }
            )
        }
        var restoredEffortByChoice = Self.decodeChoiceEffortMap(
            defaults.dictionary(forKey: Self.defaultsPrefix + "effortByVendor") ?? [:]
        )
        if restoredEffortByChoice.isEmpty {
            restoredEffortByChoice = Dictionary(
                uniqueKeysWithValues: restoredEffortByVendor.compactMap { vendor, effort in
                    (.builtin(vendor), effort)
                }
            )
        }
        self.selectedModelByVendor = restoredModelByVendor
        self.selectedEffortByVendor = restoredEffortByVendor
        self.selectedModelByChoice = restoredModelByChoice
        self.selectedEffortByChoice = restoredEffortByChoice
        let restoredModeRaw = defaults.string(forKey: Self.defaultsPrefix + "mode") ?? ChatV2Mode.broadcast.rawValue
        self.mode = ChatV2Mode(rawValue: restoredModeRaw)
            ?? (restoredChoices.count > 1 ? .broadcast : .solo)
        let primaryProvider = restoredChoices.first?.backingAgent(in: .bundled) ?? .codex
        let restoredProviderRaw = hasVendorSelection
            ? (defaults.string(forKey: Self.defaultsPrefix + "provider") ?? primaryProvider.rawValue)
            : primaryProvider.rawValue
        let restoredProvider = AgentKind(rawValue: restoredProviderRaw) ?? primaryProvider
        self.selectedProvider = restoredProvider
        let restoredBroadcast = hasVendorSelection
            ? (defaults.stringArray(forKey: Self.defaultsPrefix + "broadcastProviders") ?? restoredChoices.compactMap(\.chatVendor).map(\.backingProvider.rawValue))
            : restoredChoices.compactMap(\.chatVendor).map(\.backingProvider.rawValue)
        let decodedBroadcast = Set(restoredBroadcast.compactMap(AgentKind.init(rawValue:)))
            .intersection(Self.broadcastCapableProviders)
        self.broadcastProviders = decodedBroadcast.isEmpty
            ? Set(restoredChoices.compactMap { $0.backingAgent(in: .bundled) })
            : decodedBroadcast
        let restoredReplyRaw = hasVendorSelection
            ? (defaults.string(forKey: Self.defaultsPrefix + "replyProvider") ?? primaryProvider.rawValue)
            : primaryProvider.rawValue
        let restoredReplyProvider = AgentKind(rawValue: restoredReplyRaw) ?? primaryProvider
        self.selectedReplyProvider = restoredReplyProvider
        self.selectedModelByProvider = Self.decodeStringMap(
            defaults.dictionary(forKey: Self.defaultsPrefix + "modelByProvider") ?? [:]
        )
        self.selectedEffortByProvider = Self.decodeEffortMap(
            defaults.dictionary(forKey: Self.defaultsPrefix + "effortByProvider") ?? [:]
        )
        self.deepResearch = defaults.bool(forKey: Self.defaultsPrefix + "deepResearch")
        self.selectedAccountByVendor = Self.decodeVendorStringMap(
            defaults.dictionary(forKey: Self.defaultsPrefix + "accountByVendor") ?? [:]
        )
    }

    /// The pinned account wireId for a vendor — nil means the primary.
    /// `available` (the fetched instance list) filters out stale pins.
    public func accountWireId(for vendor: ChatVendor, available: [ProviderInstanceDTO]? = nil) -> String? {
        guard let wireId = selectedAccountByVendor[vendor] else { return nil }
        if let available, !available.contains(where: { $0.wireId == wireId }) {
            return nil
        }
        return wireId
    }

    public func selectAccount(_ wireId: String?, for vendor: ChatVendor) {
        if let wireId, ProviderInstanceId.isSecondaryWireId(wireId) {
            selectedAccountByVendor[vendor] = wireId
        } else {
            selectedAccountByVendor.removeValue(forKey: vendor)
        }
        persist()
    }

    // MARK: - Persistence

    /// Call from `.onChange(of: ...)` modifiers in the V2 view to
    /// persist updates after the user picks something. Cheap — single
    /// UserDefaults write per modifier — so callers don't need to
    /// debounce.
    public func persist() {
        selectedChoices = normalizedChoicesForEnabledProviders(selectedChoices)
        syncLegacyVendorMapsFromChoices()
        let choicesToPersist: [ProviderChoice]
        if selectedChoices.isEmpty, !persistedChoiceSelection.isEmpty {
            choicesToPersist = persistedChoiceSelection
        } else {
            persistedChoiceSelection = selectedChoices
            choicesToPersist = selectedChoices
        }
        mode = selectedChoices.count > 1 ? .broadcast : .solo
        selectedProvider = selectedChoices.first?.backingAgent(in: .bundled) ?? .codex
        broadcastProviders = Set(selectedChoices.compactMap { $0.backingAgent(in: .bundled) })
        if !broadcastProviders.contains(selectedReplyProvider) {
            selectedReplyProvider = selectedProvider
        }
        defaults.set(choicesToPersist.map(\.id), forKey: Self.defaultsPrefix + "vendors")
        defaults.set(Self.encodeMap(selectedModelByChoice), forKey: Self.defaultsPrefix + "modelByVendor")
        defaults.set(Self.encodeMap(selectedAccountByVendor), forKey: Self.defaultsPrefix + "accountByVendor")
        defaults.set(Self.encodeMap(selectedEffortByChoice.mapValues { $0.rawValue }),
                     forKey: Self.defaultsPrefix + "effortByVendor")
        defaults.set(mode.rawValue, forKey: Self.defaultsPrefix + "mode")
        defaults.set(selectedProvider.rawValue, forKey: Self.defaultsPrefix + "provider")
        defaults.set(
            broadcastProviders
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.rawValue),
            forKey: Self.defaultsPrefix + "broadcastProviders"
        )
        defaults.set(selectedReplyProvider.rawValue, forKey: Self.defaultsPrefix + "replyProvider")
        defaults.set(Self.encodeMap(selectedModelByProvider), forKey: Self.defaultsPrefix + "modelByProvider")
        defaults.set(Self.encodeMap(selectedEffortByProvider.mapValues { $0.rawValue }),
                     forKey: Self.defaultsPrefix + "effortByProvider")
        defaults.set(deepResearch, forKey: Self.defaultsPrefix + "deepResearch")
    }

    /// Picker accessor — falls back to the bundled catalog default
    /// when the user hasn't picked yet. The V2 model pill reads this
    /// and renders the result.
    public var selectedModel: String? {
        model(forChoice: primaryChoice)
    }

    public var selectedEffort: ReasoningEffort? {
        effort(forChoice: primaryChoice)
    }

    public static let defaultChatVendorOrder: [ChatVendor] = ProviderDescriptor.chatOrder
    public static let broadcastCapableProviders: Set<AgentKind> = Set(defaultChatVendorOrder.map(\.backingProvider))
    public static let defaultBroadcastProviderOrder: [AgentKind] = defaultChatVendorOrder.map(\.backingProvider)

    public static func enabledChatVendors(from providerIDs: [String]?) -> [ChatVendor] {
        guard let providerIDs else { return defaultChatVendorOrder }
        let enabled = Set(providerIDs.map { ProviderRegistry.rootProviderID(for: $0) })
        return defaultChatVendorOrder.filter { vendor in
            enabled.contains(ProviderRegistry.rootProviderID(for: vendor.backingProvider.rawValue))
        }
    }

    public static func enabledChatChoices(
        from providerIDs: [String]?,
        catalog: ModelCatalog,
        usageSnapshot: UsageHistorySnapshot? = nil
    ) -> [ProviderChoice] {
        var choices = enabledChatVendors(from: providerIDs).map(ProviderChoice.builtin)
        if AgentControlWireVersion.supportsCustomProviders(serverWireVersion: AgentControlWireVersion.current) {
            choices.append(contentsOf: catalog.customProviders.filter(\.enabled).map { .custom($0.id) })
        }
        return sortModelPickerChoices(choices, usageSnapshot: usageSnapshot, catalog: catalog)
    }

    /// Orders the model-picker rail by trailing-30d token usage (descending),
    /// then by the canonical fallback order (Claude → Codex → Cursor →
    /// OpenRouter → Grok → Antigravity), then display name for custom providers.
    nonisolated public static func sortModelPickerChoices(
        _ choices: [ProviderChoice],
        usageSnapshot: UsageHistorySnapshot?,
        catalog: ModelCatalog
    ) -> [ProviderChoice] {
        func past30dTokenUsage(for choice: ProviderChoice) -> Int {
            guard let snapshot = usageSnapshot,
                  let provider = choice.usageProvider,
                  let totals = snapshot.byProvider[provider]
            else { return 0 }
            return totals.past30d.totals.totalTokens
        }

        return choices.sorted { lhs, rhs in
            let usageDelta = past30dTokenUsage(for: lhs) - past30dTokenUsage(for: rhs)
            if usageDelta != 0 { return usageDelta > 0 }
            let rankDelta = lhs.modelPickerDefaultRank - rhs.modelPickerDefaultRank
            if rankDelta != 0 { return rankDelta < 0 }
            return lhs.displayName(in: catalog).localizedCaseInsensitiveCompare(rhs.displayName(in: catalog)) == .orderedAscending
        }
    }

    public var primaryChoice: ProviderChoice {
        selectedChoices.first ?? effectiveEnabledChatChoices.first ?? .builtin(.chatgpt)
    }

    public var primaryVendor: ChatVendor {
        primaryChoice.chatVendor ?? effectiveEnabledChatVendors.first ?? .chatgpt
    }

    public var selectedChoiceCount: Int {
        selectedChoices.count
    }

    public var selectedVendorCount: Int {
        selectedChoices.count
    }

    public var selectedVendorSelections: [ChatVendorSelection] {
        selectedChoices.compactMap { choice in
            guard let vendor = choice.chatVendor else { return nil }
            return ChatVendorSelection(
                vendor: vendor,
                modelId: model(forChoice: choice),
                effort: effort(forChoice: choice)
            )
        }
    }

    public var broadcastProviderOrder: [AgentKind] {
        selectedChoices.compactMap { $0.backingAgent(in: .bundled) }
    }

    public var broadcastReady: Bool {
        selectedChoices.count >= 2
    }

    public func toggleBroadcastProvider(_ provider: AgentKind) {
        guard let vendor = ChatVendor.migrated(from: provider) else { return }
        toggleChoice(.builtin(vendor))
    }

    public func isChoiceSelected(_ choice: ProviderChoice) -> Bool {
        selectedChoices.contains(choice)
    }

    public func isVendorSelected(_ vendor: ChatVendor) -> Bool {
        isChoiceSelected(.builtin(vendor))
    }

    public func toggleChoice(_ choice: ProviderChoice) {
        guard effectiveEnabledChatChoices.contains(choice) else { return }
        if selectedChoices.contains(choice) {
            guard selectedChoices.count > 1 else { return }
            selectedChoices.removeAll { $0 == choice }
        } else {
            selectedChoices.append(choice)
        }
        selectedChoices = normalizedChoicesForEnabledProviders(selectedChoices)
        persist()
    }

    public func toggleVendor(_ vendor: ChatVendor) {
        toggleChoice(.builtin(vendor))
    }

    public func applyEnabledChoiceScope(_ choices: [ProviderChoice]?, persistSelection: Bool = false) {
        enabledChoiceScope = choices.map(Self.uniqueChoices)
        normalizeForEnabledProviders(persistSelection: persistSelection)
    }

    public func applyEnabledVendorScope(_ vendors: [ChatVendor]?, persistSelection: Bool = false) {
        applyEnabledChoiceScope(vendors?.map(ProviderChoice.builtin), persistSelection: persistSelection)
    }

    public func normalizeForEnabledProviders(persistSelection: Bool = false) {
        let candidates = selectedChoices.isEmpty ? persistedChoiceSelection : selectedChoices
        let normalized = normalizedChoicesForEnabledProviders(candidates)
        guard normalized != selectedChoices else { return }
        selectedChoices = normalized
        mode = selectedChoices.count > 1 ? .broadcast : .solo
        if let provider = selectedChoices.first?.backingAgent(in: .bundled) {
            selectedProvider = provider
            selectedReplyProvider = provider
            broadcastProviders = Set(selectedChoices.compactMap { $0.backingAgent(in: .bundled) })
        } else {
            broadcastProviders = []
        }
        if persistSelection {
            persist()
        }
    }

    public func selectModel(_ modelId: String, forChoice choice: ProviderChoice, catalog: ModelCatalog = .bundled) {
        selectedModelByChoice[choice] = modelId
        if let vendor = choice.chatVendor {
            selectedModelByVendor[vendor] = modelId
            selectedModelByProvider[vendor.backingProvider] = modelId
        }
        let effectiveEffort = ProviderModelPickerSupport.normalizedEffort(
            selectedEffortByChoice[choice],
            choice: choice,
            modelId: modelId,
            catalog: catalog
        )
        if effectiveEffort == nil {
            selectedEffortByChoice.removeValue(forKey: choice)
            if let vendor = choice.chatVendor {
                selectedEffortByVendor.removeValue(forKey: vendor)
                selectedEffortByProvider.removeValue(forKey: vendor.backingProvider)
            }
        }
        providerDefaults.setDefault(
            forChoice: choice,
            model: modelId,
            effort: effectiveEffort,
            catalog: catalog
        )
        persist()
    }

    public func selectModel(_ modelId: String, for vendor: ChatVendor, catalog: ModelCatalog = .bundled) {
        selectModel(modelId, forChoice: .builtin(vendor), catalog: catalog)
    }

    public func selectEffort(_ effort: ReasoningEffort?, forChoice choice: ProviderChoice, catalog: ModelCatalog = .bundled) {
        let effectiveEffort = ProviderModelPickerSupport.normalizedEffort(
            effort,
            choice: choice,
            modelId: model(forChoice: choice, catalog: catalog),
            catalog: catalog
        )
        if let effectiveEffort {
            selectedEffortByChoice[choice] = effectiveEffort
            if let vendor = choice.chatVendor {
                selectedEffortByVendor[vendor] = effectiveEffort
                selectedEffortByProvider[vendor.backingProvider] = effectiveEffort
            }
        } else {
            selectedEffortByChoice.removeValue(forKey: choice)
            if let vendor = choice.chatVendor {
                selectedEffortByVendor.removeValue(forKey: vendor)
                selectedEffortByProvider.removeValue(forKey: vendor.backingProvider)
            }
        }
        providerDefaults.setDefault(
            forChoice: choice,
            model: model(forChoice: choice, catalog: catalog),
            effort: effectiveEffort,
            clearEffort: effectiveEffort == nil,
            catalog: catalog
        )
        persist()
    }

    public func selectEffort(_ effort: ReasoningEffort?, for vendor: ChatVendor, catalog: ModelCatalog = .bundled) {
        selectEffort(effort, forChoice: .builtin(vendor), catalog: catalog)
    }

    public func applyProviderDefaults(_ snapshot: ProviderDefaultsSnapshot, catalog: ModelCatalog = .bundled) {
        providerDefaults.replace(with: snapshot)
        for vendor in Self.defaultChatVendorOrder {
            if let modelId = snapshot.modelId(for: vendor),
               Self.catalog(catalog, contains: modelId, for: vendor) {
                selectedModelByVendor[vendor] = modelId
                selectedModelByProvider[vendor.backingProvider] = modelId
            } else {
                selectedModelByVendor.removeValue(forKey: vendor)
                selectedModelByProvider.removeValue(forKey: vendor.backingProvider)
            }

            let effectiveEffort = ProviderModelPickerSupport.normalizedEffort(
                snapshot.effort(for: vendor),
                vendor: vendor,
                modelId: selectedModelByVendor[vendor],
                catalog: catalog
            )
            if let effectiveEffort {
                selectedEffortByVendor[vendor] = effectiveEffort
                selectedEffortByProvider[vendor.backingProvider] = effectiveEffort
            } else {
                selectedEffortByVendor.removeValue(forKey: vendor)
                selectedEffortByProvider.removeValue(forKey: vendor.backingProvider)
            }
        }
        persist()
    }

    public func model(for provider: AgentKind) -> String? {
        if let vendor = selectedVendors.first(where: { $0.backingProvider == provider }) {
            return model(for: vendor)
        }
        if let userPick = selectedModelByProvider[provider], !userPick.isEmpty {
            return userPick
        }
        if let vendor = ChatVendor.migrated(from: provider),
           let providerDefault = providerDefaults.modelId(for: vendor) {
            return providerDefault
        }
        switch provider {
        case .claude:   return ModelCatalog.bundled.claude.first?.id
        case .codex:    return ModelCatalog.bundled.codex.first?.id
        case .gemini:   return ModelCatalog.bundled.gemini.first?.id
        case .opencode: return ModelCatalog.bundled.opencode.first?.id
        case .cursor:   return ModelCatalog.bundled.cursor.first?.id
        case .grok:     return ModelCatalog.bundled.grok.first?.id
        case .unknown:  return nil
        }
    }

    public func model(for vendor: ChatVendor, catalog: ModelCatalog = .bundled) -> String? {
        model(forChoice: .builtin(vendor), catalog: catalog)
    }

    public func effort(for provider: AgentKind) -> ReasoningEffort? {
        if let vendor = selectedVendors.first(where: { $0.backingProvider == provider }) {
            return effort(for: vendor)
        }
        return selectedEffortByProvider[provider]
    }

    public func effort(for vendor: ChatVendor, catalog: ModelCatalog = .bundled) -> ReasoningEffort? {
        effort(forChoice: .builtin(vendor), catalog: catalog)
    }

    public func frontierSlots(catalog: ModelCatalog = .bundled) -> [FrontierModelSlot] {
        selectedChoices.map { choice in
            switch choice {
            case .builtin(let vendor):
                return FrontierModelSlot(
                    provider: vendor.backingProvider,
                    model: model(forChoice: choice, catalog: catalog),
                    effort: effort(forChoice: choice, catalog: catalog),
                    codexChatBackend: nil,
                    deepResearch: deepResearch,
                    chatVendor: vendor,
                    billingProvider: vendor.billingProvider
                )
            case .custom(let providerId):
                let agent = choice.backingAgent(in: catalog) ?? .codex
                return FrontierModelSlot(
                    provider: agent,
                    model: model(forChoice: choice, catalog: catalog),
                    effort: nil,
                    codexChatBackend: nil,
                    deepResearch: deepResearch,
                    chatVendor: nil,
                    billingProvider: providerId,
                    customProviderId: providerId
                )
            }
        }
    }

    public func model(forChoice choice: ProviderChoice, catalog: ModelCatalog = .bundled) -> String? {
        if let userPick = selectedModelByChoice[choice], !userPick.isEmpty {
            return userPick
        }
        if let providerDefault = providerDefaults.snapshot.modelId(forChoice: choice, catalog: catalog) {
            return providerDefault
        }
        if let vendor = choice.chatVendor,
           let legacyPick = selectedModelByProvider[vendor.backingProvider], !legacyPick.isEmpty {
            return legacyPick
        }
        return choice.defaultModelId(in: catalog)
    }

    public func effort(forChoice choice: ProviderChoice, catalog: ModelCatalog = .bundled) -> ReasoningEffort? {
        let modelId = model(forChoice: choice, catalog: catalog)
        if let modelId,
           let entry = choice.models(in: catalog).first(where: { $0.id == modelId }),
           !entry.supportsEffort {
            return nil
        }
        return selectedEffortByChoice[choice]
            ?? (choice.chatVendor.flatMap { providerDefaults.effort(for: $0, catalog: catalog) })
            ?? (choice.chatVendor.flatMap { selectedEffortByProvider[$0.backingProvider] })
            ?? choice.chatVendor?.defaultEffort
    }

    // MARK: - First-send helper (Mac + iOS)

    /// Build the `SendKind` the V2 composer's first send dispatches
    /// through `ComposerSendController.send(via:)`. Centralizing this
    /// keeps the V2 composer view dumb — it just calls
    /// `sendCtl.send(via: store.firstSendKind())`.
    public func firstSendKind(catalog: ModelCatalog = .bundled) -> SendKind {
        let choice = primaryChoice
        return .chatCreateV2(
            provider: choice.backingAgent(in: catalog) ?? primaryVendor.backingProvider,
            model: selectedModel,
            effort: selectedEffort,
            deepResearch: deepResearch,
            codexBackend: nil,
            customProviderId: choice.customProviderId
        )
    }

    // MARK: - Attachments

    public func addAttachment(_ a: ChatV2Attachment) {
        // Cap to 10 to avoid runaway accidental drag-drops; the V2 UI
        // shows "+N more" if anyone hits the cap in practice.
        guard attachments.count < 10 else { return }
        attachments.append(a)
    }

    public func removeAttachment(id: UUID) {
        attachments.removeAll(where: { $0.id == id })
    }

    public func clearAttachments() {
        attachments.removeAll()
    }

    // MARK: - Encode/decode helpers

    private static func encodeMap<V>(_ m: [AgentKind: V]) -> [String: V] {
        Dictionary(uniqueKeysWithValues: m.map { ($0.key.rawValue, $0.value) })
    }

    private static func encodeMap<V>(_ m: [ChatVendor: V]) -> [String: V] {
        Dictionary(uniqueKeysWithValues: m.map { ($0.key.rawValue, $0.value) })
    }

    private static func restorePersistedChoices(defaults: UserDefaults) -> [ProviderChoice] {
        guard let raw = defaults.stringArray(forKey: Self.defaultsPrefix + "vendors") else { return [] }
        let decoded = raw.compactMap(ProviderChoice.decode)
        return mergePersistedChoices(decoded)
    }

    /// Raw persisted selection — builtins filtered to known vendors only; custom
    /// ids kept verbatim for later scope normalization.
    private static func mergePersistedChoices(_ decoded: [ProviderChoice]) -> [ProviderChoice] {
        let builtins = decoded.compactMap { choice -> ProviderChoice? in
            guard case .builtin(let vendor) = choice else { return nil }
            return defaultChatVendorOrder.contains(vendor) ? choice : nil
        }
        let customs = decoded.filter { if case .custom = $0 { return true }; return false }
        return uniqueChoices(builtins + customs)
    }

    private static func mergeRestoredChoices(_ decoded: [ProviderChoice]) -> [ProviderChoice] {
        let builtins = decoded.filter { if case .builtin = $0 { return true }; return false }
        let customs = decoded.filter { if case .custom = $0 { return true }; return false }
        let filteredBuiltins = normalizedChoices(builtins, enabledChoices: defaultEnabledBuiltinChoices)
        return uniqueChoices(filteredBuiltins + customs)
    }

    private static func restoreChoices(persistedChoices: [ProviderChoice]) -> [ProviderChoice] {
        if !persistedChoices.isEmpty {
            return normalizedChoicesForEnabledProviders(persistedChoices)
        }
        return firstEnabledChoice().map { [$0] } ?? []
    }

    public static let defaultBuiltinChoices: [ProviderChoice] = defaultChatVendorOrder.map(ProviderChoice.builtin)

    private static var defaultEnabledBuiltinChoices: [ProviderChoice] {
        ProviderEnablement.enabledChatVendors(in: defaultChatVendorOrder).map(ProviderChoice.builtin)
    }

    public static func normalizedChoices(_ choices: [ProviderChoice], enabledChoices: [ProviderChoice]) -> [ProviderChoice] {
        let out = uniqueChoices(choices.filter { enabledChoices.contains($0) })
        return out.isEmpty ? Array(enabledChoices.prefix(1)) : out
    }

    private static func uniqueChoices(_ choices: [ProviderChoice]) -> [ProviderChoice] {
        var out: [ProviderChoice] = []
        for choice in choices {
            guard !out.contains(choice) else { continue }
            out.append(choice)
        }
        return out
    }

    private func normalizedChoicesForEnabledProviders(_ choices: [ProviderChoice]) -> [ProviderChoice] {
        let enabled = effectiveEnabledChatChoices
        let builtins = choices.filter { if case .builtin = $0 { return true }; return false }
        let customs = choices.filter { if case .custom = $0 { return true }; return false }
        let enabledBuiltins = enabled.filter { if case .builtin = $0 { return true }; return false }
        let filteredBuiltins = Self.normalizedChoices(builtins, enabledChoices: enabledBuiltins)
        let filteredCustoms = customs.filter { enabled.contains($0) }
        if enabledChoiceScope == nil {
            return Self.uniqueChoices(filteredBuiltins + customs)
        }
        return Self.uniqueChoices(filteredBuiltins + filteredCustoms)
    }

    private var effectiveEnabledChatChoices: [ProviderChoice] {
        if let enabledChoiceScope { return enabledChoiceScope }
        return Self.defaultEnabledBuiltinChoices
    }

    private static func normalizedChoicesForEnabledProviders(_ choices: [ProviderChoice]) -> [ProviderChoice] {
        let enabled = defaultEnabledBuiltinChoices
        let builtins = choices.filter { if case .builtin = $0 { return true }; return false }
        let customs = choices.filter { if case .custom = $0 { return true }; return false }
        let filteredBuiltins = normalizedChoices(builtins, enabledChoices: enabled)
        return uniqueChoices(filteredBuiltins + customs)
    }

    private static func firstEnabledChoice() -> ProviderChoice? {
        ProviderRegistry.firstEnabledProvider(for: .chat).map { .builtin($0.chatVendor) }
    }

    private func syncLegacyVendorMapsFromChoices() {
        selectedModelByVendor = Dictionary(
            uniqueKeysWithValues: selectedChoices.compactMap { choice in
                guard let vendor = choice.chatVendor,
                      let model = selectedModelByChoice[choice] else { return nil }
                return (vendor, model)
            }
        )
        selectedEffortByVendor = Dictionary(
            uniqueKeysWithValues: selectedChoices.compactMap { choice in
                guard let vendor = choice.chatVendor,
                      let effort = selectedEffortByChoice[choice] else { return nil }
                return (vendor, effort)
            }
        )
    }

    private static func encodeMap(_ m: [ProviderChoice: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: m.map { ($0.key.id, $0.value) })
    }

    private static func encodeMap(_ m: [ProviderChoice: ReasoningEffort]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: m.map { ($0.key.id, $0.value.rawValue) })
    }

    private static func decodeChoiceStringMap(_ d: [String: Any]) -> [ProviderChoice: String] {
        var out: [ProviderChoice: String] = [:]
        for (k, v) in d {
            guard let choice = ProviderChoice.decode(k), let str = v as? String else { continue }
            out[choice] = str
        }
        return out
    }

    private static func decodeChoiceEffortMap(_ d: [String: Any]) -> [ProviderChoice: ReasoningEffort] {
        var out: [ProviderChoice: ReasoningEffort] = [:]
        for (k, v) in d {
            guard let choice = ProviderChoice.decode(k),
                  let str = v as? String,
                  let effort = ReasoningEffort(rawValue: str) else { continue }
            out[choice] = effort
        }
        return out
    }

    private static func restorePersistedVendors(defaults: UserDefaults) -> [ChatVendor] {
        restorePersistedChoices(defaults: defaults).compactMap(\.chatVendor)
    }

    private static func restoreVendors(persistedVendors: [ChatVendor]) -> [ChatVendor] {
        restoreChoices(persistedChoices: persistedVendors.map(ProviderChoice.builtin)).compactMap(\.chatVendor)
    }

    public static func normalizedVendors(_ vendors: [ChatVendor], enabledVendors: [ChatVendor]) -> [ChatVendor] {
        let out = uniqueVendors(vendors.filter { enabledVendors.contains($0) })
        return out.isEmpty ? Array(enabledVendors.prefix(1)) : out
    }

    private static func uniqueVendors(_ vendors: [ChatVendor]) -> [ChatVendor] {
        var out: [ChatVendor] = []
        for vendor in vendors {
            guard !out.contains(vendor) else { continue }
            out.append(vendor)
            if out.count == 3 { break }
        }
        return out
    }

    private func normalizedVendorsForEnabledProviders(_ vendors: [ChatVendor]) -> [ChatVendor] {
        normalizedChoicesForEnabledProviders(vendors.map(ProviderChoice.builtin)).compactMap(\.chatVendor)
    }

    private var effectiveEnabledChatVendors: [ChatVendor] {
        effectiveEnabledChatChoices.compactMap(\.chatVendor)
    }

    private static func normalizedVendorsForEnabledProviders(_ vendors: [ChatVendor]) -> [ChatVendor] {
        normalizedChoicesForEnabledProviders(vendors.map(ProviderChoice.builtin)).compactMap(\.chatVendor)
    }

    private static func firstEnabledVendor() -> ChatVendor? {
        ProviderRegistry.firstEnabledProvider(for: .chat)?.chatVendor
    }

    private static func catalog(_ catalog: ModelCatalog, contains id: String, for vendor: ChatVendor) -> Bool {
        let entries = vendor.models(in: catalog)
        guard !entries.isEmpty else { return true }
        return entries.contains { $0.id == id || $0.cliAlias == id }
    }

    private static func decodeStringMap(_ d: [String: Any]) -> [AgentKind: String] {
        var out: [AgentKind: String] = [:]
        for (k, v) in d {
            guard let agent = AgentKind(rawValue: k), let str = v as? String else { continue }
            out[agent] = str
        }
        return out
    }

    private static func decodeVendorStringMap(_ d: [String: Any]) -> [ChatVendor: String] {
        var out: [ChatVendor: String] = [:]
        for (k, v) in d {
            guard let vendor = ChatVendor(rawValue: k), let str = v as? String else { continue }
            out[vendor] = str
        }
        return out
    }

    private static func decodeEffortMap(_ d: [String: Any]) -> [AgentKind: ReasoningEffort] {
        var out: [AgentKind: ReasoningEffort] = [:]
        for (k, v) in d {
            guard let agent = AgentKind(rawValue: k),
                  let str = v as? String,
                  let effort = ReasoningEffort(rawValue: str) else { continue }
            out[agent] = effort
        }
        return out
    }

    private static func decodeVendorEffortMap(_ d: [String: Any]) -> [ChatVendor: ReasoningEffort] {
        var out: [ChatVendor: ReasoningEffort] = [:]
        for (k, v) in d {
            guard let vendor = ChatVendor(rawValue: k),
                  let str = v as? String,
                  let effort = ReasoningEffort(rawValue: str) else { continue }
            out[vendor] = effort
        }
        return out
    }
}

/// One attachment staged by the V2 composer before send. The V2 view
/// uploads each via `AgentControlClient.uploadAttachment(...)` and
/// replaces `pathOnDaemon` with the daemon-returned absolute path,
/// which is then `@`-mentioned into the user's prompt body at send
/// time (the existing path-mention contract).
public struct ChatV2Attachment: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Local filename + extension. Drives the thumbnail chip label.
    public let displayName: String
    /// Daemon-side absolute path returned by `/sessions/:id/attachments`.
    /// Nil while the upload is in flight.
    public var pathOnDaemon: String?
    /// Local file URL retained until first-send creates a session/group
    /// and can upload the bytes. This is essential on iOS where the Mac
    /// daemon cannot read the phone's sandbox path directly.
    public var localFileURL: URL?

    public init(id: UUID = UUID(), displayName: String, pathOnDaemon: String? = nil, localFileURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.pathOnDaemon = pathOnDaemon
        self.localFileURL = localFileURL
    }
}

public enum ChatV2Mode: String, Codable, Hashable, Sendable, CaseIterable {
    case broadcast
    case solo
}

public enum ChatOpenTarget: Codable, Hashable, Sendable {
    case solo(UUID)
    case frontier(UUID)
    case transcript(sessionId: UUID, jsonlPath: String)

    public var id: UUID {
        switch self {
        case .solo(let id), .frontier(let id), .transcript(let id, _):
            return id
        }
    }

    public var isFrontier: Bool {
        if case .frontier = self { return true }
        return false
    }

    public var isReadOnlyTranscript: Bool {
        if case .transcript = self { return true }
        return false
    }
}

public struct BroadcastProviderSelection: Codable, Hashable, Sendable {
    public let providers: [AgentKind]

    public init(providers: [AgentKind]) {
        self.providers = providers
    }
}
