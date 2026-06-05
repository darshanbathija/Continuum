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
#endif
