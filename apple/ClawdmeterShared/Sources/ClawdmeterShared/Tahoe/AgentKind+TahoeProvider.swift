#if canImport(SwiftUI)
import Foundation

/// Cross-platform mapping from the wire-level `AgentKind` to the Tahoe
/// design-system `TahoeProvider`. The legacy `MacChatDataAdapter`
/// exposed this on Mac-only code; lifting it to Shared so both the
/// Mac and iOS V2 chat views can drive the same Tahoe glyphs + tints
/// without each platform reinventing the case statement.
///
/// `.unknown` falls through to `.claude` because every V2 surface
/// expects to render *something* — picking the legacy default keeps
/// the layout intact while the forward-compat fallback handles the
/// new-agent case at a higher level (chip label etc.).
public extension AgentKind {
    var tahoeProvider: TahoeProvider {
        switch self {
        case .claude:   return .claude
        case .codex:    return .codex
        case .gemini:   return .gemini
        case .opencode: return .opencode
        case .cursor:   return .cursor
        case .grok:     return .grok
        case .unknown:  return .claude
        }
    }

    /// Branded display name for chat column headers + sidebar rows. Uses the
    /// Tahoe branding (e.g. Gemini → "Antigravity").
    var brandedChatName: String {
        tahoeProvider.displayName
    }
}

public extension ChatVendor {
    var tahoeProvider: TahoeProvider {
        switch self {
        case .chatgpt: return .codex
        case .claude: return .claude
        case .antigravity: return .gemini
        case .cursor: return .cursor
        case .opencode: return .opencode
        case .openrouter: return .openrouter
        case .grok: return .grok
        }
    }
}

public extension TahoeProvider {
    /// Resolve the branded glyph lane when the wire agent is shared
    /// (`AgentKind.opencode` backs both OpenCode Go and OpenRouter BYOK).
    static func resolved(
        agent: AgentKind,
        modelId: String? = nil,
        chatVendorRaw: String? = nil
    ) -> TahoeProvider {
        if let chatVendorRaw, let vendor = ChatVendor(rawValue: chatVendorRaw) {
            return vendor.tahoeProvider
        }
        if agent == .opencode, let modelId, modelId.contains("/") {
            return .openrouter
        }
        return agent.tahoeProvider
    }

    /// Header / chip glyph that follows the selected catalog model when set.
    static func resolvedForModelEntry(
        modelId: String?,
        customProviderId: String?,
        fallbackAgent: AgentKind,
        catalog: ModelCatalog
    ) -> TahoeProvider {
        if let trimmed = modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty,
           let entry = catalog.entry(forId: trimmed, customProviderId: customProviderId) {
            return resolved(agent: entry.provider, modelId: trimmed)
        }
        return resolved(agent: fallbackAgent, modelId: modelId)
    }
}

public extension AgentSession {
    var tahoeProvider: TahoeProvider {
        TahoeProvider.resolved(
            agent: agent,
            modelId: model,
            chatVendorRaw: runtimeBinding?.metadata["chatVendor"]
        )
    }
}
#endif
