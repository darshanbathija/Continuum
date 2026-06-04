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
        case .openrouter: return "OpenRouter"
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

    public var codexBackend: CodexChatBackend? {
        self == .chatgpt ? .sdk : nil
    }

    public var billingProvider: String? {
        switch self {
        case .openrouter: return "openrouter"
        default: return nil
        }
    }

    public var defaultEffort: ReasoningEffort? {
        switch self {
        case .chatgpt, .claude, .openrouter: return .high
        case .antigravity, .cursor, .grok: return nil
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
    @Published public var selectedVendors: [ChatVendor]
    @Published public var selectedModelByVendor: [ChatVendor: String]
    @Published public var selectedEffortByVendor: [ChatVendor: ReasoningEffort]

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
    @Published public var codexBackendPreference: CodexChatBackend
    @Published public var attachments: [ChatV2Attachment] = []

    private let defaults: UserDefaults
    private let providerDefaults: ProviderDefaultsStore
    private static let defaultsPrefix = "clawdmeter.chatv2."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let providerDefaults = ProviderDefaultsStore(defaults: defaults)
        self.providerDefaults = providerDefaults
        // Restore prior session picks. Each individual key falls back
        // to a sensible default; collectively this gives a working
        // composer state on cold-launch without prompting the user
        // for everything.
        let hasVendorSelection = defaults.object(forKey: Self.defaultsPrefix + "vendors") != nil
        let restoredVendors = Self.restoreVendors(defaults: defaults)
        self.selectedVendors = restoredVendors
        self.selectedModelByVendor = providerDefaults.snapshot.decodedModelMap()
        self.selectedEffortByVendor = providerDefaults.snapshot.decodedEffortMap()
        let restoredModeRaw = defaults.string(forKey: Self.defaultsPrefix + "mode") ?? ChatV2Mode.broadcast.rawValue
        self.mode = ChatV2Mode(rawValue: restoredModeRaw)
            ?? (restoredVendors.count > 1 ? .broadcast : .solo)
        let primaryProvider = restoredVendors.first?.backingProvider ?? .codex
        let restoredProviderRaw = hasVendorSelection
            ? (defaults.string(forKey: Self.defaultsPrefix + "provider") ?? primaryProvider.rawValue)
            : primaryProvider.rawValue
        let restoredProvider = AgentKind(rawValue: restoredProviderRaw) ?? primaryProvider
        self.selectedProvider = restoredProvider
        let restoredBroadcast = hasVendorSelection
            ? (defaults.stringArray(forKey: Self.defaultsPrefix + "broadcastProviders") ?? restoredVendors.map(\.backingProvider.rawValue))
            : restoredVendors.map(\.backingProvider.rawValue)
        let decodedBroadcast = Set(restoredBroadcast.compactMap(AgentKind.init(rawValue:)))
            .intersection(Self.broadcastCapableProviders)
        self.broadcastProviders = decodedBroadcast.isEmpty
            ? Set(restoredVendors.map(\.backingProvider))
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
        let codexRaw = defaults.string(forKey: Self.defaultsPrefix + "codexBackend") ?? CodexChatBackend.sdk.rawValue
        self.codexBackendPreference = CodexChatBackend(rawValue: codexRaw) ?? .sdk
    }

    // MARK: - Persistence

    /// Call from `.onChange(of: ...)` modifiers in the V2 view to
    /// persist updates after the user picks something. Cheap — single
    /// UserDefaults write per modifier — so callers don't need to
    /// debounce.
    public func persist() {
        selectedVendors = Self.normalizedVendors(selectedVendors)
        mode = selectedVendors.count > 1 ? .broadcast : .solo
        selectedProvider = selectedVendors.first?.backingProvider ?? .codex
        broadcastProviders = Set(selectedVendors.map(\.backingProvider))
        if !broadcastProviders.contains(selectedReplyProvider) {
            selectedReplyProvider = selectedProvider
        }
        defaults.set(selectedVendors.map(\.rawValue), forKey: Self.defaultsPrefix + "vendors")
        defaults.set(Self.encodeMap(selectedModelByVendor), forKey: Self.defaultsPrefix + "modelByVendor")
        defaults.set(Self.encodeMap(selectedEffortByVendor.mapValues { $0.rawValue }),
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
        defaults.set(codexBackendPreference.rawValue, forKey: Self.defaultsPrefix + "codexBackend")
    }

    /// Picker accessor — falls back to the bundled catalog default
    /// when the user hasn't picked yet. The V2 model pill reads this
    /// and renders the result.
    public var selectedModel: String? {
        model(for: primaryVendor)
    }

    public var selectedEffort: ReasoningEffort? {
        effort(for: primaryVendor)
    }

    public static let defaultChatVendorOrder: [ChatVendor] = [.chatgpt, .claude, .antigravity, .cursor, .openrouter, .grok]
    public static let broadcastCapableProviders: Set<AgentKind> = Set(defaultChatVendorOrder.map(\.backingProvider))
    public static let defaultBroadcastProviderOrder: [AgentKind] = defaultChatVendorOrder.map(\.backingProvider)

    public var primaryVendor: ChatVendor {
        selectedVendors.first ?? .chatgpt
    }

    public var selectedVendorCount: Int {
        selectedVendors.count
    }

    public var selectedVendorSelections: [ChatVendorSelection] {
        selectedVendors.map { vendor in
            ChatVendorSelection(
                vendor: vendor,
                modelId: model(for: vendor),
                effort: effort(for: vendor)
            )
        }
    }

    public var broadcastProviderOrder: [AgentKind] {
        selectedVendors.map(\.backingProvider)
    }

    public var broadcastReady: Bool {
        selectedVendors.count >= 2
    }

    public func toggleBroadcastProvider(_ provider: AgentKind) {
        guard let vendor = ChatVendor.migrated(from: provider) else { return }
        toggleVendor(vendor)
    }

    public func isVendorSelected(_ vendor: ChatVendor) -> Bool {
        selectedVendors.contains(vendor)
    }

    public func toggleVendor(_ vendor: ChatVendor) {
        if selectedVendors.contains(vendor) {
            guard selectedVendors.count > 1 else { return }
            selectedVendors.removeAll { $0 == vendor }
        } else {
            // No upper cap on compare — the broadcast answer columns scroll
            // horizontally, so allow selecting every available provider.
            selectedVendors.append(vendor)
        }
        selectedVendors = Self.normalizedVendors(selectedVendors)
        persist()
    }

    public func selectModel(_ modelId: String, for vendor: ChatVendor, catalog: ModelCatalog = .bundled) {
        selectedModelByVendor[vendor] = modelId
        if let provider = ChatVendor.migrated(from: vendor.backingProvider)?.backingProvider {
            selectedModelByProvider[provider] = modelId
        }
        let effectiveEffort = ProviderModelPickerSupport.normalizedEffort(
            selectedEffortByVendor[vendor],
            vendor: vendor,
            modelId: modelId,
            catalog: catalog
        )
        if effectiveEffort == nil {
            selectedEffortByVendor.removeValue(forKey: vendor)
            selectedEffortByProvider.removeValue(forKey: vendor.backingProvider)
        }
        providerDefaults.setDefault(
            for: vendor,
            model: modelId,
            effort: effectiveEffort,
            catalog: catalog
        )
        persist()
    }

    public func selectEffort(_ effort: ReasoningEffort?, for vendor: ChatVendor, catalog: ModelCatalog = .bundled) {
        let effectiveEffort = ProviderModelPickerSupport.normalizedEffort(
            effort,
            vendor: vendor,
            modelId: model(for: vendor, catalog: catalog),
            catalog: catalog
        )
        if let effectiveEffort {
            selectedEffortByVendor[vendor] = effectiveEffort
            selectedEffortByProvider[vendor.backingProvider] = effectiveEffort
        } else {
            selectedEffortByVendor.removeValue(forKey: vendor)
            selectedEffortByProvider.removeValue(forKey: vendor.backingProvider)
        }
        providerDefaults.setDefault(
            for: vendor,
            model: model(for: vendor, catalog: catalog),
            effort: effectiveEffort,
            clearEffort: effectiveEffort == nil,
            catalog: catalog
        )
        persist()
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
        if let userPick = selectedModelByVendor[vendor], !userPick.isEmpty {
            return userPick
        }
        if let providerDefault = providerDefaults.modelId(for: vendor, catalog: catalog) {
            return providerDefault
        }
        if let legacyPick = selectedModelByProvider[vendor.backingProvider], !legacyPick.isEmpty {
            return legacyPick
        }
        return vendor.defaultModelId(in: catalog)
    }

    public func effort(for provider: AgentKind) -> ReasoningEffort? {
        if let vendor = selectedVendors.first(where: { $0.backingProvider == provider }) {
            return effort(for: vendor)
        }
        return selectedEffortByProvider[provider]
    }

    public func effort(for vendor: ChatVendor, catalog: ModelCatalog = .bundled) -> ReasoningEffort? {
        let modelId = model(for: vendor, catalog: catalog)
        if let modelId,
           let entry = vendor.models(in: catalog).first(where: { $0.id == modelId }),
           !entry.supportsEffort {
            return nil
        }
        return selectedEffortByVendor[vendor]
            ?? providerDefaults.effort(for: vendor, catalog: catalog)
            ?? selectedEffortByProvider[vendor.backingProvider]
            ?? vendor.defaultEffort
    }

    public func frontierSlots(catalog: ModelCatalog = .bundled) -> [FrontierModelSlot] {
        selectedVendors.map { vendor in
            FrontierModelSlot(
                provider: vendor.backingProvider,
                model: model(for: vendor, catalog: catalog),
                effort: effort(for: vendor, catalog: catalog),
                codexChatBackend: vendor == .chatgpt ? codexBackendPreference : nil,
                deepResearch: deepResearch,
                chatVendor: vendor,
                billingProvider: vendor.billingProvider
            )
        }
    }

    // MARK: - First-send helper (Mac + iOS)

    /// Build the `SendKind` the V2 composer's first send dispatches
    /// through `ComposerSendController.send(via:)`. Centralizing this
    /// keeps the V2 composer view dumb — it just calls
    /// `sendCtl.send(via: store.firstSendKind())`.
    public func firstSendKind() -> SendKind {
        .chatCreateV2(
            provider: primaryVendor.backingProvider,
            model: selectedModel,
            effort: selectedEffort,
            deepResearch: deepResearch,
            codexBackend: primaryVendor == .chatgpt ? codexBackendPreference : nil
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

    private static func restoreVendors(defaults: UserDefaults) -> [ChatVendor] {
        if let raw = defaults.stringArray(forKey: Self.defaultsPrefix + "vendors") {
            return normalizedVendors(raw.compactMap(ChatVendor.init(rawValue:)))
        }
        return [.chatgpt]
    }

    private static func normalizedVendors(_ vendors: [ChatVendor]) -> [ChatVendor] {
        var out: [ChatVendor] = []
        for vendor in vendors {
            guard defaultChatVendorOrder.contains(vendor), !out.contains(vendor) else { continue }
            out.append(vendor)
            if out.count == 3 { break }
        }
        return out.isEmpty ? [.chatgpt] : out
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
