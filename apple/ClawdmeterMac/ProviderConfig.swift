import Foundation
import SwiftUI
import ClawdmeterShared

/// Per-source UI + behavior config. One per provider (Claude, Codex, Gemini).
public struct ProviderConfig: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let logoAssetName: String            // Bundle resource name (e.g. "ClaudeLogo")
    public let reviveModel: String              // Model id previously used by AutoReviver
    public let reviveEndpoint: URL              // Reserved for a future non-generative AutoReviver endpoint
    public let reviveAuthVersion: String?       // e.g. "anthropic-version: 2023-06-01" (nil for OpenAI)
    public let storageKeyPrefix: String         // Namespacing for @AppStorage
    /// True when this provider supports a non-consuming "perpetual 5h timer"
    /// auto-revive path. Prompt-based keepalives are not allowed: they create
    /// visible throwaway conversations and spend quota.
    public let supportsAutoRevive: Bool

    /// True when this provider exposes a separate weekly quota window
    /// alongside the 5h session window. Claude has both (Anthropic Max plan
    /// session + weekly cap). Codex has both (wham/usage session + weekly).
    /// Gemini cloudcode-pa returns ONE quota per model with a single
    /// refresh time — no weekly bucket. The Mac dashboard's Weekly limits
    /// card hides when this is false so we don't lie about a window that
    /// doesn't exist upstream. Settings → Providers also drives the "5h
    /// refresh" vs "Session N% · Weekly N%" copy from this flag.
    public let hasWeeklyWindow: Bool

    public init(
        id: String,
        displayName: String,
        logoAssetName: String,
        reviveModel: String,
        reviveEndpoint: URL,
        reviveAuthVersion: String?,
        storageKeyPrefix: String,
        supportsAutoRevive: Bool = false,
        hasWeeklyWindow: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.logoAssetName = logoAssetName
        self.reviveModel = reviveModel
        self.reviveEndpoint = reviveEndpoint
        self.reviveAuthVersion = reviveAuthVersion
        self.storageKeyPrefix = storageKeyPrefix
        self.supportsAutoRevive = supportsAutoRevive
        self.hasWeeklyWindow = hasWeeklyWindow
    }

    public static let claude = ProviderConfig(
        id: "claude",
        displayName: "Claude",
        logoAssetName: "ClaudeLogo",
        reviveModel: "claude-haiku-4-5",
        reviveEndpoint: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        reviveAuthVersion: "2023-06-01",
        storageKeyPrefix: "clawdmeter.claude",
        supportsAutoRevive: AutoReviveSupport.supports("claude")
    )

    public static let codex = ProviderConfig(
        id: "codex",
        displayName: "Codex",
        logoAssetName: "CodexLogo",
        reviveModel: "gpt-5.5-mini",
        reviveEndpoint: URL(string: "https://chatgpt.com/backend-api/conversation")!,
        reviveAuthVersion: nil,
        storageKeyPrefix: "clawdmeter.codex",
        supportsAutoRevive: AutoReviveSupport.supports("codex")
    )

    /// Gemini via Google's Cloud Code Assist API (same endpoint Antigravity
    /// uses). Auth via the user's `~/.gemini/oauth_creds.json`. No
    /// `reviveModel` — Gemini's quota model doesn't have a perpetual-5h
    /// window to keep warm. Dashboard hides the auto-revive section when
    /// `supportsAutoRevive == false`.
    public static let gemini = ProviderConfig(
        id: "gemini",
        displayName: "Gemini",
        logoAssetName: "GeminiLogo",
        reviveModel: "",
        reviveEndpoint: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!,
        reviveAuthVersion: nil,
        storageKeyPrefix: "clawdmeter.gemini",
        supportsAutoRevive: AutoReviveSupport.supports("gemini"),
        // cloudcode-pa returns a single refreshTime per model — no weekly
        // bucket exists upstream. Dashboard column hides Weekly limits.
        hasWeeklyWindow: false
    )

    /// v0.28.0: Cursor backed by the api2.cursor.sh gRPC-Web endpoint.
    /// Auth via the cursor-agent CLI's keychain entries (`cursor-access-token`
    /// / `cursor-refresh-token`). No reviveModel — Cursor's billing period
    /// is monthly (not a perpetual 5h rolling window) so AutoReviver
    /// keep-warm doesn't apply. Dashboard column hides Weekly limits in
    /// favor of the single billing-period bucket.
    public static let cursor = ProviderConfig(
        id: "cursor",
        displayName: "Cursor",
        logoAssetName: "CursorLogo",
        reviveModel: "",
        reviveEndpoint: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
        reviveAuthVersion: nil,
        storageKeyPrefix: "clawdmeter.cursor",
        supportsAutoRevive: AutoReviveSupport.supports("cursor"),
        hasWeeklyWindow: false
    )

    /// Grok is a first-class chat/analytics provider. Its live Usage tab /
    /// menu-bar percentage comes from the Grok CLI's `/usage show` credits
    /// readout, while token analytics still come from Continuum-captured
    /// harness history.
    public static let grok = ProviderConfig(
        id: "grok",
        displayName: "Grok",
        logoAssetName: "GrokLogo",
        reviveModel: "",
        reviveEndpoint: URL(string: "https://grok.com")!,
        reviveAuthVersion: nil,
        storageKeyPrefix: "clawdmeter.grok",
        supportsAutoRevive: false,
        hasWeeklyWindow: false
    )
}
