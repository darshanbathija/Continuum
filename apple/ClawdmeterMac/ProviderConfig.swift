import Foundation
import SwiftUI
import ClawdmeterShared

/// Per-source UI + behavior config. One per provider (Claude, Codex, Gemini).
public struct ProviderConfig: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let logoAssetName: String            // Bundle resource name (e.g. "ClaudeLogo")
    public let reviveModel: String              // Model id used by AutoReviver for the "Hi" ping
    public let reviveEndpoint: URL              // POST target for AutoReviver
    public let reviveAuthVersion: String?       // e.g. "anthropic-version: 2023-06-01" (nil for OpenAI)
    public let storageKeyPrefix: String         // Namespacing for @AppStorage
    /// True when this provider supports the "perpetual 5h timer" auto-revive
    /// pattern (a 1-token "Hi" ping to extend the rate-limit window). Today
    /// only Claude supports this — Codex needs a streaming SSE protocol we
    /// haven't wired up, and Gemini's quota model isn't a 5h window we can
    /// extend with a free ping. Eliminates the `id == "claude"` hardcoded
    /// check at `DashboardView.swift` and `PopoverView.swift`.
    public let supportsAutoRevive: Bool

    public init(
        id: String,
        displayName: String,
        logoAssetName: String,
        reviveModel: String,
        reviveEndpoint: URL,
        reviveAuthVersion: String?,
        storageKeyPrefix: String,
        supportsAutoRevive: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.logoAssetName = logoAssetName
        self.reviveModel = reviveModel
        self.reviveEndpoint = reviveEndpoint
        self.reviveAuthVersion = reviveAuthVersion
        self.storageKeyPrefix = storageKeyPrefix
        self.supportsAutoRevive = supportsAutoRevive
    }

    public static let claude = ProviderConfig(
        id: "claude",
        displayName: "Claude",
        logoAssetName: "ClaudeLogo",
        reviveModel: "claude-haiku-4-5",
        reviveEndpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
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
        supportsAutoRevive: AutoReviveSupport.supports("gemini")
    )
}
