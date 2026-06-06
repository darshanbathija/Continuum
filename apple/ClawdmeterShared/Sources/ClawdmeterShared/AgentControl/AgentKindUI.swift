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
        ProviderDescriptor.byAgent[agent]?.assetName ?? "ClaudeLogo"
    }

    /// `true` when the platform's image view should template-tint the
    /// asset (Codex silhouette + Gemini "G" need template mode; Claude
    /// burst stays full-color). OpenCode is also a silhouette and
    /// template-tints with the accent so dark / light themes both work.
    public static func isTemplate(for agent: AgentKind) -> Bool {
        ProviderDescriptor.byAgent[agent]?.isTemplateAsset ?? true
    }

    /// Provider display label (used in chips, recent rows, session
    /// detail headers, etc.). Matches the CLI binary the user invokes
    /// (`claude`, `codex`, `gemini`, `opencode`). `.unknown` renders as
    /// "Other agent" — the X3 forward-compat fallback for future kinds
    /// older clients don't recognize yet.
    public static func displayName(for agent: AgentKind) -> String {
        ProviderDescriptor.byAgent[agent]?.agentDisplayName ?? "Other agent"
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
        ProviderDescriptor.byAgent[agent]?.accentRGB ?? (0x88, 0x88, 0x88)
    }

    /// Provider display label for `UsageRecord.Provider` (the analytics-
    /// layer enum). Same labels as `displayName(for: AgentKind)` — the
    /// two enums happen to align value-by-value (now including
    /// `.opencode` after PR #29).
    public static func displayName(for provider: UsageRecord.Provider) -> String {
        ProviderDescriptor.byAnalyticsProvider[provider]?.agentDisplayName ?? provider.rawValue
    }

    public static func assetName(for provider: UsageRecord.Provider) -> String {
        ProviderDescriptor.byAnalyticsProvider[provider]?.assetName ?? "ClaudeLogo"
    }

    public static func isTemplate(for provider: UsageRecord.Provider) -> Bool {
        ProviderDescriptor.byAnalyticsProvider[provider]?.isTemplateAsset ?? true
    }
}
