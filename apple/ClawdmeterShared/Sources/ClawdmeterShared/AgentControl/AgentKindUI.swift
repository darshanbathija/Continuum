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
        case .unknown: return "ClaudeLogo" // neutral fallback; UI shows "Other"
        }
    }

    /// `true` when the platform's image view should template-tint the
    /// asset (Codex silhouette + Gemini "G" need template mode; Claude
    /// burst stays full-color).
    public static func isTemplate(for agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return false
        case .codex, .gemini, .unknown: return true
        }
    }

    /// Provider display label (used in chips, recent rows, session
    /// detail headers, etc.). Matches the CLI binary the user invokes
    /// (`claude`, `codex`, `gemini`). `.unknown` renders as "Other agent"
    /// — the X3 forward-compat fallback for future kinds older clients
    /// don't recognize yet.
    public static func displayName(for agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .unknown: return "Other agent"
        }
    }

    /// Accent color as 0-255 RGB triple. Callers wrap into AppKit/UIKit
    /// Color / NSColor / UIColor — keeping this type-agnostic lets the
    /// shared package compile on all four platforms.
    /// - Claude: terra-cotta (#D97757)
    /// - Codex: blue (#5C9DFF)
    /// - Gemini: Google blue (#4285F4)
    /// - Unknown: neutral gray (#888888) — X3 fallback
    public static func accentRGB(for agent: AgentKind) -> (r: Int, g: Int, b: Int) {
        switch agent {
        case .claude: return (0xD9, 0x77, 0x57)
        case .codex:  return (0x5C, 0x9D, 0xFF)
        case .gemini: return (0x42, 0x85, 0xF4)
        case .unknown: return (0x88, 0x88, 0x88)
        }
    }

    /// Provider display label for `UsageRecord.Provider` (the analytics-
    /// layer enum). Same labels as `displayName(for: AgentKind)` — the
    /// two enums happen to align value-by-value.
    public static func displayName(for provider: UsageRecord.Provider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }

    public static func assetName(for provider: UsageRecord.Provider) -> String {
        switch provider {
        case .claude: return "ClaudeLogo"
        case .codex:  return "CodexLogo"
        case .gemini: return "GeminiLogo"
        }
    }

    public static func isTemplate(for provider: UsageRecord.Provider) -> Bool {
        switch provider {
        case .claude: return false
        case .codex, .gemini: return true
        }
    }
}
