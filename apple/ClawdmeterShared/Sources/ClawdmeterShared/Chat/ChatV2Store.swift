import Foundation
#if canImport(Combine)
import Combine
#endif

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
    @Published public var selectedProvider: AgentKind
    @Published public var selectedModelByProvider: [AgentKind: String]
    @Published public var selectedEffortByProvider: [AgentKind: ReasoningEffort]
    @Published public var deepResearch: Bool
    @Published public var codexBackendPreference: CodexChatBackend
    @Published public var attachments: [ChatV2Attachment] = []

    private let defaults: UserDefaults
    private static let defaultsPrefix = "clawdmeter.chatv2."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Restore prior session picks. Each individual key falls back
        // to a sensible default; collectively this gives a working
        // composer state on cold-launch without prompting the user
        // for everything.
        let restoredProviderRaw = defaults.string(forKey: Self.defaultsPrefix + "provider") ?? AgentKind.claude.rawValue
        self.selectedProvider = AgentKind(rawValue: restoredProviderRaw) ?? .claude
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
        defaults.set(selectedProvider.rawValue, forKey: Self.defaultsPrefix + "provider")
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
        if let userPick = selectedModelByProvider[selectedProvider], !userPick.isEmpty {
            return userPick
        }
        switch selectedProvider {
        case .claude:   return ModelCatalog.bundled.claude.first?.id
        case .codex:    return ModelCatalog.bundled.codex.first?.id
        case .gemini:   return ModelCatalog.bundled.gemini.first?.id
        case .opencode: return nil
        case .unknown:  return nil
        }
    }

    public var selectedEffort: ReasoningEffort? {
        selectedEffortByProvider[selectedProvider]
    }

    // MARK: - First-send helper (Mac + iOS)

    /// Build the `SendKind` the V2 composer's first send dispatches
    /// through `ComposerSendController.send(via:)`. Centralizing this
    /// keeps the V2 composer view dumb — it just calls
    /// `sendCtl.send(via: store.firstSendKind())`.
    public func firstSendKind() -> SendKind {
        .chatCreateV2(
            provider: selectedProvider,
            model: selectedModel,
            effort: selectedEffort,
            deepResearch: deepResearch,
            codexBackend: selectedProvider == .codex ? codexBackendPreference : nil
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

    private static func decodeStringMap(_ d: [String: Any]) -> [AgentKind: String] {
        var out: [AgentKind: String] = [:]
        for (k, v) in d {
            guard let agent = AgentKind(rawValue: k), let str = v as? String else { continue }
            out[agent] = str
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

    public init(id: UUID = UUID(), displayName: String, pathOnDaemon: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.pathOnDaemon = pathOnDaemon
    }
}
