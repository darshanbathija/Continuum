import Foundation

/// Cross-platform display metadata for `AgentKind` — the source of truth
/// for asset names, display labels, and accent-color tuples used across
/// Mac/iOS/Watch chrome. Centralizing this kills the `agent == .claude ?
/// "ClaudeLogo" : "CodexLogo"` pattern that silently mislabels Gemini
/// sessions as Codex (the falsey branch swallows any non-Claude agent).
///
/// Pure data — no AppKit/UIKit. Callers map `accentRGB` to their UI
/// framework's Color.
public enum AgentKindUI {
    /// Asset name in `Assets.xcassets` shared by all three platforms.
    /// Codex + Gemini are alpha-shaped silhouettes designed for template
    /// rendering; Claude's burst is a full-color logo. Callers use
    /// `isTemplate(for:)` to flip rendering mode.
    public static func assetName(for agent: AgentKind) -> String {
        switch agent {
        case .claude: return "ClaudeLogo"
        case .codex:  return "CodexLogo"
        case .gemini: return "GeminiLogo"
        case .opencode: return "OpencodeLogo" // PR #29: alpha-shaped silhouette
        case .cursor: return "CodexLogo"
        case .grok: return "GrokLogo"
        case .unknown: return "ClaudeLogo" // neutral fallback; UI shows "Other"
        }
    }

    /// `true` when the platform's image view should template-tint the
    /// asset (Codex silhouette + Gemini "G" need template mode; Claude
    /// burst stays full-color). OpenCode is also a silhouette and
    /// template-tints with the accent so dark / light themes both work.
    public static func isTemplate(for agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return false
        case .codex, .gemini, .opencode, .cursor, .grok, .unknown: return true
        }
    }

    /// Provider display label (used in chips, recent rows, session
    /// detail headers, etc.). Matches the CLI binary the user invokes
    /// (`claude`, `codex`, `gemini`, `opencode`). `.unknown` renders as
    /// "Other agent" — the X3 forward-compat fallback for future kinds
    /// older clients don't recognize yet.
    public static func displayName(for agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .unknown: return "Other agent"
        }
    }

    /// Provider dot color as a 0-255 RGB triple (Quiet Black Workbench
    /// rationed palette — see DESIGN.md + `TahoeProvider.dot`). This is the
    /// cross-cutting source for non-SwiftUI / widget / menu-bar chrome that
    /// can't read `ContinuumTokens` directly. Color travels with a glyph +
    /// label; never used as a button/header fill.
    /// - Claude: terra-cotta (#D97757) — the heritage warmth, only here.
    /// - Codex: graphite (#8A9099)
    /// - Antigravity (gemini key): cool blue (#5C9DFF)
    /// - OpenCode: muted violet (#9B87D4)
    /// - Cursor: cool steel (#7FA8B5)
    /// - Grok / unknown: neutral slate / grey
    public static func accentRGB(for agent: AgentKind) -> (r: Int, g: Int, b: Int) {
        switch agent {
        case .claude: return (0xD9, 0x77, 0x57)
        case .codex:  return (0x8A, 0x90, 0x99)
        case .gemini: return (0x5C, 0x9D, 0xFF)
        case .opencode: return (0x9B, 0x87, 0xD4) // muted violet
        case .cursor: return (0x7F, 0xA8, 0xB5) // cool steel
        case .grok: return (0x70, 0x74, 0x7C) // neutral slate, distinct from codex graphite
        case .unknown: return (0x88, 0x88, 0x88)
        }
    }

    /// Provider display label for `UsageRecord.Provider` (the analytics-
    /// layer enum). Same labels as `displayName(for: AgentKind)` — the
    /// two enums happen to align value-by-value (now including
    /// `.opencode` after PR #29).
    public static func displayName(for provider: UsageRecord.Provider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        }
    }

    public static func assetName(for provider: UsageRecord.Provider) -> String {
        switch provider {
        case .claude: return "ClaudeLogo"
        case .codex:  return "CodexLogo"
        case .gemini: return "GeminiLogo"
        case .opencode: return "OpencodeLogo"
        case .cursor: return "CodexLogo"
        case .grok: return "GrokLogo"
        }
    }

    public static func isTemplate(for provider: UsageRecord.Provider) -> Bool {
        switch provider {
        case .claude: return false
        case .codex, .gemini, .opencode, .cursor, .grok: return true
        }
    }
}
